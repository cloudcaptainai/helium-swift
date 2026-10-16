import CryptoKit
import Foundation

struct FallbackBundleFingerprint {
    static let storageKey = "fallbackPaywallsConfiguredBundle"
    private static let lock = NSLock()

    static func fingerprint(_ config: HeliumFetchedConfig) -> String {
        var parts = [config.generatedAt ?? "", config.organizationID ?? ""]
        parts += config.triggerToPaywalls
            .map { "\($0.key)=\($0.value.paywallUUID ?? "")" }
            .sorted()
        parts += (config.bundles ?? [:]).keys.sorted()
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
