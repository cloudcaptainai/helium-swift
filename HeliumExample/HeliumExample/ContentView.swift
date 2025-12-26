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
                Helium.shared.presentUpsell(trigger: "sdk_testf") { reason in
                    print("aosyfdouydof \(reason)")
                }
            }
            
            Button("show via modifier") {
                showModifierPaywall = true
            }
            .triggerUpsell(isPresented: $showModifierPaywall, trigger: "sdk_test") { reason in
                Text("no show! \(reason)")
            }
            
            Button("show via embedded") {
                showEmbeddedPaywall = true
            }
            .fullScreenCover(isPresented: $showEmbeddedPaywall) {
                HeliumPaywallView(trigger: "sdk_test") { reason in
                    Text("no show embedded! \(reason)")
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
