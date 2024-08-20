//
//  HeliumPublic.swift
//  Helium
//
//  Created by Anish Doshi on 7/30/24.
//

import Foundation
import SwiftUI
import HeliumCore

public class Helium {
    var controller: HeliumController?
    private var baseTemplateViewType: (any BaseTemplateView.Type)?
    
    public static let shared = Helium()
    
    public func configure(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        baseTemplateView: any BaseTemplateView.Type
    ) {
        self.controller = HeliumController(
            apiKey: apiKey
        )
        HeliumPaywallDelegateWrapper.shared.setDelegate(heliumPaywallDelegate)
        self.baseTemplateViewType = baseTemplateView
    }
    
    public func initializeAndFetchVariants(
        apiKey: String,
        heliumPaywallDelegate: HeliumPaywallDelegate,
        baseTemplateView: any BaseTemplateView.Type,
        useCache: Bool
    ) async {
        self.configure(apiKey: apiKey, heliumPaywallDelegate: heliumPaywallDelegate, baseTemplateView: baseTemplateView);
        await self.downloadVariants(useCache: useCache);
    }
    
    public func downloadVariants(
        useCache: Bool
    ) async {
        await self.controller!.downloadConfig(useCache: useCache)
    }
    
    public func downloadStatus() -> HeliumFetchedConfigStatus {
        return HeliumFetchedConfigManager.shared.downloadStatus
    }
    
    public func getBaseTemplateView(clientName: String?, paywallInfo: HeliumPaywallInfo?, trigger: String) -> AnyView {
        guard let viewType = baseTemplateViewType else {
            fatalError("Base template view not set up correctly. Please contact founders@tryhelium.com to get set up!")
        }
        return AnyView(viewType.init(clientName: clientName, paywallInfo: paywallInfo, trigger: trigger))
    }
}

@available(iOS 16.0, *)
struct DynamicPaywallModifier: ViewModifier {
    @Binding var isPresented: Bool
    let trigger: String
    @StateObject private var configManager = HeliumFetchedConfigManager.shared
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if configManager.downloadStatus == HeliumFetchedConfigStatus.downloadSuccess,
           let paywallInfo = configManager.getPaywallInfoForTrigger(trigger),
           let clientName = configManager.getClientName() {
            content
                .fullScreenCover(isPresented: $isPresented) {
                    Helium.shared.getBaseTemplateView(clientName: clientName, paywallInfo: paywallInfo, trigger: trigger)
                }
        } else if configManager.downloadStatus == HeliumFetchedConfigStatus.notDownloadedYet {
            content
        } else {
            content.fullScreenCover(isPresented: $isPresented) {
                Helium.shared.getBaseTemplateView(
                    clientName: nil,
                    paywallInfo: nil,
                    trigger: trigger
                )
            }
        }
    }
}

// Extension to make DynamicPaywallModifier easier to use
@available(iOS 16.0, *)
public extension View {
    func triggerUpsell(isPresented: Binding<Bool>, trigger: String) -> some View {
        self.modifier(DynamicPaywallModifier(isPresented: isPresented, trigger: trigger))
    }
}
