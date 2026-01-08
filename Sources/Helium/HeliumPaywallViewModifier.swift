//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/11/24.
//

import Foundation
import SwiftUI

struct DynamicPaywallModifier: ViewModifier {
    @StateObject private var presentationState: HeliumPaywallPresentationState = HeliumPaywallPresentationState(viewType: .triggered)
    @Binding var isPresented: Bool
    let trigger: String
    let eventHandlers: PaywallEventHandlers?
    let customPaywallTraits: [String: Any]?
    
    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding(
                get: { isPresented && Helium.shared.canShowPaywallFor(trigger: trigger).canShow },
                set: { isPresented = $0 }
            )) {
                Helium.shared.upsellViewForTrigger(trigger: trigger, eventHandlers: eventHandlers, customPaywallTraits: customPaywallTraits)
                    .environment(\.paywallPresentationState, presentationState)
            }
    }
}

// Extension to make DynamicPaywallModifier easier to use
public extension View {
    func triggerUpsell(isPresented: Binding<Bool>, trigger: String, eventHandlers: PaywallEventHandlers? = nil, customPaywallTraits: [String: Any]? = nil) -> some View {
        self.modifier(DynamicPaywallModifier(isPresented: isPresented, trigger: trigger, eventHandlers: eventHandlers, customPaywallTraits: customPaywallTraits))
    }
}
