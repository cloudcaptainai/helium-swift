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
                Helium.shared.presentUpsell(trigger: "insert_trigger_here")
            }
            
            Button("show via modifier") {
                showModifierPaywall = true
            }
            .triggerUpsell(isPresented: $showModifierPaywall, trigger: "insert_trigger_here")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
