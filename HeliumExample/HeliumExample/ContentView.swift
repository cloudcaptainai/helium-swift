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
                Helium.shared.presentUpsell(trigger: AppConfig.triggerKey)
            }
            .accessibilityIdentifier("presentPaywall")
            
            Button("show via modifier") {
                showModifierPaywall = true
            }
            .accessibilityIdentifier("showPaywallViaModifier")
            .triggerUpsell(isPresented: $showModifierPaywall, trigger: AppConfig.triggerKey)
            
            Button("deep link test") {
                Helium.shared.handleDeepLink(URL(string: "helium-test://helium-test?burl=https://bundles.t3.storage.dev/e5546567-858d-4275-97eb-1a3f73cdba43/d9e10954-bbf0-47c7-af0b-42178bdacefc/bundle_1761021697892.html")!)
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
