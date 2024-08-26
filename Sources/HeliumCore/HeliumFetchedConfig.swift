//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/17/24.
//

import Foundation
import Alamofire

public enum HeliumFetchedConfigStatus: Codable {
    case notDownloadedYet
    case downloadSuccess
    case downloadFailure
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
                let response = await AF.request(endpoint, method: .post, parameters: params, encoding: JSONEncoding.default, interceptor: .retryPolicy)
                    .cacheResponse(using: .cache)
                    .validate()
                    .serializingDecodable(HeliumFetchedConfig.self).response
                
                // Check for errors
                if let error = response.error {
                    await self.updateDownloadState(.downloadFailure);
                    completion(.failure(error))
                    return
                }
                
                // Ensure we have data
                guard let newConfig = response.value else {
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
        return fetchedConfig?.fetchedConfigId
    }
    
    public func getPaywallInfoForTrigger(_ trigger: String) -> HeliumPaywallInfo? {
        return fetchedConfig?.triggerToPaywalls[trigger];
    }
    
    public func getClientName() -> String? {
        return fetchedConfig?.orgName;
    }
}
