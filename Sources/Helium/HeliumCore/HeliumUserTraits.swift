//
//  File.swift
//  
//
//  Created by Anish Doshi on 2/5/25.
//

import Foundation

public struct HeliumUserTraits {
    private var storage: [String: AnyCodable]
    
    private static let maxStringLength = 5_000 // ~5KB strings
    private static let maxArrayCount = 500 // 500 elements
    private static let maxDictionaryCount = 100 // 100 keys
    private static let maxNestingDepth = 10 // 10 levels deep
    
    /// Create HeliumUserTraits with a dictionary.
    /// Supports JSON-compatible types: String, Int, Double, Bool, Array, Dictionary.
    /// Date, UUID, and URL are auto-converted to strings; other types are skipped.
    /// Large values are truncated with a warning.
    public init(_ traits: [String: Any]) {
        self.storage = traits.compactMapValues { value -> AnyCodable? in
            if let safeValue = Self.toJSONSafeValue(value, depth: 0) {
                return AnyCodable(safeValue)
            }
            return nil
        }
    }

    /// Converts a value to a JSON-safe type recursively, or returns nil if not convertible.
    /// Truncates values that exceed size limits.
    private static func toJSONSafeValue(_ value: Any, depth: Int) -> Any? {
        // Check nesting depth first
        if depth > maxNestingDepth {
            print("[Helium] Warning: User trait value exceeds maximum nesting depth of \(maxNestingDepth). Skipping nested value.")
            return nil
        }
        // Convert known types to JSON-safe equivalents first
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        if let url = value as? URL {
            let urlString = url.absoluteString
            if urlString.count > maxStringLength {
                print("[Helium] Warning: User trait URL value exceeds maximum length of \(maxStringLength) characters. Truncating.")
                return String(urlString.prefix(maxStringLength))
            }
            return urlString
        }

        // Handle strings with length limit
        if let string = value as? String {
            if string.count > maxStringLength {
                print("[Helium] Warning: User trait string value exceeds maximum length of \(maxStringLength) characters. Truncating.")
                return String(string.prefix(maxStringLength))
            }
            return string
        }
        
        // Handle arrays recursively with count limit
        if let array = value as? [Any] {
            var truncatedArray = array
            if array.count > maxArrayCount {
                print("[Helium] Warning: User trait array exceeds maximum count of \(maxArrayCount) elements. Truncating.")
                truncatedArray = Array(array.prefix(maxArrayCount))
            }
            return truncatedArray.compactMap { toJSONSafeValue($0, depth: depth + 1) }
        }

        // Handle dictionaries recursively with count limit
        if let dict = value as? [String: Any] {
            var truncatedDict = dict
            if dict.count > maxDictionaryCount {
                print("[Helium] Warning: User trait dictionary exceeds maximum count of \(maxDictionaryCount) keys. Truncating.")
                truncatedDict = Dictionary(uniqueKeysWithValues: dict.prefix(maxDictionaryCount).map { ($0.key, $0.value) })
            }
            return truncatedDict.compactMapValues { toJSONSafeValue($0, depth: depth + 1) }
        }

        // Check if it's a JSON-safe primitive (Int, Double, Bool, NSNull)
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
            if let safeValue = Self.toJSONSafeValue(newValue, depth: 0) {
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
