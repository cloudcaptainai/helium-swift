//
//  ExperimentAllocationTracker.swift
//  Helium
//
//  Centralized tracking for experiment allocation events
//

import Foundation

struct ExperimentAllocationSnapshot {
    let generation: UUID
    let paywallInfo: HeliumPaywallInfo
    let fetchedConfigId: UUID
    let experimentInfo: ExperimentInfo

    init?(trigger: String, config: HeliumFetchedConfig, paywallInfo: HeliumPaywallInfo?) {
        guard let paywallInfo,
              let experimentInfo = config.extractExperimentInfo(trigger: trigger, paywallInfo: paywallInfo) else { return nil }
        self.paywallInfo = paywallInfo
        self.generation = ExperimentAllocationTracker.shared.generation
        self.fetchedConfigId = config.fetchedConfigID
        self.experimentInfo = experimentInfo
    }

    static func capture(trigger: String, paywallInfo: HeliumPaywallInfo?) -> ExperimentAllocationSnapshot? {
        guard let config = HeliumFetchedConfigManager.shared.getConfig() else { return nil }
        return ExperimentAllocationSnapshot(trigger: trigger, config: config, paywallInfo: paywallInfo)
    }
}

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

private struct StoredAllocationEntry: Decodable {
    let value: StoredAllocation?

    init(from decoder: Decoder) {
        value = try? StoredAllocation(from: decoder)
    }
}

/// Manages experiment allocation event tracking across all presentation types
/// - Note: Ensures UserAllocatedEvent fires only when user gets a new allocation or 
///   when experiment details change for the user (by Helium persistent ID)
class ExperimentAllocationTracker {
    static let shared = ExperimentAllocationTracker()
    @HeliumAtomic private(set) var generation = UUID()
    
    private init() {
        loadStoredAllocations()
    }
    
    private let allocationsUserDefaultsKey = "heliumExperimentAllocations"
    private let allocationsFileName = "helium_experiment_allocations.json"
    
    /// Maps "persistentId_experimentId" (or legacy "persistentId_trigger") to stored allocation details
    @HeliumAtomic private var storedAllocations: [String: StoredAllocation] = [:]
    
    /// File URL for allocations storage, as a backup to UserDefaults
    private var allocationsFileURL: URL? {
        heliumAppSupportDirectory?.appendingPathComponent(allocationsFileName)
    }
    
    func loadStoredAllocations() {
        var allocations: [String: StoredAllocation] = [:]
        if let fileURL = allocationsFileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: StoredAllocationEntry].self, from: data) {
            allocations = decoded.compactMapValues(\.value)
        }
        if let data = UserDefaults.standard.data(forKey: allocationsUserDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: StoredAllocationEntry].self, from: data) {
            allocations.merge(decoded.compactMapValues(\.value)) { _, current in current }
        }
        storedAllocations = allocations
    }
    
    /// Persists allocations to UserDefaults and file (as backup)
    private func saveStoredAllocations() {
        guard let encoded = try? JSONEncoder().encode(storedAllocations) else {
            HeliumLogger.log(.error, category: .core, "Failed to persist experiment allocations")
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
                    HeliumLogger.log(.warn, category: .core, "Allocation file save was slow: \(String(format: "%.2f", elapsed))s")
                }
            } catch {
                HeliumLogger.log(.error, category: .core, "Failed to persist allocations to file: \(error.localizedDescription)")
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
    
    @discardableResult
    func recordDecision(trigger: String, paywallInfo: HeliumPaywallInfo?) -> Bool {
        recordDecision(trigger: trigger, snapshot: ExperimentAllocationSnapshot.capture(trigger: trigger, paywallInfo: paywallInfo))
    }

    @discardableResult
    func recordDecision(trigger: String, snapshot: ExperimentAllocationSnapshot?) -> Bool {
        guard let snapshot, snapshot.generation == generation else { return false }
        return recordAllocation(trigger: trigger, paywallInfo: snapshot.paywallInfo, experimentInfo: snapshot.experimentInfo, fetchedConfigId: snapshot.fetchedConfigId, atDecision: true)
    }

    func recordOpen(paywallSession: PaywallSession, isFallback: Bool) {
        guard !isFallback, !paywallSession.isFallback,
              HeliumFetchedConfigManager.shared.getConfig() != nil,
              let experimentInfo = paywallSession.allocationExperimentInfo else {
            return
        }
        recordAllocation(trigger: paywallSession.trigger, paywallInfo: paywallSession.paywallInfo, experimentInfo: experimentInfo, fetchedConfigId: paywallSession.allocationConfigId, atDecision: false)
    }

    @discardableResult
    private func recordAllocation(trigger: String, paywallInfo: HeliumPaywallInfo?, experimentInfo: ExperimentInfo, fetchedConfigId: UUID?, atDecision: Bool) -> Bool {
        var experimentInfo = experimentInfo
        // Need experiment ID to track allocations
        guard let experimentId = experimentInfo.experimentId, !experimentId.isEmpty else {
            return false
        }

        let isSkipExperiment = experimentInfo.hasNoPaywallArm == true || paywallInfo?.shouldShow == false
        guard isSkipExperiment == atDecision else { return true }
        
        // Get user's persistent ID
        let persistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let newKey = storageKey(persistentId: persistentId, experimentId: experimentId)
        let legacyKey = legacyStorageKey(persistentId: persistentId, trigger: trigger)
        
        // Create current allocation details
        let currentAllocation = StoredAllocation(from: experimentInfo, trigger: trigger)
        
        // Check both new and legacy keys for existing allocation
        let existingAllocation = storedAllocations[newKey] ?? storedAllocations[legacyKey]
        guard shouldFireAllocationEvent(current: currentAllocation, existing: existingAllocation) else {
            return true  // No change, don't fire event
        }
        
        // Store the new allocation using experiment ID key
        storedAllocations[newKey] = currentAllocation
        // Remove the legacy key if we've stored the new one, to avoid duplicates
        if storedAllocations[newKey] != nil && newKey != legacyKey {
            storedAllocations.removeValue(forKey: legacyKey)
        }
        saveStoredAllocations()
        
        // Update experiment info to mark as enrolled for userAllocated event
        experimentInfo.enrolledAt = currentAllocation.enrolledAt
        experimentInfo.isEnrolled = true
        experimentInfo.enrolledTrigger = trigger
        
        // Fire the allocation event
        let allocationEvent = UserAllocatedEvent(trigger: trigger, experimentInfo: experimentInfo, paywallInfo: paywallInfo, fetchedConfigId: fetchedConfigId)
        HeliumPaywallDelegateWrapper.shared.fireEvent(allocationEvent, paywallSession: nil)
        return true
    }
    
    /// Resets all allocation tracking
    func reset() {
        generation = UUID()
        storedAllocations.removeAll()
        UserDefaults.standard.removeObject(forKey: allocationsUserDefaultsKey)
        
        // Delete file backup on saveQueue to avoid race with pending async saves
        if let fileURL = allocationsFileURL {
            saveQueue.async {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
    
    func buildAllocationHistoryRequestPayload() -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for allocation in storedAllocations.values {
            guard let experimentId = allocation.experimentId else { continue }
            
            // If duplicate experimentId, prefer entry with experimentVersionId
            if let existing = result[experimentId],
               let existingVersion = existing["experimentVersionId"] as? String,
               !existingVersion.isEmpty,
               (allocation.experimentVersionId ?? "").isEmpty {
                continue
            }
            
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
