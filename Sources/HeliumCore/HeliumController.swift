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
    let DEFAULT_API_ENDPOINT = "https://api.tryhelium.com/on-launch"
    let FAILURE_MONITOR_BROWSER_WRITE_KEY = "RRVlneoxysmfB9IdrJPmdri8gThW5lZV:FgPUdTsNAlJxCrK1XCbjjxALb31iEiwd"
    let FAILURE_MONITOR_ANALYTICS_ENDPOINT = "cm2kqwnbc00003p6u45zdyl8z.d.jitsu.com"
    
    var apiKey: String
    var triggers: [HeliumTrigger]?
    
    public init(apiKey: String, triggers: [HeliumTrigger]? = nil) {
        self.apiKey = apiKey
        self.triggers = triggers;
    }
    
    public func identifyUser(userId: String) {
        if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil && HeliumPaywallDelegateWrapper.shared.getIsAnalyticsEnabled()) {
            let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
            analytics.identify(userId: userId, traits: CodableUserContext.create());
        }
    }
    
    public func setCustomAPIEndpoint(endpoint: String) {
        UserDefaults.standard.set(endpoint, forKey: "heliumApiEndpoint");
    }
    
    public func downloadConfig() {
        var payload: [String: Any]
        payload = [
            "apiKey": self.apiKey,
            "userId": HeliumIdentityManager.shared.getUserId(),
            "userContext": HeliumIdentityManager.shared.getUserContext().asParams(),
            "triggers": self.triggers?.compactMap({ trigger in trigger.name }) as Any
        ]
        
        let apiEndpointOrDefault = UserDefaults.standard.string(forKey: "heliumApiEndpoint") ?? DEFAULT_API_ENDPOINT;
        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: apiEndpointOrDefault, params: payload) { result in
            switch result {
            case .success(let fetchedConfig):
                let configuration = Configuration(writeKey: fetchedConfig.segmentBrowserWriteKey)
                    .apiHost(fetchedConfig.segmentAnalyticsEndpoint)
                    .cdnHost(fetchedConfig.segmentAnalyticsEndpoint)
                    .trackApplicationLifecycleEvents(false)
                    .flushInterval(10)
                
                if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil) {
                    let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
                    analytics.identify(
                        userId: HeliumIdentityManager.shared.getUserId(),
                        traits: HeliumIdentityManager.shared.getUserContext()
                    );
                } else {
                    do {
                        let analytics = Analytics(configuration: configuration)
                        analytics.identify(
                            userId: HeliumIdentityManager.shared.getUserId(),
                            traits: HeliumIdentityManager.shared.getUserContext()
                        );
                        HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics);
                    } catch {
                        // no op
                    }
                }
                
                let event: HeliumPaywallEvent = .paywallsDownloadSuccess(
                    configId: fetchedConfig.fetchedConfigID,
                    downloadTimeTakenMS: HeliumFetchedConfigManager.shared.downloadTimeTakenMS,
                    imagesDownloadTimeTakenMS: HeliumAssetManager.shared.imageStatus.timeTakenMS,
                    fontsDownloadTimeTakenMS: HeliumAssetManager.shared.fontStatus.timeTakenMS
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
                    let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
                    analytics.identify(
                        userId: HeliumIdentityManager.shared.getUserId(),
                        traits: HeliumIdentityManager.shared.getUserContext()
                    );
                } else {
                    let analytics = Analytics(configuration: configuration)
                    analytics.identify(
                        userId: HeliumIdentityManager.shared.getUserId(),
                        traits: HeliumIdentityManager.shared.getUserContext()
                    );
                    HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics);
                }

                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
            }
        }
    }
}
