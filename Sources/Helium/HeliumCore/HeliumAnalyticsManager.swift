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
    
    /// Tracks a paywall event, building the logged event and sending to analytics.
    /// Handles conversion to legacy format, event enrichment, and flushing for critical events.
    func trackPaywallEvent(_ event: HeliumEvent, paywallSession: PaywallSession?) {
        queue.async { [weak self] in
            guard let self else { return }
            
            let legacyEvent = event.toLegacyEvent()
            let fallbackBundleConfig = HeliumFallbackViewManager.shared.getConfig()
            
            var experimentID: String? = nil
            var modelID: String? = nil
            var paywallInfo: HeliumPaywallInfo? = paywallSession?.paywallInfoWithBackups
            var experimentInfo: ExperimentInfo? = nil
            var isFallback: Bool? = nil
            if let paywallSession {
                isFallback = paywallSession.fallbackType != .notFallback
            }
            if let triggerName = (legacyEvent.getTriggerIfExists() ?? paywallSession?.trigger) {
                experimentID = HeliumFetchedConfigManager.shared.getExperimentIDForTrigger(triggerName)
                modelID = HeliumFetchedConfigManager.shared.getModelIDForTrigger(triggerName)
                experimentInfo = HeliumFetchedConfigManager.shared.extractExperimentInfo(trigger: triggerName)

                if paywallInfo == nil && paywallSession == nil {
                    paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(triggerName)
                }
                if isFallback == nil {
                    // Old isFallback determination. This can likely be removed at some point.
                    if paywallInfo == nil {
                        isFallback = true
                    } else {
                        let eventPaywallTemplateName = legacyEvent.getPaywallTemplateNameIfExists() ?? ""
                        isFallback = eventPaywallTemplateName == HELIUM_FALLBACK_PAYWALL_NAME || paywallInfo?.paywallTemplateName == HELIUM_FALLBACK_PAYWALL_NAME || eventPaywallTemplateName.starts(with: "fallback_")
                    }
                }
            }
            
            let fetchedConfigId = HeliumFetchedConfigManager.shared.getConfigId() ?? fallbackBundleConfig?.fetchedConfigID
            let organizationID = HeliumFetchedConfigManager.shared.getOrganizationID() ?? fallbackBundleConfig?.organizationID
            let eventForLogging = HeliumPaywallLoggedEvent(
                heliumEvent: legacyEvent,
                fetchedConfigId: fetchedConfigId,
                timestamp: formatAsTimestamp(date: Date()),
                contextTraits: HeliumIdentityManager.shared.getUserContext(skipDeviceCapacity: true),
                experimentID: experimentID,
                modelID: modelID,
                paywallID: paywallInfo?.paywallID,
                paywallUUID: paywallInfo?.paywallUUID,
                organizationID: organizationID,
                heliumPersistentID: HeliumIdentityManager.shared.getHeliumPersistentId(),
                heliumSessionID: HeliumIdentityManager.shared.getHeliumSessionId(),
                heliumInitializeId: HeliumIdentityManager.shared.heliumInitializeId,
                heliumPaywallSessionId: paywallSession?.sessionId,
                appAttributionToken: HeliumIdentityManager.shared.appAttributionToken.uuidString,
                appTransactionId: HeliumIdentityManager.shared.appTransactionID,
                revenueCatAppUserID: HeliumIdentityManager.shared.revenueCatAppUserId,
                isFallback: isFallback,
                downloadStatus: HeliumFetchedConfigManager.shared.downloadStatus,
                additionalFields: HeliumFetchedConfigManager.shared.fetchedConfig?.additionalFields,
                additionalPaywallFields: paywallInfo?.additionalPaywallFields,
                experimentInfo: experimentInfo
            )
            
            // Track event and flush for critical events
            let eventName = "helium_" + legacyEvent.caseString()
            let trackAndFlush: (Analytics) -> Void = { analytics in
                analytics.track(name: eventName, properties: eventForLogging)
                
                // Flush immediately for critical events to minimize event loss
                switch legacyEvent {
                case .paywallOpen, .paywallClose, .subscriptionSucceeded:
                    analytics.flush()
                default:
                    break
                }
            }
            
            if let analytics {
                trackAndFlush(analytics)
            } else {
                pendingTracks.append(trackAndFlush)
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
            HeliumLogger.log(.debug, category: .events, "Identifying user", metadata: ["userId": userId ?? "Unknown userId"])
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
                HeliumLogger.log(.trace, category: .events, "Reusing existing analytics instance")
                return // Already set up
            }

            HeliumLogger.log(.debug, category: .events, "Setting up new analytics instance", metadata: ["endpoint": endpoint])
            let configuration = createConfiguration(writeKey: writeKey, endpoint: endpoint)
            let newAnalytics = Analytics.getOrCreateAnalytics(configuration: configuration)
            analytics = newAnalytics
            currentWriteKey = writeKey
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
