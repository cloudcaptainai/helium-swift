//
//  HeliumFallbackViewWrapper.swift
//
//
//  Created by Anish Doshi on 11/11/24.
//

import Foundation
import SwiftUI

public struct HeliumFallbackViewWrapper<Content: View>: View {
    public static let fallbackTemplateName = "Fallback"
    public static let fallbackTriggerName = "UnknownTrigger"
    
    let content: Content
    let trigger: String?
    
    init(
        trigger: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.trigger = trigger
    }
    
    var body: some View {
        content
            .onAppear {
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpen(
                    triggerName: trigger ?? Self.fallbackTriggerName,
                    paywallTemplateName: Self.fallbackTemplateName
                ))
            }
            .onDisappear {
                HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallClose(
                    triggerName: trigger ?? Self.fallbackTriggerName,
                    paywallTemplateName: Self.fallbackTemplateName
                ))
            }
    }
}
