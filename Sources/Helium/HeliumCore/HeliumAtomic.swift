//
//  HeliumAtomic.swift
//  Helium
//
//  Thread-safe property wrapper for atomic access to mutable values.
//

import Foundation

/// A property wrapper that provides thread-safe atomic access to values.
///
/// Use this to prevent data races when a value may be accessed from multiple threads.
/// All read and write operations are serialized through a dedicated queue.
///
/// Example:
/// ```swift
/// @HeliumAtomic private var priceMap: [String: Price] = [:]
///
/// // Thread-safe read
/// let prices = priceMap
///
/// // Thread-safe write
/// priceMap = newPrices
///
/// // Atomic read-modify-write
/// _priceMap.withValue { map in
///     map.merge(newPrices) { _, new in new }
/// }
/// ```
// TODO: When minimum iOS version is raised to 18+, consider using Synchronization.Mutex
// for better performance while maintaining the same @propertyWrapper API. This would provide
// lock-free atomic operations without breaking any existing code.
@propertyWrapper
final class HeliumAtomic<T>: @unchecked Sendable {
    
    private var value: T
    private let queue: DispatchQueue
    
    init(wrappedValue value: T) {
        self.value = value
        self.queue = DispatchQueue(label: "helium_\(DispatchTime.now().uptimeNanoseconds)")
    }
    
    var wrappedValue: T {
        get { queue.sync { value } }
        set { queue.sync { value = newValue } }
    }
    
    /// Performs an atomic read-modify-write operation.
    /// - Parameter operation: A closure that receives mutable access to the wrapped value
    /// - Returns: The updated value after the operation completes
    @discardableResult
    func withValue(_ operation: (inout T) -> Void) -> T {
        queue.sync {
            operation(&self.value)
            return self.value
        }
    }

    /// Performs an atomic operation that returns an arbitrary result.
    /// - Parameter operation: A closure that receives mutable access to the wrapped value and returns a result
    /// - Returns: The result of the operation
    func withValue<R>(_ operation: (inout T) -> R) -> R {
        queue.sync {
            operation(&self.value)
        }
    }
}
