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
    
    public init(
        trigger: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.trigger = trigger
    }
    
    public var body: some View {
        content
            .onAppear {
                if !presentationState.firstOnAppearHandled {
                    presentationState.handleOnAppear()
                }
            }
            .onDisappear {
                presentationState.handleOnDisappear()
            }
            .onReceive(presentationState.$isOpen) { newIsOpen in
                if presentationState.viewType == .presented {
                    return
                }
                HeliumPaywallDelegateWrapper.shared.onFallbackOpenCloseEvent(trigger: trigger, isOpen: newIsOpen, viewType: presentationState.viewType.rawValue)
            }
    }
}
