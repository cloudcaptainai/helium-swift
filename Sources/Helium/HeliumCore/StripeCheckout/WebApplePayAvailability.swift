import Foundation

/// Tracks whether the browser that external web checkout hands off to reports an Apple Pay
/// card it can pay with, so the readiness reported on launch reflects the browser rather
/// than the device.
///
/// Reads never block. The last measurement is persisted and served immediately on the next
/// launch, and a single refresh runs in the background per launch, so a value is stale for
/// at most one launch. This mirrors how the store country code is cached. A device that has
/// never probed has nothing to report, so the config request waits for that one measurement,
/// bounded by the launch wait budget; a probe slower than the budget outlives it and stores
/// its measurement for the next launch.
///
/// Measuring costs up to the launch wait budget of work at launch, so it only happens when
/// the host app opts in with `Helium.config.enableWebApplePayReadiness`. Opted out, readiness
/// is reported as ready and the probe never runs.
class WebApplePayAvailability {
    static let shared = WebApplePayAvailability()

    private static let persistedReadinessKey = "heliumWebApplePayReadiness"
    private static let hasProbedKey = "heliumWebApplePayProbed"

    /// How long a launch is willing to wait on a first measurement.
    static let launchWaitBudget: TimeInterval = 2

    /// The browser evaluates Apple Pay against the origin serving checkout, and the merchant
    /// identifier is derived from that hostname, so the probe loads the origin web checkout
    /// is served from. Paddle and Stripe checkout share it.
    static let probeOrigin = URL(string: PaddleBFFClient.prodSourcePageOrigin)

    private let storage: HeliumStorage

    @HeliumAtomic private var cachedReadiness: WebApplePayReadiness = .unknown(.notMeasured)
    @HeliumAtomic private var persistedReadiness: WebApplePayReadiness?
    @HeliumAtomic private var probeInFlight: Bool = false
    @HeliumAtomic private var probeAttempted: Bool = false
    @HeliumAtomic private var probedOnAPreviousLaunch: Bool = false
    @HeliumAtomic private var measurementWaiters: [ObjectIdentifier: MeasurementWaiter] = [:]
    @HeliumAtomic private var launchWaitMs: Int?

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

    /// Readies the value the launch request carries. A device that has never probed has
    /// nothing to report, so it waits for a measurement, bounded by the launch wait budget;
    /// any later launch returns at once and measures behind the request. Waiting is keyed on
    /// having probed rather than on holding a measurement, so a probe that keeps failing
    /// costs the budget once rather than on every launch.
    func prepareForRequest() async {
        let waitsForMeasurement = needsMeasurementBeforeLaunch()
        let started = startProbe()
        guard waitsForMeasurement, started else { return }
        await awaitMeasurement(upTo: Self.launchWaitBudget)
    }

    func needsMeasurementBeforeLaunch() -> Bool {
        !probedOnAPreviousLaunch && shouldProbe() && Self.probeOrigin != nil
    }

    /// Starts the one refresh this launch gets, reporting whether it started. Returns
    /// immediately; the result lands in the cache and in storage when the probe completes,
    /// however long after the launch request that is.
    @discardableResult
    func startProbe() -> Bool {
        guard let origin = claimProbe() else { return false }

        Task { @MainActor in
            self.apply(await WebApplePayProbe(origin: origin).run())
        }
        return true
    }

    /// Waits for a measurement, giving up after the budget. Giving up leaves the probe
    /// running rather than cancelling it, so a launch too slow to measure still pays for
    /// the next one.
    func awaitMeasurement(upTo budget: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = MeasurementWaiter(continuation)
            let key = ObjectIdentifier(waiter)
            _measurementWaiters.withValue { $0[key] = waiter }

            Task { [weak self, budget] in
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                self?.resumeWaiter(key)
            }

            // A probe that answered before this waiter registered has nothing left to wait on.
            if probeAttempted && !probeInFlight {
                resumeWaiter(key)
            }
        }
    }

    private func resumeWaiter(_ key: ObjectIdentifier) {
        let waiter = _measurementWaiters.withValue { $0.removeValue(forKey: key) }
        if let heldMs = waiter?.resume() { launchWaitMs = heldMs }
    }

    private func resumeMeasurementWaiters() {
        let waiters = _measurementWaiters.withValue { waiters -> [MeasurementWaiter] in
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        if let heldMs = waiters.compactMap({ $0.resume() }).max() { launchWaitMs = heldMs }
    }

    /// The origin to probe, claimed for this caller, or `nil` when no probe should run.
    private func claimProbe() -> URL? {
        guard Helium.config.enableWebApplePayReadiness else { return nil }
        guard let origin = Self.probeOrigin else {
            HeliumLogger.log(.warn, category: .core, "No origin to measure web Apple Pay readiness at")
            return nil
        }
        guard shouldProbe() else {
            HeliumLogger.log(.debug, category: .core, "Skipping web Apple Pay probe", metadata: [
                "webCheckoutEnabled": String(!Helium.config.webCheckoutProcessors.isEmpty),
                "deviceCanMakePayments": String(ApplePayHelper.shared.canMakePayments()),
                "alreadyProbed": String(probeAttempted),
            ])
            return nil
        }

        let claimed = _probeInFlight.withValue { inFlight -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard claimed else { return nil }
        probeAttempted = true
        return origin
    }

    func apply(_ outcome: WebApplePayProbe.Outcome) {
        let servedFromCache = persistedReadiness
        cachedReadiness = outcome.readiness
        probeInFlight = false
        recordProbed()
        resumeMeasurementWaiters()
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
                launchWaitMs: launchWaitMs,
                servedFromCache: servedFromCache?.rawValue,
                cacheWasCorrect: Self.cacheCorrectness(of: servedFromCache, against: outcome.readiness)
            ),
            scope: nil
        )
    }

    /// Unverified, rather than incorrect, when the probe itself measured nothing.
    static func cacheCorrectness(
        of servedFromCache: WebApplePayReadiness?,
        against measured: WebApplePayReadiness
    ) -> Bool? {
        guard !measured.isUnknown else { return nil }
        return servedFromCache.map { $0 == measured }
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
        probedOnAPreviousLaunch = storage.bool(forKey: Self.hasProbedKey)
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

    private func recordProbed() {
        guard !probedOnAPreviousLaunch else { return }
        probedOnAPreviousLaunch = true
        storage.set(true, forKey: Self.hasProbedKey)
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
        probedOnAPreviousLaunch = false
    }

    func setProbeInFlightForTesting(_ inFlight: Bool) {
        probeInFlight = inFlight
        probeAttempted = probeAttempted || inFlight
    }

    func persistedReadinessForTesting() -> WebApplePayReadiness? {
        persistedReadiness
    }

    func launchWaitMsForTesting() -> Int? {
        launchWaitMs
    }
}

/// A launch waiting on a measurement, resumed by whichever of the measurement and the
/// wait budget arrives first.
private final class MeasurementWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private let startedAt = Date()

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// How long the launch was held, or `nil` when it was already resumed.
    @discardableResult
    func resume() -> Int? {
        guard let continuation else { return nil }
        self.continuation = nil
        continuation.resume()
        return Int(Date().timeIntervalSince(startedAt) * 1000)
    }
}
