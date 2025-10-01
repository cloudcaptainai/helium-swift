//
//  ExperimentInfo.swift
//  Helium
//
//  Experiment Allocation Information Models
//

import Foundation

// MARK: - Server Response Structure

/// Structured experiment info from server response
/// - Note: Matches top-level experimentInfo structure from bandit server
struct ExperimentInfoResponse: Codable {
    let experimentId: String?
    let experimentName: String?
    let experimentType: String?
    let userPercentage: Int
    let allocations: [Int]
    let chosenAllocation: Int
    let audienceId: String?
    let audienceData: String?  // Stringified JSON
    let allocationMetadata: AnyCodable?
    let hashMethod: String?
}


// MARK: - Hash Details

/// Details about user hash bucketing for allocation
public struct HashDetails: Codable {
    /// User hash bucket (1-100) - used for consistent allocation
    public let hashedUserIdBucket1To100: Int?
    
    /// User ID that was hashed for allocation
    public let hashedUserId: String?
    
    /// Hash method used (e.g., "HASH_USER_ID", "HASH_HELIUM_PERSISTENT_ID")
    public let hashMethod: String?
    
    public init(
        hashedUserIdBucket1To100: Int?,
        hashedUserId: String?,
        hashMethod: String?
    ) {
        self.hashedUserIdBucket1To100 = hashedUserIdBucket1To100
        self.hashedUserId = hashedUserId
        self.hashMethod = hashMethod
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
    
    /// Experiment name
    public let experimentName: String?
    
    /// Experiment ID
    public let experimentId: String?
    
    /// Experiment type (e.g., "A/B/n test")
    public let experimentType: String?
    
    /// Audience ID that user matched
    public let audienceId: String?
    
    /// Stringified JSON of audience data (internal storage)
    let audienceData: String?
    
    /// Public accessor for audience data as dictionary
    public var audienceDataDictionary: [String: Any]? {
        guard let audienceData = audienceData,
              let data = audienceData.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }
    
    /// Additional allocation metadata (internal storage)
    let allocationMetadata: AnyCodable?
    
    /// Public accessor for allocation metadata as dictionary
    public var allocationMetadataDictionary: [String: Any]? {
        return allocationMetadata?.value as? [String: Any]
    }
    
    /// Details about the chosen variant
    public let chosenVariantDetails: VariantDetails?
    
    /// Hash bucketing details
    public let hashDetails: HashDetails?
    
    init(
        trigger: String,
        experimentName: String?,
        experimentId: String?,
        experimentType: String?,
        audienceId: String?,
        audienceData: String?,
        allocationMetadata: AnyCodable?,
        chosenVariantDetails: VariantDetails?,
        hashDetails: HashDetails?
    ) {
        self.trigger = trigger
        self.experimentName = experimentName
        self.experimentId = experimentId
        self.experimentType = experimentType
        self.audienceId = audienceId
        self.audienceData = audienceData
        self.allocationMetadata = allocationMetadata
        self.chosenVariantDetails = chosenVariantDetails
        self.hashDetails = hashDetails
    }
}
