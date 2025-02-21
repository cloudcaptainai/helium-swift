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
    @Published public var downloadTimeTakenMS: UInt64?
    
    private init() {
        downloadStatus = .notDownloadedYet
    }
    
    private(set) var fetchedConfig: HeliumFetchedConfig?
    private(set) var fetchedConfigJSON: JSON?
    
    func fetchConfig(
        endpoint: String,
        params: [String: Any],
        completion: @escaping (Result<HeliumFetchedConfig, Error>) -> Void
    ) {
        Task {
            do {
                let startTime = DispatchTime.now()
                // Make the request asynchronously
                let response = try await fetchEndpoint(endpoint: endpoint, params: params)
                
                // Ensure we have data
                guard let newConfig = response.0, let newConfigJSON = response.1 else {
                    await self.updateDownloadState(.downloadFailure)
                    return
                }
                let endTime = DispatchTime.now()
                downloadTimeTakenMS = UInt64(Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0)
                
                // Update the fetched config
                self.fetchedConfig = newConfig;
                self.fetchedConfigJSON = newConfigJSON;
                
                // Download assets
                let startTimeConfig = Date()

                if let config = self.fetchedConfig {
                    if (self.fetchedConfig?.bundles != nil && self.fetchedConfig?.bundles?.count ?? 0 > 0) {
                        do {
                            let bundles = (self.fetchedConfig?.bundles)!;
                            let endTimeNewConfig = Date()
                            let timeElapsed = endTimeNewConfig.timeIntervalSince(startTimeConfig)
                            
                            try HeliumAssetManager.shared.writeBundles(bundles: bundles);
                            await self.updateDownloadState(.downloadSuccess)
                            completion(.success(newConfig))
                            
                        } catch {
                            await self.updateDownloadState(.downloadFailure);
                            completion(.failure(error))
                            return
                        }
                    }
                }

                
            } catch {
                await self.updateDownloadState(.downloadFailure)
                completion(.failure(error))
            }
        }
    }
    
    @MainActor func updateDownloadState(_ status: HeliumFetchedConfigStatus) {
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
