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
import AnyCodable
import Segment

public func createDummyHeliumPaywallInfo(paywallTemplateName: String) -> HeliumPaywallInfo {
    return HeliumPaywallInfo(
        paywallID: 1,
        paywallTemplateName: paywallTemplateName,
        productsOffered: [],
        resolvedConfig: [:],
        shouldShow: true,
        fallbackPaywallName: ""
    )
}

public struct HeliumPaywallInfo: Codable {
    public init(paywallID: Int, paywallTemplateName: String, productsOffered: [String], resolvedConfig: AnyCodable, shouldShow: Bool, fallbackPaywallName: String, experimentID: String? = nil) {
        self.paywallID = paywallID
        self.paywallTemplateName = paywallTemplateName;
        self.productsOffered = productsOffered;
        self.resolvedConfig = resolvedConfig;
        self.shouldShow = shouldShow;
        self.fallbackPaywallName = fallbackPaywallName;
        self.experimentID = experimentID;
    }
    
    var paywallID: Int
    public var paywallTemplateName: String
    var productsOffered: [String]
    public var resolvedConfig: AnyCodable
    var shouldShow: Bool
    var fallbackPaywallName: String
    public var experimentID: String?
    var secondChance: Bool?
    var secondChancePaywall: AnyCodable?
}

public struct HeliumFetchedConfig: Codable {
    var triggerToPaywalls: [String: HeliumPaywallInfo]
    var segmentBrowserWriteKey: String
    var segmentAnalyticsEndpoint: String
    var orgName: String
    var fetchedConfigID: UUID
}

public enum HeliumPaywallEvent: Codable {
    case ctaPressed(ctaName: String, triggerName: String, paywallTemplateName: String)
    case offerSelected(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionPressed(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionCancelled(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionSucceeded(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionFailed(productKey: String, triggerName: String, paywallTemplateName: String, error: String? = nil)
    case subscriptionRestored(productKey: String, triggerName: String, paywallTemplateName: String)
    case subscriptionPending(productKey: String, triggerName: String, paywallTemplateName: String)
    case paywallOpen(triggerName: String, paywallTemplateName: String)
    case paywallOpenFailed(triggerName: String, paywallTemplateName: String)
    case paywallClose(triggerName: String, paywallTemplateName: String)
    case paywallDismissed(triggerName: String, paywallTemplateName: String)
    case paywallsDownloadSuccess(configId: UUID, downloadTimeTakenMS: UInt64? = nil, imagesDownloadTimeTakenMS: UInt64? = nil, fontsDownloadTimeTakenMS: UInt64? = nil)
    case paywallsDownloadError(error: String)

    private enum CodingKeys: String, CodingKey {
        case type, ctaName, productKey, triggerName, paywallTemplateName, configId, errorDescription, downloadTimeTakenMS, imagesDownloadTimeTakenMS, fontsDownloadTimeTakenMS
    }
    
    public func getTriggerIfExists() -> String?{
        switch self {
        case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName):
            return triggerName;
            
        case .offerSelected(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPressed(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionCancelled(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionSucceeded(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionRestored(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPending(let productKey, let triggerName, let paywallTemplateName):
            
            return triggerName;
        case .subscriptionFailed(let productKey, let triggerName, let paywallTemplateName, let error):
            return triggerName;
            
        case .paywallOpen(let triggerName, let paywallTemplateName),
             .paywallOpenFailed(let triggerName, let paywallTemplateName),
             .paywallClose(let triggerName, let paywallTemplateName),
             .paywallDismissed(let triggerName, let paywallTemplateName):
            return triggerName;
            
        case .paywallsDownloadSuccess(let configId):
            return nil;
        case .paywallsDownloadError(let error):
            return nil;
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .ctaPressed(let ctaName, let triggerName, let paywallTemplateName):
            try container.encode("ctaPressed", forKey: .type)
            try container.encode(ctaName, forKey: .ctaName)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
        case .offerSelected(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionPressed(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionCancelled(let productKey, let triggerName, let paywallTemplateName),
             .subscriptionSucceeded(let productKey, let triggerName, let paywallTemplateName),
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
        case .paywallOpen(let triggerName, let paywallTemplateName),
             .paywallOpenFailed(let triggerName, let paywallTemplateName),
             .paywallClose(let triggerName, let paywallTemplateName),
             .paywallDismissed(let triggerName, let paywallTemplateName):
            try container.encode(String(describing: self).components(separatedBy: "(")[0], forKey: .type)
            try container.encode(triggerName, forKey: .triggerName)
            try container.encode(paywallTemplateName, forKey: .paywallTemplateName)
        case .paywallsDownloadSuccess(let configId, let downloadTimeTakenMS, let imagesDownloadTimeTakenMS, let fontsDownloadTimeTakenMS):
            try container.encode("paywallsDownloadSuccess", forKey: .type)
            try container.encode(configId, forKey: .configId)
            try container.encodeIfPresent(downloadTimeTakenMS, forKey: .downloadTimeTakenMS);
            try container.encodeIfPresent(imagesDownloadTimeTakenMS, forKey: .imagesDownloadTimeTakenMS);
            try container.encodeIfPresent(fontsDownloadTimeTakenMS, forKey: .fontsDownloadTimeTakenMS);
        case .paywallsDownloadError(let error):
            try container.encode("paywallsDownloadError", forKey: .type)
            try container.encode(error, forKey: .errorDescription)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
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
            self = .subscriptionSucceeded(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
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
        case "subscriptionPending":
            let productKey = try container.decode(String.self, forKey: .productKey)
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .subscriptionPending(productKey: productKey, triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "paywallOpen":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .paywallOpen(triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "paywallOpenFailed":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .paywallOpenFailed(triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "paywallClose":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .paywallClose(triggerName: triggerName, paywallTemplateName: paywallTemplateName)
        case "paywallDismissed":
            let triggerName = try container.decode(String.self, forKey: .triggerName)
            let paywallTemplateName = try container.decode(String.self, forKey: .paywallTemplateName)
            self = .paywallDismissed(triggerName: triggerName, paywallTemplateName: paywallTemplateName)
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
        case .paywallsDownloadSuccess:
            return "paywallsDownloadSuccess"
        case .paywallsDownloadError:
            return "paywallsDownloadError"
        }
    }
}


public struct HeliumPaywallLoggedEvent: Codable {
    var heliumEvent: HeliumPaywallEvent
    var fetchedConfigId: UUID?
    var timestamp: String
    var isHeliumEvent: Bool = true
    var experimentID: String?
    var downloadStatus: HeliumFetchedConfigStatus?
}


// Protocol for all paywall views
public protocol PaywallView: View {
    init(paywallInfo: HeliumPaywallInfo, trigger: String)
}
