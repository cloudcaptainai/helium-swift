//
//  ExperimentAllocationTracker.swift
//  Helium
//
//  Centralized tracking for experiment allocation events
//

import Foundation

/// Stored allocation details for comparison
private struct StoredAllocation: Codable {
    let experimentId: String?
    let allocationId: String?
    let allocationIndex: Int?
    let audienceId: String?
    
    init(from experimentInfo: ExperimentInfo) {
        self.experimentId = experimentInfo.experimentId
        self.allocationId = experimentInfo.chosenVariantDetails?.allocationId
        self.allocationIndex = experimentInfo.chosenVariantDetails?.allocationIndex
        self.audienceId = experimentInfo.audienceId
    }
}

/// Manages experiment allocation event tracking across all presentation types
/// - Note: Ensures UserAllocatedEvent fires only when user gets a new allocation or 
///   when experiment details change for the user (by Helium persistent ID)
class ExperimentAllocationTracker {
    static let shared = ExperimentAllocationTracker()
    
    private init() {
        loadStoredAllocations()
    }
    
    private let storageKey = "heliumExperimentAllocations"
    
    /// Maps "persistentId_trigger" to stored allocation details
    private var storedAllocations: [String: StoredAllocation] = [:]
    
    /// Loads stored allocations from UserDefaults
    private func loadStoredAllocations() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: StoredAllocation].self, from: data) else {
            return
        }
        storedAllocations = decoded
    }
    
    /// Persists allocations to UserDefaults
    private func saveStoredAllocations() {
        guard let encoded = try? JSONEncoder().encode(storedAllocations) else {
            return
        }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
    
    /// Creates a storage key for user + trigger combination
    private func storageKey(persistentId: String, trigger: String) -> String {
        return "\(persistentId)_\(trigger)"
    }
    
    /// Determines if an allocation event should fire based on allocation changes
    /// 
    /// - Parameters:
    ///   - current: The current allocation details
    ///   - existing: The previously stored allocation details (nil if no previous allocation)
    /// - Returns: true if the event should fire (new allocation or details changed), false otherwise
    ///
    /// An allocation event fires when:
    /// - No previous allocation exists (first time user sees this trigger)
    /// - The experimentId changed (different experiment is running)
    /// - The allocationId changed (different paywall variant assigned)
    /// - The allocationIndex changed (different position in variant array)
    /// - The audienceId changed (user matched a different audience)
    private func shouldFireAllocationEvent(
        current: StoredAllocation,
        existing: StoredAllocation?
    ) -> Bool {
        // No previous allocation - this is a new allocation
        guard let existing = existing else {
            return true
        }
        
        // Check each field explicitly to detect any change
        if current.experimentId != existing.experimentId {
            return true  // Different experiment
        }
        
        if current.allocationId != existing.allocationId {
            return true  // Different paywall variant
        }
        
        if current.allocationIndex != existing.allocationIndex {
            return true  // Different variant position
        }
        
        if current.audienceId != existing.audienceId {
            return true  // Different audience matched
        }
        
        // All fields match - no change, don't fire event
        return false
    }
    
    /// Tracks allocation and fires UserAllocatedEvent if this is the first time
    /// this user is allocated to this trigger, or if the experiment details have changed
    ///
    /// - Parameters:
    ///   - trigger: The trigger name being displayed
    ///   - isFallback: Whether this is a fallback paywall
    ///
    /// - Note: This method only fires events when the user doesn't have an existing
    ///   allocation or when the allocation details have changed
    func trackAllocationIfNeeded(trigger: String, isFallback: Bool) {
        // Don't fire for fallbacks
        guard !isFallback else {
            return
        }
        
        // Extract experiment info
        guard let paywallInfo = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger),
              let experimentInfo = paywallInfo.extractExperimentInfo(trigger: trigger) else {
            return
        }
        
        // Get user's persistent ID
        let persistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let key = storageKey(persistentId: persistentId, trigger: trigger)
        
        // Create current allocation details
        let currentAllocation = StoredAllocation(from: experimentInfo)
        
        // Check if we should fire the allocation event
        let existingAllocation = storedAllocations[key]
        guard shouldFireAllocationEvent(current: currentAllocation, existing: existingAllocation) else {
            return  // No change, don't fire event
        }
        
        // Store the new allocation
        storedAllocations[key] = currentAllocation
        saveStoredAllocations()
        
        // Fire the allocation event
        let allocationEvent = UserAllocatedEvent(experimentInfo: experimentInfo)
        HeliumPaywallDelegateWrapper.shared.fireEvent(allocationEvent)
    }
    
    /// Resets all allocation tracking
    /// - Note: Called when SDK cache is cleared via clearAllCachedState()
    func reset() {
        storedAllocations.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
    
    /// Check if allocation exists for a specific user and trigger
    /// - Parameters:
    ///   - persistentId: The user's Helium persistent ID
    ///   - trigger: The trigger name to check
    /// - Returns: true if an allocation has been tracked for this user + trigger
    func hasTrackedAllocation(persistentId: String, trigger: String) -> Bool {
        let key = storageKey(persistentId: persistentId, trigger: trigger)
        return storedAllocations[key] != nil
    }
}
