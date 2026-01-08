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
        let initialAnalytics = Analytics.getOrCreateAnalytics(configuration: configuration)

        initialAnalytics.identify(
            userId: HeliumIdentityManager.shared.getUserId(),
            traits: HeliumIdentityManager.shared.getUserContext()
        );
        
        initialAnalytics.track(name: "helium_initializeCalled", properties: [
            "timestamp": formatAsTimestamp(date: Date()),
            "heliumPersistentID": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "heliumSessionID": HeliumIdentityManager.shared.getHeliumSessionId(),
            "heliumInitializeId": HeliumIdentityManager.shared.heliumInitializeId,
        ]);
    }
    
    func identifyUser(userId: String, traits: HeliumUserTraits? = nil) {
        if (traits != nil) {
            HeliumIdentityManager.shared.setCustomUserTraits(traits: traits!);
        }
        if let analytics = HeliumAnalyticsManager.shared.getAnalytics() {
            let userContext = HeliumIdentityManager.shared.getUserContext()
            analytics.identify(userId: userId, traits: userContext)
        }
    }
    
    public func setCustomAPIEndpoint(endpoint: String) {
        UserDefaults.standard.setValue(endpoint, forKey: API_STORAGE_KEY);
    }
    public func clearCustomAPIEndpoint() {
        UserDefaults.standard.removeObject(forKey: API_STORAGE_KEY)
    }
    
    func downloadConfig() {
        let apiEndpointOrDefault = UserDefaults.standard.string(forKey: API_STORAGE_KEY) ?? DEFAULT_API_ENDPOINT

        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: apiEndpointOrDefault, apiKey: self.apiKey) { result in
            switch result {
            case .success(let fetchedConfig, let metrics):
                HeliumAnalyticsManager.shared.getOrSetupAnalytics(
                    writeKey: fetchedConfig.segmentBrowserWriteKey,
                    endpoint: fetchedConfig.segmentAnalyticsEndpoint,
                    overrideIfNewConfiguration: true
                )
                
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallsDownloadSuccessEvent(
                        downloadTimeTakenMS: metrics.configDownloadTimeMS,
                        bundleDownloadTimeMS: metrics.bundleDownloadTimeMS,
                        localizedPriceTimeMS: metrics.localizedPriceTimeMS,
                        localizedPriceSuccess: metrics.localizedPriceSuccess,
                        numBundles: metrics.numBundles,
                        numBundlesFromCache: metrics.numBundlesFromCache,
                        uncachedBundleSizeKB: metrics.uncachedBundleSizeKB,
                        numAttempts: metrics.numConfigAttempts,
                        numBundleAttempts: metrics.numBundleAttempts
                    ),
                    paywallSession: nil
                )
                
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: NSNotification.Name("HeliumConfigDownloadComplete"),
                        object: nil
                    )
                }
            case .failure(let errorMessage, let metrics):
                HeliumAnalyticsManager.shared.getOrSetupAnalytics(
                    writeKey: self.FAILURE_MONITOR_BROWSER_WRITE_KEY,
                    endpoint: self.FAILURE_MONITOR_ANALYTICS_ENDPOINT
                )
                
                HeliumPaywallDelegateWrapper.shared.fireEvent(
                    PaywallsDownloadErrorEvent(
                        error: errorMessage,
                        configDownloaded: metrics.configSuccess,
                        downloadTimeTakenMS: metrics.configDownloadTimeMS,
                        bundleDownloadTimeMS: metrics.bundleDownloadTimeMS,
                        numBundles: metrics.numBundles,
                        numBundlesNotDownloaded: metrics.bundleFailCount,
                        numAttempts: metrics.numConfigAttempts,
                        numBundleAttempts: metrics.numBundleAttempts
                    ),
                    paywallSession: nil
                )
            }
        }
    }
}
