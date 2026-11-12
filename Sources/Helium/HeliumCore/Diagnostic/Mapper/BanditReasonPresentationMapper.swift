//
//  BanditReasonPresentationMapper.swift
//  Helium
//

import Foundation

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

    static let presentations: [String: BanditReasonPresentation] = [
        "paddle_ip_country_not_us": geo,
        "paddle_store_country_not_us": geo,
        "paddle_locale_country_not_us": geo,
        "paddle_country_unverified": geo,
        "paddle_ca_consent_required": BanditReasonPresentation(title: "California needs the consent modal", fix: "Update the SDK and enable the consent modal for this org.", checks: []),
        "paddle_credentials_unusable": BanditReasonPresentation(title: "Paddle credentials missing", fix: "Reconnect Paddle under Integrations, then publish the paywall again.", checks: []),
        "paddle_sandbox_price_not_copied": sandbox,
        "paddle_sandbox_copies_unavailable": sandbox,
        "paddle_sandbox_credentials_unreadable": BanditReasonPresentation(title: "Paddle sandbox account unreadable", fix: "Reconnect the Paddle sandbox account under Integrations.", checks: []),
        "paddle_android_unsupported": BanditReasonPresentation(title: "Paddle checkout not supported on Android", fix: "Add a rule for Android users or use Play products.", checks: []),
        "stripe_android_unsupported": BanditReasonPresentation(title: "Stripe checkout not supported on Android", fix: "Add a rule for Android users or use Play products.", checks: []),
        "stripe_external_apple_pay_unavailable": BanditReasonPresentation(title: "Apple Pay not available", fix: applePayFix, checks: []),
        "stripe_in_app_apple_pay_unavailable": BanditReasonPresentation(title: "Apple Pay not available for in-app Stripe", fix: applePayFix, checks: []),
        "paywall_not_found": BanditReasonPresentation(title: "Paywall not found", fix: "Reconnect the workflow to an existing paywall.", checks: []),
        "paywall_version_unresolved": BanditReasonPresentation(title: "Paywall version not published", fix: "Open the paywall in the editor and publish it.", checks: []),
        "no_targeting_match": BanditReasonPresentation(title: "No targeting rule matched", fix: "Add a rule for everyone else, or set a default paywall on the workflow.", checks: []),
        "targeting_no_paywall": BanditReasonPresentation(title: "Rule shows no paywall", fix: "This rule is configured to show nothing; change it or add a paywall.", checks: []),
        "targeting_misconfigured": BanditReasonPresentation(title: "Targeting rule misconfigured", fix: "Give the rule a paywall or experiment.", checks: []),
        "targeting_parse_error": BanditReasonPresentation(title: "Targeting rules unreadable", fix: "Copy the diagnostic report and contact Helium.", checks: []),
        "workflow_no_paywall": BanditReasonPresentation(title: "Workflow has no default paywall", fix: "Set a default paywall or experiment on the workflow.", checks: []),
        "experiment_unresolved": BanditReasonPresentation(title: "Experiment stopped or missing", fix: "Reconnect the workflow to a live experiment.", checks: []),
        "experiment_misconfigured": BanditReasonPresentation(title: "Experiment misconfigured", fix: "Open the experiment and fix its allocation, then take it live again.", checks: []),
        "experiment_not_exposed": BanditReasonPresentation(title: "User outside experiment exposure", fix: "This is expected; raise exposure or add a default paywall.", checks: []),
        "no_workflow_connected": BanditReasonPresentation(title: "No workflow on this trigger", fix: "Add the trigger to a workflow in the dashboard.", checks: []),
        "workflow_not_found": BanditReasonPresentation(title: "Workflow not found", fix: "Reconnect the trigger to an existing workflow.", checks: []),
    ]

    private static let geo = BanditReasonPresentation(title: "Paddle needs a US buyer", fix: "Target this paywall at a US audience, or add a rule for users outside the US.", checks: [])
    private static let sandbox = BanditReasonPresentation(title: "Paddle sandbox products not synced", fix: "Open the Helium dashboard and sync Paddle sandbox products.", checks: [])
    private static let applePayFix = "Test on a device with a card in Wallet, or add a rule for users without Apple Pay."

    func map(_ code: String?, countrySignals: CountrySignals = CountrySignals()) -> BanditReasonPresentation {
        let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard let presentation = Self.presentations[code] else { return .unrecognised }
        let failedRow: Int
        switch code {
        case "paddle_locale_country_not_us": failedRow = 0
        case "paddle_store_country_not_us": failedRow = 1
        case "paddle_ip_country_not_us": failedRow = 2
        case "paddle_country_unverified": failedRow = -1
        default: return presentation
        }
        let labels = [
            "Device region is US" + (countrySignals.deviceRegion.map { " (\($0))" } ?? ""),
            "App Store country is US" + (countrySignals.storeCountry.map { " (\($0))" } ?? ""),
            "IP country is US"
        ]
        return BanditReasonPresentation(
            title: presentation.title,
            fix: presentation.fix,
            checks: labels.enumerated().map { index, label in
                DiagnosticCheck(label: label + (failedRow == -1 && index == 2 ? " — a signal was missing" : ""),
                                verdict: index == failedRow ? .failed : .unknown)
            }
        )
    }
}
