import Foundation
import SwiftyJSON
import SwiftUI
import WebKit

public enum HeliumFetchedConfigStatus: String, Codable, Equatable {
    case notDownloadedYet
    case inProgress
    case downloadSuccess
    case downloadFailure
}

public func fetchEndpoint(
    endpoint: String,
    params: [String: Any]
) async throws -> (HeliumFetchedConfig?, JSON?)  {
    let urlString = endpoint // Assuming 'endpoint' is a String containing the URL
    guard let url = URL(string: urlString) else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let jsonData = try JSONSerialization.data(withJSONObject: params, options: [])
    request.httpBody = jsonData


    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }
    
    
    let decodedResponse = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
    let json = try? JSON(data: data);

    return (decodedResponse, json);
}

public class HeliumFetchedConfigManager: ObservableObject {
    public static let shared = HeliumFetchedConfigManager()
    @Published public var downloadStatus: HeliumFetchedConfigStatus
    @Published public var downloadTimeTakenMS: UInt64?
    @Published public var imageDownloadTimeTakenMS: UInt64?
    @Published public var fontDownloadTimeTakenMS: UInt64?
    private var webViewCache: [String: WKWebView] = [:]

    
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
                    do {
                        let endTimeNewConfig = Date()
                        let timeElapsed = endTimeNewConfig.timeIntervalSince(startTimeConfig)
                        print("Fetch config just json took \(timeElapsed) seconds")
                        
                        var fontURLs = Set<String>()
                        var imageURLs = Set<String>()
                        
                        HeliumAssetManager.shared.collectFontURLs(from: self.fetchedConfigJSON?["triggerToPaywalls"] ?? JSON([:]), into: &fontURLs)
                        HeliumAssetManager.shared.collectImageURLs(from: self.fetchedConfigJSON?["triggerToPaywalls"] ?? JSON([:]), into: &imageURLs)
                        
                        var triggerNameToBundleURLs: [String: Set<String>] = [:];
                        config.triggerToPaywalls.forEach { (key: String, value: HeliumPaywallInfo) in
                            var bundleURLs = Set<String>();
                            
                            HeliumAssetManager.shared.collectBundleURLs(from: self.fetchedConfigJSON?["triggerToPaywalls"] ?? JSON([:]), into: &bundleURLs);
                            
                            triggerNameToBundleURLs[key] = bundleURLs;
                        }
                        
                        
                        // Create local copies for the task group
                        let fontURLsCopy = fontURLs
                        let imageURLsCopy = imageURLs
                        let bundleURLsCopy = triggerNameToBundleURLs;

                        
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                await HeliumAssetManager.shared.downloadImages(from: imageURLsCopy)
                            }
                            
                            group.addTask {
                                await HeliumAssetManager.shared.downloadFonts(from: fontURLsCopy)
                            }
                            
                            triggerNameToBundleURLs.forEach { (key: String, value: Set<String>) in
                                
                                let bundleConfigs = value.compactMap { bundleURL in
                                    HeliumAssetManager.BundleConfig(
                                        url: bundleURL,
                                        triggerName: key
                                    );
                                }
                                group.addTask {
                                    await HeliumAssetManager.shared.downloadBundles(configs: bundleConfigs);
                                }
                            }
                            
                        }
                    } catch {
                        print("Couldn't load all fonts.")
                    }
                }
                
                let endTimeConfig = Date()
                let timeElapsed = endTimeConfig.timeIntervalSince(startTimeConfig)
                print("Fetch config font/image parsing took \(timeElapsed) seconds")

                await self.updateDownloadState(.downloadSuccess)
                completion(.success(newConfig))
                
               // Initialize web views in background
               Task.detached {
                   for trigger in self.getFetchedTriggerNames() {
                       let config = WKWebViewConfiguration()
                       let webView = await WKWebView(frame: .zero, configuration: config)
                       self.webViewCache[trigger] = webView
                   }
                   
                   // Log memory usage
                   let memoryUsage = self.webViewCache.count * 10  // Approx 10MB per WKWebView
                   print("[Memory] WebView cache using ~\(memoryUsage)MB")
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
    
    // Add method
   public func getCachedWebView(bundleId: String) -> WKWebView? {
       if let cachedView = webViewCache[bundleId] {
           print("[WebView Cache] Cache hit for \(bundleId)")
           return cachedView;
       }
       print("[WebView Cache] Cache miss for \(bundleId)")
       let config = WKWebViewConfiguration()
       let webView = WKWebView(frame: .zero, configuration: config)
       webViewCache[bundleId] = webView;
       return webView;
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
