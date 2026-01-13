import Foundation
import SwiftUI
import WebKit
import Network

public enum HeliumFetchedConfigStatus: String, Codable, Equatable {
    case notDownloadedYet
    case inProgress
    case downloadSuccess
    case downloadFailure
}

enum PaywallsDownloadStep {
    case config
    case bundles
    case products
}

enum HeliumFetchResult {
    case success(HeliumFetchedConfig, HeliumFetchMetrics)
    case failure(errorMessage: String, HeliumFetchMetrics)
}

struct HeliumFetchMetrics {
    var numConfigAttempts: Int = 1
    var numBundleAttempts: Int = 0
    var configSuccess: Bool = true
    var numBundles: Int? = nil
    var numBundlesFromCache: Int? = nil
    var bundleFailCount: Int? = nil
    var configDownloadTimeMS: UInt64?
    var bundleDownloadTimeMS: UInt64?
    var localizedPriceTimeMS: UInt64?
    var localizedPriceSuccess: Bool? = nil
    var uncachedBundleSizeKB: Int? = nil
    var totalTimeMS: UInt64?
}

private struct BundlesRetrieveResult {
    let successMapBundleIdToHtml: [String : String]
    let triggersWithNoBundle: [String]
    let triggersWithSkippedBundleAndReason: [(trigger: String, reason: PaywallUnavailableReason)]
    let numBundles: Int
    let numBundlesFromCache: Int
    let numBundleAttempts: Int
}

private struct BundlesFetchResult {
    let successMapBundleIdToHtml: [String : String]
    let bundleUrlsFailedToFetched: [String]
    let bundleUrlsSkipped: [(url: String, reason: PaywallUnavailableReason)]
    var numBundleAttempts: Int? = nil
}

private struct SingleBundleFetchResult {
    let url: String
    let html: String?
    let isPermanentFailure: Bool
    let failureReason: PaywallUnavailableReason?
}

enum BundleFetchError: Error {
    case permanentFailure(PaywallUnavailableReason)
}

class NetworkReachability {
    static let shared = NetworkReachability()
    private let monitor = NWPathMonitor()
    private var isOnWiFiValue = false
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isOnWiFiValue = path.usesInterfaceType(.wifi)
        }
        monitor.start(queue: DispatchQueue.global())
    }
    
    var isOnWiFi: Bool {
        isOnWiFiValue
    }
    
    deinit {
        monitor.cancel()
    }
}

func fetchEndpoint(
    endpoint: String,
    params: [String: Any],
    timeoutInterval: TimeInterval? = nil
) async throws -> (HeliumFetchedConfig?, JSON?) {
    let urlString = endpoint
    guard let url = URL(string: urlString) else {
        throw URLError(.badURL)
    }
    
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 5
    let session = URLSession(configuration: config)
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("true", forHTTPHeaderField: "X-Helium-Skip-Bundles")
    
    request.timeoutInterval = timeoutInterval ?? 15
    
    let jsonData = try JSONSerialization.data(withJSONObject: params, options: [])
    request.httpBody = jsonData
    
    let (data, response) = try await session.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }
    
    let decodedResponse = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
    
    let json = try? JSON(data: data)
    return (decodedResponse, json)
}

public class HeliumFetchedConfigManager: ObservableObject {
    public static let shared = HeliumFetchedConfigManager()
    static func reset() {
        shared.fetchTask?.cancel()
        shared.fetchTask = nil
        Task { @MainActor in
            shared.downloadStatus = .notDownloadedYet
            shared.downloadStep = .config
        }
        shared.fetchedConfig = nil
        shared.fetchedConfigJSON = nil
        shared.triggersWithSkippedBundleAndReason = []
        shared.localizedPriceMap = [:]
    }
    
    private var fetchTask: Task<Void, Never>?
    
    @Published public var downloadStatus: HeliumFetchedConfigStatus
    private(set) var downloadStep: PaywallsDownloadStep = .config
    
    static let MAX_NUM_CONFIG_ATTEMPTS: Int = 6 // roughly 36 seconds of delays in between attempts
    static let MAX_NUM_BUNDLE_ATTEMPTS: Int = 5 // roughly 19 seconds of delays in between attempts
    
    private init() {
        downloadStatus = .notDownloadedYet
    }
    
    private(set) var fetchedConfig: HeliumFetchedConfig?
    private(set) var fetchedConfigJSON: JSON?
    private(set) var triggersWithSkippedBundleAndReason: [(trigger: String, reason: PaywallUnavailableReason)] = []
    @HeliumAtomic private var localizedPriceMap: [String: LocalizedPrice] = [:]
    
    func fetchConfig(
        endpoint: String,
        apiKey: String,
        completion: @escaping (HeliumFetchResult) -> Void
    ) {
        if downloadStatus == .inProgress {
            print("[Helium] Config download already in progress. Skipping new request.")
            return
        }
        let initializeStartTime = DispatchTime.now()
        fetchTask = Task {
            await updateDownloadState(.inProgress)
            downloadStep = .config

            // Try to ensure App Store country code is available. It should not take longer
            // than 5ms but do a short timeout to make sure we don't delay config fetch too long.
            let _ = await withTimeoutOrNil(milliseconds: 25) {
                await AppStoreCountryHelper.shared.fetchStoreCountryCode()
            }
            
            let params: [String: Any] = [
                "apiKey": apiKey,
                "userId": HeliumIdentityManager.shared.getUserId(),
                "userContext": HeliumIdentityManager.shared.getUserContext().asParams(),
                "existingBundleIds": HeliumAssetManager.shared.getExistingBundleIDs()
            ]
            
            let configStartTime = DispatchTime.now()
            await fetchConfigWithRetry(
                endpoint: endpoint,
                params: params,
                maxAttempts: HeliumFetchedConfigManager.MAX_NUM_CONFIG_ATTEMPTS,
                attemptCounter: 1,
                initializeStartTime: initializeStartTime,
                configStartTime: configStartTime,
                completion: completion
            )
        }
    }
    
    private func fetchConfigWithRetry(
        endpoint: String,
        params: [String: Any],
        maxAttempts: Int,
        attemptCounter: Int,
        initializeStartTime: DispatchTime,
        configStartTime: DispatchTime,
        completion: @escaping (HeliumFetchResult) -> Void
    ) async {
        do {
            // Increase timeout if on last attempt
            let timeoutInterval: TimeInterval? = attemptCounter == maxAttempts ? 30 : nil
            let response = try await fetchEndpoint(endpoint: endpoint, params: params, timeoutInterval: timeoutInterval)
            
            // Ensure we have data
            guard let newConfig = response.0, let newConfigJSON = response.1 else {
                if attemptCounter < maxAttempts {
                    let delaySeconds = calculateBackoffDelay(attempt: attemptCounter)
                    print("[Helium] Fetch failed on attempt \(attemptCounter) (no data), retrying in \(delaySeconds) seconds...")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    await fetchConfigWithRetry(
                        endpoint: endpoint,
                        params: params,
                        maxAttempts: maxAttempts,
                        attemptCounter: attemptCounter + 1,
                        initializeStartTime: initializeStartTime,
                        configStartTime: configStartTime,
                        completion: completion
                    )
                } else {
                    let totalTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
                    await self.updateDownloadState(.downloadFailure)
                    completion(.failure(
                        errorMessage: "Reached max retries for config.",
                        HeliumFetchMetrics(
                            numConfigAttempts: attemptCounter,
                            numBundleAttempts: 0,
                            configSuccess: false,
                            configDownloadTimeMS: totalTimeMS,
                            totalTimeMS: totalTimeMS
                        )
                    ))
                }
                return
            }
            let configDownloadTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
            
            // Update the fetched config
            guard !Task.isCancelled else { return }
            self.fetchedConfig = newConfig
            self.fetchedConfigJSON = newConfigJSON
            triggersWithSkippedBundleAndReason = []
            
            // Download assets
            
            if (self.fetchedConfig?.bundles != nil && self.fetchedConfig?.bundles?.count ?? 0 > 0) {
                // Start price fetch async (with timing), then do sync bundle save, then await price
                async let priceTask: UInt64 = {
                    let start = DispatchTime.now()
                    await self.buildLocalizedPriceMap(config: newConfig)
                    return dispatchTimeDifferenceInMS(from: start)
                }()

                let bundles = (self.fetchedConfig?.bundles)!
                let bytesWritten = saveBundleAssets(bundles: bundles)
                let sizeKB = Int(round(Double(bytesWritten) / 1024.0))

                // Bundles saved, switch to products step
                downloadStep = .products

                let localizedPriceTimeMS = await priceTask
                let totalTimeMS = dispatchTimeDifferenceInMS(from: initializeStartTime)

                let metrics = HeliumFetchMetrics(
                    numConfigAttempts: attemptCounter,
                    numBundles: fetchedConfig?.bundles?.count ?? 0,
                    numBundlesFromCache: 0,
                    bundleFailCount: 0,
                    configDownloadTimeMS: configDownloadTimeMS,
                    localizedPriceTimeMS: localizedPriceTimeMS,
                    localizedPriceSuccess: !localizedPriceMap.isEmpty,
                    uncachedBundleSizeKB: sizeKB,
                    totalTimeMS: totalTimeMS
                )
                await handleConfigFetchSuccess(
                    newConfig: newConfig,
                    metrics: metrics,
                    completion: completion
                )
            } else {
                downloadStep = .bundles
                
                // Start both operations in parallel, each tracking its own time
                async let bundlesTask: (BundlesRetrieveResult, UInt64) = {
                    let start = DispatchTime.now()
                    let result = await retrieveBundles(config: newConfig)
                    let timeMS = dispatchTimeDifferenceInMS(from: start)
                    // Bundles are fetched, switch to products step
                    downloadStep = .products
                    return (result, timeMS)
                }()
                
                async let priceTask: UInt64 = {
                    let start = DispatchTime.now()
                    await buildLocalizedPriceMap(config: newConfig)
                    return dispatchTimeDifferenceInMS(from: start)
                }()
                
                // Wait for both to complete
                let (bundlesResult, bundleDownloadTimeMS) = await bundlesTask
                let localizedPriceTimeMS = await priceTask
                
                let bundles = bundlesResult.successMapBundleIdToHtml
                guard !Task.isCancelled else { return }
                fetchedConfig?.bundles = bundles
                let bytesWritten = saveBundleAssets(bundles: bundles)
                let sizeKB = Int(round(Double(bytesWritten) / 1024.0))
                
                triggersWithSkippedBundleAndReason = bundlesResult.triggersWithSkippedBundleAndReason
                
                let totalTimeMS = dispatchTimeDifferenceInMS(from: initializeStartTime)
                
                if !bundlesResult.triggersWithNoBundle.isEmpty {
                    await self.updateDownloadState(.downloadFailure)
                    completion(.failure(
                        errorMessage: "Failed to fetch bundles for \(bundlesResult.triggersWithNoBundle.count) trigger(s)",
                        HeliumFetchMetrics(
                            numConfigAttempts: attemptCounter,
                            numBundleAttempts: bundlesResult.numBundleAttempts,
                            configSuccess: true,
                            numBundles: bundlesResult.numBundles,
                            bundleFailCount: bundlesResult.triggersWithNoBundle.count,
                            configDownloadTimeMS: configDownloadTimeMS,
                            bundleDownloadTimeMS: bundleDownloadTimeMS,
                            totalTimeMS: totalTimeMS
                        )
                    ))
                } else {
                    let metrics = HeliumFetchMetrics(
                        numConfigAttempts: attemptCounter,
                        numBundleAttempts: bundlesResult.numBundleAttempts,
                        numBundles: bundlesResult.numBundles,
                        numBundlesFromCache: bundlesResult.numBundlesFromCache,
                        bundleFailCount: 0,
                        configDownloadTimeMS: configDownloadTimeMS,
                        bundleDownloadTimeMS: bundleDownloadTimeMS,
                        localizedPriceTimeMS: localizedPriceTimeMS,
                        localizedPriceSuccess: !localizedPriceMap.isEmpty,
                        uncachedBundleSizeKB: sizeKB,
                        totalTimeMS: totalTimeMS
                    )
                    await handleConfigFetchSuccess(
                        newConfig: newConfig,
                        metrics: metrics,
                        completion: completion
                    )
                }
            }
        } catch {
            // Retry on network/fetch failure
            if attemptCounter < maxAttempts {
                let delaySeconds = calculateBackoffDelay(attempt: attemptCounter)
                print("[Helium] Fetch failed on attempt \(attemptCounter), retrying in \(delaySeconds) seconds...")
                
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                
                await fetchConfigWithRetry(
                    endpoint: endpoint,
                    params: params,
                    maxAttempts: maxAttempts,
                    attemptCounter: attemptCounter + 1,
                    initializeStartTime: initializeStartTime,
                    configStartTime: configStartTime,
                    completion: completion
                )
            } else {
                await self.updateDownloadState(.downloadFailure)
                let totalTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
                completion(.failure(
                    errorMessage: error.localizedDescription,
                    HeliumFetchMetrics(
                        numConfigAttempts: attemptCounter,
                        numBundleAttempts: 0,
                        configSuccess: false,
                        configDownloadTimeMS: totalTimeMS,
                        totalTimeMS: totalTimeMS
                    )
                ))
            }
        }
    }
    
    private func calculateBackoffDelay(attempt: Int) -> Double {
        // Simple exponential backoff
        let retryNumber = attempt - 1
        guard retryNumber >= 0 else {
            return 5.0
        }
        return pow(2.0, Double(retryNumber))
    }
    
    private func saveBundleAssets(bundles: [String: String]) -> Int {
        return HeliumAssetManager.shared.writeBundles(bundles: bundles)
    }
    
    private func retrieveBundles(config: HeliumFetchedConfig) async -> BundlesRetrieveResult {
        if config.triggerToPaywalls.isEmpty {
            // this will be treated as a success... assumes no workflows are set up
            return BundlesRetrieveResult(
                successMapBundleIdToHtml: [:],
                triggersWithNoBundle: [],
                triggersWithSkippedBundleAndReason: [],
                numBundles: 0,
                numBundlesFromCache: 0,
                numBundleAttempts: 0
            )
        }
        
        var bundleUrlToTriggersMap: [String : [String]] = [:]
        var triggersWithNoBundle: [String] = []
        var triggersWithSkippedBundle: [(trigger: String, reason: PaywallUnavailableReason)] = []

        let cachedBundleIDs = HeliumAssetManager.shared.getExistingBundleIDs()
        var cachedBundleIdToHtmlMap: [String : String] = [:]
        
        for (trigger, paywallInfo) in config.triggerToPaywalls {
            if let bundleUrl = paywallInfo.extractedBundleUrl {
                let bundleId = HeliumAssetManager.shared.getBundleIdFromURL(bundleUrl) ?? ""
                if cachedBundleIDs.contains(bundleId) {
                    // No need to fetch if already cached. Note that every time paywall is saved it will get new
                    // bundle url/id, so won't miss out on new changes by having this check.
                    // But read the html just to keep config.bundles value in sync
                    if let cachedUrl = HeliumAssetManager.shared.localPathForURL(bundleURL: bundleUrl),
                       let cachedHtml = try? String(contentsOf: URL(fileURLWithPath: cachedUrl), encoding: .utf8) {
                        cachedBundleIdToHtmlMap[bundleId] = cachedHtml
                        continue
                    } else {
                        // Something is wrong with the cached file, fetch it again
                    }
                }
                
                // Validate URL before processing - skip silently if invalid (don't fail entire download)
                guard isValidURL(bundleUrl) else {
                    print("[Helium] Invalid URL format for trigger \(trigger): \(bundleUrl)")
                    triggersWithSkippedBundle.append((trigger, .bundleFetchInvalidUrlDetected))
                    continue
                }

                if bundleUrlToTriggersMap[bundleUrl] == nil {
                    bundleUrlToTriggersMap[bundleUrl] = []
                }
                bundleUrlToTriggersMap[bundleUrl]?.append(trigger)
            } else {
                triggersWithNoBundle.append(trigger)
            }
        }
        
        let fetchResult = await retrieveBundlesWithRetry(
            bundleUrlToTriggersMap: bundleUrlToTriggersMap,
            maxAttempts: HeliumFetchedConfigManager.MAX_NUM_BUNDLE_ATTEMPTS,
            attemptCounter: 1
        )
        let additionalTriggersNotFetchedFor = fetchResult.bundleUrlsFailedToFetched.flatMap {
            bundleUrlToTriggersMap[$0] ?? []
        }
        let additionalTriggersWithSkippedBundle = fetchResult.bundleUrlsSkipped.flatMap { urlAndReason in
            (bundleUrlToTriggersMap[urlAndReason.url] ?? []).map { ($0, urlAndReason.reason) }
        }
        
        let finalResult = fetchResult.successMapBundleIdToHtml.merging(cachedBundleIdToHtmlMap) { lhs, rhs in lhs }
        return BundlesRetrieveResult(
            successMapBundleIdToHtml: finalResult,
            triggersWithNoBundle: triggersWithNoBundle + additionalTriggersNotFetchedFor,
            triggersWithSkippedBundleAndReason: triggersWithSkippedBundle + additionalTriggersWithSkippedBundle,
            numBundles: bundleUrlToTriggersMap.count + cachedBundleIdToHtmlMap.count,
            numBundlesFromCache: cachedBundleIdToHtmlMap.count,
            numBundleAttempts: fetchResult.numBundleAttempts ?? 0
        )
    }
    
    private func retrieveBundlesWithRetry(
        bundleUrlToTriggersMap: [String : [String]],
        maxAttempts: Int,
        attemptCounter: Int
    ) async -> BundlesFetchResult {
        // Increase timeout if on last attempt
        let timeoutInterval: TimeInterval? = attemptCounter == maxAttempts ? 12 : nil
        let result = await fetchBundles(bundleUrlToTriggersMap: bundleUrlToTriggersMap, timeoutInterval: timeoutInterval)
        
        if !result.bundleUrlsFailedToFetched.isEmpty {
            let missingTriggers = result.bundleUrlsFailedToFetched.flatMap {
                bundleUrlToTriggersMap[$0] ?? []
            }
            print("[Helium] Failed to fetch bundles for triggers \(missingTriggers)")
            if attemptCounter < maxAttempts {
                let delaySeconds = calculateBackoffDelay(attempt: attemptCounter)
                print("[Helium] Bundles fetch incomplete on attempt \(attemptCounter), retrying in \(delaySeconds) seconds...")
                
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                
                let retryMap = bundleUrlToTriggersMap.filter { result.bundleUrlsFailedToFetched.contains($0.key) }
                let retryResult = await retrieveBundlesWithRetry(
                    bundleUrlToTriggersMap: retryMap,
                    maxAttempts: maxAttempts,
                    attemptCounter: attemptCounter + 1
                )
                let fullSuccessMap = result.successMapBundleIdToHtml.merging(retryResult.successMapBundleIdToHtml, uniquingKeysWith: { lhs, rhs in lhs })
                return BundlesFetchResult(
                    successMapBundleIdToHtml: fullSuccessMap,
                    bundleUrlsFailedToFetched: retryResult.bundleUrlsFailedToFetched,
                    bundleUrlsSkipped: result.bundleUrlsSkipped + retryResult.bundleUrlsSkipped,
                    numBundleAttempts: retryResult.numBundleAttempts
                )
            } else {
                return BundlesFetchResult(
                    successMapBundleIdToHtml: result.successMapBundleIdToHtml,
                    bundleUrlsFailedToFetched: result.bundleUrlsFailedToFetched,
                    bundleUrlsSkipped: result.bundleUrlsSkipped,
                    numBundleAttempts: attemptCounter
                )
            }
        } else {
            return BundlesFetchResult(
                successMapBundleIdToHtml: result.successMapBundleIdToHtml,
                bundleUrlsFailedToFetched: result.bundleUrlsFailedToFetched,
                bundleUrlsSkipped: result.bundleUrlsSkipped,
                numBundleAttempts: attemptCounter
            )
        }
    }
    
    private func fetchBundles(
        bundleUrlToTriggersMap: [String : [String]],
        timeoutInterval: TimeInterval? = nil
    ) async -> BundlesFetchResult {
        var bundleUrlsNotFetched: [String] = []
        var bundleUrlsSkipped: [(String, PaywallUnavailableReason)] = []

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpMaximumConnectionsPerHost = 15
        let session = URLSession(configuration: sessionConfig)

        // Fetch all URLs concurrently and collect results
        var results: [String: String] = [:]

        await withTaskGroup(of: SingleBundleFetchResult.self) { group in
            for (url, triggers) in bundleUrlToTriggersMap {
                group.addTask {
                    do {
                        let html = try await self.fetchBundleHTML(from: url, using: session, timeoutInterval: timeoutInterval)
                        return SingleBundleFetchResult(url: url, html: html, isPermanentFailure: false, failureReason: nil)
                    } catch {
                        if case let BundleFetchError.permanentFailure(reason) = error {
                            print("[Helium] Permanent failure for triggers \(triggers): \(reason.rawValue)")
                            return SingleBundleFetchResult(url: url, html: nil, isPermanentFailure: true, failureReason: reason)
                        } else {
                            return SingleBundleFetchResult(url: url, html: nil, isPermanentFailure: false, failureReason: nil)
                        }
                    }
                }
            }

            for await result in group {
                if let html = result.html,
                   let bundleId = HeliumAssetManager.shared.getBundleIdFromURL(result.url) {
                    // bundleId should NOT be nil
                    results[bundleId] = html
                } else {
                    if result.isPermanentFailure {
                        if let reason = result.failureReason {
                            bundleUrlsSkipped.append((result.url, reason))
                        }
                    } else {
                        bundleUrlsNotFetched.append(result.url)
                    }
                }
            }
        }

        return BundlesFetchResult(
            successMapBundleIdToHtml: results,
            bundleUrlsFailedToFetched: bundleUrlsNotFetched,
            bundleUrlsSkipped: bundleUrlsSkipped
        )
    }

    private func fetchBundleHTML(
        from urlString: String,
        using session: URLSession,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw BundleFetchError.permanentFailure(.bundleFetchInvalidUrl)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval ?? 5

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let statusCode = httpResponse.statusCode

        // Check if response is successful
        guard (200...299).contains(statusCode) else {
            // Treat specific client errors as permanent failures (non-retryable)
            // 403 = Forbidden, 404 = Not Found, 410 = Gone (permanently deleted)
            if statusCode == 403 {
                print("[Helium] Non-retryable HTTP error \(statusCode) for URL: \(urlString)")
                throw BundleFetchError.permanentFailure(.bundleFetch403)
            } else if statusCode == 404 {
                print("[Helium] Non-retryable HTTP error \(statusCode) for URL: \(urlString)")
                throw BundleFetchError.permanentFailure(.bundleFetch404)
            } else if statusCode == 410 {
                print("[Helium] Non-retryable HTTP error \(statusCode) for URL: \(urlString)")
                throw BundleFetchError.permanentFailure(.bundleFetch410)
            }
            // All other errors (5xx server errors, etc.) are retryable
            throw URLError(.badServerResponse)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw BundleFetchError.permanentFailure(.bundleFetchCannotDecodeContent)
        }

        return html
    }
    
    private func handleConfigFetchSuccess(
        newConfig: HeliumFetchedConfig,
        metrics: HeliumFetchMetrics,
        completion: @escaping (HeliumFetchResult) -> Void
    ) async {
        await updateDownloadState(.downloadSuccess)
        completion(.success(newConfig, metrics))
    }
    
    private func getAllProductIds(config: HeliumFetchedConfig?) -> [String] {
        // Get all unique product IDs from all paywalls
        var allProductIds: [String] = []
        if let config {
            for paywall in config.triggerToPaywalls.values {
                allProductIds.append(contentsOf: paywall.productsOffered)
            }
        }
        return Array(Set(allProductIds))
    }
    
    func buildLocalizedPriceMap(config: HeliumFetchedConfig?) async {
        let productIds = getAllProductIds(config: config)
        await buildLocalizedPriceMap(productIds)
    }
    
    func buildLocalizedPriceMap(_ productIds: [String]) async {
        if !productIds.isEmpty {
            let newProductToPriceMap = await PriceFetcher.localizedPricing(for: productIds)

            // Merge the new prices into the existing map; atomic read-modify-write using withValue
            _localizedPriceMap.withValue { map in
                map.merge(newProductToPriceMap) { _, new in new }
            }
        }
    }
    
    func refreshLocalizedPriceMap() async {
        let productIds = Array(localizedPriceMap.keys)
        await buildLocalizedPriceMap(productIds)
    }
    
    // NOTE - be careful about removing the public declaration here because this is in use
    // by some sdk integrations.
    public func getLocalizedPriceMap() -> [String: LocalizedPrice] {
        return localizedPriceMap
    }
    
    /// Get localized prices filtered by a specific trigger's product IDs
    /// - Parameter triggerName: The trigger name to get products for
    /// - Returns: Dictionary containing only prices for products in the specified trigger
    public func getLocalizedPriceMapForTrigger(_ triggerName: String?) -> [String: LocalizedPrice] {
        guard let triggerName = triggerName,
                let productIDs = getProductIDsForTrigger(triggerName) else {
            return [:]
        }
        
        return localizedPriceMap.filter { productIDs.contains($0.key) }
    }
    
    @MainActor private func updateDownloadState(_ status: HeliumFetchedConfigStatus) {
        guard !Task.isCancelled else { return }
        self.downloadStatus = status
    }
    
    public func getConfig() -> HeliumFetchedConfig? {
        return fetchedConfig
    }
    
    func hasBundles() -> Bool {
        return fetchedConfig?.bundles?.count ?? 0 > 0
    }
    
    public func getConfigId() -> UUID? {
        return fetchedConfig?.fetchedConfigID
    }
    
    public func getPaywallInfoForTrigger(_ trigger: String) -> HeliumPaywallInfo? {
        return fetchedConfig?.triggerToPaywalls[trigger]
    }
    
    /// Extract experiment info for a specific trigger
    /// - Parameter trigger: The trigger name to extract experiment info for
    /// - Returns: ExperimentInfo if experiment data is available
    public func extractExperimentInfo(trigger: String) -> ExperimentInfo? {
        return fetchedConfig?.extractExperimentInfo(trigger: trigger)
    }
    
    // Be careful with this as there can be multiple triggers using the same paywall (and associated uuid.)
    func getTriggerFromPaywallUuid(_ uuid: String) -> String? {
        return fetchedConfig?.triggerToPaywalls
            .first { $1.paywallUUID == uuid }?.key
    }
    
    public func getOrganizationID() -> String? {
        return fetchedConfig?.organizationID;
    }
    
    func getResolvedConfigJSONForTrigger(_ trigger: String) -> JSON? {
        return fetchedConfigJSON?["triggerToPaywalls"][trigger]["resolvedConfig"]
    }
    
    public func getExperimentIDForTrigger(_ trigger: String) -> String? {
        return fetchedConfig?.triggerToPaywalls[trigger]?.experimentID;
    }
    
    public func getModelIDForTrigger(_ trigger: String) -> String? {
        return fetchedConfig?.triggerToPaywalls[trigger]?.modelID;
    }
    
    public func getProductIDsForTrigger(_ trigger: String) -> [String]? {
        return fetchedConfig?.triggerToPaywalls[trigger]?.productsOffered;
    }
    
    public func getFetchedTriggerNames() -> [String] {
        if (fetchedConfig == nil || fetchedConfig?.triggerToPaywalls == nil) {
            return []
        }
        return Array(fetchedConfig!.triggerToPaywalls.keys);
    }
    
    public func getClientName() -> String? {
        return fetchedConfig?.orgName
    }
    
    public func isValidURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return false
        }
        return true
    }
}

enum FetchError: LocalizedError {
    case couldNotFetchForAllTriggers
    
    public var errorDescription: String? {
        switch self {
        case .couldNotFetchForAllTriggers:
            return "Failed to fetch bundles for all triggers."
        }
    }
}

/// Executes an async operation with a timeout, returning nil if the timeout is exceeded
func withTimeoutOrNil<T>(milliseconds: UInt64, operation: @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            return nil
        }
        let result = await group.next()
        group.cancelAll()
        return result ?? nil
    }
}
