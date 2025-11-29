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
    let enrolledAt: Date?
    let enrolledTrigger: String?
    
    init(from experimentInfo: ExperimentInfo, trigger: String) {
        self.experimentId = experimentInfo.experimentId
        self.allocationId = experimentInfo.chosenVariantDetails?.allocationId
        self.allocationIndex = experimentInfo.chosenVariantDetails?.allocationIndex
        self.audienceId = experimentInfo.audienceId
        self.enrolledAt = Date()
        self.enrolledTrigger = trigger
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
    
    private let allocationsUserDefaultsKey = "heliumExperimentAllocations"
    
    /// Maps "persistentId_trigger" to stored allocation details
    private var storedAllocations: [String: StoredAllocation] = [:]
    
    /// Loads stored allocations from UserDefaults
    private func loadStoredAllocations() {
        guard let data = UserDefaults.standard.data(forKey: allocationsUserDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: StoredAllocation].self, from: data) else {
            return
        }
        storedAllocations = decoded
    }
    
    /// Persists allocations to UserDefaults
    private func saveStoredAllocations() {
        guard let encoded = try? JSONEncoder().encode(storedAllocations) else {
            print("[Helium] Failed to persist experiment allocations")
            return
        }
        UserDefaults.standard.set(encoded, forKey: allocationsUserDefaultsKey)
    }
    
    /// Creates a storage key for user + experiment combination
    private func storageKey(persistentId: String, experimentId: String) -> String {
        return "\(persistentId)_\(experimentId)"
    }
    
    /// Creates a legacy storage key for backward compatibility (user + trigger)
    private func legacyStorageKey(persistentId: String, trigger: String) -> String {
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
        
        return !isSameExperimentAllocation(current, existing)
    }

    private func isSameExperimentAllocation(
        _ first: StoredAllocation,
        _ second: StoredAllocation
    ) -> Bool {
        // Check each field explicitly to detect any change
        if first.experimentId != second.experimentId {
            return false  // Different experiment
        }
        
        if first.allocationId != second.allocationId {
            return false  // Different paywall variant
        }
        
        if first.allocationIndex != second.allocationIndex {
            return false  // Different variant position
        }
        
        if first.audienceId != second.audienceId {
            return false  // Different audience matched
        }
        
        // All fields match
        return true
    }
    
    /// Tracks allocation and fires UserAllocatedEvent if this is the first time
    /// this user is allocated to this experiment, or if the experiment details have changed
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
        guard let config = HeliumFetchedConfigManager.shared.getConfig(),
              var experimentInfo = config.extractExperimentInfo(trigger: trigger) else {
            return
        }
        
        // Need experiment ID to track allocations
        guard let experimentId = experimentInfo.experimentId, !experimentId.isEmpty else {
            return
        }
        
        // Get user's persistent ID
        let persistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let newKey = storageKey(persistentId: persistentId, experimentId: experimentId)
        let legacyKey = legacyStorageKey(persistentId: persistentId, trigger: trigger)
        
        // Create current allocation details
        let currentAllocation = StoredAllocation(from: experimentInfo, trigger: trigger)
        
        // Check both new and legacy keys for existing allocation
        let existingAllocation = storedAllocations[newKey] ?? storedAllocations[legacyKey]
        guard shouldFireAllocationEvent(current: currentAllocation, existing: existingAllocation) else {
            return  // No change, don't fire event
        }
        
        // Store the new allocation using experiment ID key
        storedAllocations[newKey] = currentAllocation
        saveStoredAllocations()
        
        // Update experiment info to mark as enrolled for userAllocated event
        experimentInfo.enrolledAt = currentAllocation.enrolledAt
        experimentInfo.isEnrolled = true
        experimentInfo.enrolledTrigger = trigger
        
        // Fire the allocation event
        let allocationEvent = UserAllocatedEvent(experimentInfo: experimentInfo)
        HeliumPaywallDelegateWrapper.shared.fireEvent(allocationEvent)
    }
    
    /// Resets all allocation tracking
    /// - Note: Called when SDK cache is cleared via clearAllCachedState()
    func reset() {
       storedAllocations.removeAll()
       UserDefaults.standard.removeObject(forKey: allocationsUserDefaultsKey)
    }
    
    /// Get the enrollment timestamp and status for a specific user and trigger
    /// - Parameters:
    ///   - persistentId: The user's Helium persistent ID
    ///   - trigger: The trigger name to check
    ///   - experimentInfo: The current experiment info to validate against stored allocation
    /// - Returns: Tuple of (enrolledAt: Date?, isEnrolled: Bool, enrolledTrigger: String?) where isEnrolled is true if user has a matching allocation
    func getEnrollmentInfo(
        persistentId: String,
        trigger: String,
        experimentInfo: ExperimentInfo
    ) -> (enrolledAt: Date?, isEnrolled: Bool, enrolledTrigger: String?) {
        // Try new key format first (persistentId_experimentId)
        var storedAllocation: StoredAllocation? = nil
        if let experimentId = experimentInfo.experimentId, !experimentId.isEmpty {
            let newKey = storageKey(persistentId: persistentId, experimentId: experimentId)
            storedAllocation = storedAllocations[newKey]
        }
        
        // Then legacy key format (persistentId_trigger) for backward compatibility
        if storedAllocation == nil {
            let legacyKey = legacyStorageKey(persistentId: persistentId, trigger: trigger)
            storedAllocation = storedAllocations[legacyKey]
        }
        
        guard let storedAllocation = storedAllocation else {
            return (nil, false, nil)
        }
        
        // Only return enrollment if allocation hasn't changed
        let currentAllocation = StoredAllocation(from: experimentInfo, trigger: trigger)
        guard isSameExperimentAllocation(storedAllocation, currentAllocation) else {
            return (nil, false, nil)
        }
        
        // User is enrolled - return date (may be nil for old SDK data), isEnrolled = true, and enrolledTrigger
        return (storedAllocation.enrolledAt, true, storedAllocation.enrolledTrigger)
    }
}
