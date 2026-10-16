import XCTest
@testable import Helium

final class FallbackBundleFingerprintTests: XCTestCase {
    private let suite = "FallbackBundleFingerprintTests.\(UUID().uuidString)"
    private var storage: HeliumStorage!

    override func setUp() {
        super.setUp()
        storage = HeliumStorage(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeConfig(
        generatedAt: String? = "2026-10-01T00:00:00Z",
        uuid: String = "uuid_1",
        bundles: [String: String] = ["bundle_1": "<html></html>"]
    ) -> HeliumFetchedConfig {
        var info = makeTestPaywallInfo(paywallName: "default_fallback_paywall")
        info.paywallUUID = uuid
        var config = makeTestConfig(triggers: [HeliumFallbackViewManager.defaultFallbackTrigger: info], bundles: bundles)
        config.generatedAt = generatedAt
        return config
    }

    func testFirstLoadOnThisInstallIsReported() {
        XCTAssertTrue(FallbackBundleFingerprint.markConfigured(makeConfig(), storage: storage))
        XCTAssertNotNil(storage.string(forKey: FallbackBundleFingerprint.storageKey))
    }

    func testSameBundleOnALaterLaunchIsNotReportedAgain() {
        _ = FallbackBundleFingerprint.markConfigured(makeConfig(), storage: storage)

        XCTAssertFalse(FallbackBundleFingerprint.markConfigured(makeConfig(), storage: storage))
    }

    func testBundleWithADifferentGeneratedAtIsReportedAgain() {
        _ = FallbackBundleFingerprint.markConfigured(makeConfig(), storage: storage)

        XCTAssertTrue(FallbackBundleFingerprint.markConfigured(makeConfig(generatedAt: "2026-10-02T00:00:00Z"), storage: storage))
    }

    func testBundleWithADifferentPaywallIsReportedAgain() {
        _ = FallbackBundleFingerprint.markConfigured(makeConfig(), storage: storage)

        XCTAssertTrue(FallbackBundleFingerprint.markConfigured(makeConfig(uuid: "uuid_2"), storage: storage))
    }

    func testBundleWithDifferentBundleIdsIsReportedAgain() {
        _ = FallbackBundleFingerprint.markConfigured(makeConfig(), storage: storage)

        XCTAssertTrue(FallbackBundleFingerprint.markConfigured(makeConfig(bundles: ["bundle_2": "<html></html>"]), storage: storage))
    }

    func testMissingAndEmptyGeneratedAtAreDifferentBundles() {
        XCTAssertNotEqual(
            FallbackBundleFingerprint.fingerprint(makeConfig(generatedAt: nil)),
            FallbackBundleFingerprint.fingerprint(makeConfig(generatedAt: ""))
        )
    }

    func testTriggerAndPaywallBoundariesAreNotAmbiguous() {
        var p = makeTestPaywallInfo(paywallName: "p"); p.paywallUUID = "p"
        var trialP = makeTestPaywallInfo(paywallName: "p"); trialP.paywallUUID = "trial=p"
        let first = makeTestConfig(triggers: ["offer=trial": p])
        let second = makeTestConfig(triggers: ["offer": trialP])

        XCTAssertNotEqual(FallbackBundleFingerprint.fingerprint(first), FallbackBundleFingerprint.fingerprint(second))
    }

    func testFingerprintIgnoresTriggerOrderAndConfigId() {
        var a = makeTestPaywallInfo(paywallName: "a"); a.paywallUUID = "ua"
        var b = makeTestPaywallInfo(paywallName: "b"); b.paywallUUID = "ub"
        let first = makeTestConfig(triggers: ["t1": a, "t2": b])
        let second = makeTestConfig(triggers: ["t2": b, "t1": a])

        XCTAssertEqual(FallbackBundleFingerprint.fingerprint(first), FallbackBundleFingerprint.fingerprint(second))
    }
}
