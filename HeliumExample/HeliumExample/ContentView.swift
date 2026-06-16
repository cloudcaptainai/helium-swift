//
//  ContentView.swift
//  HeliumExample
//
//  Created by Kyle Gorlick on 11/17/25.
//

import SwiftUI
import Helium

struct ContentView: View {
    
    @State private var showEmbeddedPaywall: Bool = false
    @State private var showModifierPaywall: Bool = false
    @State private var dontShowIfAlreadyEntitled: Bool = false
    @State private var showEntitlementAlert: Bool = false
    @State private var entitlementInfo: String = ""
    @State private var trigger: String = AppConfig.triggerKey
    @State private var userId: String = Helium.identify.userId ?? "nil"

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle("Helium Example App")
        }
    }

    private var formContent: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Trigger") {
                    TextField("Trigger key", text: $trigger)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("dontShowIfAlreadyEntitled", isOn: $dontShowIfAlreadyEntitled)
                LabeledContent("User ID") {
                    Text(userId)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Present Paywall") {
                Button("show paywall") {
                    Helium.shared.presentPaywall(
                        trigger: trigger, config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: dontShowIfAlreadyEntitled)
                    ) { reason in
                        print("[Helium Example] show paywall - Could not show paywall. \(reason)")
                    }
                }
                .accessibilityIdentifier("presentPaywall")

                Button("show via modifier") {
                    showModifierPaywall = true
                }
                .accessibilityIdentifier("showPaywallViaModifier")
                .heliumPaywall(
                    isPresented: $showModifierPaywall,
                    trigger: trigger,
                    config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: dontShowIfAlreadyEntitled)
                ) { reason in
                    Text("no show! \(reason.description)")
                }

                Button("show via embedded") {
                    showEmbeddedPaywall = true
                }
                .accessibilityIdentifier("showPaywallEmbedded")
                .fullScreenCover(isPresented: $showEmbeddedPaywall) {
                    HeliumPaywall(
                        trigger: trigger, config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: dontShowIfAlreadyEntitled)
                    ) { reason in
                        Text("no show embedded! \(reason.description)")
                    }
                }
            }

            Section("Test Default Paywall") {
                Button("show fallback (invalid trigger)") {
                    Helium.shared.presentPaywall(trigger: "nonexistent_trigger_that_does_not_exist") { reason in
                        print("[Helium Example] invalid trigger - Could not show paywall. \(reason)")
                    }
                }
                .accessibilityIdentifier("presentFallbackInvalidTrigger")
            }

            Section("User & Entitlements") {
                Button("set random user id") {
                    let newId = UUID().uuidString
                    Helium.identify.userId = newId
                    userId = newId
                }

                Button("check entitlements") {
                    Task {
                        let hasAny = await Helium.entitlements.hasAny()
                        let hasActiveSub = await Helium.entitlements.hasAnyActiveSubscription()
                        let productIds = await Helium.entitlements.purchasedProductIds()

                        let hasPaddle = await Helium.entitlements.hasActivePaddleEntitlement()
                        let hasStripe = await Helium.entitlements.hasActiveStripeEntitlement()

                        var info = "Has Any Entitlement: \(hasAny)\n"
                        info += "Has Active Subscription: \(hasActiveSub)\n"
                        
                        info += "Paddle entitled? \(hasPaddle)\n"
                        info += "Stripe entitled? \(hasStripe)\n"

                        info += "\nPurchased Product IDs:\n"
                        if productIds.isEmpty {
                            info += "  None"
                        } else {
                            info += "  " + productIds.joined(separator: "\n  ")
                        }

                        entitlementInfo = info
                        showEntitlementAlert = true
                    }
                }

                Button("open paddle portal") {
                    Task {
                        do {
                            let url = try await Helium.shared.createPaddlePortalSession()
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        } catch {
                            
                        }
                    }
                }
                
                Button("open stripe portal") {
                    Task {
                        let url = try await Helium.shared.createStripePortalSession(returnUrl: "")
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
            }
        }
        .alert("Entitlements", isPresented: $showEntitlementAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(entitlementInfo)
        }
    }
}

#Preview {
    ContentView()
}
