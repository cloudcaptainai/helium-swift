//
//  HeliumAnalyticsManager.swift
//

import Foundation

class HeliumAnalyticsManager {
    static let shared = HeliumAnalyticsManager()
    
    private var analytics: Analytics?
    private var currentWriteKey: String?
    private var currentEndpoint: String?
    
    func getAnalytics() -> Analytics? {
        return analytics
    }
    
    func setAnalytics(_ analytics: Analytics) {
        self.analytics = analytics
    }
    
    /// Creates a SegmentConfiguration with standard settings
    func createConfiguration(writeKey: String, endpoint: String) -> SegmentConfiguration {
        return SegmentConfiguration(writeKey: writeKey)
            .apiHost(endpoint)
            .cdnHost(endpoint)
            .trackApplicationLifecycleEvents(false)
            .flushInterval(10)
    }
    
    /// Gets existing analytics or creates and configures a new instance.
    /// Also performs identify call with current user context.
    /// - Parameter overrideIfNewConfiguration: If true and the writeKey or endpoint differs from the
    ///   existing configuration, creates a new analytics instance instead of reusing the existing one.
    @discardableResult
    func getOrSetupAnalytics(writeKey: String, endpoint: String, overrideIfNewConfiguration: Bool = false) -> Analytics {
        let configurationChanged = currentWriteKey != writeKey || currentEndpoint != endpoint
        let shouldCreateNew = overrideIfNewConfiguration && configurationChanged
        
        if let existingAnalytics = analytics, !shouldCreateNew {
            existingAnalytics.identify(
                userId: HeliumIdentityManager.shared.getUserId(),
                traits: HeliumIdentityManager.shared.getUserContext()
            )
            return existingAnalytics
        }

        let configuration = createConfiguration(writeKey: writeKey, endpoint: endpoint)
        let newAnalytics = Analytics.getOrCreateAnalytics(configuration: configuration)
        newAnalytics.identify(
            userId: HeliumIdentityManager.shared.getUserId(),
            traits: HeliumIdentityManager.shared.getUserContext()
        )
        self.analytics = newAnalytics
        self.currentWriteKey = writeKey
        self.currentEndpoint = endpoint
        return newAnalytics
    }
}
