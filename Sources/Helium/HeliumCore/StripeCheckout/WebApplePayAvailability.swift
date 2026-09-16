import Foundation

/// Tracks whether Apple Pay can actually be paid with in the browser that external web
/// checkout hands off to, so the readiness reported on launch reflects the browser rather
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
    private static let persistedOriginKey = "heliumWebApplePayReadinessOrigin"

    private let storage: HeliumStorage

    @HeliumAtomic private var cachedReadiness: WebApplePayReadiness = .unknown(.notMeasured)
    @HeliumAtomic private var persistedReadiness: WebApplePayReadiness?
    @HeliumAtomic private var probedOrigin: URL?
    @HeliumAtomic private var probeInFlight: Bool = false
    @HeliumAtomic private var probeAttempted: Bool = false
    @HeliumAtomic private var generation: Int = 0

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
        guard measurementMatchesCurrentOrigin() else { return .unknown(.notMeasured) }
        return cachedReadiness
    }

    /// Readiness is measured against a merchant identifier derived from the origin, so an
    /// answer measured elsewhere says nothing about the origin checkout now hands off to.
    func measurementMatchesCurrentOrigin() -> Bool {
        guard let probedOrigin, let currentOrigin = probeOrigin() else { return true }
        return probedOrigin == currentOrigin
    }

    /// Starts the one refresh this launch gets. Returns immediately; the result lands in the
    /// cache and in storage when the probe completes.
    func refreshIfNeeded() {
        guard shouldProbe() else { return }
        guard let origin = probeOrigin() else { return }

        let claimed = _probeInFlight.withValue { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard claimed else { return }
        probeAttempted = true
        let startedAt = generation

        Task { @MainActor in
            let outcome = await WebApplePayProbe(origin: origin).run()
            apply(outcome, origin: origin, generation: startedAt)
        }
    }

    func apply(_ outcome: WebApplePayProbe.Outcome, origin: URL? = nil, generation: Int? = nil) {
        // A probe that started before a reset measured a state the caller has thrown away.
        if let generation, generation != self.generation { return }
        let servedFromCache = persistedReadiness
        cachedReadiness = outcome.readiness
        probedOrigin = origin
        probeInFlight = false
        // An unknown outcome measured nothing, so the persisted value stays as it is rather
        // than being replaced by an absent measurement.
        if !outcome.readiness.isUnknown {
            persist(outcome.readiness, origin: origin)
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

    func reset() {
        cachedReadiness = .unknown(.notMeasured)
        persistedReadiness = nil
        probedOrigin = nil
        probeInFlight = false
        probeAttempted = false
        generation += 1
        storage.remove(forKey: Self.persistedReadinessKey)
        storage.remove(forKey: Self.persistedOriginKey)
    }

    /// The browser evaluates Apple Pay against the origin serving checkout, and the merchant
    /// identifier is derived from that hostname, so the probe has to load the same origin the
    /// web paywall bundle is served from. Paddle and Stripe checkout share it.
    func probeOrigin() -> URL? {
        if let bundleOrigin = webPaywallBundleOrigin() {
            return bundleOrigin
        }
        guard let clientToken = HeliumFetchedConfigManager.shared.paddleClientToken else { return nil }
        return URL(string: PaddleBFFClient.sourcePageOrigin(for: clientToken))
    }

    private func webPaywallBundleOrigin() -> URL? {
        guard let paywalls = HeliumFetchedConfigManager.shared.getConfig()?.triggerToPaywalls else {
            return nil
        }
        for trigger in paywalls.keys.sorted() {
            guard let bundleUrl = paywalls[trigger]?.webPaywallBundleUrl,
                  var components = URLComponents(string: bundleUrl),
                  components.scheme != nil,
                  components.host != nil else {
                continue
            }
            components.path = ""
            components.query = nil
            components.fragment = nil
            if let origin = components.url {
                return origin
            }
        }
        return nil
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
        probedOrigin = storage.string(forKey: Self.persistedOriginKey).flatMap(URL.init(string:))
    }

    private func persist(_ readiness: WebApplePayReadiness, origin: URL?) {
        persistedReadiness = readiness
        storage.set(readiness.rawValue, forKey: Self.persistedReadinessKey)
        storage.set(origin?.absoluteString, forKey: Self.persistedOriginKey)
    }

    // MARK: - Testing

    func setReadinessForTesting(
        _ readiness: WebApplePayReadiness,
        probed: Bool = true,
        origin: URL? = nil
    ) {
        cachedReadiness = readiness
        persistedReadiness = nil
        probedOrigin = origin
        probeInFlight = false
        probeAttempted = probed
    }

    func setProbeInFlightForTesting(_ inFlight: Bool) {
        probeInFlight = inFlight
        probeAttempted = probeAttempted || inFlight
    }

    func generationForTesting() -> Int {
        generation
    }

    func persistedReadinessForTesting() -> WebApplePayReadiness? {
        persistedReadiness
    }
}
