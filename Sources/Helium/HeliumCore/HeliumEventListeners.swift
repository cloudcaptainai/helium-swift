//
//  HeliumEventListeners.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 10/23/25.
//

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
    
    func addListener(_ listener: HeliumEventListener) {
        // Remove any nil references before adding
        cleanupListeners()
        listeners.append(WeakListener(value: listener))
    }
    
    func removeListener(_ listener: HeliumEventListener) {
        listeners.removeAll { $0.value === listener || $0.value == nil }
    }
    
    func onHeliumEvent(event: HeliumEvent) {
        // Clean up nil references and notify active listeners
        cleanupListeners()
        listeners.forEach {
            $0.value?.onHeliumEvent(event: event)
        }
    }
    
    func removeAllListeners() {
        listeners.removeAll()
    }
    
    // Helper to remove deallocated listeners
    private func cleanupListeners() {
        listeners.removeAll { $0.value == nil }
    }
}
