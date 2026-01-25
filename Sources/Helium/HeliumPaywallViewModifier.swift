//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/11/24.
//

import Foundation
import SwiftUI

struct DynamicPaywallModifier<LoadingView: View, FallbackView: View>: ViewModifier {
    @StateObject private var presentationState: HeliumPaywallPresentationState = HeliumPaywallPresentationState(viewType: .triggered)
    @Binding var isPresented: Bool
    let trigger: String
    let config: PaywallPresentationConfig
    let eventHandlers: PaywallEventHandlers?
    let loadingView: (() -> LoadingView)?
    let fallbackView: (PaywallNotShownReason) -> FallbackView
    
    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                createPaywallView()
                    .environment(\.paywallPresentationState, presentationState)
            }
    }
    
    @ViewBuilder
    private func createPaywallView() -> some View {
        if let loadingView {
            HeliumPaywall(
                trigger: trigger,
                config: config,
                eventHandlers: eventHandlers,
                loadingView: loadingView,
                whenPaywallNotShown: fallbackView
            )
        } else {
            HeliumPaywall(
                trigger: trigger,
                config: config,
                eventHandlers: eventHandlers,
                whenPaywallNotShown: fallbackView
            )
        }
    }
}

// Extension to make DynamicPaywallModifier easier to use
public extension View {
    /// Show a paywall with custom loading view
      func triggerUpsell<LoadingView: View, FallbackView: View>(
          isPresented: Binding<Bool>,
          trigger: String,
          config: PaywallPresentationConfig = PaywallPresentationConfig(),
          eventHandlers: PaywallEventHandlers? = nil,
          @ViewBuilder loadingView: @escaping () -> LoadingView,
          @ViewBuilder fallbackView: @escaping (PaywallNotShownReason) -> FallbackView
      ) -> some View {
          self.modifier(DynamicPaywallModifier(
               isPresented: isPresented,
               trigger: trigger,
               config: config,
               eventHandlers: eventHandlers,
               loadingView: loadingView,
               fallbackView: fallbackView
           ))
       }

       /// Show a paywall with default loading view
       func triggerUpsell<FallbackView: View>(
           isPresented: Binding<Bool>,
           trigger: String,
           config: PaywallPresentationConfig = PaywallPresentationConfig(),
           eventHandlers: PaywallEventHandlers? = nil,
           @ViewBuilder fallbackView: @escaping (PaywallNotShownReason) -> FallbackView
       ) -> some View {
           self.modifier(DynamicPaywallModifier(
               isPresented: isPresented,
               trigger: trigger,
               config: config,
               eventHandlers: eventHandlers,
               loadingView: nil as (() -> EmptyView)?,
               fallbackView: fallbackView
           ))
    }
}
