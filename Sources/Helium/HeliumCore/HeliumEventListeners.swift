//
//  HeliumEventListeners.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 10/23/25.
//

import Foundation

public protocol HeliumEventListener : AnyObject {
    func onHeliumEvent(event: HeliumEvent)
}

class HeliumEventListeners {
    static let shared = HeliumEventListeners()
    
    // Wrapper to hold weak references
    private struct WeakListener {
        weak var value: HeliumEventListener?
    }
    
    private var listeners: [WeakListener] = []
    private let queue = DispatchQueue(label: "com.helium.eventListeners")
    
    func addListener(_ listener: HeliumEventListener) {
        queue.async { [weak self] in
            guard let self else { return }
            
            cleanupListeners()
            
            // Check if listener already exists
            guard !listeners.contains(where: { $0.value === listener }) else {
                HeliumLogger.log(.warn, category: .events, "Attempted to add the same event listener multiple times. Ignoring.")
                return
            }
            
            listeners.append(WeakListener(value: listener))
        }
    }
    
    func removeListener(_ listener: HeliumEventListener) {
        queue.async { [weak self] in
            guard let self else { return }
            listeners.removeAll { $0.value === listener || $0.value == nil }
        }
    }
    
    func dispatchEvent(_ event: HeliumEvent) {
        // Capture active listeners inside the queue synchronously
        let activeListeners: [HeliumEventListener] = queue.sync { [weak self] in
            guard let self else { return [] }
            
            cleanupListeners()
            return listeners.compactMap { $0.value }
        }
        
        Task { @MainActor in
            activeListeners.forEach { $0.onHeliumEvent(event: event) }
        }
    }
    
    /// Synchronously checks whether the given listener is currently registered.
    /// Performs a queue.sync read, which also acts as a barrier ensuring any
    /// prior queue.async add/remove operations have completed.
    /// Accessible via @testable import for unit tests.
    func hasListener(_ listener: HeliumEventListener) -> Bool {
        return queue.sync {
            listeners.contains(where: { $0.value === listener })
        }
    }

    func removeAllListeners() {
        queue.async { [weak self] in
            guard let self else { return }
            listeners.removeAll()
        }
    }
    
    // Helper to remove deallocated listeners
    private func cleanupListeners() {
        listeners.removeAll { $0.value == nil }
    }
}
