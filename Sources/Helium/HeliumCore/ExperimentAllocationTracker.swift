//
//  ExperimentAllocationTracker.swift
//  Helium
//
//  Centralized tracking for experiment allocation events
//

import Foundation

/// Stored allocation details for comparison
struct StoredAllocation: Codable {
    let experimentId: String?
    let allocationId: String?
    let allocationIndex: Int?
    let audienceId: String?
    let experimentVersionId: String?
    let enrolledAt: Date?
    let enrolledTrigger: String?
    
    init(from experimentInfo: ExperimentInfo, trigger: String) {
        self.experimentId = experimentInfo.experimentId
        self.allocationId = experimentInfo.chosenVariantDetails?.allocationId
        self.allocationIndex = experimentInfo.chosenVariantDetails?.allocationIndex
        self.audienceId = experimentInfo.audienceId
        self.experimentVersionId = experimentInfo.experimentVersionId
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
    private let allocationsFileName = "helium_experiment_allocations.json"
    
    /// Maps "persistentId_experimentId" (or legacy "persistentId_trigger") to stored allocation details
    private var storedAllocations: [String: StoredAllocation] = [:]
    
    /// File URL for fallback storage
    private var allocationsFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Helium", isDirectory: true)
            .appendingPathComponent(allocationsFileName)
    }
    
    /// Loads stored allocations - tries UserDefaults first, falls back to file
    private func loadStoredAllocations() {
        // Try UserDefaults first
        if let data = UserDefaults.standard.data(forKey: allocationsUserDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: StoredAllocation].self, from: data) {
            storedAllocations = decoded
            return
        }
        
        // Fallback to file
        if let fileURL = allocationsFileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: StoredAllocation].self, from: data) {
            storedAllocations = decoded
        }
    }
    
    /// Persists allocations to UserDefaults and file (as backup)
    private func saveStoredAllocations() {
        guard let encoded = try? JSONEncoder().encode(storedAllocations) else {
            print("[Helium] Failed to persist experiment allocations")
            return
        }
        
        // Save to UserDefaults
        UserDefaults.standard.set(encoded, forKey: allocationsUserDefaultsKey)
        
        // Also save to file as backup
        saveToFile(encoded)
    }
    
    private let saveQueue = DispatchQueue(label: "com.helium.allocationSave")
    
    /// Saves encoded data to file asynchronously
    private func saveToFile(_ data: Data) {
        guard let fileURL = allocationsFileURL else { return }
        
        saveQueue.async {
            let startTime = Date()
            do {
                // Create directory if needed
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 2.0 {
                    print("[Helium] Allocation file save was slow: \(String(format: "%.2f", elapsed))s")
                }
            } catch {
                print("[Helium] Failed to persist allocations to file: \(error.localizedDescription)")
            }
        }
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
    private func shouldFireAllocationEvent(
        current: StoredAllocation,
        existing: StoredAllocation?
    ) -> Bool {
        guard let existing = existing else {
            return true  // No previous allocation - fire event
        }
        return !isSameExperimentAllocation(current, existing)
    }
    
    private func isSameExperimentAllocation(
        _ first: StoredAllocation,
        _ second: StoredAllocation
    ) -> Bool {
        return first.experimentId == second.experimentId
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
    func trackAllocationIfNeeded(trigger: String, isFallback: Bool, paywallSession: PaywallSession?) {
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
        let allocationEvent = UserAllocatedEvent(trigger: trigger, experimentInfo: experimentInfo)
        // Include paywall session if available but note that it will not be available for holdouts
        HeliumPaywallDelegateWrapper.shared.fireEvent(allocationEvent, paywallSession: paywallSession)
    }
    
    /// Resets all allocation tracking
    /// - Note: Called when SDK cache is cleared via clearAllCachedState()
    func reset() {
        storedAllocations.removeAll()
        UserDefaults.standard.removeObject(forKey: allocationsUserDefaultsKey)
        
        // Also delete file backup
        if let fileURL = allocationsFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// Returns stored allocations keyed by experiment ID
    func getAllocationHistoryByExperimentId() -> [String: StoredAllocation] {
        var result: [String: StoredAllocation] = [:]
        for allocation in storedAllocations.values {
            if let experimentId = allocation.experimentId {
                result[experimentId] = allocation
            }
        }
        return result
    }
    
    /// Returns allocation history as dictionary for API params
    func getAllocationHistoryAsParams() -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for allocation in storedAllocations.values {
            guard let experimentId = allocation.experimentId else { continue }
            result[experimentId] = [
                "allocationId": allocation.allocationId ?? "",
                "enrolledAt": allocation.enrolledAt?.timeIntervalSince1970 ?? 0,
                "experimentVersionId": allocation.experimentVersionId ?? ""
            ]
        }
        return result
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
        var legacyEnrolledTrigger: String? = nil
        if storedAllocation == nil {
            let legacyKey = legacyStorageKey(persistentId: persistentId, trigger: trigger)
            storedAllocation = storedAllocations[legacyKey]
            legacyEnrolledTrigger = trigger
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
        return (storedAllocation.enrolledAt, true, storedAllocation.enrolledTrigger ?? legacyEnrolledTrigger)
    }
}
