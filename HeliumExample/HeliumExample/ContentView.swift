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
            .triggerUpsell(isPresented: $showModifierPaywall, trigger: AppConfig.triggerKey)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
