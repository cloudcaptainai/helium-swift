//
//  HeliumAnalyticsManager.swift
//

import Foundation
import UIKit

class HeliumAnalyticsManager {
    static let shared = HeliumAnalyticsManager()
    
    private let queue = DispatchQueue(label: "com.helium.analyticsManager")
    private var analytics: Analytics?
    private var currentWriteKey: String?
    
    init() {
        // Flush when will resign active for more frequent event dispatch and better chance of success during app force-close.
        // Note that this will also fire for things like checking notification drawer and phone call, but that's probably fine
        // and perhaps preferred.
        // Also note that analytics-swift does NOT flush when app goes to background, despite their code calling an empty
        // flush() {} method. It's unclear if this is intentional by them.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[HeliumAnalytics] willResignActive - triggering flush")
            self?.flush()
        }
    }

    func getAnalytics() -> Analytics? {
        queue.sync { analytics }
    }
    
    /// Flushes pending analytics events.
    func flush() {
        queue.async { [weak self] in
            self?.analytics?.flush()
        }
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
    func createConfiguration(writeKey: String, endpoint: String) -> SegmentConfiguration {
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
