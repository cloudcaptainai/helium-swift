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
    let onEntitled: ((PaywallEntitledEvent) -> Void)?
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
                onEntitled: onEntitled,
                loadingView: loadingView,
                whenPaywallNotShown: fallbackView
            )
        } else {
            HeliumPaywall(
                trigger: trigger,
                config: config,
                eventHandlers: eventHandlers,
                onEntitled: onEntitled,
                whenPaywallNotShown: fallbackView
            )
        }
    }
}

// Extension to make DynamicPaywallModifier easier to use
public extension View {
    /// Show a paywall with custom loading view
      func heliumPaywall<LoadingView: View, PaywallNotShownView: View>(
          isPresented: Binding<Bool>,
          trigger: String,
          config: PaywallPresentationConfig = PaywallPresentationConfig(),
          eventHandlers: PaywallEventHandlers? = nil,
          onEntitled: ((PaywallEntitledEvent) -> Void)? = nil,
          @ViewBuilder loadingView: @escaping () -> LoadingView,
          @ViewBuilder fallbackView: @escaping (PaywallNotShownReason) -> PaywallNotShownView
      ) -> some View {
          self.modifier(DynamicPaywallModifier(
               isPresented: isPresented,
               trigger: trigger,
               config: config,
               eventHandlers: eventHandlers,
               onEntitled: onEntitled,
               loadingView: loadingView,
               fallbackView: fallbackView
           ))
       }

       /// Show a paywall with default loading view
       func heliumPaywall<PaywallNotShownView: View>(
           isPresented: Binding<Bool>,
           trigger: String,
           config: PaywallPresentationConfig = PaywallPresentationConfig(),
           eventHandlers: PaywallEventHandlers? = nil,
           onEntitled: ((PaywallEntitledEvent) -> Void)? = nil,
           @ViewBuilder fallbackView: @escaping (PaywallNotShownReason) -> PaywallNotShownView
       ) -> some View {
           self.modifier(DynamicPaywallModifier(
               isPresented: isPresented,
               trigger: trigger,
               config: config,
               eventHandlers: eventHandlers,
               onEntitled: onEntitled,
               loadingView: nil as (() -> EmptyView)?,
               fallbackView: fallbackView
           ))
    }
}
