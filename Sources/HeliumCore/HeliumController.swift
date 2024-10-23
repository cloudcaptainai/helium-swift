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
    let FAILURE_MONITOR_BROWSER_WRITE_KEY = "RRVlneoxysmfB9IdrJPmdri8gThW5lZV:FgPUdTsNAlJxCrK1XCbjjxALb31iEiwd"
    let FAILURE_MONITOR_ANALYTICS_ENDPOINT = "cm2kqwnbc00003p6u45zdyl8z.d.jitsu.com"
    
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
    
    public func identifyUser(userId: String) {
        if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil && HeliumPaywallDelegateWrapper.shared.getIsAnalyticsEnabled()) {
            let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
            analytics.identify(userId: userId, traits: CodableUserContext.create());
        }
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
                
                let event: HeliumPaywallEvent = .paywallsDownloadSuccess(
                    configId: fetchedConfig.fetchedConfigID,
                    downloadTimeTakenMS: HeliumFetchedConfigManager.shared.downloadTimeTakenMS,
                    imagesDownloadTimeTakenMS: HeliumFetchedConfigManager.shared.imageDownloadTimeTakenMS,
                    fontsDownloadTimeTakenMS: HeliumFetchedConfigManager.shared.fontDownloadTimeTakenMS
                );
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: event)
                
                // Use the config as needed
            case .failure(let error):
                
                let configuration = Configuration(writeKey: self.FAILURE_MONITOR_BROWSER_WRITE_KEY)
                    .apiHost(self.FAILURE_MONITOR_ANALYTICS_ENDPOINT)
                    .cdnHost(self.FAILURE_MONITOR_ANALYTICS_ENDPOINT)
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

                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
            }
        }
    }
}
