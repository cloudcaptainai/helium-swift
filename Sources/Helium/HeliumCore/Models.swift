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

extension KeyedDecodingContainer {
    /// A style this SDK version does not recognize is treated as unset. Synthesized decoding would
    /// otherwise throw, and this field decodes alongside `resolvedConfig`, so one bad value would
    /// fail the entire config and take every trigger down with it rather than just the animation.
    ///
    /// Only applies to optional properties; a non-optional declaration emits `decode` instead.
    func decodeIfPresent(
        _ type: HeliumPresentationStyle.Type,
        forKey key: Key
    ) throws -> HeliumPresentationStyle? {
        guard let rawValue = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return HeliumPresentationStyle(rawValue: rawValue)
    }
}

public struct HeliumPaywallInfo: Codable {
    var paywallID: Int
    var paywallUUID: String?
    public var paywallTemplateName: String
    var productsOffered: [String]?
    var productsOfferedIOS: [String]?
    var productsOfferedStripe: [String]?
    var productsOfferedPaddle: [String]?
    var webProductsOfferedPaddle: [String]?
    var webProductsOfferedStripe: [String]?
    var resolvedConfig: AnyCodable
    var shouldShow: Bool?
    var fallbackPaywallName: String?
    public var experimentID: String?
    var modelID: String?
    var forceShowFallback: Bool?
    var secondChance: Bool?
    var secondChancePaywall: AnyCodable?
    var resolvedConfigJSON: JSON?
    var experimentInfo: JSON?  // New top-level field from server
    var additionalPaywallFields: JSON?
    var presentationStyle: HeliumPresentationStyle?
    var productHapticsEnabled: [String]? = nil
    
    var productIdsIOS: [String] {
        productsOfferedIOS ?? productsOffered ?? []
    }
    
    var productIds: [String] {
        productIdsIOS + (productsOfferedStripe ?? []) + (productsOfferedPaddle ?? [])
    }

    var productIdsIncludingWebProductIds: [String] {
        productIds + (webProductsOfferedPaddle ?? []) + (webProductsOfferedStripe ?? [])
    }

    var hasProducts: Bool {
        !productIds.isEmpty
    }
    
    /// Extracted bundle URL - single source of truth for bundle URL extraction
    var extractedBundleUrl: String? {
        // First try resolvedConfig
        if let resolvedConfig = resolvedConfig.value as? [String : Any],
           let baseStack = resolvedConfig["baseStack"] as? [String : Any],
           let componentProps = baseStack["componentProps"] as? [String : Any] {
            let bundleUrl = componentProps["bundleURL"] as? String ?? ""
            if !bundleUrl.isEmpty {
                return bundleUrl
            }
        }
        // Then additionalPaywallFields
        if let bundleUrl = additionalPaywallFields?["paywallBundleUrl"].string, !bundleUrl.isEmpty {
            return bundleUrl
        }
        return nil
    }
    
    var webPaywallBundleUrl: String? {
        if let bundleUrl = additionalPaywallFields?["webPaywallBundleUrl"].string, !bundleUrl.isEmpty {
            return bundleUrl
        }
        return nil
    }
    
    /// Local file path for the bundle - converts extractedBundleUrl to local path
    var localBundlePath: String? {
        guard let bundleUrl = extractedBundleUrl else { return nil }
        return HeliumAssetManager.shared.localPathForURL(bundleURL: bundleUrl)
    }
}

//User-facing details about a paywall
public struct PaywallInfo {
    public let paywallTemplateName: String
    public let shouldShow: Bool
}

public struct CanShowPaywallResult {
    public let canShow: Bool
    public let isFallback: Bool?
    public let paywallUnavailableReason: PaywallUnavailableReason?
}

public struct HeliumFetchedConfig: Codable {
    var triggerToPaywalls: [String: HeliumPaywallInfo]
    var segmentBrowserWriteKey: String
    var segmentAnalyticsEndpoint: String
    var orgName: String?
    var organizationID: String?
    var fetchedConfigID: UUID
    var additionalFields: JSON?
    var bundles: [String: String]?
    var generatedAt: String?
    
    var stripeProducts: [String: ServerProductPrice]?
    var stripeCustomerId: String?
    var enableProductionPaywallPreviews: Bool?
    
    var paddleProducts: [String: ServerProductPrice]?
    var paddleCustomerId: String?

    var paddleClientToken: String?
    
    /// Extract experiment info for a specific trigger
    /// - Parameter trigger: The trigger name to extract experiment info for
    /// - Returns: ExperimentInfo if experiment data is available
    func extractExperimentInfo(trigger: String) -> ExperimentInfo? {
        // Get paywall info for this trigger
        guard let paywallInfo = triggerToPaywalls[trigger] else {
            return nil
        }
        
        // Check top-level experimentInfo field
        guard let expInfo = paywallInfo.experimentInfo, expInfo.exists(),
              let experimentInfoData = try? JSONEncoder().encode(expInfo),
              let response = try? JSONDecoder().decode(ExperimentInfoResponse.self, from: experimentInfoData) else {
            return nil
        }
        
        // Find all triggers with the same experiment ID
        var allTriggersForExperiment: [String] = []
        if let experimentId = response.experimentId, !experimentId.isEmpty {
            for (triggerName, info) in triggerToPaywalls {
                if info.experimentID == experimentId {
                    allTriggersForExperiment.append(triggerName)
                }
            }
        }
        
        var experimentInfo = ExperimentInfo(
            enrolledTrigger: nil,
            triggers: allTriggersForExperiment.isEmpty ? nil : allTriggersForExperiment,
            experimentName: response.experimentName,
            experimentId: response.experimentId,
            experimentType: response.experimentType,
            experimentVersionId: response.experimentVersionId,
            experimentMetadata: response.experimentMetadata,
            startDate: response.startDate,
            endDate: response.endDate,
            audienceId: response.audienceId,
            audienceData: response.audienceData,
            chosenVariantDetails: response.chosenVariantDetails,
            hashDetails: response.hashDetails,
            enrolledAt: nil,
            isEnrolled: false
        )
        
        // enrolledAt, isEnrolled, and enrolledTrigger are stored locally by sdk
        let persistentId = HeliumIdentityManager.shared.getHeliumPersistentId()
        let enrollment = ExperimentAllocationTracker.shared.getEnrollmentInfo(
            persistentId: persistentId,
            trigger: trigger,
            experimentInfo: experimentInfo
        )
        experimentInfo.enrolledAt = enrollment.enrolledAt
        experimentInfo.isEnrolled = enrollment.isEnrolled
        experimentInfo.enrolledTrigger = enrollment.enrolledTrigger
        
        return experimentInfo
    }
    
    func getTriggersWithMissingProducts() -> [String] {
        triggerToPaywalls.filter { !$0.value.hasProducts }.map { $0.key }
    }
}


public struct HeliumPaywallLoggedEvent: Codable {
    /// Analytics payload built by `HeliumAnalyticsMapper.mapToAnalyticsPayload`.
    /// Deliberately `SegmentJSON` rather than `AnyCodable`: its throwing init
    /// validates the payload eagerly at construction, and it is the type Segment
    /// converts Codable properties into internally.
    var heliumEvent: SegmentJSON
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
    var userId: String?
    var hasCustomUserId: Bool = false
    var heliumSessionID: String?
    var heliumInitializeId: String?
    var heliumPaywallSessionId: String?
    var appAttributionToken: String?
    var appTransactionId: String?
    var revenueCatAppUserID: String?
    var thirdPartyAnalyticsAnonymousId: String?
    var isFallback: Bool?
    
    var downloadStatus: HeliumFetchedConfigStatus?
    var additionalFields: JSON?
    var additionalPaywallFields: JSON?
    var experimentInfo: ExperimentInfo?  // New: experiment allocation data
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

public enum PaywallUnavailableReason: String, Codable, CaseIterable {
    case notInitialized
    case triggerHasNoPaywall
    case forceShowFallback
    case invalidResolvedConfig
    case paywallsNotDownloaded
    case configFetchInProgress
    case bundlesFetchInProgress
    case productsFetchInProgress
    case paywallsDownloadFail
    case secondTryNoMatch
    case alreadyPresented
    case noRootController
    case webviewRenderFail
    case bridgingError
    case couldNotFindBundleUrl
    case bundleFetchInvalidUrlDetected
    case bundleFetchInvalidUrl
    case bundleFetch403
    case bundleFetch404
    case bundleFetch410
    case bundleFetchCannotDecodeContent
    case noProductsIOS
    case webCheckoutNoCustomUserId
    case webCheckoutNotEnabled
}

/// Reason a paywall was not shown.
public enum PaywallNotShownReason: Equatable, CustomStringConvertible {
    /// Paywall not shown because user is already entitled to a product in the paywall.
    /// To disable this, ensure `dontShowIfAlreadyEntitled` is `false`.
    case alreadyEntitled
    /// Paywall skipped due to targeting holdout. Check your workflow configuration if this is
    /// not expected: https://app.tryhelium.com/workflows
    case targetingHoldout
    /// An unexpected error prevented the paywall from being shown.
    case error(unavailableReason: PaywallUnavailableReason?)

    public var description: String {
        switch self {
        case .error(let unavailableReason):
            if let reason = unavailableReason {
                return "error: \(reason.rawValue)"
            } else {
                return "error: unknown"
            }
        case .alreadyEntitled:
            return "alreadyEntitled"
        case .targetingHoldout:
            return "targetingHoldout"
        }
    }
}

public enum PaywallSkippedReason: String, Codable, CaseIterable {
    case targetingHoldout
    case alreadyEntitled
}

public enum HeliumLightDarkMode {
    case light
    case dark
    case system
}

/// Selects which External Web Checkout payment processors are enabled.
/// Use `.all` for both, or `.paddle` / `.stripe` individually.
public struct WebCheckoutProcessors: OptionSet, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let paddle = WebCheckoutProcessors(rawValue: 1 << 0)
    public static let stripe = WebCheckoutProcessors(rawValue: 1 << 1)
    public static let all: WebCheckoutProcessors = [.paddle, .stripe]

    public var description: String {
        if isEmpty { return "none" }
        var names: [String] = []
        if contains(.paddle) { names.append("paddle") }
        if contains(.stripe) { names.append("stripe") }
        return names.joined(separator: ", ")
    }
}
