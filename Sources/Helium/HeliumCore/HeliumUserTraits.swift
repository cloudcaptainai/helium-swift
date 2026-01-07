//
//  File.swift
//  
//
//  Created by Anish Doshi on 2/5/25.
//

import Foundation

public struct HeliumUserTraits {
    private var storage: [String: AnyCodable]
    
    /// Create HeliumUserTraits with a dictionary.
    /// Supports JSON-compatible types: String, Int, Double, Bool, Array, Dictionary.
    /// Date, UUID, and URL are auto-converted to strings; other types are skipped.
    public init(_ traits: [String: Any]) {
        self.storage = traits.compactMapValues { value -> AnyCodable? in
            if let safeValue = Self.toJSONSafeValue(value) {
                return AnyCodable(safeValue)
            }
            return nil
        }
    }

    /// Converts a value to a JSON-safe type recursively, or returns nil if not convertible
    private static func toJSONSafeValue(_ value: Any) -> Any? {
        // Convert known types to JSON-safe equivalents first
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        if let url = value as? URL {
            return url.absoluteString
        }

        // Handle arrays recursively
        if let array = value as? [Any] {
            return array.compactMap { toJSONSafeValue($0) }
        }

        // Handle dictionaries recursively
        if let dict = value as? [String: Any] {
            return dict.compactMapValues { toJSONSafeValue($0) }
        }

        // Check if it's a JSON-safe primitive (String, Int, Double, Bool, NSNull)
        if JSONSerialization.isValidJSONObject(["k": value]) {
            return value
        }

        // Non-serializable type - log warning and skip
        print("[Helium] Warning: Skipping non-JSON-serializable user trait value of type \(type(of: value)). Supported types are String, Int, Double, Bool, Date, Array, Dictionary.")
        return nil
    }
    
    public subscript<T: Codable>(key: String) -> T? {
        get { storage[key]?.value as? T }
        set {
            guard let newValue else {
                storage[key] = nil
                return
            }
            if let safeValue = Self.toJSONSafeValue(newValue) {
                storage[key] = AnyCodable(safeValue)
            }
            // If toJSONSafeValue returns nil, the value is silently dropped
        }
    }

    /// Fluent setter for chaining.
    /// Supports JSON-compatible types: String, Int, Double, Bool, Array, Dictionary.
    /// Date, UUID, and URL are auto-converted to strings; other types are skipped.
    @discardableResult
    public mutating func set<T: Codable>(_ key: String, _ value: T?) -> Self {
        self[key] = value
        return self
    }
    
    // Dictionary representation for serialization
    public var dictionaryRepresentation: [String: Any] {
        storage.compactMapValues { $0.value }
    }
    
    // Merge traits
    public mutating func merge(_ other: HeliumUserTraits) {
        storage.merge(other.storage, uniquingKeysWith: { _, new in new })
    }
    
    // Remove a trait
    public mutating func remove(_ key: String) {
        storage.removeValue(forKey: key)
    }
    
    // Check if trait exists
    public func has(_ key: String) -> Bool {
        storage.keys.contains(key)
    }
    
    // Clear all traits
    public mutating func clear() {
        storage.removeAll()
    }
    
    // Count of traits
    public var count: Int {
        storage.count
    }
    
    // All trait keys
    public var keys: [String] {
        Array(storage.keys)
    }
}

// MARK: - Codable
extension HeliumUserTraits: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dictionary = try container.decode([String: AnyCodable].self)
        self.storage = dictionary
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}

// MARK: - Equatable
extension HeliumUserTraits: Equatable {
    public static func == (lhs: HeliumUserTraits, rhs: HeliumUserTraits) -> Bool {
        lhs.storage == rhs.storage
    }
}

// MARK: - Type-specific convenience constructors
extension HeliumUserTraits {
    // Instead of having multiple init(_ traits:) with different types,
    // we'll use specifically named initializers
    public static func withStringTraits(_ traits: [String: String]) -> HeliumUserTraits {
        HeliumUserTraits(traits.mapValues { $0 as Any })
    }
    
    public static func withIntTraits(_ traits: [String: Int]) -> HeliumUserTraits {
        HeliumUserTraits(traits.mapValues { $0 as Any })
    }
    
    public static func withDoubleTraits(_ traits: [String: Double]) -> HeliumUserTraits {
        HeliumUserTraits(traits.mapValues { $0 as Any })
    }
    
    public static func withBoolTraits(_ traits: [String: Bool]) -> HeliumUserTraits {
        HeliumUserTraits(traits.mapValues { $0 as Any })
    }
    
    // Empty traits constructor
    public static var empty: HeliumUserTraits {
        HeliumUserTraits([:])
    }
}
