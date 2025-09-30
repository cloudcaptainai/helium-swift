////
////  HeliumPaywallControllerDelegate.swift
////  Helium
////
////  Created by Anish Doshi on 7/31/24.
////
//
import Foundation
import UIKit
import SwiftUI

public struct HeliumPaywallInfo: Codable {
    init(paywallID: Int, paywallTemplateName: String, productsOffered: [String], resolvedConfig: AnyCodable, shouldShow: Bool, fallbackPaywallName: String, experimentID: String? = nil, modelID: String? = nil, resolvedConfigJSON: JSON? = nil, forceShowFallback: Bool? = false, paywallUUID: String? = nil) {
        self.paywallID = paywallID
        self.paywallUUID = paywallUUID;
        self.paywallTemplateName = paywallTemplateName;
        self.productsOffered = productsOffered;
        self.resolvedConfig = resolvedConfig;
        self.shouldShow = shouldShow;
        self.fallbackPaywallName = fallbackPaywallName;
        self.experimentID = experimentID;
        self.modelID = modelID;
        self.resolvedConfigJSON = resolvedConfigJSON;
        self.forceShowFallback = forceShowFallback;
    }
    
    var paywallID: Int
    var paywallUUID: String?
    public var paywallTemplateName: String
    var productsOffered: [String]
    var resolvedConfig: AnyCodable
    var shouldShow: Bool?
    var fallbackPaywallName: String?
    public var experimentID: String?
    var modelID: String?
    var forceShowFallback: Bool?
    var secondChance: Bool?
    var secondChancePaywall: AnyCodable?
    var resolvedConfigJSON: JSON?
    var additionalPaywallFields: JSON?
    
    /// Extract experiment info from additionalPaywallFields
    /// - Parameter trigger: The trigger name for this paywall
    /// - Returns: ExperimentInfo if experiment data is available
    func extractExperimentInfo(trigger: String) -> ExperimentInfo? {
        guard let additionalFields = additionalPaywallFields else {
            return nil
        }
        
        // Try new structured experimentFields first
        if let experimentFieldsJSON = additionalFields["experimentFields"],
           let experimentFieldsData = try? JSONEncoder().encode(experimentFieldsJSON),
           let experimentFields = try? JSONDecoder().decode(ExperimentFieldsResponse.self, from: experimentFieldsData) {
            
            // Parse targeting details if present
            var targetingDetails: TargetingDetails? = nil
            if let audienceId = experimentFields.audienceId {
                targetingDetails = TargetingDetails(
                    audienceId: audienceId,
                    audienceData: experimentFields.audienceData
                )
            }
            
            // Use structured fields from server
            let experimentDetails = ExperimentDetails(
                name: experimentFields.experimentName,
                id: experimentFields.experimentId,
                targetingDetails: targetingDetails,
                type: experimentFields.experimentType
            )
            
            let variantDetails = VariantDetails(
                allocationName: paywallTemplateName,
                allocationId: paywallUUID,
                allocationIndex: experimentFields.chosenAllocation + 1,
                allocationTime: Date()
            )
            
            let userHashDetails = UserHashDetails(
                hashedUserIdBucket1To100: experimentFields.userPercentage,
                hashedUserId: nil,
                hashType: nil
            )
            
            return ExperimentInfo(
                trigger: trigger,
                experimentDetails: experimentDetails,
                chosenVariantDetails: variantDetails,
                userHashDetails: userHashDetails
            )
        }
        
        // Fall back to legacy flat field parsing
        guard let experimentID = experimentID, !experimentID.isEmpty else {
            return nil
        }
        
        let experimentName = additionalFields["experimentName"].string
        
        let experimentDetails = ExperimentDetails(
            name: experimentName,
            id: experimentID,
            targetingDetails: nil,
            type: nil
        )
        
        let userPercentage = additionalFields["userPercentage"].int
        let chosenAllocation = additionalFields["chosen_allocation"].int
        
        let variantDetails = VariantDetails(
            allocationName: paywallTemplateName,
            allocationId: paywallUUID,
            allocationIndex: (chosenAllocation ?? 0) + 1,
            allocationTime: Date()
        )
        
        let userHashDetails = UserHashDetails(
            hashedUserIdBucket1To100: userPercentage,
            hashedUserId: nil,
            hashType: nil
        )
        
        return ExperimentInfo(
            trigger: trigger,
            experimentDetails: experimentDetails,
            chosenVariantDetails: variantDetails,
            userHashDetails: userHashDetails
        )
    }
}

//User-facing details about a paywall
public struct PaywallInfo {
    public let paywallTemplateName: String
    public let shouldShow: Bool
}

public struct HeliumFetchedConfig: Codable {
    var triggerToPaywalls: [String: HeliumPaywallInfo]
    var segmentBrowserWriteKey: String
    var segmentAnalyticsEndpoint: String
    var orgName: String?
    var organizationID: String?
    var fetchedConfigID: UUID
    var additionalFields: JSON?
    var bundles: [String: String]?;
}

public enum HeliumPaywallEvent: Codable {
    case initializeStart
    case ctaPressed(ctaName: String, triggerName: String, paywallTemplateName: String)
    case offerSelected(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionPressed(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionCancelled(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionSucceeded(productKey: String, triggerName: String, paywallTemplateName: String, storeKitTransactionId: String?, storeKitOriginalTransactionId: String?, skPostPurchaseTxnTimeMS: UInt64?)
    case subscriptionFailed(productKey: String, triggerName: String, paywallTemplateName: String, error: String? = nil)
    case subscriptionRestored(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionRestoreFailed(triggerName: String, paywallTemplateName: String)
    case subscriptionPending(productKey: String, triggerName: String, paywallTemplateName: String)
    case paywallOpen(triggerName: String, paywallTemplateName: String, viewType: String, loadTimeTakenMS: UInt64? = nil, loadingBudgetMS: UInt64? = nil)
    case paywallOpenFailed(triggerName: String, paywallTemplateName: String, error: String)
    case paywallClose(triggerName: String, paywallTemplateName: String)
    case paywallDismissed(triggerName: String, paywallTemplateName: String, dismissAll: Bool = false)
    case paywallSkipped(triggerName: String)
    case paywallsDownloadSuccess(configId: UUID, downloadTimeTakenMS: UInt64? = nil, imagesDownloadTimeTakenMS: UInt64? = nil, fontsDownloadTimeTakenMS: UInt64? = nil, bundleDownloadTimeMS: UInt64? = nil, numAttempts: Int? = nil)
    case paywallsDownloadError(error: String, numAttempts: Int? = nil)
    case paywallWebViewRendered(triggerName: String, paywallTemplateName: String, webviewRenderTimeTakenMS: UInt64? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, ctaName, productKey, triggerName, paywallTemplateName, viewType, dismissAll, configId, errorDescription, downloadTimeTakenMS, imagesDownloadTimeTakenMS, fontsDownloadTimeTakenMS, bundleDownloadTimeMS, webviewRenderTimeTakenMS, numAttempts, loadTimeTakenMS, loadingBudgetMS, storeKitTransactionId, storeKitOriginalTransactionId, skPostPurchaseTxnTimeMS
    }
    
    public func getTriggerIfExists() -> String?{
        switch self {
        case .initializeStart:
            return nil
        case .paywallWebViewRendered(let triggerName, let paywallTemplateName, let timeTakenMS):
            return triggerName;
        case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName):
            return triggerName;
            
        case .offerSelected(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPressed(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionCancelled(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionSucceeded(let productKey, let triggerName, let paywallTemplateName, let _, let _, let _),
             .subscriptionRestored(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPending(let productKey, let triggerName, let paywallTemplateName):
            
            return triggerName;
        case .subscriptionFailed(let productKey, let triggerName, let paywallTemplateName, let error):
            return triggerName;
        case .subscriptionRestoreFailed(let triggerName, let paywallTemplateName):
            return triggerName;
        
        case .paywallOpen(let triggerName, let paywallTemplateName, let viewType, let _, let _):
            return triggerName;
            
        case .paywallOpenFailed(let triggerName, _, _):
            return triggerName
        case .paywallClose(let triggerName, _):
            return triggerName
            
        case .paywallDismissed(let triggerName, let paywallTemplateName, let dismissAll):
            return triggerName;
            
        case .paywallSkipped(let triggerName):
            return triggerName;
            
        case .paywallsDownloadSuccess(let configId):
            return nil;
        case .paywallsDownloadError(let error):
            return nil;
        }
    }
    
    public func getPaywallTemplateNameIfExists() -> String?{
        switch self {
        case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName):
            return paywallTemplateName;
        case .offerSelected(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPressed(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionCancelled(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionSucceeded(let productKey, let triggerName, let paywallTemplateName, let _, let _, let _),
             .subscriptionRestored(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPending(let productKey, let triggerName, let paywallTemplateName):
            return paywallTemplateName;
        case .subscriptionFailed(let productKey, let triggerName, let paywallTemplateName, let error):
            return paywallTemplateName;
        case .subscriptionRestoreFailed(let triggerName, let paywallTemplateName):
            return paywallTemplateName;
        case .paywallOpen(let triggerName, let paywallTemplateName, let viewType, let _, let _):
            return paywallTemplateName;
        case .paywallOpenFailed( _, let paywallTemplateName, _):
            return paywallTemplateName
        case .paywallClose(_, let paywallTemplateName):
            return paywallTemplateName
        case .paywallDismissed(let triggerName, let paywallTemplateName, let dismissAll):
            return paywallTemplateName;
        case .paywallWebViewRendered(let triggerName, let paywallTemplateName, let timeTakenMS):
            return paywallTemplateName;
        default:
            return nil;
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .initializeStart:
            break;
        case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName):
            try container.encode("ctaPressed", forKey: .type)
            try container.encode(ctaName, forKey: .ctaName)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
        case .subscriptionSucceeded(let productKey, let triggerName, let paywallTemplateName, let storeKitTransactionId, let storeKitOriginalTransactionId, let skPostPurchaseTxnTimeMS):
            try container.encode("subscriptionSucceeded", forKey: .type)
            try container.encode(productKey, forKey: .productKey)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
            try container.encodeIfPresent(storeKitTransactionId, forKey: .storeKitTransactionId)
            try container.encodeIfPresent(storeKitOriginalTransactionId, forKey: .storeKitOriginalTransactionId)
            try container.encodeIfPresent(skPostPurchaseTxnTimeMS, forKey: .skPostPurchaseTxnTimeMS)
        case .offerSelected(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPressed(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionCancelled(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionRestored(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPending(let productKey, let triggerName, let paywallTemplateName):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(productKey, forKey: .productKey)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
        case .subscriptionFailed(let productKey, let triggerName, let paywallTemplateName, let error):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(productKey, forKey: .productKey)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
            try container.encodeIfPresent(error, forKey: .errorDescription)
        case .subscriptionRestoreFailed(let triggerName, let paywallTemplateName):
            try container.encode("subscriptionRestoreFailed", forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
        case .paywallOpen(let triggerName, let paywallTemplateName, let viewType, let loadTimeTakenMS, let loadingBudgetMS):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
            try container.encode(viewType, forKey: .viewType)
            try container.encodeIfPresent(loadTimeTakenMS, forKey: .loadTimeTakenMS);
            try container.encodeIfPresent(loadingBudgetMS, forKey: .loadingBudgetMS);
        case .paywallOpenFailed(let triggerName, let paywallTemplateName, let error):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
            try container.encode(error, forKey: .errorDescription)
        case .paywallClose(let triggerName, let paywallTemplateName):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
        case .paywallDismissed(let triggerName, let paywallTemplateName, let dismissAll):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
            try container.encode(dismissAll, forKey: .dismissAll)
        case .paywallSkipped(let triggerName):
            try container.encode("paywallSkipped", forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
        case .paywallWebViewRendered(let triggerName, let paywallTemplateName, let webviewRenderTimeTakenMS):
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
            try container.encode(webviewRenderTimeTakenMS, forKey: .webviewRenderTimeTakenMS)
        case .paywallsDownloadSuccess(let configId, let downloadTimeTakenMS, let imagesDownloadTimeTakenMS, let fontsDownloadTimeTakenMS, let bundleTimeTakenMS, let numAttempts):
            try container.encode("paywallsDownloadSuccess", forKey: .type)
            try container.encode(configId, forKey: .configId)
            try container.encodeIfPresent(downloadTimeTakenMS, forKey: .downloadTimeTakenMS);
            try container.encodeIfPresent(imagesDownloadTimeTakenMS, forKey: .imagesDownloadTimeTakenMS);
            try container.encodeIfPresent(fontsDownloadTimeTakenMS, forKey: .fontsDownloadTimeTakenMS);
            try container.encodeIfPresent(bundleTimeTakenMS, forKey: .bundleDownloadTimeMS);
            try container.encodeIfPresent(numAttempts, forKey: .numAttempts)
        case .paywallsDownloadError(let error, let numAttempts):
            try container.encode("paywallsDownloadError", forKey: .type)
            try container.encode(error, forKey: .errorDescription)
            try container.encodeIfPresent(numAttempts, forKey: .numAttempts)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "initializeStart":
            self = .initializeStart
        case "ctaPressed":
            let ctaName = try container.decode(String.self, forKey: .ctaName)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .ctaPressed(ctaName: ctaName, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "offerSelected":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .offerSelected(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "subscriptionPressed":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .subscriptionPressed(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "subscriptionCancelled":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .subscriptionCancelled(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "subscriptionSucceeded":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            let storeKitTransactionId = try container.decodeIfPresent(String.self, forKey: .storeKitTransactionId)
            let storeKitOriginalTransactionId = try container.decodeIfPresent(String.self, forKey: .storeKitOriginalTransactionId)
            let skPostPurchaseTxnTimeMS = try container.decodeIfPresent(UInt64.self, forKey: .skPostPurchaseTxnTimeMS)
            self = .subscriptionSucceeded(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName, storeKitTransactionId: storeKitTransactionId, storeKitOriginalTransactionId: storeKitOriginalTransactionId, skPostPurchaseTxnTimeMS: skPostPurchaseTxnTimeMS)
        case "subscriptionFailed":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            let error = try container.decodeIfPresent(String.self, forKey: .errorDescription)
            self = .subscriptionFailed(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "subscriptionRestored":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .subscriptionRestored(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "subscriptionRestoreFailed":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .subscriptionRestoreFailed(triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "subscriptionPending":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .subscriptionPending(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "paywallOpen":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            let viewType = try container.decode(String.self, forKey: .viewType)
            self = .paywallOpen(triggerName: triggerName, paywallTemplateName: paywallTemplateName, viewType: viewType)
        case "paywallOpenFailed":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            let error = try container.decode(String.self, forKey: .errorDescription)
            self = .paywallOpenFailed(triggerName: triggerName, paywallTemplateName: paywallTemplateName, error: error)
        case "paywallClose":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .paywallClose(triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "paywallDismissed":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            let dimissAll = try container.decode(Bool.self, forKey: .dismissAll)
            self = .paywallDismissed(triggerName: triggerName, paywallTemplateName: paywallTemplateName, dismissAll: dimissAll)
        case "paywallSkipped":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            self = .paywallSkipped(triggerName: triggerName)
        case "paywallsDownloadSuccess":
            let configId = try container.decode(UUID.self, forKey: .configId)
            self = .paywallsDownloadSuccess(configId: configId)
        case "paywallsDownloadError":
            let error = try container.decode(String.self, forKey: .errorDescription)
            self = .paywallsDownloadError(error: error)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid type value")
        }
    }

    public func caseString() -> String {
        switch self {
        case .initializeStart:
            return "initializeStart"
        case .paywallWebViewRendered:
            return "paywallWebViewRendered"
        case .ctaPressed:
            return "ctaPressed"
        case .offerSelected:
            return "offerSelected"
        case .subscriptionPressed:
            return "subscriptionPressed"
        case .subscriptionCancelled:
            return "subscriptionCancelled"
        case .subscriptionSucceeded:
            return "subscriptionSucceeded"
        case .subscriptionFailed:
            return "subscriptionFailed"
        case .subscriptionRestored:
            return "subscriptionRestored"
        case .subscriptionRestoreFailed:
            return "subscriptionRestoreFailed"
        case .subscriptionPending:
            return "subscriptionPending"
        case .paywallOpen:
            return "paywallOpen"
        case .paywallOpenFailed:
            return "paywallOpenFailed"
        case .paywallClose:
            return "paywallClose"
        case .paywallDismissed:
            return "paywallDismissed"
        case .paywallSkipped:
            return "paywallSkipped"
        case .paywallsDownloadSuccess:
            return "paywallsDownloadSuccess"
        case .paywallsDownloadError:
            return "paywallsDownloadError"
        }
    }
    
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": self.caseString()
        ]
        
        switch self {
        case .initializeStart:
            break;
        case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName):
            dict["ctaName"] = ctaName
            dict["triggerName"] = triggerName
            dict["paywallTemplateName"] = paywallTemplateName
            
        case .offerSelected(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPressed(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionCancelled(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionSucceeded(let productKey, let triggerName, let paywallTemplateName, let _, let _, let _),
             .subscriptionRestored(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPending(let productKey, let triggerName, let paywallTemplateName):
            dict["productKey"] = productKey
            dict["triggerName"] = triggerName
            dict["paywallTemplateName"] = paywallTemplateName
        case .subscriptionRestoreFailed(let triggerName, let paywallTemplateName):
            dict["triggerName"] = triggerName
            dict["paywallTemplateName"] = paywallTemplateName
        case .subscriptionFailed(let productKey, let triggerName, let paywallTemplateName, let error):
            dict["productKey"] = productKey
            dict["triggerName"] = triggerName
            dict["paywallTemplateName"] = paywallTemplateName
            dict["errorDescription"] = error
            
        case .paywallWebViewRendered(let triggerName, let paywallTemplateName, let webviewRenderTimeTakenMS):
            dict["triggerName"] = triggerName
            dict["paywallTemplateName"] = paywallTemplateName
            dict["webviewRenderTimeTakenMS"] = webviewRenderTimeTakenMS
            
        case .paywallsDownloadSuccess(let configId, let downloadTimeTakenMS, let imagesDownloadTimeTakenMS, let fontsDownloadTimeTakenMS, let bundleDownloadTimeMS, let numAttempts):
            dict["configId"] = configId
            dict["downloadTimeTakenMS"] = downloadTimeTakenMS
            dict["imagesDownloadTimeTakenMS"] = imagesDownloadTimeTakenMS
            dict["fontsDownloadTimeTakenMS"] = fontsDownloadTimeTakenMS
            dict["bundleDownloadTimeMS"] = bundleDownloadTimeMS
            dict["numAttempts"] = numAttempts

        case .paywallOpen(let triggerName, let paywallTemplateName, let viewType, let loadTimeTakenMS, let loadingBudgetMS):
            dict["triggerName"] = triggerName;
            dict["paywallTemplateName"] = paywallTemplateName
            dict["viewType"] = viewType
            if let loadTimeTakenMS {
                dict["loadTimeTakenMS"] = loadTimeTakenMS
            }
            if let loadingBudgetMS {
                dict["loadingBudgetMS"] = loadingBudgetMS
            }
            
        case .paywallOpenFailed(let triggerName, let paywallTemplateName, let error):
            dict["triggerName"] = triggerName;
            dict["paywallTemplateName"] = paywallTemplateName
            dict["errorDescription"] = error
            
        case .paywallClose(let triggerName, let paywallTemplateName):
            dict["triggerName"] = triggerName;
            dict["paywallTemplateName"] = paywallTemplateName
            
        case .paywallDismissed(let triggerName, let paywallTemplateName, let dismissAll):
            dict["triggerName"] = triggerName;
            dict["paywallTemplateName"] = paywallTemplateName
            dict["dismissAll"] = dismissAll
            
        case .paywallSkipped(let triggerName):
            dict["triggerName"] = triggerName;
            
        case .paywallsDownloadError(let error, let numAttempts):
            dict["errorDescription"] = error
            dict["numAttempts"] = numAttempts
            
        }
        
        return dict
    }
}


public struct HeliumPaywallLoggedEvent: Codable {
    var heliumEvent: HeliumPaywallEvent
    var fetchedConfigId: UUID?
    var timestamp: String
    var isHeliumEvent: Bool = true
    
    var contextTraits: CodableUserContext?
    
    var experimentID: String?
    var modelID: String?
    var paywallID: Int?
    var paywallUUID: String?
    var organizationID: String?
    var heliumPersistentID: String?
    var heliumSessionID: String?
    var heliumPaywallSessionId: String?
    var appAttributionToken: String?
    var revenueCatAppUserID: String?
    var isFallback: Bool?
    
    var downloadStatus: HeliumFetchedConfigStatus?
    var additionalFields: JSON?
    var additionalPaywallFields: JSON?
}


// Protocol for all paywall views
public protocol PaywallView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String)
}

public enum PaywallOpenViewType : String {
    case presented = "presented"
    case triggered = "triggered" // SwiftUI view modifier
    case embedded = "embedded"
}
