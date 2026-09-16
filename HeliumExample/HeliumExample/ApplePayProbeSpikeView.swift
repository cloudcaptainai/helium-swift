//
//  ApplePayProbeSpikeView.swift
//  HeliumExample
//
//  SPIKE (HEL-5834): side-by-side comparison of
//    (A) web Apple Pay eligibility  - Stripe.js `canMakePayment()` in a hidden
//        WKWebView, from an https origin registered for Apple Pay
//    (B) in-app Apple Pay eligibility - native PassKit, mirroring ApplePayHelper
//
//  The point of (B) next to (A) is to sanity-check the premise: is the
//  web-vs-native "nuance" actually large enough on real devices to move the
//  dead-click number, or do the two signals mostly agree?
//

import SwiftUI
import PassKit

struct ApplePayProbeSpikeView: View {

    // Real Paddle publishable key (publishable = public, safe client-side).
    // Must pair with an https host registered for Apple Pay in Paddle's Stripe
    // account - see httpsBaseURL below.
    @State private var publishableKey: String = "pk_live_51HfRouK86Yke5s34QKy5C7D8Idlp8v3znnZJeojqlZKFCefPNDM3iPiT8jRi8fNS0vXLqp3B4SiPyXOyHpbOGKmI00xcRzEy1o"
    @State private var country: String = "US"
    @State private var currency: String = "usd"
    @State private var amountCents: String = "100"
    // The hostname Paddle registers for Apple Pay (SDK's prod source_page origin).
    @State private var httpsBaseURL: String = "https://bundles.clickthrough.to/"

    @State private var result: ProbeResult?
    @State private var running: Bool = false

    private let native = NativeApplePayEligibility.current()

    var body: some View {
        Form {
            configSection
            runSection
            webResultSection
            nativeSection
            comparisonSection
        }
        .navigationTitle("Apple Pay Probe Spike")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var configSection: some View {
        Section("Probe config") {
            LabeledContent("Publishable key") {
                TextField("pk_...", text: $publishableKey)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.footnote)
            }
            LabeledContent("Country") {
                TextField("US", text: $country).multilineTextAlignment(.trailing)
            }
            LabeledContent("Currency") {
                TextField("usd", text: $currency).multilineTextAlignment(.trailing)
            }
            LabeledContent("Amount (cents)") {
                TextField("100", text: $amountCents)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("https origin") {
                TextField("https://...", text: $httpsBaseURL)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.footnote)
            }
        }
    }

    private var runSection: some View {
        Section {
            Button(running ? "Running…" : "Run probe") {
                Task { await run() }
            }
            .disabled(running)
            .accessibilityIdentifier("runApplePayProbe")
            if result != nil {
                Button("Copy results as text") {
                    UIPasteboard.general.string = resultsDump()
                    print(resultsDump())
                }
                Button("Clear result", role: .destructive) { result = nil }
            }
        }
    }

    @ViewBuilder
    private var webResultSection: some View {
        if let r = result {
            Section("Web probe (Stripe.js canMakePayment)") {
                webResultRow(r)
            }
        }
    }

    private func webResultRow(_ r: ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Result").font(.headline)
                Spacer()
                readyBadge(r.applePayReady, timedOut: r.timedOut, error: r.loadError != nil)
            }
            row("stage", r.stage)
            row("ApplePaySession present", boolText(r.hasApplePaySession))
            row("secureContext", boolText(r.secureContext))
            if let cap = r.payload["applePayCanMakePayments"] as? Bool {
                row("ApplePaySession.canMakePayments()", boolText(cap))
            }
            if let activeCard = r.payload["activeCard"] as? String {
                row("canMakePaymentsWithActiveCard()", activeCard)
                row("merchantId", r.merchantId)
            }
            if let status = r.payload["paymentCredentialStatus"] as? String {
                row("applePayCapabilities()", status)
            }
            row("Stripe applePay ready", boolText(r.applePayReady))
            if let load = r.payload["stripeLoadMs"] as? Double {
                row("Stripe.js load", String(format: "%.0f ms", load))
            }
            if let cmp = r.payload["canMakePaymentMs"] as? Double {
                row("canMakePayment()", String(format: "%.0f ms", cmp))
            }
            if let total = r.payload["totalMs"] as? Double {
                row("JS total", String(format: "%.0f ms", total))
            }
            row("wall clock (native)", String(format: "%.0f ms", r.swiftWallClockMs))
            if let href = r.payload["href"] as? String {
                row("origin href", href)
            }
            if let err = r.loadError {
                row("load error", err).foregroundStyle(.red)
            }
            if let err = r.payload["error"] as? String {
                row("js error", err).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var nativeSection: some View {
        Section("In-app native (PassKit - mirrors ApplePayHelper)") {
            row("canMakePayments() [device]", boolText(native.canMakePayments))
            row("has credit card in Wallet", boolText(native.hasCreditCard))
            row("has debit card in Wallet", boolText(native.hasDebitCard))
            row("networks", native.networks)
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if let r = result {
            Section("Comparison") {
                let webCard = webActiveCard(r)
                let nativeCard = native.hasCreditCard || native.hasDebitCard
                row("web says has card", webCard.map(boolText) ?? "unavailable")
                row("native says has card", boolText(nativeCard))
                row("Stripe applePay (card-aware)", boolText(r.applePayReady))
                if let webCard {
                    if webCard != nativeCard {
                        Text("⚠️ Card-aware signals DISAGREE, the web/native nuance is real on this device.")
                            .font(.footnote).foregroundStyle(.orange)
                    } else {
                        Text("Card-aware signals agree on this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No card-aware web answer on this device, comparison inconclusive.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// `canMakePaymentsWithActiveCard()` as a tri-state: nil when the API
    /// errored, was unsupported or never resolved.
    private func webActiveCard(_ r: ProbeResult) -> Bool? {
        switch r.payload["activeCard"] as? String {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    // MARK: - Run

    private func run() async {
        running = true
        defer { running = false }
        result = nil
        let config = ProbeConfig(
            publishableKey: publishableKey,
            country: country,
            currency: currency,
            amount: Int(amountCents) ?? 100,
            httpsBaseURL: httpsBaseURL
        )
        let probe = WebApplePayProbe()
        result = await probe.run(config: config)
    }

    /// Full text dump of config + web result (all fields) + native values, so
    /// the whole run can be pasted somewhere instead of transcribed.
    private func resultsDump() -> String {
        var out = "=== Apple Pay Probe (HEL-5834) ===\n"
        out += "pk: \(publishableKey.prefix(12))…  country: \(country)  currency: \(currency)  amount: \(amountCents)\n"
        out += "httpsBaseURL: \(httpsBaseURL)\n\n"
        if let r = result {
            out += "swiftWallClockMs: \(String(format: "%.0f", r.swiftWallClockMs))  timedOut: \(r.timedOut)\n"
            if let e = r.loadError { out += "loadError: \(e)\n" }
            for k in r.payload.keys.sorted() {
                out += "\(k): \(r.payload[k].map { String(describing: $0) } ?? "nil")\n"
            }
            out += "\n"
        }
        out += "--- native (PassKit) ---\n"
        out += "canMakePayments: \(native.canMakePayments)\n"
        out += "hasCreditCard: \(native.hasCreditCard)\n"
        out += "hasDebitCard: \(native.hasDebitCard)\n"
        return out
    }

    // MARK: - Small view helpers

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.footnote.monospaced()).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func boolText(_ b: Bool) -> String { b ? "true" : "false" }

    private func readyBadge(_ ready: Bool, timedOut: Bool, error: Bool) -> some View {
        let (text, color): (String, Color) =
            timedOut ? ("TIMEOUT", .orange)
            : error ? ("ERROR", .red)
            : ready ? ("READY", .green)
            : ("not ready", .secondary)
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// Native PassKit eligibility, computed exactly like `ApplePayHelper` does
/// (same networks list) so the numbers are directly comparable.
struct NativeApplePayEligibility {
    let canMakePayments: Bool
    let hasCreditCard: Bool
    let hasDebitCard: Bool
    let networks: String

    static func current() -> NativeApplePayEligibility {
        let networks: [PKPaymentNetwork] = [.amex, .masterCard, .visa, .discover]
        return NativeApplePayEligibility(
            canMakePayments: PKPaymentAuthorizationController.canMakePayments(),
            hasCreditCard: PKPaymentAuthorizationController.canMakePayments(usingNetworks: networks, capabilities: .credit),
            hasDebitCard: PKPaymentAuthorizationController.canMakePayments(usingNetworks: networks, capabilities: .debit),
            networks: "amex, mastercard, visa, discover"
        )
    }
}

#Preview {
    NavigationStack { ApplePayProbeSpikeView() }
}
