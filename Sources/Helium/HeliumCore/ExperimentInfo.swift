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
    let experimentMetadata: AnyCodable?
    let experimentVersionId: String?
    let startDate: String?
    let endDate: String?
    let audienceId: String?
    let audienceData: AnyCodable?
    let chosenVariantDetails: VariantDetails?
    let hashDetails: HashDetails?
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
    
    internal init(
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
    
    /// Additional allocation metadata (internal storage)
    let allocationMetadata: AnyCodable?
    
    /// Public accessor for allocation metadata as dictionary
    public var allocationMetadataDictionary: [String: Any]? {
        return allocationMetadata?.value as? [String: Any]
    }
    
    internal init(
        allocationName: String?,
        allocationId: String?,
        allocationIndex: Int?,
        allocationMetadata: AnyCodable?
    ) {
        self.allocationName = allocationName
        self.allocationId = allocationId
        self.allocationIndex = allocationIndex
        self.allocationMetadata = allocationMetadata
    }
}

// MARK: - Experiment Info

/// Enrollment status for an experiment
public enum ExperimentEnrollmentStatus: String, Codable {
    /// Currently enrolled, experiment running and user has hit trigger
    case activeEnrollment
    
    /// Not enrolled yet, but will be enrolled when user sees the trigger
    case predictedEnrollment
    
    /// Unknown status
    case unknown
}

/// Complete experiment allocation information for a user
public struct ExperimentInfo: Codable {
    /// Trigger where this user was enrolled
    public var enrolledTrigger: String?
    
    /// All triggers where this experiment is configured
    public let allTriggers: [String]?
    
    /// Experiment name
    public let experimentName: String?
    
    /// Experiment ID
    public let experimentId: String?
    
    /// Experiment type (e.g., "A/B/n test")
    public let experimentType: String?
    
    /// Experiment version ID for version resolution
    public let experimentVersionId: String?
    
    /// Additional experiment metadata (internal storage)
    let experimentMetadata: AnyCodable?
    
    /// Public accessor for experiment metadata as dictionary
    public var experimentMetadataDictionary: [String: Any]? {
        return experimentMetadata?.value as? [String: Any]
    }
    
    /// When the experiment started (ISO8601 string)
    public let startDate: String?
    
    /// When the experiment ends (ISO8601 string)
    public let endDate: String?
    
    /// Audience ID that user matched
    public let audienceId: String?
    
    /// Audience data as structured object (internal storage)
    let audienceData: AnyCodable?
    
    /// Public accessor for audience data as dictionary
    public var audienceDataDictionary: [String: Any]? {
        return audienceData?.value as? [String: Any]
    }
    
    /// Details about the chosen variant
    public let chosenVariantDetails: VariantDetails?
    
    /// Hash bucketing details
    public let hashDetails: HashDetails?
    
    /// When the user was first enrolled in this experiment (nil if not enrolled yet)
    public var enrolledAt: Date?
    
    /// Whether the user is currently enrolled in this experiment
    public var isEnrolled: Bool
    
    /// Computed enrollment status based on whether user has been allocated
    public var enrollmentStatus: ExperimentEnrollmentStatus {
        if isEnrolled {
            return .activeEnrollment
        } else if experimentId != nil && !experimentId!.isEmpty {
            return .predictedEnrollment
        } else {
            return .unknown
        }
    }
    
    internal init(
        enrolledTrigger: String?,
        triggers: [String]?,
        experimentName: String?,
        experimentId: String?,
        experimentType: String?,
        experimentVersionId: String?,
        experimentMetadata: AnyCodable?,
        startDate: String?,
        endDate: String?,
        audienceId: String?,
        audienceData: AnyCodable?,
        chosenVariantDetails: VariantDetails?,
        hashDetails: HashDetails?,
        enrolledAt: Date? = nil,
        isEnrolled: Bool = false
    ) {
        self.enrolledTrigger = enrolledTrigger
        self.allTriggers = triggers
        self.experimentName = experimentName
        self.experimentId = experimentId
        self.experimentType = experimentType
        self.experimentVersionId = experimentVersionId
        self.experimentMetadata = experimentMetadata
        self.startDate = startDate
        self.endDate = endDate
        self.audienceId = audienceId
        self.audienceData = audienceData
        self.chosenVariantDetails = chosenVariantDetails
        self.hashDetails = hashDetails
        self.enrolledAt = enrolledAt
        self.isEnrolled = isEnrolled
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case trigger
        case enrolledTrigger
        case triggers
        case experimentName
        case experimentId
        case experimentType
        case experimentVersionId
        case experimentMetadata
        case startDate
        case endDate
        case audienceId
        case audienceData
        case chosenVariantDetails
        case hashDetails
        case enrolledAt
        case isEnrolled
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // keep "trigger" for now, for better backwards-compatibility
        try container.encodeIfPresent(enrolledTrigger, forKey: .trigger)
        try container.encodeIfPresent(enrolledTrigger, forKey: .enrolledTrigger)
        try container.encodeIfPresent(allTriggers, forKey: .triggers)
        try container.encodeIfPresent(experimentName, forKey: .experimentName)
        try container.encodeIfPresent(experimentId, forKey: .experimentId)
        try container.encodeIfPresent(experimentType, forKey: .experimentType)
        try container.encodeIfPresent(experimentVersionId, forKey: .experimentVersionId)
        try container.encodeIfPresent(experimentMetadata, forKey: .experimentMetadata)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(audienceId, forKey: .audienceId)
        
        // Stringify audienceData at the last mile for logging
        if let audienceData = audienceData {
            if let jsonData = try? JSONEncoder().encode(audienceData),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                try container.encode(jsonString, forKey: .audienceData)
            } else {
                print("[Helium] Failed to encode audienceData for experiment info")
            }
        }
        
        try container.encodeIfPresent(chosenVariantDetails, forKey: .chosenVariantDetails)
        try container.encodeIfPresent(hashDetails, forKey: .hashDetails)
        try container.encodeIfPresent(enrolledAt, forKey: .enrolledAt)
        try container.encode(isEnrolled, forKey: .isEnrolled)
    }
    
    // Note - currently this custom decoder does not seem to be used at all
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enrolledTrigger = try container.decodeIfPresent(String.self, forKey: .enrolledTrigger)
        allTriggers = try container.decodeIfPresent([String].self, forKey: .triggers)
        experimentName = try container.decodeIfPresent(String.self, forKey: .experimentName)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        experimentType = try container.decodeIfPresent(String.self, forKey: .experimentType)
        experimentVersionId = try container.decodeIfPresent(String.self, forKey: .experimentVersionId)
        experimentMetadata = try container.decodeIfPresent(AnyCodable.self, forKey: .experimentMetadata)
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        audienceId = try container.decodeIfPresent(String.self, forKey: .audienceId)
        
        // Handle audienceData - could be string or object
        if let stringData = try? container.decodeIfPresent(String.self, forKey: .audienceData),
           let data = stringData.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
            audienceData = decoded
        } else {
            audienceData = try container.decodeIfPresent(AnyCodable.self, forKey: .audienceData)
        }
        
        chosenVariantDetails = try container.decodeIfPresent(VariantDetails.self, forKey: .chosenVariantDetails)
        hashDetails = try container.decodeIfPresent(HashDetails.self, forKey: .hashDetails)
        enrolledAt = try container.decodeIfPresent(Date.self, forKey: .enrolledAt)
        isEnrolled = try container.decodeIfPresent(Bool.self, forKey: .isEnrolled) ?? false
    }
}
