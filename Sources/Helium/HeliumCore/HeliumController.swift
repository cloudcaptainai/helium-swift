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
    let API_STORAGE_KEY = "heliumApiEndpoint"
    let FAILURE_MONITOR_BROWSER_WRITE_KEY = "RRVlneoxysmfB9IdrJPmdri8gThW5lZV:FgPUdTsNAlJxCrK1XCbjjxALb31iEiwd"
    let FAILURE_MONITOR_ANALYTICS_ENDPOINT = "cm2kqwnbc00003p6u45zdyl8z.d.jitsu.com"
    
    var apiKey: String
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    public func identifyUser(userId: String, traits: HeliumUserTraits? = nil) {
        if (traits != nil) {
            HeliumIdentityManager.shared.setCustomUserTraits(traits: traits!);
        }
        if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil && HeliumPaywallDelegateWrapper.shared.getIsAnalyticsEnabled()) {
            let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
            let userContext = HeliumIdentityManager.shared.getUserContext();
            analytics.identify(userId, traits: userContext.asParams())
        }
    }
    
    public func setCustomAPIEndpoint(endpoint: String) {
        UserDefaults.standard.setValue(endpoint, forKey: API_STORAGE_KEY);
    }
    
    public func downloadConfig() {
        var payload: [String: Any]
        payload = [
            "apiKey": self.apiKey,
            "userId": HeliumIdentityManager.shared.getUserId(),
            "userContext": HeliumIdentityManager.shared.getUserContext().asParams(),
        ]
        
        let apiEndpointOrDefault = UserDefaults.standard.string(forKey: API_STORAGE_KEY) ?? DEFAULT_API_ENDPOINT;

        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: apiEndpointOrDefault, params: payload) { result in
            switch result {
            case .success(let fetchedConfig):
                let apiURL = URL(string: fetchedConfig.segmentAnalyticsEndpoint);
                let configuration = AnalyticsConfiguration(writeKey: fetchedConfig.segmentBrowserWriteKey, defaultAPIHost: apiURL);
                
                if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil) {
                    let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
                    analytics.identify(
                        HeliumIdentityManager.shared.getUserId(),
                        traits: HeliumIdentityManager.shared.getUserContext().asParams()
                    );
                } else {
                    do {
                        let analytics = Analytics(configuration: configuration)
                        analytics.identify(
                            HeliumIdentityManager.shared.getUserId(),
                            traits: HeliumIdentityManager.shared.getUserContext().asParams()
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
                    fontsDownloadTimeTakenMS: HeliumAssetManager.shared.fontStatus.timeTakenMS,
                    bundleDownloadTimeMS: HeliumAssetManager.shared.bundleStatus.timeTakenMS
                );
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: event)
                
                // Use the config as needed
            case .failure(let error):
                let apiURLFailure = URL(string: self.FAILURE_MONITOR_ANALYTICS_ENDPOINT);
                let configuration = AnalyticsConfiguration(writeKey: self.FAILURE_MONITOR_BROWSER_WRITE_KEY, defaultAPIHost: apiURLFailure);
                
                if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil) {
                    let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
                    analytics.identify(
                        HeliumIdentityManager.shared.getUserId(),
                        traits: HeliumIdentityManager.shared.getUserContext().asParams()
                    );
                } else {
                    let analytics = Analytics(configuration: configuration)
                    analytics.identify(
                        HeliumIdentityManager.shared.getUserId(),
                        traits: HeliumIdentityManager.shared.getUserContext().asParams()
                    );
                    HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics);
                }

                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallsDownloadError(error: error.localizedDescription))
            }
        }
    }
}
