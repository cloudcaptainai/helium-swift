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
    static func reset() {
        shared.fallbackBundleURL = nil
        shared.loadedConfig = nil
        shared.loadedConfigJSON = nil
        shared.triggerToFallbackView = [:]
        shared.defaultFallback = nil
    }
    
    private init() {
        self.triggerToFallbackView = [:]
    }
    
    // **MARK: - Properties**
    private var fallbackBundleURL: URL? = nil
    private var loadedConfig: HeliumFetchedConfig?
    private var loadedConfigJSON: JSON?
    
    private var triggerToFallbackView: [String: AnyView]
    private var defaultFallback: AnyView?
    
    // **MARK: - Public Methods**
    public func setFallbackBundleURL(_ fallbackBundleURL: URL) {
        self.fallbackBundleURL = fallbackBundleURL
        // Give immediate feedback if assets are not accessible & avoid trying to use later.
        // This is synchronous but very fast (typically < 1 ms).
        if !FileManager.default.fileExists(atPath: fallbackBundleURL.path) {
            print("[Helium] Fallback bundle URL not accessible.")
        } else {
            print("[Helium] Fallback bundle URL provided.")
        }
        Task {
            do {
                let data = try Data(contentsOf: fallbackBundleURL)
                let decodedConfig = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
                
                loadedConfig = decodedConfig
                if let json = try? JSON(data: data) {
                    loadedConfigJSON = json
                }
                
                if let bundles = loadedConfig?.bundles, !bundles.isEmpty {
                    HeliumAssetManager.shared.writeBundles(bundles: bundles)
                    print("[Helium] Successfully loaded paywalls from fallback bundle file.")
                } else {
                    print("[Helium] No bundles found in fallback bundle file.")
                }
                
                Task {
                    await HeliumFetchedConfigManager.shared.buildLocalizedPriceMap(config: loadedConfig)
                }
                
                if let config = loadedConfig {
                    HeliumAnalyticsManager.shared.setUpAnalytics(
                        writeKey: config.segmentBrowserWriteKey,
                        endpoint: config.segmentAnalyticsEndpoint
                    )
                }
            } catch {
                print("[Helium] Failed to load fallback bundle: \(error)")
            }
        }
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
    
    
    public func getFallbackForTrigger(trigger: String) -> AnyView? {
        if let fallbackView = triggerToFallbackView[trigger] {
            return fallbackView
        }
        // Safe handling of optional defaultFallback
        if let defaultFallback = defaultFallback {
            return defaultFallback
        }
        return nil
    }
    
    public func getFallbackInfo(trigger: String) -> HeliumPaywallInfo? {
        return loadedConfig?.triggerToPaywalls[trigger]
    }
    func getResolvedConfigJSONForTrigger(_ trigger: String) -> JSON? {
        return loadedConfigJSON?["triggerToPaywalls"][trigger]["resolvedConfig"]
    }
    
    public func getConfig() -> HeliumFetchedConfig? {
        return loadedConfig
    }
    
    public func getBackgroundConfigForTrigger(_ trigger: String) -> BackgroundConfig? {
        guard let resolvedConfig = getResolvedConfigJSONForTrigger(trigger) else {
            return nil
        }
        
        // Try the direct path first (for newer configs)
        let json = resolvedConfig["backgroundConfig"]
        if json.type != .null {
            return BackgroundConfig(json: json)
        }
        
        // Fall back to nested path under baseStack.componentProps (for current configs)
        let nestedJson = resolvedConfig["baseStack"]["componentProps"]["backgroundConfig"]
        if nestedJson.type != .null {
            return BackgroundConfig(json: nestedJson)
        }
        
        return nil
    }
    
}
