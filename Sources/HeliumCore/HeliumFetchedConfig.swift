import Foundation
import SwiftyJSON

public enum HeliumFetchedConfigStatus: Codable {
    case notDownloadedYet
    case downloadSuccess(fetchedConfigId: UUID)
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
    return decodedResponse
}

public func downloadFonts(from jsonData: Data) async throws {
    // Parse JSON data
    let json = try! JSON(data: jsonData)
    
    // Collect fontURLs
    var fontURLs = Set<String>()
    collectFontURLs(from: json, into: &fontURLs)
    
    // Download fonts in parallel
    await withTaskGroup(of: Void.self) { group in
        for fontURL in fontURLs {
            group.addTask {
                if let url = URL(string: fontURL) {
                    let result = await downloadRemoteFont(fontURL: url);
                    print(result);
                }
            }
        }
    }
    print("Successfully downloaded \(fontURLs.count) fonts");
}

func collectFontURLs(from json: JSON, into fontURLs: inout Set<String>) {
    switch json.type {
    case .dictionary:
        for (key, value) in json {
            if key == "fontURL", let url = value.string {
                fontURLs.insert(url)
            } else {
                collectFontURLs(from: value, into: &fontURLs)
            }
        }
    case .array:
        for item in json.arrayValue {
            collectFontURLs(from: item, into: &fontURLs)
        }
    default:
        break
    }
}


public class HeliumFetchedConfigManager: ObservableObject {
    public static let shared = HeliumFetchedConfigManager()
    @Published public var downloadStatus: HeliumFetchedConfigStatus
    @Published public var downloadTimeTakenMS: UInt64?
    
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
                let startTime = DispatchTime.now();
                // Make the request asynchronously
                let response = try await fetchEndpoint(endpoint: endpoint, params: params)
                
                // Ensure we have data
                guard let newConfig = response else {
                    await self.updateDownloadState(.downloadFailure)
                    return
                }
                
                // Update the fetched config
                self.fetchedConfig = newConfig
                
                // Download assets
                if (self.fetchedConfig != nil) {
                    do {
                        let encoder = JSONEncoder()
                        let jsonData = try encoder.encode(self.fetchedConfig!.triggerToPaywalls)
                        try await downloadFonts(from: jsonData);
                    } catch {
                        print("Couldnt load all fonts.");
                    }
                }
                
                await self.updateDownloadState(.downloadSuccess(fetchedConfigId: newConfig.fetchedConfigID))
                let endTime = DispatchTime.now();

                let elapsedTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
                let elapsedTimeInMilliSeconds = Double(elapsedTime) / 1_000_000.0;

                downloadTimeTakenMS = UInt64(elapsedTimeInMilliSeconds);
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
