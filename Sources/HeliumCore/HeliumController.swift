//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/8/24.
//

import Foundation
import SwiftUI
import Segment
import Alamofire


public protocol BaseTemplateView: View {
    init(clientName: String?, paywallInfo: HeliumPaywallInfo?, trigger: String)
}

public class HeliumController {
    let fetchEndpoint = "https://cloudcaptainai--helium-prod-fastapi-app.modal.run/serve_template"
    
    let userContext = CodableUserContext.create()
    let userId: UUID = createHeliumUserId()
    
    var apiKey: String
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    public func downloadConfig() async {
        do {
            
            var payload: [String: Any]
            do {
                payload = [
                    "apiKey": self.apiKey,
                    "userId": self.userId.uuidString,
                    "userContext": try self.userContext.toJSON()
                ]
            } catch {
                payload = [
                    "apiKey": self.apiKey,
                    "userId": self.userId.uuidString,
                ]
            }
            
            HeliumFetchedConfigManager.shared.fetchConfig(endpoint: fetchEndpoint, params: payload) { result in
                switch result {
                case .success(let fetchedConfig):
                    let configuration = Configuration(writeKey: fetchedConfig.segmentBrowserWriteKey)
                        .apiHost(fetchedConfig.segmentAnalyticsEndpoint)
                        .cdnHost(fetchedConfig.segmentAnalyticsEndpoint)
                        .trackApplicationLifecycleEvents(false)
                        .flushInterval(10)
                    
            
                    let analytics = Analytics(configuration: configuration)
                    analytics.identify(userId: self.userId.uuidString, traits: self.userContext)
                    HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics)
                    
                    let event: HeliumPaywallEvent = .paywallsDownloadSuccess(configId: fetchedConfig.fetchedConfigId)
                    HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: event)
                    
                    // Use the config as needed
                case .failure(let error):
                    HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
                }
            }

            
        } catch {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
        }
    }
}
