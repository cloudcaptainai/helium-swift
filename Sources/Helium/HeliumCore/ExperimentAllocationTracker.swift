//
//  ExperimentAllocationTracker.swift
//  Helium
//
//  Centralized tracking for experiment allocation events
//

import Foundation

/// Manages experiment allocation event tracking across all presentation types
/// - Note: Ensures UserAllocatedEvent fires exactly once per trigger per session,
///   regardless of whether paywall is presented modally, embedded, or via view modifier
class ExperimentAllocationTracker {
    static let shared = ExperimentAllocationTracker()
    
    private init() {}
    
    /// Set of triggers for which allocation events have been fired
    private var allocatedTriggers: Set<String> = []
    
    /// Tracks allocation and fires UserAllocatedEvent if this is the first time
    /// showing a non-fallback paywall for this trigger
    ///
    /// - Parameters:
    ///   - trigger: The trigger name being displayed
    ///   - isFallback: Whether this is a fallback paywall
    ///
    /// - Note: This method is idempotent - calling it multiple times for the same
    ///   trigger will only fire the allocation event once
    func trackAllocationIfNeeded(trigger: String, isFallback: Bool) {
        // Don't fire for fallbacks or if already fired for this trigger
        guard !isFallback && !allocatedTriggers.contains(trigger) else {
            return
        }
        
        // Mark as allocated
        allocatedTriggers.insert(trigger)
        
        // Extract experiment info and fire event
        guard let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger),
              let experimentInfo = paywallInfo.extractExperimentInfo(trigger: trigger) else {
            return
        }
        
        let allocationEvent = UserAllocatedEvent(experimentInfo: experimentInfo)
        HeliumPaywallDelegateWrapper.shared.fireEvent(allocationEvent)
    }
    
    /// Resets all allocation tracking
    /// - Note: Called when SDK cache is cleared via clearAllCachedState()
    func reset() {
        allocatedTriggers.removeAll()
    }
    
    /// Check if allocation event has been fired for a trigger
    /// - Parameter trigger: The trigger name to check
    /// - Returns: true if allocation event was already fired for this trigger
    func hasTrackedAllocation(for trigger: String) -> Bool {
        return allocatedTriggers.contains(trigger)
    }
}
