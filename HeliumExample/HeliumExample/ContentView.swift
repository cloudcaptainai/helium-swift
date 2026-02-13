//
//  ContentView.swift
//  HeliumExample
//
//  Created by Kyle Gorlick on 11/17/25.
//

import SwiftUI
import Helium

struct ContentView: View {
    
    @State var showEmbeddedPaywall: Bool = false
    @State var showModifierPaywall: Bool = false
    
    var body: some View {
        VStack(spacing: 30) {
            Button("show paywall") {
                Helium.shared.presentPaywall(trigger: AppConfig.triggerKey) { reason in
                    print("[Helium Example] show paywall - Could not show paywall. \(reason)")
                }
            }
            .accessibilityIdentifier("presentPaywall")
            
            Button("show via modifier") {
                showModifierPaywall = true
            }
            .accessibilityIdentifier("showPaywallViaModifier")
            .heliumPaywall(isPresented: $showModifierPaywall, trigger: AppConfig.triggerKey) { reason in
                Text("no show! \(reason.description)")
            }
            
            Button("show via embedded") {
                showEmbeddedPaywall = true
            }
            .accessibilityIdentifier("showPaywallEmbedded")
            .fullScreenCover(isPresented: $showEmbeddedPaywall) {
                HeliumPaywall(trigger: AppConfig.triggerKey) { reason in
                    Text("no show embedded! \(reason.description)")
                }
            }

            Button("show fallback (invalid trigger)") {
                Helium.shared.presentPaywall(trigger: "nonexistent_trigger_that_does_not_exist") { reason in
                    print("[Helium Example] invalid trigger - Could not show paywall. \(reason)")
                }
            }
            .accessibilityIdentifier("presentFallbackInvalidTrigger")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
