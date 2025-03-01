//
//  File.swift
//  
//
//  Created by Anish Doshi on 2/28/25.
//
import SwiftUI
import Foundation

public class HeliumFallbackViewManager {
    // **MARK: - Singleton**
    public static let shared = HeliumFallbackViewManager()
    private init() {
        self.triggerToFallbackView = [:]
    }
    
    // **MARK: - Properties**
    private var triggerToFallbackView: [String: AnyView]
    private var defaultFallback: AnyView?
    
    // **MARK: - Public Methods**
    public func setTriggerToFallback(toSet: [String: AnyView]) {
        self.triggerToFallbackView = toSet
    }
    
    public func getTriggerToFallback() -> [String: AnyView] {
        return triggerToFallbackView
    }
    
    public func setDefaultFallback(fallbackView: AnyView) {
        self.defaultFallback = fallbackView
    }
    
    public func getDefaultFallback() -> AnyView? {
        return defaultFallback
    }
    
    public func getFallbackForTrigger(trigger: String) -> AnyView? {
        if let fallbackView = triggerToFallbackView[trigger] {
            return fallbackView
        }
        return defaultFallback
    }
}
