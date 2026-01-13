//
//  HeliumAnalyticsManager.swift
//

import Foundation

class HeliumAnalyticsManager {
    static let shared = HeliumAnalyticsManager()
    
    private let queue = DispatchQueue(label: "com.helium.analyticsManager")
    private var analytics: Analytics?
    private var currentWriteKey: String?
    
    func getAnalytics() -> Analytics? {
        queue.sync { analytics }
    }
    
    /// Identifies the current user with the analytics instance.
    /// - Parameter userId: Optional userId to use. If nil, uses HeliumIdentityManager's userId.
    func identify(userId: String? = nil) {
        queue.sync {
            guard let analytics else { return }
            let resolvedUserId = userId ?? HeliumIdentityManager.shared.getUserId()
            let userContext = HeliumIdentityManager.shared.getUserContext()
            analytics.identify(userId: resolvedUserId, traits: userContext)
        }
    }
    
    /// Creates a SegmentConfiguration with standard settings
    private func createConfiguration(writeKey: String, endpoint: String) -> SegmentConfiguration {
        return SegmentConfiguration(writeKey: writeKey)
            .apiHost(endpoint)
            .cdnHost(endpoint)
            .trackApplicationLifecycleEvents(false)
            .flushAt(10)
            .flushInterval(10)
    }
    
    /// Gets existing analytics or creates and configures a new instance.
    /// Also performs identify call with current user context.
    /// - Parameter overrideIfNewConfiguration: If true and the writeKey differs from the
    ///   existing configuration, creates a new analytics instance instead of reusing the existing one.
    @discardableResult
    func getOrSetupAnalytics(writeKey: String, endpoint: String, overrideIfNewConfiguration: Bool = false) -> Analytics {
        let result = queue.sync { () -> Analytics in
            let configurationChanged = currentWriteKey != writeKey
            let shouldCreateNew = overrideIfNewConfiguration && configurationChanged
            
            if let existingAnalytics = analytics, !shouldCreateNew {
                return existingAnalytics
            }
            
            let configuration = createConfiguration(writeKey: writeKey, endpoint: endpoint)
            let newAnalytics = Analytics.getOrCreateAnalytics(configuration: configuration)
            self.analytics = newAnalytics
            self.currentWriteKey = writeKey
            return newAnalytics
        }
        identify()
        return result
    }
}
