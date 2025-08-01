import Foundation
import SwiftyJSON
import SwiftUI
import WebKit
import Network

public enum HeliumFetchedConfigStatus: String, Codable, Equatable {
    case notDownloadedYet
    case inProgress
    case downloadSuccess
    case downloadFailure
}

struct HeliumFetchResult {
    var fetchedConfig: HeliumFetchedConfig
    var numRequests: Int = 1
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

public func fetchEndpoint(
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
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
    
    if NetworkReachability.shared.isOnWiFi {
        request.timeoutInterval = 30
    } else {
        request.timeoutInterval = 15
    }
    
    let jsonData = try JSONSerialization.data(withJSONObject: params, options: [])
    request.httpBody = jsonData
    
    let networkStartTime = DispatchTime.now()
    print("🌐 Starting network request to: \(urlString)")
    
    let (data, response) = try await session.data(for: request)
    
    let networkEndTime = DispatchTime.now()
    let networkTimeMS = Double(networkEndTime.uptimeNanoseconds - networkStartTime.uptimeNanoseconds) / 1_000_000.0
    print("🌐 Network request completed in: \(String(format: "%.2f", networkTimeMS)) ms")
    
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }
    
    let parsingStartTime = DispatchTime.now()
    print("📄 Starting response parsing...")
    
    let decodedResponse = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
    
    let json = try? JSON(data: data)
    
    let parsingEndTime = DispatchTime.now()
    let parsingTimeMS = Double(parsingEndTime.uptimeNanoseconds - parsingStartTime.uptimeNanoseconds) / 1_000_000.0
    print("📄 Response parsing completed in: \(String(format: "%.2f", parsingTimeMS)) ms")
    
    return (decodedResponse, json)
}

public class HeliumFetchedConfigManager: ObservableObject {
    public static let shared = HeliumFetchedConfigManager()
    @Published public var downloadStatus: HeliumFetchedConfigStatus
    public var downloadTimeTakenMS: UInt64?
    public var numRetries: Int = 0
    
    static let MAX_NUM_RETRIES: Int = 6 // approximately 94 seconds
    
    private init() {
        downloadStatus = .notDownloadedYet
    }
    
    private(set) var fetchedConfig: HeliumFetchedConfig?
    private(set) var fetchedConfigJSON: JSON?
    private(set) var localizedPriceMap: [String: LocalizedPrice] = [:]
    
    func fetchConfig(
        endpoint: String,
        params: [String: Any],
        completion: @escaping (Result<HeliumFetchResult, Error>) -> Void
    ) {
        Task {
            await fetchConfigWithRetry(
                endpoint: endpoint,
                params: params,
                maxRetries: HeliumFetchedConfigManager.MAX_NUM_RETRIES,
                retryCount: 0,
                completion: completion
            )
        }
    }
    
    private func fetchConfigWithRetry(
        endpoint: String,
        params: [String: Any],
        maxRetries: Int,
        retryCount: Int,
        completion: @escaping (Result<HeliumFetchResult, Error>) -> Void
    ) async {
        do {
            let overallStartTime = DispatchTime.now()
            print("⏱️ Starting config fetch attempt \(retryCount + 1)")
            
            let startTime = DispatchTime.now()
            // Make the request asynchronously
            let response = try await fetchEndpoint(endpoint: endpoint, params: params)
            
            // Ensure we have data
            guard let newConfig = response.0, let newConfigJSON = response.1 else {
                if retryCount < maxRetries {
                    let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                    print("Fetch failed on attempt \(retryCount + 1) (no data), retrying in \(delaySeconds) seconds...")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    await fetchConfigWithRetry(
                        endpoint: endpoint,
                        params: params,
                        maxRetries: maxRetries,
                        retryCount: retryCount + 1,
                        completion: completion
                    )
                } else {
                    await self.updateDownloadState(.downloadFailure)
                    completion(.failure(URLError(.unknown)))
                }
                return
            }
            let endTime = DispatchTime.now()
            downloadTimeTakenMS = UInt64(Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0)
            print("✅ Config fetch completed in: \(downloadTimeTakenMS ?? 0) ms")
            
            let configUpdateStartTime = DispatchTime.now()
            print("💾 Updating config in memory...")
            // Update the fetched config
            self.fetchedConfig = newConfig
            self.fetchedConfigJSON = newConfigJSON
            let configUpdateEndTime = DispatchTime.now()
            let configUpdateTimeMS = Double(configUpdateEndTime.uptimeNanoseconds - configUpdateStartTime.uptimeNanoseconds) / 1_000_000.0
            print("💾 Config memory update completed in: \(String(format: "%.2f", configUpdateTimeMS)) ms")
            
            // Download assets
            if (self.fetchedConfig?.bundles != nil && self.fetchedConfig?.bundles?.count ?? 0 > 0) {
                do {
                    let bundleStartTime = DispatchTime.now()
                    print("📦 Starting bundle processing (\((self.fetchedConfig?.bundles)!.count) bundles)...")
                    
                    let bundles = (self.fetchedConfig?.bundles)!
                    
                    try HeliumAssetManager.shared.writeBundles(bundles: bundles)
                    
                    let bundleEndTime = DispatchTime.now()
                    let bundleTimeMS = Double(bundleEndTime.uptimeNanoseconds - bundleStartTime.uptimeNanoseconds) / 1_000_000.0
                    print("📦 Bundle processing completed in: \(String(format: "%.2f", bundleTimeMS)) ms")
                    
                    let priceStartTime = DispatchTime.now()
                    print("💰 Starting price fetching...")
                    // Fetch localized prices for all products
                    await fetchLocalizedPrices()
                    let priceEndTime = DispatchTime.now()
                    let priceTimeMS = Double(priceEndTime.uptimeNanoseconds - priceStartTime.uptimeNanoseconds) / 1_000_000.0
                    print("💰 Price fetching completed in: \(String(format: "%.2f", priceTimeMS)) ms")
                    
                    await self.updateDownloadState(.downloadSuccess)
                    
                    let overallEndTime = DispatchTime.now()
                    let overallTimeMS = Double(overallEndTime.uptimeNanoseconds - overallStartTime.uptimeNanoseconds) / 1_000_000.0
                    print("🎉 Total operation completed in: \(String(format: "%.2f", overallTimeMS)) ms")
                    
                    completion(.success(HeliumFetchResult(fetchedConfig: newConfig, numRequests: retryCount + 1)))
                    
                } catch {
                    // Retry on asset processing failure
                    if retryCount < maxRetries {
                        let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                        print("Asset processing failed on attempt \(retryCount + 1), retrying in \(delaySeconds) seconds...")
                        
                        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        
                        await fetchConfigWithRetry(
                            endpoint: endpoint,
                            params: params,
                            maxRetries: maxRetries,
                            retryCount: retryCount + 1,
                            completion: completion
                        )
                    } else {
                        await self.updateDownloadState(.downloadFailure)
                        completion(.failure(error))
                    }
                    return
                }
            } else {
                let priceStartTime = DispatchTime.now()
                print("💰 Starting price fetching (no bundles)...")
                // Fetch localized prices for all products
                await fetchLocalizedPrices()
                let priceEndTime = DispatchTime.now()
                let priceTimeMS = Double(priceEndTime.uptimeNanoseconds - priceStartTime.uptimeNanoseconds) / 1_000_000.0
                print("💰 Price fetching completed in: \(String(format: "%.2f", priceTimeMS)) ms")
                
                await self.updateDownloadState(.downloadSuccess)
                
                let overallEndTime = DispatchTime.now()
                let overallTimeMS = Double(overallEndTime.uptimeNanoseconds - overallStartTime.uptimeNanoseconds) / 1_000_000.0
                print("🎉 Total operation completed in: \(String(format: "%.2f", overallTimeMS)) ms")
                
                completion(.success(HeliumFetchResult(fetchedConfig: newConfig, numRequests: retryCount + 1)))
            }
        } catch {
            // Retry on network/fetch failure
            if retryCount < maxRetries {
                let delaySeconds = calculateBackoffDelay(attempt: retryCount)
                print("Fetch failed on attempt \(retryCount + 1), retrying in \(delaySeconds) seconds...")
                
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                
                await fetchConfigWithRetry(
                    endpoint: endpoint,
                    params: params,
                    maxRetries: maxRetries,
                    retryCount: retryCount + 1,
                    completion: completion
                )
            } else {
                await self.updateDownloadState(.downloadFailure)
                completion(.failure(error))
            }
        }
    }
    
    private func calculateBackoffDelay(attempt: Int) -> Double {
        // Simple exponential backoff: 2^attempt seconds
        return pow(2.0, Double(attempt))
    }
    
    private func fetchLocalizedPrices() async {
        do {
            let productIdStartTime = DispatchTime.now()
            // Get all unique product IDs from all paywalls
            var allProductIds = Set<String>()
            if let config = fetchedConfig {
                for paywall in config.triggerToPaywalls.values {
                    allProductIds.formUnion(paywall.productsOffered)
                }
            }
            let productIdEndTime = DispatchTime.now()
            let productIdTimeMS = Double(productIdEndTime.uptimeNanoseconds - productIdStartTime.uptimeNanoseconds) / 1_000_000.0
            print("🛍️ Product ID collection completed in: \(String(format: "%.2f", productIdTimeMS)) ms (\(allProductIds.count) products)")
            
            // Fetch prices for all products in one shot
            let priceApiStartTime = DispatchTime.now()
            if #available(iOS 15.0, *) {
                self.localizedPriceMap = await PriceFetcher.localizedPricing(for: Array(allProductIds))
            } else {
                // Fallback for older iOS versions
                await withCheckedContinuation { continuation in
                    PriceFetcher.localizedPricing(for: Array(allProductIds)) { prices in
                        self.localizedPriceMap = prices
                        continuation.resume()
                    }
                }
            }
            let priceApiEndTime = DispatchTime.now()
            let priceApiTimeMS = Double(priceApiEndTime.uptimeNanoseconds - priceApiStartTime.uptimeNanoseconds) / 1_000_000.0
            print("🛍️ StoreKit price fetching completed in: \(String(format: "%.2f", priceApiTimeMS)) ms")
        } catch {
            print("Error fetching localized prices");
        }
    }
    
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
    
    public func getResolvedConfigJSONForTrigger(_ trigger: String) -> JSON? {
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
