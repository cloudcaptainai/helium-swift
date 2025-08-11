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
    private var fallbackBundleConfig: FallbackBundleConfig? = nil
    private var triggerToFallbackView: [String: AnyView]
    private var defaultFallback: AnyView?
    
    // **MARK: - Public Methods**
    public func setFallbackBundleConfig(_ config: FallbackBundleConfig) {
        fallbackBundleConfig = config
        // Give immediate feedback if assets are not accessible & avoid trying to use later.
        // This is synchronous but very fast (typically < 1 ms).
        var fallbackAssetCount: Int = 0
        var foundCount: Int = 0
        if let defaultURL = config.defaultURL {
            fallbackAssetCount += 1
            if !FileManager.default.fileExists(atPath: defaultURL.path) {
                print("[Helium] Fallback asset not found: \(defaultURL.path)")
                fallbackBundleConfig?.defaultURL = nil
            } else {
                foundCount += 1
            }
        }
        let triggersToURLs = config.triggersToURLs
        for (trigger, asset) in triggersToURLs {
            fallbackAssetCount += 1
            if !FileManager.default.fileExists(atPath: asset.path) {
                print("[Helium] Fallback asset not found for trigger \(trigger): \(asset.path)")
                fallbackBundleConfig?.triggersToURLs[trigger] = nil
            } else {
                foundCount += 1
            }
        }
        print("[Helium] \(foundCount)/\(fallbackAssetCount) fallback assets found")
    }
    
    public func setTriggerToFallback(toSet: [String: AnyView]) {
        self.triggerToFallbackView = toSet
    }
    
    public func setDefaultFallback(fallbackView: AnyView) {
        self.defaultFallback = fallbackView
    }
    
    public func getDefaultFallback() -> AnyView? {
        return defaultFallback
    }
    
    public func getFallbackForTrigger(trigger: String) -> AnyView {
        if let fallbackView = triggerToFallbackView[trigger] {
            return fallbackView
        }
        return defaultFallback!
    }
    
    public func getFallbackAsset(trigger: String) -> URL? {
        if let asset = fallbackBundleConfig?.triggersToURLs[trigger] {
            return asset
        }
        return fallbackBundleConfig?.defaultURL
    }
}
