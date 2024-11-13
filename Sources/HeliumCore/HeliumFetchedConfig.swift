import Foundation
import SwiftyJSON

public enum HeliumFetchedConfigStatus: String, Codable, Equatable {
    case notDownloadedYet
    case inProgress
    case downloadSuccess
    case downloadFailure
}

public func fetchEndpoint(
    endpoint: String,
    params: [String: Any]
) async throws -> HeliumFetchedConfig? {
    let urlString = endpoint // Assuming 'endpoint' is a String containing the URL
    guard let url = URL(string: urlString) else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    do {
        let jsonData = try JSONSerialization.data(withJSONObject: params, options: [])
        request.httpBody = jsonData
    } catch {
        throw error
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
    }
    let decodedResponse = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
    return decodedResponse;
}

public class HeliumFetchedConfigManager: ObservableObject {
    public static let shared = HeliumFetchedConfigManager()
    @Published public var downloadStatus: HeliumFetchedConfigStatus
    @Published public var downloadTimeTakenMS: UInt64?
    @Published public var imageDownloadTimeTakenMS: UInt64?
    @Published public var fontDownloadTimeTakenMS: UInt64?
    
    private init() {
        downloadStatus = .notDownloadedYet
    }
    
    private(set) var fetchedConfig: HeliumFetchedConfig?
    
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
                guard let newConfig = response else {
                    await self.updateDownloadState(.downloadFailure)
                    return
                }
                let endTime = DispatchTime.now()
                downloadTimeTakenMS = UInt64(Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0)
                
                // Update the fetched config
                self.fetchedConfig = newConfig
                
                // Download assets
                if let config = self.fetchedConfig {
                    do {
                        let encoder = JSONEncoder()
                        let jsonData = try encoder.encode(config.triggerToPaywalls)
                        let jsonWrapped = try JSON(data: jsonData)
                        var fontURLs = Set<String>()
                        var imageURLs = Set<String>()
                        HeliumAssetManager.shared.collectFontURLs(from: jsonWrapped, into: &fontURLs)
                        HeliumAssetManager.shared.collectImageURLs(from: jsonWrapped, into: &imageURLs)
                        
                        // Create local copies for the task group
                        let fontURLsCopy = fontURLs
                        let imageURLsCopy = imageURLs
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask {
                                await HeliumAssetManager.shared.downloadImages(from: imageURLsCopy)
                            }
                            
                            group.addTask {
                                await HeliumAssetManager.shared.downloadFonts(from: fontURLsCopy)
                            }
                        }
                    } catch {
                        print("Couldn't load all fonts.")
                    }
                }

                await self.updateDownloadState(.downloadSuccess)
                completion(.success(newConfig))
                
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
    
    public func getExperimentIDForTrigger(_ trigger: String) -> String? {
        return fetchedConfig?.triggerToPaywalls[trigger]?.experimentID;
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
