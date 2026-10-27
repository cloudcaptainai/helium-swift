//
//  BanditReasonPresentationMapper.swift
//  Helium
//

import Foundation

enum BanditReasonKind: CaseIterable {
    case paddleGeo
    case paddleCaliforniaConsent
    case paddleCredentials
    case applePayUnavailable
    case versionUnresolved
    case noTargetingMatch
    case workflowNoPaywall
    case experimentMisconfigured
    case workflowError
    case noWorkflow

    init?(sentence: String) {
        let text = sentence.lowercased()
        guard let kind = Self.allCases.first(where: { text.contains($0.sentenceMarker) }) else {
            return nil
        }
        self = kind
    }

    private var sentenceMarker: String {
        switch self {
        case .paddleGeo: return "users verified as located in the us"
        case .paddleCaliforniaConsent: return "california"
        case .paddleCredentials: return "paddle credentials"
        case .applePayUnavailable: return "apple pay"
        case .versionUnresolved: return "single published version"
        case .noTargetingMatch: return "did not match any targeting rule"
        case .workflowNoPaywall: return "no default paywall or experiment configured"
        case .experimentMisconfigured: return "allocation metadata"
        case .workflowError: return "error while evaluating"
        case .noWorkflow: return "no workflow is connected"
        }
    }
}

struct CountrySignals: Equatable {
    let deviceRegion: String?
    let storeCountry: String?

    init(deviceRegion: String? = nil, storeCountry: String? = nil) {
        self.deviceRegion = deviceRegion
        self.storeCountry = storeCountry
    }
}

struct BanditReasonPresentation: Equatable {
    let title: String
    let fix: String?
    let checks: [DiagnosticCheck]

    static let unrecognised = BanditReasonPresentation(
        title: "No paywall was resolved for this trigger",
        fix: nil,
        checks: []
    )
}

struct BanditReasonPresentationMapper {

    func map(_ sentence: String, countrySignals: CountrySignals = CountrySignals()) -> BanditReasonPresentation {
        guard let kind = BanditReasonKind(sentence: sentence) else { return .unrecognised }
        return map(kind, countrySignals: countrySignals)
    }

    func map(_ kind: BanditReasonKind, countrySignals: CountrySignals = CountrySignals()) -> BanditReasonPresentation {
        switch kind {
        case .paddleGeo:
            return BanditReasonPresentation(
                title: "Paddle needs a US buyer",
                fix: "Target this paywall at a US audience, or give the trigger a fallback rule.",
                checks: [
                    DiagnosticCheck(label: "Device region is US", verdict: Self.verdict(isUS: countrySignals.deviceRegion)),
                    DiagnosticCheck(label: "App Store country is US", verdict: Self.verdict(isUS: countrySignals.storeCountry)),
                    DiagnosticCheck(label: "IP country is US", verdict: .checkedByServer),
                ]
            )
        case .paddleCaliforniaConsent:
            return BanditReasonPresentation(
                title: "California needs the consent modal",
                fix: "Update to iOS SDK 4.7.1 or newer and enable the consent modal for this org.",
                checks: []
            )
        case .paddleCredentials:
            return BanditReasonPresentation(
                title: "Paddle credentials missing",
                fix: "Reconnect Paddle under Integrations, then publish the paywall again.",
                checks: []
            )
        case .applePayUnavailable:
            return BanditReasonPresentation(
                title: "Apple Pay not available",
                fix: "Test on a device with a card in Wallet, or give the trigger a fallback rule.",
                checks: []
            )
        case .versionUnresolved:
            return BanditReasonPresentation(
                title: "Paywall version not published",
                fix: "Open the paywall in the editor and publish it.",
                checks: []
            )
        case .noTargetingMatch:
            return BanditReasonPresentation(
                title: "No targeting rule matched",
                fix: "Add a rule for everyone else, or set a default paywall on the workflow.",
                checks: []
            )
        case .workflowNoPaywall:
            return BanditReasonPresentation(
                title: "Workflow has no default paywall",
                fix: "Set a default paywall or experiment on the workflow.",
                checks: []
            )
        case .experimentMisconfigured:
            return BanditReasonPresentation(
                title: "Experiment misconfigured",
                fix: "Open the experiment and fix its allocation, then take it live again.",
                checks: []
            )
        case .workflowError:
            return BanditReasonPresentation(
                title: "Workflow evaluation failed",
                fix: "Copy the diagnostic report and contact Helium.",
                checks: []
            )
        case .noWorkflow:
            return BanditReasonPresentation(
                title: "No workflow on this trigger",
                fix: "Add the trigger to a workflow in the dashboard.",
                checks: []
            )
        }
    }

    private static func verdict(isUS code: String?) -> DiagnosticCheck.Verdict {
        code?.uppercased() == "US" ? .passed : .failed
    }
}
