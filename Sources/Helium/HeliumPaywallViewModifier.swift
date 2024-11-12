//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/11/24.
//

import Foundation
import SwiftUI

struct DynamicPaywallModifier: ViewModifier {
    @Binding var isPresented: Bool
    let trigger: String
    @StateObject private var configManager = HeliumFetchedConfigManager.shared
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if case .downloadSuccess = configManager.downloadStatus {
            content
                .fullScreenCover(isPresented: $isPresented) {
                    Helium.shared.upsellViewForTrigger(trigger: trigger)
                }
        } else if case .notDownloadedYet = configManager.downloadStatus {
            content
        } else {
            content.fullScreenCover(isPresented: $isPresented) {
                Helium.shared.upsellViewForTrigger(trigger: trigger)
            }
        }
    }
}

// Extension to make DynamicPaywallModifier easier to use
public extension View {
    func triggerUpsell(isPresented: Binding<Bool>, trigger: String) -> some View {
        self.modifier(DynamicPaywallModifier(isPresented: isPresented, trigger: trigger))
    }
}
