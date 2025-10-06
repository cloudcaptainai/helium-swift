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
    let audienceData: AnyCodable?
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
    
    /// Audience data as structured object (internal storage)
    let audienceData: AnyCodable?
    
    /// Public accessor for audience data as dictionary
    public var audienceDataDictionary: [String: Any]? {
        return audienceData?.value as? [String: Any]
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
        audienceData: AnyCodable?,
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
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case trigger
        case experimentName
        case experimentId
        case experimentType
        case audienceId
        case audienceData
        case allocationMetadata
        case chosenVariantDetails
        case hashDetails
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trigger, forKey: .trigger)
        try container.encodeIfPresent(experimentName, forKey: .experimentName)
        try container.encodeIfPresent(experimentId, forKey: .experimentId)
        try container.encodeIfPresent(experimentType, forKey: .experimentType)
        try container.encodeIfPresent(audienceId, forKey: .audienceId)
        
        // Stringify audienceData at the last mile for logging
        if let audienceData = audienceData {
            if let jsonData = try? JSONEncoder().encode(audienceData),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                try container.encode(jsonString, forKey: .audienceData)
            }
        }
        
        try container.encodeIfPresent(allocationMetadata, forKey: .allocationMetadata)
        try container.encodeIfPresent(chosenVariantDetails, forKey: .chosenVariantDetails)
        try container.encodeIfPresent(hashDetails, forKey: .hashDetails)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decode(String.self, forKey: .trigger)
        experimentName = try container.decodeIfPresent(String.self, forKey: .experimentName)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        experimentType = try container.decodeIfPresent(String.self, forKey: .experimentType)
        audienceId = try container.decodeIfPresent(String.self, forKey: .audienceId)
        
        // Handle audienceData - could be string or object
        if let stringData = try? container.decodeIfPresent(String.self, forKey: .audienceData),
           let data = stringData.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
            audienceData = decoded
        } else {
            audienceData = try container.decodeIfPresent(AnyCodable.self, forKey: .audienceData)
        }
        
        allocationMetadata = try container.decodeIfPresent(AnyCodable.self, forKey: .allocationMetadata)
        chosenVariantDetails = try container.decodeIfPresent(VariantDetails.self, forKey: .chosenVariantDetails)
        hashDetails = try container.decodeIfPresent(HashDetails.self, forKey: .hashDetails)
    }
}
