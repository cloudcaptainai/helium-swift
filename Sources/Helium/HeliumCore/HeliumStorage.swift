//
//  HeliumStorage.swift
//  helium-swift
//

import Foundation

/// Helium-owned subdirectory of Application Support. All Helium SDK file persistence
/// lives under this root so it stays isolated from host-app data and any other
/// Segment/third-party SDKs the host may ship.
///
/// Returns nil only if the user-domain Application Support URL cannot be resolved,
/// which doesn't happen on real Apple devices; callers should tolerate the optional
/// rather than force-unwrapping.
///
/// Future consideration: the `Helium` directory name could collide with a host app
/// that happens to use the same subdirectory for its own data. Consider migrating
/// to a reverse-DNS name like `com.tryhelium.sdk` (matching the UserDefaults suite)
/// to guarantee uniqueness. Would require a one-time migration of existing files.
internal var heliumAppSupportDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("Helium", isDirectory: true)
}

/// Centralized persistence layer for the Helium SDK.
///
/// Backed by a dedicated UserDefaults suite (`com.tryhelium.sdk`) to avoid
/// polluting the host app's standard UserDefaults.
///
/// If the suite cannot be created (no known case, but defensive), all operations
/// become silent no-ops — persistence degrades but the SDK never crashes and
/// never writes to the host app's standard UserDefaults.
///
/// All existing callers still use `UserDefaults.standard` directly — migrate
/// them to this manager incrementally. New persistence should go through here.
///
/// Thread safety: UserDefaults is thread-safe, so no additional locking is needed.
class HeliumStorage {
    static let shared = HeliumStorage()

    private let defaults: UserDefaults?

    private static let suiteName = "com.tryhelium.sdk"

    init() {
        // The Optional return is an Obj-C bridging artifact — no known case where this returns nil.
        self.defaults = UserDefaults(suiteName: Self.suiteName)
    }

    /// Allows injection of a custom UserDefaults for testing.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - String

    func string(forKey key: String) -> String? {
        defaults?.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        if let value {
            defaults?.set(value, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Bool

    func bool(forKey key: String) -> Bool {
        defaults?.bool(forKey: key) ?? false
    }

    func set(_ value: Bool, forKey key: String) {
        defaults?.set(value, forKey: key)
    }

    // MARK: - Int

    func int(forKey key: String) -> Int? {
        defaults?.object(forKey: key) as? Int
    }

    func set(_ value: Int, forKey key: String) {
        defaults?.set(value, forKey: key)
    }

    // MARK: - Data

    func data(forKey key: String) -> Data? {
        defaults?.data(forKey: key)
    }

    func set(_ value: Data?, forKey key: String) {
        if let value {
            defaults?.set(value, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Codable

    func codable<T: Codable>(forKey key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setCodable<T: Codable>(_ value: T?, forKey key: String) {
        guard let value else {
            defaults?.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else {
            HeliumLogger.log(.warn, category: .core, "Failed to encode value for key '\(key)'")
            return
        }
        defaults?.set(data, forKey: key)
    }

    // MARK: - Remove

    func remove(forKey key: String) {
        defaults?.removeObject(forKey: key)
    }
}
