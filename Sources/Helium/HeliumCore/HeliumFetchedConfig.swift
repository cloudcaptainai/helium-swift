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

enum HeliumFetchResult {
    case success(HeliumFetchedConfig, HeliumFetchMetrics)
    case failure(errorMessage: String, HeliumFetchMetrics)
}

struct HeliumFetchMetrics {
    var numConfigAttempts: Int = 1
    var numBundleAttempts: Int = 0
    var configSuccess: Bool = true
    var numBundles: Int = 0
    var bundleFailCount: Int = 0
    var configDownloadTimeMS: UInt64?
    var bundleDownloadTimeMS: UInt64?
    var localizedPriceTimeMS: UInt64?
}

private struct BundlesRetrieveResult {
    let successMapBundleIdToHtml: [String : String]
    let triggersWithNoBundle: [String]
    let numBundles: Int
    let numBundleAttempts: Int
}

private struct BundlesFetchResult {
    let successMapBundleIdToHtml: [String : String]
    let bundleUrlsNotFetched: [String]
    var numBundleAttempts: Int? = nil
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
    params: [String: Any]
) async throws -> (HeliumFetchedConfig?, JSON?) {
    let urlString = endpoint
    guard let url = URL(string: urlString) else {
        throw URLError(.badURL)
    }
    
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 5
    let session = URLSession(configuration: config)
    
    // todo pass in new header or param to indicate self-fetch for bundles
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
    
    request.timeoutInterval = 15
    
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
    @Published public var downloadStatus: HeliumFetchedConfigStatus
    
    static let MAX_NUM_CONFIG_RETRIES: Int = 5
    static let MAX_NUM_BUNDLE_RETRIES: Int = 2
    
    private init() {
        downloadStatus = .notDownloadedYet
    }
    
    private(set) var fetchedConfig: HeliumFetchedConfig?
    private(set) var fetchedConfigJSON: JSON?
    private(set) var localizedPriceMap: [String: LocalizedPrice] = [:]
    
    func fetchConfig(
        endpoint: String,
        params: [String: Any],
        completion: @escaping (HeliumFetchResult) -> Void
    ) {
        Task {
            await updateDownloadState(.inProgress)
            
            let configStartTime = DispatchTime.now()
            await fetchConfigWithRetry(
                endpoint: endpoint,
                params: params,
                maxRetries: HeliumFetchedConfigManager.MAX_NUM_CONFIG_RETRIES,
                retryCount: 0,
                configStartTime: configStartTime,
                completion: completion
            )
        }
    }
    
    private func fetchConfigWithRetry(
        endpoint: String,
        params: [String: Any],
        maxRetries: Int,
        retryCount: Int,
        configStartTime: DispatchTime,
        completion: @escaping (HeliumFetchResult) -> Void
    ) async {
        do {
            // Make the request asynchronously
            let response = try await fetchEndpoint(endpoint: endpoint, params: params)
            
            // Ensure we have data
            guard let newConfig = response.0, let newConfigJSON = response.1 else {
                if retryCount < maxRetries {
                    let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                    print("[Helium] Fetch failed on attempt \(retryCount + 1) (no data), retrying in \(delaySeconds) seconds...")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    await fetchConfigWithRetry(
                        endpoint: endpoint,
                        params: params,
                        maxRetries: maxRetries,
                        retryCount: retryCount + 1,
                        configStartTime: configStartTime,
                        completion: completion
                    )
                } else {
                    let configDownloadTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
                    await self.updateDownloadState(.downloadFailure)
                    completion(.failure(
                        errorMessage: "Reached max retries for config.",
                        HeliumFetchMetrics(
                            numConfigAttempts: retryCount + 1,
                            numBundleAttempts: 0,
                            configSuccess: false,
                            numBundles: 0,
                            bundleFailCount: 0,
                            configDownloadTimeMS: configDownloadTimeMS
                        )
                    ))
                }
                return
            }
            let configDownloadTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
            
            // Update the fetched config
            self.fetchedConfig = newConfig
            self.fetchedConfigJSON = newConfigJSON
            
            // Download assets
            
            if (self.fetchedConfig?.bundles != nil && self.fetchedConfig?.bundles?.count ?? 0 > 0) {
                do {
                    let bundles = (self.fetchedConfig?.bundles)!
                    
                    try HeliumAssetManager.shared.writeBundles(bundles: bundles)
                    
                    await handleConfigFetchSuccess(
                        newConfig: newConfig,
                        retryCount: retryCount,
                        configDownloadTimeMS: configDownloadTimeMS,
                        bundleDownloadTimeMS: nil,
                        numBundles: fetchedConfig?.bundles?.count ?? 0,
                        bundleFailCount: 0,
                        numBundleAttempts: 0,
                        completion: completion
                    )
                } catch {
                    // Retry on asset processing failure
                    if retryCount < maxRetries {
                        let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                        print("[Helium] Asset processing failed on attempt \(retryCount + 1), retrying in \(delaySeconds) seconds...")
                        
                        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        
                        await fetchConfigWithRetry(
                            endpoint: endpoint,
                            params: params,
                            maxRetries: maxRetries,
                            retryCount: retryCount + 1,
                            configStartTime: configStartTime,
                            completion: completion
                        )
                    } else {
                        await self.updateDownloadState(.downloadFailure)
                        let configTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
                        completion(.failure(
                            errorMessage: error.localizedDescription,
                            HeliumFetchMetrics(
                                numConfigAttempts: retryCount + 1,
                                numBundleAttempts: 0,
                                configSuccess: true,
                                numBundles: 0,
                                bundleFailCount: 0,
                                configDownloadTimeMS: configTimeMS
                            )
                        ))
                    }
                    return
                }
            } else {
                let bundleStartTime = DispatchTime.now()
                let bundlesResult = await retrieveBundles(config: newConfig)
                let bundleDownloadTimeMS = dispatchTimeDifferenceInMS(from: bundleStartTime)
                
                // todo write assets!!!!
                
                fetchedConfig?.bundles = bundlesResult.successMapBundleIdToHtml
                if !bundlesResult.triggersWithNoBundle.isEmpty {
                    await self.updateDownloadState(.downloadFailure)
                    completion(.failure(
                        errorMessage: "Failed to fetch bundles for \(bundlesResult.triggersWithNoBundle.count) trigger(s)",
                        HeliumFetchMetrics(
                            numConfigAttempts: retryCount + 1,
                            numBundleAttempts: bundlesResult.numBundleAttempts,
                            configSuccess: true,
                            numBundles: bundlesResult.numBundles,
                            bundleFailCount: bundlesResult.triggersWithNoBundle.count,
                            configDownloadTimeMS: configDownloadTimeMS,
                            bundleDownloadTimeMS: bundleDownloadTimeMS
                        )
                    ))
                } else {
                    await handleConfigFetchSuccess(
                        newConfig: newConfig,
                        retryCount: retryCount,
                        configDownloadTimeMS: configDownloadTimeMS,
                        bundleDownloadTimeMS: bundleDownloadTimeMS,
                        numBundles: bundlesResult.numBundles,
                        bundleFailCount: 0,
                        numBundleAttempts: bundlesResult.numBundleAttempts,
                        completion: completion
                    )
                }
            }
        } catch {
            // Retry on network/fetch failure
            if retryCount < maxRetries {
                let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                print("[Helium] Fetch failed on attempt \(retryCount + 1), retrying in \(delaySeconds) seconds...")
                
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                
                await fetchConfigWithRetry(
                    endpoint: endpoint,
                    params: params,
                    maxRetries: maxRetries,
                    retryCount: retryCount + 1,
                    configStartTime: configStartTime,
                    completion: completion
                )
            } else {
                await self.updateDownloadState(.downloadFailure)
                let configTimeMS = dispatchTimeDifferenceInMS(from: configStartTime)
                completion(.failure(
                    errorMessage: error.localizedDescription,
                    HeliumFetchMetrics(
                    numConfigAttempts: retryCount + 1,
                    numBundleAttempts: 0,
                    configSuccess: false,
                    numBundles: 0,
                    bundleFailCount: 0,
                    configDownloadTimeMS: configTimeMS
                    )
                ))
            }
        }
    }
    
    private func calculateBackoffDelay(attempt: Int) -> Double {
        // Simple exponential backoff: 2^attempt seconds
        return pow(2.0, Double(attempt))
    }
    
    private func retrieveBundles(config: HeliumFetchedConfig) async -> BundlesRetrieveResult {
        var bundleUrlToTriggersMap: [String : [String]] = [:]
        var triggersWithNoBundle: [String] = []

        for (trigger, paywallInfo) in config.triggerToPaywalls {
            var bundleUrl: String? = paywallInfo.additionalPaywallFields?["paywallBundleUrl"].string
            if bundleUrl == nil || bundleUrl == "" {
                let resolvedConfig = getResolvedConfigJSONForTrigger(trigger)
                if let resolvedConfig {
                    if resolvedConfig["baseStack"].exists(),
                       resolvedConfig["baseStack"]["componentProps"].exists() {
                        bundleUrl = resolvedConfig["baseStack"]["componentProps"]["bundleURL"].stringValue
                    }
                }
            }
            if let bundleUrl, !bundleUrl.isEmpty {
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
            maxRetries: HeliumFetchedConfigManager.MAX_NUM_BUNDLE_RETRIES,
            retryCount: 0
        )
        let additionalTriggersNotFetchedFor = fetchResult.bundleUrlsNotFetched.flatMap {
            bundleUrlToTriggersMap[$0] ?? []
        }
        return BundlesRetrieveResult(
            successMapBundleIdToHtml: fetchResult.successMapBundleIdToHtml,
            triggersWithNoBundle: triggersWithNoBundle + additionalTriggersNotFetchedFor,
            numBundles: bundleUrlToTriggersMap.count,
            numBundleAttempts: fetchResult.numBundleAttempts ?? 0
        )
    }
    
    private func retrieveBundlesWithRetry(
        bundleUrlToTriggersMap: [String : [String]],
        maxRetries: Int,
        retryCount: Int
    ) async -> BundlesFetchResult {
        let result = await fetchBundles(bundleUrlToTriggersMap: bundleUrlToTriggersMap, maxRetries: maxRetries, retryCount: retryCount)
        
        if !result.bundleUrlsNotFetched.isEmpty {
            let missingTriggers = result.bundleUrlsNotFetched.flatMap {
                bundleUrlToTriggersMap[$0] ?? []
            }
            print("[Helium] Failed to fetch bundles for triggers \(missingTriggers)")
            if retryCount < maxRetries {
                let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                print("[Helium] Bundles fetch incomplete on attempt \(retryCount + 1), retrying in \(delaySeconds) seconds...")
                
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                
                let retryMap = bundleUrlToTriggersMap.filter { result.bundleUrlsNotFetched.contains($0.key) }
                let retryResult = await retrieveBundlesWithRetry(
                    bundleUrlToTriggersMap: retryMap,
                    maxRetries: maxRetries,
                    retryCount: retryCount + 1
                )
                var fullSuccessMap = result.successMapBundleIdToHtml
                fullSuccessMap.merge(retryResult.successMapBundleIdToHtml, uniquingKeysWith: { lhs, rhs in lhs })
                return BundlesFetchResult(
                    successMapBundleIdToHtml: fullSuccessMap,
                    bundleUrlsNotFetched: retryResult.bundleUrlsNotFetched,
                    numBundleAttempts: retryResult.numBundleAttempts
                )
            } else {
                return BundlesFetchResult(
                    successMapBundleIdToHtml: result.successMapBundleIdToHtml,
                    bundleUrlsNotFetched: result.bundleUrlsNotFetched,
                    numBundleAttempts: retryCount + 1
                )
            }
        } else {
            return BundlesFetchResult(
                successMapBundleIdToHtml: result.successMapBundleIdToHtml,
                bundleUrlsNotFetched: result.bundleUrlsNotFetched,
                numBundleAttempts: retryCount + 1
            )
        }
    }
    
    private func fetchBundles(
        bundleUrlToTriggersMap: [String : [String]],
        maxRetries: Int,
        retryCount: Int,
    ) async -> BundlesFetchResult {
        var bundleUrlsNotFetched: [String] = []

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpMaximumConnectionsPerHost = 15
        let session = URLSession(configuration: sessionConfig)

        // Fetch all URLs concurrently and collect results
        var results: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            for (url, _) in bundleUrlToTriggersMap {
                group.addTask {
                    do {
                        let html = try await self.fetchBundleHTML(from: url, using: session)
                        return (url, html)
                    } catch {
                        if let urlError = error as? URLError, urlError.code == .badURL {
                            // don't retry if bad url
                        } else {
                            bundleUrlsNotFetched.append(url)
                        }
                        return (url, nil)
                    }
                }
            }

            // Collect results using bundleId as key
            for await (url, html) in group {
                if let html,
                   let bundleId = HeliumAssetManager.shared.getBundleIdFromURL(url) { // bundleId should NOT be nil
                    results[bundleId] = html
                }
            }
        }

        return BundlesFetchResult(
            successMapBundleIdToHtml: results,
            bundleUrlsNotFetched: bundleUrlsNotFetched
        )
    }

    private func fetchBundleHTML(from urlString: String, using session: URLSession) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return html
    }
    
    private func handleConfigFetchSuccess(
        newConfig: HeliumFetchedConfig,
        retryCount: Int,
        configDownloadTimeMS: UInt64?,
        bundleDownloadTimeMS: UInt64?,
        numBundles: Int,
        bundleFailCount: Int,
        numBundleAttempts: Int,
        completion: @escaping (HeliumFetchResult) -> Void
    ) async {
        let numRequestsTaken = retryCount + 1
        
        // Prefetch products and build localized price map
        let localizedPricesStartTime = DispatchTime.now()
        let allProductIds = getAllProductIds()
        if #available(iOS 15.0, *) {
            await ProductsCache.shared.prefetchProducts(Array(allProductIds))
        }
        await buildLocalizedPriceMap(allProductIds)
        let localizedPriceTimeMS = dispatchTimeDifferenceInMS(from: localizedPricesStartTime)
        
        await updateDownloadState(.downloadSuccess)
        completion(.success(newConfig, HeliumFetchMetrics(
            numConfigAttempts: numRequestsTaken,
            numBundleAttempts: numBundleAttempts,
            numBundles: numBundles,
            bundleFailCount: bundleFailCount,
            configDownloadTimeMS: configDownloadTimeMS,
            bundleDownloadTimeMS: bundleDownloadTimeMS,
            localizedPriceTimeMS: localizedPriceTimeMS
        )))
    }
    
    private func getAllProductIds() -> [String] {
        // Get all unique product IDs from all paywalls
        var allProductIds: [String] = []
        if let config = fetchedConfig {
            for paywall in config.triggerToPaywalls.values {
                allProductIds.append(contentsOf: paywall.productsOffered)
            }
        }
        return allProductIds
    }
    
    
    private func buildLocalizedPriceMap(_ productIds: [String]) async {
        do {
            if #available(iOS 15.0, *) {
                // StoreKit 2 available
                self.localizedPriceMap = await PriceFetcher.localizedPricing(for: productIds)
            } else {
                // Fallback for older iOS versions (StoreKit 1)
                await withCheckedContinuation { continuation in
                    PriceFetcher.localizedPricing(for: productIds) { prices in
                        self.localizedPriceMap = prices
                        continuation.resume()
                    }
                }
            }
        }
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
        self.downloadStatus = status
    }
    
    public func getConfig() -> HeliumFetchedConfig? {
        return fetchedConfig
    }
    
    func hasBundles() -> Bool {
        return fetchedConfig?.bundles?.count ?? 0 > 0
    }
    
    /// Clears all fetched configuration and resets to initial state.
    /// 
    /// **Warning:** This is intended for debugging and testing scenarios only.
    /// In production, configurations should be managed through normal fetch cycles.
    /// 
    /// This method will:
    /// - Clear all fetched paywall configurations
    /// - Reset download status to `.notDownloadedYet`
    /// - Clear any cached pricing information
    /// - Reset retry counters
    ///
    /// After calling this, paywalls will show fallback views until a new fetch completes.
    public func clearAllFetchedState() {
        fetchedConfig = nil
        fetchedConfigJSON = nil
        localizedPriceMap = [:]
        downloadStatus = .notDownloadedYet
    }
    
    public func getConfigId() -> UUID? {
        return fetchedConfig?.fetchedConfigID
    }
    
    public func getPaywallInfoForTrigger(_ trigger: String) -> HeliumPaywallInfo? {
        return fetchedConfig?.triggerToPaywalls[trigger]
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
