//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/8/24.
//

import Foundation
import SwiftUI
import Segment


public protocol BaseTemplateView: View {
    init(clientName: String?, paywallInfo: HeliumPaywallInfo?, trigger: String)
}

public class HeliumController {
    let fetchEndpoint = "https://api.tryhelium.com/on-launch"
    
    let userContext = CodableUserContext.create()
    let userId: UUID = createHeliumUserId()
    
    var apiKey: String
    var triggers: [HeliumTrigger]?
    
    public init(apiKey: String, triggers: [HeliumTrigger]? = nil) {
        self.apiKey = apiKey
        self.triggers = triggers;
    }
    
    public func downloadConfig() async {
        var payload: [String: Any]
        payload = [
            "apiKey": self.apiKey,
            "userId": self.userId.uuidString,
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
                
        
                let analytics = Analytics(configuration: configuration)
                analytics.identify(userId: self.userId.uuidString, traits: self.userContext)
                HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics)
                
                let event: HeliumPaywallEvent = .paywallsDownloadSuccess(configId: fetchedConfig.fetchedConfigID)
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: event)
                
                // Use the config as needed
            case .failure(let error):
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
            }
        }
    }
}
