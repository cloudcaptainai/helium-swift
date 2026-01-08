//
//  HeliumAnalyticsManager.swift
//

import Foundation

class HeliumAnalyticsManager {
    static let shared = HeliumAnalyticsManager()
    
    private var analytics: Analytics?
    
    static func reset() {
        shared.analytics = nil
    }
    
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
    @discardableResult
    func getOrSetupAnalytics(writeKey: String, endpoint: String) -> Analytics {
        if let existingAnalytics = analytics {
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
        return newAnalytics
    }
}
