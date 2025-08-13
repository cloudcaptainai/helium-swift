//
//  File.swift
//  
//
//  Created by Anish Doshi on 2/28/25.
//
import SwiftUI
import Foundation
import SwiftyJSON

public class HeliumFallbackViewManager {
    // **MARK: - Singleton**
    public static let shared = HeliumFallbackViewManager()
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
                
                loadedConfig = massageFallbackConfig(decodedConfig)
                if let json = try? JSON(data: data) {
                    loadedConfigJSON = json
                }
                
                if let bundles = loadedConfig?.bundles, !bundles.isEmpty {
                    try HeliumAssetManager.shared.writeBundles(bundles: bundles)
                    print("[Helium] Successfully loaded paywalls from fallback bundle file.")
                } else {
                    print("[Helium] No bundles found in fallback bundle file.")
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
    
    public func getFallbackForTrigger(trigger: String) -> AnyView {
        if let fallbackView = triggerToFallbackView[trigger] {
            return fallbackView
        }
        return defaultFallback!
    }
    
    public func getFallbackInfo(trigger: String) -> HeliumPaywallInfo? {
        return loadedConfig?.triggerToPaywalls[trigger]
    }
    public func getResolvedConfigJSONForTrigger(_ trigger: String) -> JSON? {
        return massageResolvedConfigJSON(loadedConfigJSON?["triggerToPaywalls"][trigger]["resolvedConfig"])
    }
    
    private func massageFallbackConfig(_ config: HeliumFetchedConfig) -> HeliumFetchedConfig {
        var newConfig = config
        newConfig.bundles = [:]
        for (bundleId, content) in (config.bundles ?? [:]) {
            let fallbackBundleId = bundleId.starts(with: "flbk_") ? bundleId : "flbk_\(bundleId)"
            newConfig.bundles![fallbackBundleId] = content
        }
        return newConfig
    }
    private func massageResolvedConfigJSON(_ json: JSON?) -> JSON? {
        guard let json else { return nil }
        guard let providedURL = json["baseStack"]["componentProps"]["bundleURL"].string else {
            return json
        }
        var newJSON = json
        if let newBundleURL = JSON(rawValue: providedURL.replacingOccurrences(of: "/bundle_", with: "/bundle_flbk_")) {
            newJSON["baseStack"]["componentProps"]["bundleURL"] = newBundleURL
        }
        return newJSON
    }
    
}
