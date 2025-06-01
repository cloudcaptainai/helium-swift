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
            .onReceive(presentationState.$isOpen) { newIsOpen in
                if newIsOpen {
                    HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(
                        triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                        paywallTemplateName: HELIUM_FALLBACK_PAYWALL_NAME
                    ))
                } else {
                    HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallClose(
                        triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                        paywallTemplateName: HELIUM_FALLBACK_PAYWALL_NAME
                    ))
                }
            }
    }
}
