import Foundation
import UIKit

/// Ops/debug telemetry pipeline. Writes to a dedicated Jitsu connection
/// distinct from product analytics.
class HeliumObservabilityManager {
    static let shared = HeliumObservabilityManager()

    private let observabilityWriteKey = "rd7IAMin23xZal1auumIJURjaNrHIh7t:lJ8ssvJjYfGE8FT5ItaHkVwgqvOiMQjV"
    private let observabilityEndpoint = "cmp1v4znj00002e6pt8smcti9.d.jitsu.com"

    private let queue = DispatchQueue(label: "com.helium.observabilityManager")
    private var analytics: Analytics?
    private var pendingTracks: [(Analytics) -> Void] = []

    private init() {}

    // MARK: - Setup

    func setUp() {
        queue.async { [weak self] in
            guard let self, analytics == nil else { return }
            let configuration = SegmentConfiguration(writeKey: observabilityWriteKey)
                .apiHost(observabilityEndpoint)
                .cdnHost(observabilityEndpoint)
                .trackApplicationLifecycleEvents(false)
                .flushAt(10)
                .flushInterval(10)
            analytics = Analytics.getOrCreateAnalytics(configuration: configuration)
            dispatchPendingTracks()
        }
    }

    // MARK: - Tracking

    func track(
        _ event: any HeliumObservabilityEvent,
        scope: PaywallObservabilityScope
    ) {
        let eventName = event.name
        let eventProps = event.properties
        queue.async { [weak self] in
            guard let self else { return }
            let enriched = enrich(eventProps: eventProps, scope: scope)
            let send: (Analytics) -> Void = { analytics in
                analytics.track(name: eventName, properties: enriched)
            }
            if let analytics {
                send(analytics)
            } else {
                pendingTracks.append(send)
            }
        }
    }

    private func enrich(
        eventProps: [String: Any],
        scope: PaywallObservabilityScope
    ) -> [String: Any] {
        var p = eventProps
        p["sdkVersion"] = BuildConstants.version
        p["heliumPersistentId"] = HeliumIdentityManager.shared.getHeliumPersistentId()
        p["userId"] = HeliumIdentityManager.shared.getResolvedUserId()
        p["hasCustomUserId"] = HeliumIdentityManager.shared.hasCustomUserId()
        if let rcId = HeliumIdentityManager.shared.revenueCatAppUserId {
            p["revenueCatAppUserId"] = rcId
        }
        p["heliumSessionId"] = HeliumIdentityManager.shared.getHeliumSessionId()
        p["heliumPaywallSessionId"] = scope.sessionId
        p["triggerName"] = scope.trigger
        if let uuid = scope.paywallUUID {
            p["paywallUUID"] = uuid
        }
        if let orgId = HeliumFetchedConfigManager.shared.getOrganizationID() {
            p["organizationId"] = orgId
        }
        p["platform"] = "ios"
        p["osVersion"] = UIDevice.current.systemVersion
        p["timestamp"] = formatAsTimestamp(date: Date())
        return p
    }

    private func dispatchPendingTracks() {
        guard let analytics else { return }
        for trackClosure in pendingTracks {
            trackClosure(analytics)
        }
        pendingTracks.removeAll()
    }
}
