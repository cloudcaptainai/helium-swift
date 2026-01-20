//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/8/24.
//

import Foundation

public class HeliumController {
    let DEFAULT_API_ENDPOINT = "https://api-v2.tryhelium.com/on-launch"
    let FAILURE_MONITOR_BROWSER_WRITE_KEY = "RRVlneoxysmfB9IdrJPmdri8gThW5lZV:FgPUdTsNAlJxCrK1XCbjjxALb31iEiwd"
    let FAILURE_MONITOR_ANALYTICS_ENDPOINT = "cm2kqwnbc00003p6u45zdyl8z.d.jitsu.com"
    
    var apiKey: String
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    public func logInitializeEvent() {
        HeliumAnalyticsManager.shared.logInitializeEvent()
    }
    
    func downloadConfig() {
        let apiEndpointOrDefault = Helium.config.customAPIEndpoint ?? DEFAULT_API_ENDPOINT

        HeliumFetchedConfigManager.shared.fetchConfig(endpoint: apiEndpointOrDefault, apiKey: self.apiKey) { result in
            switch result {
            case .success(let fetchedConfig, let metrics):
                HeliumAnalyticsManager.shared.setUpAnalytics(
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
                        numBundleAttempts: metrics.numBundleAttempts,
                        totalInitializeTimeMS: metrics.totalTimeMS
                    ),
                    paywallSession: nil
                )
            case .failure(let errorMessage, let metrics):
                HeliumAnalyticsManager.shared.setUpAnalytics(
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
                        numBundleAttempts: metrics.numBundleAttempts,
                        totalInitializeTimeMS: metrics.totalTimeMS
                    ),
                    paywallSession: nil
                )
            }
        }
    }
}
