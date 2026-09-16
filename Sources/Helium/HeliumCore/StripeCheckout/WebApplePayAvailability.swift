import Foundation

/// Tracks whether the browser that external web checkout hands off to reports an Apple Pay
/// card it can pay with, so the readiness reported on launch reflects the browser rather
/// than the device.
///
/// Reads never block. The last measurement is persisted and served immediately on the next
/// launch, and a single refresh runs in the background per launch, so a value is stale for
/// at most one launch. This mirrors how the store country code is cached.
///
/// Measuring costs up to the probe timeout of work at launch, so it only happens when the
/// host app opts in with `Helium.config.enableWebApplePayReadiness`. Opted out, readiness is
/// reported as ready and the probe never runs.
class WebApplePayAvailability {
    static let shared = WebApplePayAvailability()

    private static let persistedReadinessKey = "heliumWebApplePayReadiness"

    /// The browser evaluates Apple Pay against the origin serving checkout, and the merchant
    /// identifier is derived from that hostname, so the probe loads the origin web checkout
    /// is served from. Paddle and Stripe checkout share it.
    static let probeOrigin = URL(string: PaddleBFFClient.prodSourcePageOrigin)

    private let storage: HeliumStorage

    @HeliumAtomic private var cachedReadiness: WebApplePayReadiness = .unknown(.notMeasured)
    @HeliumAtomic private var persistedReadiness: WebApplePayReadiness?
    @HeliumAtomic private var probeInFlight: Bool = false
    @HeliumAtomic private var probeAttempted: Bool = false

    init(storage: HeliumStorage = .shared) {
        self.storage = storage
        loadPersistedReadiness()
    }

    /// The value sent to targeting. Opted out, every user is reported ready so a server rule
    /// keyed on readiness leaves their behavior unchanged.
    func readiness() -> WebApplePayReadiness {
        guard Helium.config.enableWebApplePayReadiness else { return .ready }
        // Apple Pay being unavailable on the device outranks any browser measurement, including
        // one taken before restrictions or an iCloud sign-out removed it.
        guard ApplePayHelper.shared.canMakePayments() else { return .unknown(.deviceCannotPay) }
        return cachedReadiness
    }

    /// Starts the one refresh this launch gets. Returns immediately; the result lands in the
    /// cache and in storage when the probe completes.
    func refreshIfNeeded() {
        guard Helium.config.enableWebApplePayReadiness else { return }
        guard let origin = Self.probeOrigin else {
            HeliumLogger.log(.warn, category: .core, "No origin to measure web Apple Pay readiness at")
            return
        }
        guard shouldProbe() else {
            HeliumLogger.log(.debug, category: .core, "Skipping web Apple Pay probe", metadata: [
                "webCheckoutEnabled": String(!Helium.config.webCheckoutProcessors.isEmpty),
                "deviceCanMakePayments": String(ApplePayHelper.shared.canMakePayments()),
                "alreadyProbed": String(probeAttempted),
            ])
            return
        }

        let claimed = _probeInFlight.withValue { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard claimed else { return }
        probeAttempted = true

        Task { @MainActor in
            let outcome = await WebApplePayProbe(origin: origin).run()
            apply(outcome)
        }
    }

    func apply(_ outcome: WebApplePayProbe.Outcome) {
        let servedFromCache = persistedReadiness
        cachedReadiness = outcome.readiness
        probeInFlight = false
        // An unknown outcome measured nothing, so the persisted value stays as it is rather
        // than being replaced by an absent measurement.
        if !outcome.readiness.isUnknown {
            persist(outcome.readiness)
        }

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
                deviceCanMakePayments: ApplePayHelper.shared.canMakePayments(),
                servedFromCache: servedFromCache?.rawValue,
                cacheWasCorrect: servedFromCache.map { $0 == outcome.readiness }
            ),
            scope: nil
        )
    }

    /// A device that cannot do Apple Pay at all is left as `unknown` rather than
    /// reported as not ready, so the value only ever reflects a real measurement.
    func shouldProbe() -> Bool {
        guard Helium.config.enableWebApplePayReadiness else { return false }
        guard !Helium.config.webCheckoutProcessors.isEmpty else { return false }
        guard ApplePayHelper.shared.canMakePayments() else { return false }
        return !probeAttempted
    }

    // MARK: - Persistence

    private func loadPersistedReadiness() {
        guard let raw = storage.string(forKey: Self.persistedReadinessKey) else { return }
        let readiness: WebApplePayReadiness
        switch raw {
        case "ready": readiness = .ready
        case "notReady": readiness = .notReady
        default: return
        }
        persistedReadiness = readiness
        cachedReadiness = readiness
    }

    private func persist(_ readiness: WebApplePayReadiness) {
        persistedReadiness = readiness
        storage.set(readiness.rawValue, forKey: Self.persistedReadinessKey)
    }

    // MARK: - Testing

    func setReadinessForTesting(_ readiness: WebApplePayReadiness, probed: Bool = true) {
        cachedReadiness = readiness
        persistedReadiness = nil
        probeInFlight = false
        probeAttempted = probed
    }

    func setProbeInFlightForTesting(_ inFlight: Bool) {
        probeInFlight = inFlight
        probeAttempted = probeAttempted || inFlight
    }

    func persistedReadinessForTesting() -> WebApplePayReadiness? {
        persistedReadiness
    }
}
