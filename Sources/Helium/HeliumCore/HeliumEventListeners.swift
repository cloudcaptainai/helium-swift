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
                print("[Helium] Attempted to add the same event listener multiple times. Ignoring.")
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
    
    func onHeliumEvent(event: HeliumEvent) {
        // Capture active listeners inside the queue synchronously
        let activeListeners: [HeliumEventListener] = queue.sync { [weak self] in
            guard let self else { return [] }
            
            cleanupListeners()
            return listeners.compactMap { $0.value }
        }
        
        // Notify listeners outside the queue to avoid blocking it
        activeListeners.forEach { $0.onHeliumEvent(event: event) }
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
