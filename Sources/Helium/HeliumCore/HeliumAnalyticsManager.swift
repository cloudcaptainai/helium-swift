//
//  HeliumAnalyticsManager.swift
//

import Foundation
import UIKit

class HeliumAnalyticsManager {
    static let shared = HeliumAnalyticsManager()
    
    private let initializationWriteKey = "dIPnOYdPFgAabYaURULtIHAxbofvIIAD:GV9TlMOuPgt989LaumjVTJofZ8vipJXb"
    private let initializationEndpoint = "cm7mjur1o00003p6r7lio27sb.d.jitsu.com"
    
    private let queue = DispatchQueue(label: "com.helium.analyticsManager")
    private var analytics: Analytics?
    private var currentWriteKey: String?
    private var pendingTracks: [(Analytics) -> Void] = []
    
    private init() {
        // Flush when will resign active for more frequent event dispatch and better chance of success during app force-close.
        // Note that this will also fire for things like checking notification drawer and phone call, but that's probably fine
        // and perhaps preferred.
        // Also note that analytics-swift does NOT flush when app goes to background, despite their code calling an empty
        // flush() {} method. It's unclear if this is intentional by them.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleResignActive() {
        flush()
    }
    
    /// Flushes pending analytics events to the network.
    func flush() {
        queue.async { [weak self] in
            self?.analytics?.flush()
        }
    }
    
    /// Queues a track operation. If analytics is set up, executes immediately.
    /// Otherwise queues for dispatch when analytics becomes available.
    /// Events are dispatched in order.
    func trackEvent(_ trackClosure: @escaping (Analytics) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let analytics {
                trackClosure(analytics)
            } else {
                pendingTracks.append(trackClosure)
            }
        }
    }
    
    /// Dispatches all pending track operations to analytics. Called after analytics is set up.
    /// Must be called within queue.async.
    private func dispatchPendingTracks() {
        guard let analytics else { return }
        for trackClosure in pendingTracks {
            trackClosure(analytics)
        }
        pendingTracks.removeAll()
    }
    
    private func performIdentify(on analytics: Analytics, userId: String? = nil) {
        let resolvedUserId = userId ?? HeliumIdentityManager.shared.getUserId()
        let userContext = HeliumIdentityManager.shared.getUserContext()
        analytics.identify(userId: resolvedUserId, traits: userContext)
    }
    
    /// Identifies the current user with the analytics instance.
    /// - Parameter userId: Optional userId to use. If nil, uses HeliumIdentityManager's userId.
    func identify(userId: String? = nil) {
        queue.async { [weak self] in
            guard let self, let analytics else { return }
            performIdentify(on: analytics, userId: userId)
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
    
    /// Sets up analytics asynchronously and dispatches any pending events.
    /// Also performs identify call with current user context.
    /// - Parameter overrideIfNewConfiguration: If true and the writeKey differs from the
    ///   existing configuration, creates a new analytics instance instead of reusing the existing one.
    func setUpAnalytics(writeKey: String, endpoint: String, overrideIfNewConfiguration: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            
            let configurationChanged = currentWriteKey != writeKey
            let shouldCreateNew = overrideIfNewConfiguration && configurationChanged
            
            if analytics != nil && !shouldCreateNew {
                return // Already set up
            }
            
            let configuration = createConfiguration(writeKey: writeKey, endpoint: endpoint)
            let newAnalytics = Analytics.getOrCreateAnalytics(configuration: configuration)
            self.analytics = newAnalytics
            self.currentWriteKey = writeKey
            performIdentify(on: newAnalytics)
            dispatchPendingTracks()
        }
    }

    /// Logs the initialize event to a dedicated analytics endpoint.
    /// Runs in a separate Task to avoid blocking core analytics operations.
    func logInitializeEvent() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            
            let configuration = SegmentConfiguration(writeKey: initializationWriteKey)
                .apiHost(initializationEndpoint)
                .cdnHost(initializationEndpoint)
                .trackApplicationLifecycleEvents(false)
                .flushInterval(10)
            let initAnalytics = Analytics.getOrCreateAnalytics(configuration: configuration)
            
            initAnalytics.identify(
                userId: HeliumIdentityManager.shared.getUserId(),
                traits: HeliumIdentityManager.shared.getUserContext()
            )
            
            initAnalytics.track(name: "helium_initializeCalled", properties: [
                "timestamp": formatAsTimestamp(date: Date()),
                "heliumPersistentID": HeliumIdentityManager.shared.getHeliumPersistentId(),
                "heliumSessionID": HeliumIdentityManager.shared.getHeliumSessionId(),
                "heliumInitializeId": HeliumIdentityManager.shared.heliumInitializeId
            ])
        }
    }
    
}
