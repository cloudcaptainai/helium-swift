//
//  HeliumStorage.swift
//  helium-swift
//

import Foundation

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

    /// Creates the shared storage instance backed by the dedicated Helium UserDefaults suite.
    init() {
        // The Optional return is an Obj-C bridging artifact — no known case where this returns nil.
        self.defaults = UserDefaults(suiteName: Self.suiteName)
    }

    /// Allows injection of a custom UserDefaults for testing.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - String

    /// Returns the string value associated with the given key, or `nil` if absent.
    func string(forKey key: String) -> String? {
        defaults?.string(forKey: key)
    }

    /// Stores or removes a string value for the given key.
    func set(_ value: String?, forKey key: String) {
        if let value {
            defaults?.set(value, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Bool

    /// Returns the boolean value associated with the given key, defaulting to `false` if absent.
    func bool(forKey key: String) -> Bool {
        defaults?.bool(forKey: key) ?? false
    }

    /// Stores a boolean value for the given key.
    func set(_ value: Bool, forKey key: String) {
        defaults?.set(value, forKey: key)
    }

    // MARK: - Int

    /// Returns the integer value associated with the given key, or `nil` if absent.
    func int(forKey key: String) -> Int? {
        defaults?.object(forKey: key) as? Int
    }

    /// Stores an integer value for the given key.
    func set(_ value: Int, forKey key: String) {
        defaults?.set(value, forKey: key)
    }

    // MARK: - Data

    /// Returns the raw data associated with the given key, or `nil` if absent.
    func data(forKey key: String) -> Data? {
        defaults?.data(forKey: key)
    }

    /// Stores or removes raw data for the given key.
    func set(_ value: Data?, forKey key: String) {
        if let value {
            defaults?.set(value, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Codable

    /// Decodes and returns a `Codable` value from the stored JSON data for the given key.
    func codable<T: Codable>(forKey key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Encodes a `Codable` value to JSON and stores it for the given key. Passing `nil` removes the entry.
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

    /// Removes the value associated with the given key.
    func remove(forKey key: String) {
        defaults?.removeObject(forKey: key)
    }
}
