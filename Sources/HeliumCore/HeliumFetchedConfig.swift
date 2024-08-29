//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/17/24.
//

import Foundation


public enum HeliumFetchedConfigStatus: Codable {
    case notDownloadedYet
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
    return decodedResponse
}

public class HeliumFetchedConfigManager: ObservableObject {
    public static let shared = HeliumFetchedConfigManager()
    @Published public var downloadStatus: HeliumFetchedConfigStatus
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
                // Make the request asynchronously
                let response = try await fetchEndpoint(endpoint: endpoint, params: params);
                
                
                // Ensure we have data
                guard let newConfig = response else {
                    await self.updateDownloadState(.downloadFailure);
                    return
                }
                
                // Update the fetched config
                self.fetchedConfig = newConfig
                await self.updateDownloadState(.downloadSuccess)
                completion(.success(newConfig))
            } catch {
                await self.updateDownloadState(.downloadFailure);
                completion(.failure(error))
            }
        }
    }
    
    @MainActor func updateDownloadState(_ status: HeliumFetchedConfigStatus) {
        self.downloadStatus = status;
    }
    
    public func getConfig() -> HeliumFetchedConfig? {
        return fetchedConfig
    }
    
    public func getConfigId() -> UUID? {
        return fetchedConfig?.fetchedConfigID
    }
    
    public func getPaywallInfoForTrigger(_ trigger: String) -> HeliumPaywallInfo? {
        return fetchedConfig?.triggerToPaywalls[trigger];
    }
    
    public func getClientName() -> String? {
        return fetchedConfig?.orgName;
    }
}
