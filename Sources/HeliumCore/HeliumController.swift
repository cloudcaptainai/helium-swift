//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/8/24.
//

import Foundation
import SwiftUI
import Segment


public class HeliumController {
    let fetchEndpoint = "https://api.tryhelium.com/on-launch"
    
    let userContext = CodableUserContext.create()
    
    var apiKey: String
    var triggers: [HeliumTrigger]?
    
    public init(apiKey: String, triggers: [HeliumTrigger]? = nil) {
        self.apiKey = apiKey
        self.triggers = triggers;
    }
    
    public func getUserId() -> String {
        return createHeliumUserId();
    }
    
    public func downloadConfig() async {
        var payload: [String: Any]
        payload = [
            "apiKey": self.apiKey,
            "userId": self.getUserId(),
            "userContext": self.userContext.asParams(),
            "triggers": self.triggers?.compactMap({ trigger in trigger.name }) as Any
        ]
        
        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: fetchEndpoint, params: payload) { result in
            switch result {
            case .success(let fetchedConfig):
                let configuration = Configuration(writeKey: fetchedConfig.segmentBrowserWriteKey)
                    .apiHost(fetchedConfig.segmentAnalyticsEndpoint)
                    .cdnHost(fetchedConfig.segmentAnalyticsEndpoint)
                    .trackApplicationLifecycleEvents(false)
                    .flushInterval(10)
                
                if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil) {
                    print("Can't re-set analytics.")
                    let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
                    analytics.identify(userId: self.getUserId(), traits: self.userContext);
                } else {
                    let analytics = Analytics(configuration: configuration)
                    analytics.identify(userId: self.getUserId(), traits: self.userContext)
                    HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics);
                }
                
                let event: HeliumPaywallEvent = .paywallsDownloadSuccess(configId: fetchedConfig.fetchedConfigID)
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: event)
                
                // Use the config as needed
            case .failure(let error):
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
            }
        }
    }
}
