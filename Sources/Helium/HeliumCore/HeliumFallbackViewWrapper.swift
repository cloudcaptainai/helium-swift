//
//  HeliumFallbackViewWrapper.swift
//
//
//  Created by Anish Doshi on 11/11/24.
//

import Foundation
import SwiftUI

public let HELIUM_FALLBACK_PAYWALL_NAME = "Fallback";
public let HELIUM_FALLBACK_TRIGGER_NAME = "UnknownTrigger";

public struct HeliumFallbackViewWrapper<Content: View>: View {
    
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    
    let content: Content
    let trigger: String?
    let fallbackReason: PaywallUnavailableReason
    let paywallSessionId: String
    
    public init(
        trigger: String? = nil,
        fallbackReason: PaywallUnavailableReason,
        paywallSessionId: String,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.trigger = trigger
        self.fallbackReason = fallbackReason
        self.paywallSessionId = paywallSessionId
    }
    
    public var body: some View {
        content
            .onAppear {
                if presentationState.viewType != .presented {
                    if !presentationState.isOpen {
                        presentationState.isOpen = true
                        HeliumPaywallDelegateWrapper.shared.onFallbackOpenCloseEvent(
                            trigger: trigger,
                            isOpen: true,
                            viewType: presentationState.viewType.rawValue,
                            fallbackReason: fallbackReason,
                            paywallSessionId: paywallSessionId
                        )
                    }
                }
            }
            .onDisappear {
                if presentationState.viewType != .presented {
                    if presentationState.isOpen {
                        presentationState.isOpen = false
                        HeliumPaywallDelegateWrapper.shared.onFallbackOpenCloseEvent(
                            trigger: trigger,
                            isOpen: false,
                            viewType: presentationState.viewType.rawValue,
                            fallbackReason: fallbackReason,
                            paywallSessionId: paywallSessionId
                        )
                    }
                }
            }
    }
}
