//
//  ContentView.swift
//  HeliumExample
//
//  Created by Kyle Gorlick on 11/17/25.
//

import SwiftUI
import StoreKit
import Helium

struct ContentView: View {
    
    @State private var showEmbeddedPaywall: Bool = false
    @State private var showModifierPaywall: Bool = false
    @State private var dontShowIfAlreadyEntitled: Bool = false
    @State private var showEntitlementAlert: Bool = false
    @State private var entitlementInfo: String = ""
    @State private var showStorefrontAlert: Bool = false
    @State private var storefrontInfo: String = ""
    @State private var trigger: String = AppConfig.triggerKey
    @State private var selectedCheckoutStyle: StripeCheckoutStyle = .externalBrowser

    var body: some View {
        VStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger").font(.caption).foregroundStyle(.secondary)
                TextField("Trigger key", text: $trigger)
                    .textFieldStyle(.roundedBorder)

                Spacer().frame(height: 10)

                Toggle("dontShowIfAlreadyEntitled", isOn: $dontShowIfAlreadyEntitled)

                Spacer().frame(height: 10)

                Picker("Stripe Checkout Style", selection: $selectedCheckoutStyle) {
                    Text("External Browser").tag(StripeCheckoutStyle.externalBrowser)
                    Text("Safari In-App").tag(StripeCheckoutStyle.safariInApp)
                    Text("WebView").tag(StripeCheckoutStyle.webView)
                }
                .onChange(of: selectedCheckoutStyle) { _, newValue in
                    Helium.config.stripeCheckoutStyle = newValue
                }
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
            
            Button("change user id") {
                Helium.identify.userId = UUID().uuidString
            }
            
            Button("open stripe portal") {
                Task {
                    let url = try await Helium.shared.createStripePortalSession(returnUrl: "")
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
            
//            Button("check storefront") {
//                Task {
//                    var info = ""
//                    if let storefront = await Storefront.current {
//                        info += "id: \(storefront.id)\n"
//                        info += "countryCode: \(storefront.countryCode)\n"
//                        if #available(iOS 17.0, *) {
//                            info += "currency: \(storefront.currency?.identifier ?? "nil")\n"
//                        }
//                    } else {
//                        info = "Storefront.current is nil"
//                    }
//                    info += "\nLocale.current.region: \(Locale.current.region?.identifier ?? "nil")"
//                    storefrontInfo = info
//                    showStorefrontAlert = true
//                }
//            }

            Button("check entitlement") {
                Task {
                    let hasAny = await Helium.entitlements.hasAny()
                    let hasActiveSub = await Helium.entitlements.hasAnyActiveSubscription()
                    let productIds = await Helium.entitlements.purchasedProductIds()
                    
                    let hasStripe = await Helium.entitlements.hasActiveStripeEntitlement()
                    
                    var info = "Has Any Entitlement: \(hasAny)\n"
                    info += "Has Active Subscription: \(hasActiveSub)\n"
                    
                    info += "\nPurchased Product IDs:\n"
                    if productIds.isEmpty {
                        info += "  None"
                    } else {
                        info += "  " + productIds.joined(separator: "\n  ")
                    }
                    
                    info += "\n\nStripe entitled? \(hasStripe)"

                    entitlementInfo = info
                    showEntitlementAlert = true
                }
            }
            
            Button("clear stripe entitlements") {
                Helium.shared.resetStripeEntitlements(clearUserId: true)
            }
            
            Spacer()
        }
        .padding()
        .alert("Entitlements", isPresented: $showEntitlementAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(entitlementInfo)
        }
        .alert("Storefront", isPresented: $showStorefrontAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storefrontInfo)
        }
    }
}

#Preview {
    ContentView()
}
