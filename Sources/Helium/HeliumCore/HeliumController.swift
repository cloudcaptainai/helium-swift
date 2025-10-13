//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/8/24.
//

import Foundation
import SwiftUI

public class HeliumController {
    let DEFAULT_API_ENDPOINT = "https://api-v2.tryhelium.com/on-launch"
    let API_STORAGE_KEY = "heliumApiEndpoint"
    let FAILURE_MONITOR_BROWSER_WRITE_KEY = "RRVlneoxysmfB9IdrJPmdri8gThW5lZV:FgPUdTsNAlJxCrK1XCbjjxALb31iEiwd"
    let FAILURE_MONITOR_ANALYTICS_ENDPOINT = "cm2kqwnbc00003p6u45zdyl8z.d.jitsu.com"
    
    let INITIALIZATION_BROWSER_WRITE_KEY = "dIPnOYdPFgAabYaURULtIHAxbofvIIAD:GV9TlMOuPgt989LaumjVTJofZ8vipJXb";
    let INITIALIZATION_ANALYTICS_ENDPOINT = "cm7mjur1o00003p6r7lio27sb.d.jitsu.com";
    
    var apiKey: String
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    public func logInitializeEvent() {
        let configuration = SegmentConfiguration(writeKey: self.INITIALIZATION_BROWSER_WRITE_KEY)
            .apiHost(self.INITIALIZATION_ANALYTICS_ENDPOINT)
            .cdnHost(self.INITIALIZATION_ANALYTICS_ENDPOINT)
            .trackApplicationLifecycleEvents(false)
            .flushInterval(10)
        let initialAnalytics = Analytics(configuration: configuration)

        initialAnalytics.identify(
            userId: HeliumIdentityManager.shared.getUserId(),
            traits: HeliumIdentityManager.shared.getUserContext()
        );
        
        initialAnalytics.track(name: "helium_initializeCalled", properties: [
            "timestamp": formatAsTimestamp(date: Date()),
            "heliumPersistentID": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "heliumSessionID": HeliumIdentityManager.shared.getHeliumSessionId()
        ]);
    }
    
    public func identifyUser(userId: String, traits: HeliumUserTraits? = nil) {
        if (traits != nil) {
            HeliumIdentityManager.shared.setCustomUserTraits(traits: traits!);
        }
        if (HeliumPaywallDelegateWrapper.shared.getAnalytics() != nil && HeliumPaywallDelegateWrapper.shared.getIsAnalyticsEnabled()) {
            let analytics = HeliumPaywallDelegateWrapper.shared.getAnalytics()!;
            let userContext = HeliumIdentityManager.shared.getUserContext();
            analytics.identify(userId: userId, traits: userContext);
        }
    }
    
    public func setCustomAPIEndpoint(endpoint: String) {
        UserDefaults.standard.setValue(endpoint, forKey: API_STORAGE_KEY);
    }
    public func clearCustomAPIEndpoint() {
        UserDefaults.standard.removeObject(forKey: API_STORAGE_KEY)
    }
    
    public func downloadConfig() {
        var payload: [String: Any]
        payload = [
            "apiKey": self.apiKey,
            "userId": HeliumIdentityManager.shared.getUserId(),
            "userContext": HeliumIdentityManager.shared.getUserContext().asParams(),
            "existingBundleIds": HeliumAssetManager.shared.getExistingBundleIDs()
        ]
        
        let apiEndpointOrDefault = UserDefaults.standard.string(forKey: API_STORAGE_KEY) ?? DEFAULT_API_ENDPOINT;

        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: apiEndpointOrDefault, params: payload) { result in
            switch result {
            case .success(let fetchResult):
                let fetchedConfig = fetchResult.fetchedConfig
                let numFetchRequests = fetchResult.numRequests
                let configuration = SegmentConfiguration(writeKey: fetchedConfig.segmentBrowserWriteKey)
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
                        HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics, writeKey: fetchedConfig.segmentBrowserWriteKey);
                    } catch {
                        // no op
                    }
                }
                
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallsDownloadSuccessEvent(
                        downloadTimeTakenMS: HeliumFetchedConfigManager.shared.downloadTimeTakenMS,
                        numAttempts: numFetchRequests
                    )
                )
                
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: NSNotification.Name("HeliumConfigDownloadComplete"),
                        object: nil
                    )
                }
            case .failure(let error):
            
                let configuration = SegmentConfiguration(writeKey: self.FAILURE_MONITOR_BROWSER_WRITE_KEY)
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
                    HeliumPaywallDelegateWrapper.shared.setAnalytics(analytics, writeKey: self.FAILURE_MONITOR_BROWSER_WRITE_KEY);
                }

                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallsDownloadErrorEvent(
                        error: error.localizedDescription,
                        numAttempts: HeliumFetchedConfigManager.MAX_NUM_CONFIG_RETRIES + 1
                    )
                )
            }
        }
    }
}
