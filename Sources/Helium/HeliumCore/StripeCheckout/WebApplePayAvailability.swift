import Foundation

/// Tracks whether Apple Pay can actually be paid with in the browser that external web
/// checkout hands off to, so a paywall can avoid offering a checkout that will show
/// Apple Pay as unavailable.
///
/// The answer is cached in memory and refreshed on a timer because a Wallet card can be
/// added or removed while the app is running. Reads never block: callers get the last
/// known value, which is `unknown` until the first probe answers.
class WebApplePayAvailability {
    static let shared = WebApplePayAvailability()

    private let cacheDuration: TimeInterval = 30 * 60

    @HeliumAtomic private var cachedReadiness: WebApplePayReadiness = .unknown
    @HeliumAtomic private var lastProbeTime: Date?
    @HeliumAtomic private var probeInFlight: Bool = false

    private init() {}

    func readiness() -> WebApplePayReadiness {
        return cachedReadiness
    }

    /// Starts a probe unless one is running or the cached answer is still fresh.
    /// Returns immediately; the result lands in the cache when the probe completes.
    func refreshIfNeeded() {
        guard shouldProbe() else { return }
        guard let origin = probeOrigin() else { return }

        let claimed = _probeInFlight.withValue { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard claimed else { return }

        Task { @MainActor in
            let outcome = await WebApplePayProbe(origin: origin).run()
            apply(outcome)
        }
    }

    func apply(_ outcome: WebApplePayProbe.Outcome) {
        cachedReadiness = outcome.readiness
        // An unknown outcome measured nothing, so it does not hold off the next probe.
        lastProbeTime = outcome.readiness == .unknown ? nil : Date()
        probeInFlight = false

        HeliumLogger.log(.debug, category: .core, "Web Apple Pay probe completed", metadata: [
            "readiness": outcome.readiness.rawValue,
            "durationMs": String(outcome.durationMs),
        ])
        HeliumObservabilityManager.shared.track(
            WebApplePayProbeCompleted(
                readiness: outcome.readiness,
                durationMs: outcome.durationMs,
                timedOut: outcome.timedOut,
                failureReason: outcome.failureReason,
                deviceCanMakePayments: ApplePayHelper.shared.canMakePayments()
            ),
            scope: nil
        )
    }

    /// A device that cannot do Apple Pay at all is left as `unknown` rather than
    /// reported as not ready, so the value only ever reflects a real measurement.
    func shouldProbe() -> Bool {
        guard Helium.config.webCheckoutProcessors.contains(.paddle) else { return false }
        guard ApplePayHelper.shared.canMakePayments() else { return false }
        return !isCacheFresh()
    }

    func isCacheFresh() -> Bool {
        guard let lastProbe = lastProbeTime else { return false }
        return Date().timeIntervalSince(lastProbe) < cacheDuration
    }

    /// The browser evaluates Apple Pay against the origin serving checkout, and the merchant
    /// identifier is derived from that hostname, so the probe has to load the same origin
    /// checkout is served from.
    func probeOrigin() -> URL? {
        guard let clientToken = HeliumFetchedConfigManager.shared.paddleClientToken else { return nil }
        return URL(string: PaddleBFFClient.sourcePageOrigin(for: clientToken))
    }

    func setReadinessForTesting(_ readiness: WebApplePayReadiness, probedAt: Date? = Date()) {
        cachedReadiness = readiness
        lastProbeTime = probedAt
        probeInFlight = false
    }

    func cacheDurationForTesting() -> TimeInterval {
        return cacheDuration
    }
}
