//
//  ExperimentInfo.swift
//  Helium
//
//  Experiment Allocation Information Models
//

import Foundation

// MARK: - Server Response Structure

/// Structured experiment fields from server response
/// - Note: Matches experimentFields structure from bandit server
struct ExperimentFieldsResponse: Codable {
    let experimentId: String?
    let experimentName: String?
    let experimentType: String?
    let userPercentage: Int
    let allocations: [Int]
    let chosenAllocation: Int
    let audienceId: String?
    let audienceData: AnyCodable?
}

// MARK: - Targeting Details

/// Details about audience targeting for an experiment
public struct TargetingDetails: Codable {
    /// Unique identifier for the audience being targeted
    /// - Note: Used for lookup in Helium dashboard
    public let audienceId: String?
    
    /// Raw audience data containing targeting criteria
    /// - Note: JSON mapping with audience configuration details
    public let audienceData: AnyCodable?
    
    public init(audienceId: String?, audienceData: AnyCodable?) {
        self.audienceId = audienceId
        self.audienceData = audienceData
    }
}

// MARK: - Experiment Details

/// Details about the experiment configuration
public struct ExperimentDetails: Codable {
    /// Name of the experiment
    public let name: String?
    
    /// Unique identifier for the experiment
    public let id: String?
    
    /// Start date of the experiment
    // public let startDate: Date?
    
    /// End date of the experiment
    // public let endDate: Date?
    
    /// Targeting details for this experiment
    public let targetingDetails: TargetingDetails?
    
    /// Type of experiment (e.g., "AB_TEST", "MAB", "CMAB")
    public let type: String?
    
    // Additional experiment configuration
    // public let rolloutPercentage: Double?
    
    public init(
        name: String?,
        id: String?,
        targetingDetails: TargetingDetails?,
        type: String?
    ) {
        self.name = name
        self.id = id
        self.targetingDetails = targetingDetails
        self.type = type
    }
}

// MARK: - User Hash Details

/// Details about user hash bucketing for allocation
public struct UserHashDetails: Codable {
    /// User hash bucket (1-100) - used for consistent allocation
    public let hashedUserIdBucket1To100: Int?
    
    /// User ID that was hashed for allocation
    public let hashedUserId: String?
    
    /// Type of hash used (e.g., "HASH_USER_ID", "HASH_HELIUM_PERSISTENT_ID")
    public let hashType: String?
    
    public init(
        hashedUserIdBucket1To100: Int?,
        hashedUserId: String?,
        hashType: String?
    ) {
        self.hashedUserIdBucket1To100 = hashedUserIdBucket1To100
        self.hashedUserId = hashedUserId
        self.hashType = hashType
    }
}

// MARK: - Variant Details

/// Details about the chosen variant in an experiment
public struct VariantDetails: Codable {
    /// Name or identifier of the allocation/variant (e.g., paywall template name)
    public let allocationName: String?
    
    /// Unique identifier for this allocation (paywall UUID)
    public let allocationId: String?
    
    /// Index of chosen variant (1 to len(variants))
    public let allocationIndex: Int?
    
    /// Timestamp when allocation occurred
    public let allocationTime: Date
    
    public init(
        allocationName: String?,
        allocationId: String?,
        allocationIndex: Int?,
        allocationTime: Date = Date()
    ) {
        self.allocationName = allocationName
        self.allocationId = allocationId
        self.allocationIndex = allocationIndex
        self.allocationTime = allocationTime
    }
}

// MARK: - Experiment Info

/// Complete experiment allocation information for a user
public struct ExperimentInfo: Codable {
    /// Trigger name at which user was enrolled
    public let trigger: String
    
    /// Details about the experiment configuration
    public let experimentDetails: ExperimentDetails?
    
    /// Details about the chosen variant
    public let chosenVariantDetails: VariantDetails?
    
    /// User hash bucketing details
    public let userHashDetails: UserHashDetails?
    
    public init(
        trigger: String,
        experimentDetails: ExperimentDetails?,
        chosenVariantDetails: VariantDetails?,
        userHashDetails: UserHashDetails?
    ) {
        self.trigger = trigger
        self.experimentDetails = experimentDetails
        self.chosenVariantDetails = chosenVariantDetails
        self.userHashDetails = userHashDetails
    }
    
    /// Convert to dictionary with experiment_info_* prefixed keys for consistent logging
    func toDictionaryWithPrefix() -> [String: Any] {
        var dict: [String: Any] = [
            "experiment_info_trigger": trigger
        ]
        
        // Experiment details
        if let experimentDetails = experimentDetails {
            if let name = experimentDetails.name {
                dict["experiment_info_experiment_name"] = name
            }
            if let id = experimentDetails.id {
                dict["experiment_info_experiment_id"] = id
            }
            if let type = experimentDetails.type {
                dict["experiment_info_experiment_type"] = type
            }
            
            // Targeting details
            if let targeting = experimentDetails.targetingDetails {
                if let audienceId = targeting.audienceId {
                    dict["experiment_info_audience_id"] = audienceId
                }
                if let audienceData = targeting.audienceData {
                    dict["experiment_info_audience_data"] = audienceData.value
                }
            }
        }
        
        // Variant details
        if let variantDetails = chosenVariantDetails {
            if let allocationName = variantDetails.allocationName {
                dict["experiment_info_allocation_name"] = allocationName
            }
            if let allocationId = variantDetails.allocationId {
                dict["experiment_info_allocation_id"] = allocationId
            }
            if let allocationIndex = variantDetails.allocationIndex {
                dict["experiment_info_allocation_index"] = allocationIndex
            }
            dict["experiment_info_allocation_time"] = variantDetails.allocationTime.timeIntervalSince1970
        }
        
        // User hash details
        if let hashDetails = userHashDetails {
            if let hashedUserIdBucket = hashDetails.hashedUserIdBucket1To100 {
                dict["experiment_info_hashed_user_id_bucket"] = hashedUserIdBucket
            }
            if let hashedUserId = hashDetails.hashedUserId {
                dict["experiment_info_hashed_user_id"] = hashedUserId
            }
            if let hashType = hashDetails.hashType {
                dict["experiment_info_hash_type"] = hashType
            }
        }
        
        return dict
    }
}
