//
//  HeliumOnAppOpenConfig.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 7/21/25.
//

import SwiftUI

public struct HeliumOnAppOpenConfig {
    let onAppOpenTriggerEnabled: Bool = true
    let onAppOpenTriggerIndicateLoading: Bool = false
    let onAppOpenLoadingBudgetInSeconds: TimeInterval = 0.5
    let onAppOpenCustomLoadingView: View? = nil
}
