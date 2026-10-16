import CryptoKit
import Foundation

struct FallbackBundleFingerprint {
    static let storageKey = "fallbackPaywallsConfiguredBundle"
    private static let lock = NSLock()

    private struct Snapshot: Encodable {
        let generatedAt: String?
        let organizationID: String?
        let triggerToPaywallUUID: [String: String?]
        let bundleIDs: [String]
    }

    static func fingerprint(_ config: HeliumFetchedConfig) -> String {
        let snapshot = Snapshot(
            generatedAt: config.generatedAt,
            organizationID: config.organizationID,
            triggerToPaywallUUID: config.triggerToPaywalls.mapValues { $0.paywallUUID },
            bundleIDs: (config.bundles ?? [:]).keys.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(snapshot)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func markConfigured(_ config: HeliumFetchedConfig, storage: HeliumStorage = .shared) -> Bool {
        let current = fingerprint(config)
        lock.lock()
        defer { lock.unlock() }
        guard storage.string(forKey: storageKey) != current else { return false }
        storage.set(current, forKey: storageKey)
        return true
    }
}
