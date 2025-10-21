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
    
    public init(
        trigger: String? = nil,
        fallbackReason: PaywallUnavailableReason,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.trigger = trigger
        self.fallbackReason = fallbackReason
    }
    
    public var body: some View {
        content
            .onAppear {
                presentationState.handleOnAppear()
            }
            .onDisappear {
                presentationState.handleOnDisappear()
            }
            .onReceive(presentationState.$isOpen) { newIsOpenValue in
                if presentationState.viewType == .presented {
                    return
                }
                if let newIsOpenValue {
                    HeliumPaywallDelegateWrapper.shared.onFallbackOpenCloseEvent(trigger: trigger, isOpen: newIsOpenValue, viewType: presentationState.viewType.rawValue, fallbackReason: fallbackReason)
                }
            }
    }
}
