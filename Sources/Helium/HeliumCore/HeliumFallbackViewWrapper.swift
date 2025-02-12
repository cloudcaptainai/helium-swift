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
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(
                    triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                    paywallTemplateName: HELIUM_FALLBACK_PAYWALL_NAME
                ))
            }
            .onDisappear {
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallClose(
                    triggerName: trigger ?? HELIUM_FALLBACK_TRIGGER_NAME,
                    paywallTemplateName: HELIUM_FALLBACK_PAYWALL_NAME
                ))
            }
    }
}
