//
//  File.swift
//  
//
//  Created by Anish Doshi on 2/5/25.
//

import Foundation

public struct HeliumUserTraits {
    private var storage: [String: AnyCodable]
    
    // Main dictionary initializer that others will call into
    public init(_ traits: [String: Any]) {
        self.storage = traits.mapValues { AnyCodable($0) }
    }
    
    public subscript<T: Codable>(key: String) -> T? {
        get { storage[key]?.value as? T }
        set { storage[key] = newValue.map(AnyCodable.init) }
    }
    
    // Fluent setter for chaining
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
