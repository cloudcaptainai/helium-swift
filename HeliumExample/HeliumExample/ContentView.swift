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
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger").font(.caption).foregroundStyle(.secondary)
                TextField("Trigger key", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                
                Spacer().frame(height: 10)
                
                Toggle("dontShowIfAlreadyEntitled", isOn: $dontShowIfAlreadyEntitled)

                Spacer().frame(height: 10)

                Text("User ID").font(.caption).foregroundStyle(.secondary)
                Text(userId)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)

            Spacer()

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

            Button("show fallback (invalid trigger)") {
                Helium.shared.presentPaywall(trigger: "nonexistent_trigger_that_does_not_exist") { reason in
                    print("[Helium Example] invalid trigger - Could not show paywall. \(reason)")
                }
            }
            .accessibilityIdentifier("presentFallbackInvalidTrigger")
            
            Spacer().frame(height: 20)
            
            Button("set random user id") {
                let newId = UUID().uuidString
                Helium.identify.userId = newId
                userId = newId
            }

            Button("check entitlement") {
                Task {
                    let hasAny = await Helium.entitlements.hasAny()
                    let hasActiveSub = await Helium.entitlements.hasAnyActiveSubscription()
                    let productIds = await Helium.entitlements.purchasedProductIds()

                    var info = "Has Any Entitlement: \(hasAny)\n"
                    info += "Has Active Subscription: \(hasActiveSub)\n"

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
            
            Spacer()
        }
        .padding()
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
