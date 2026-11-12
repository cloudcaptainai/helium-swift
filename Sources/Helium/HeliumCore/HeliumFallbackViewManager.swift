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
        shared._loaded.withValue { $0 = LoadedFallbacks(generation: $0.generation + 1) }
    }

    /// Inject fallback config for testing purposes only. Accessible via @testable import.
    func injectFallbackConfigForTesting(_ config: HeliumFetchedConfig, json: JSON? = nil) {
        _loaded.withValue {
            $0.config = config
            $0.json = json
        }
    }
    
    // **MARK: - Properties**
    private let defaultFallbacksName = "helium-fallbacks"
    static let defaultFallbackTrigger = "hlm_ios_default_flbk"
    
    private struct LoadedFallbacks {
        var config: HeliumFetchedConfig?
        var json: JSON?
        var generation = 0
    }

    @HeliumAtomic private var loaded = LoadedFallbacks()
    private var loadedConfig: HeliumFetchedConfig? { loaded.config }
    private var loadedConfigJSON: JSON? { loaded.json }
    
    func setUpFallbackBundle() {
        var fallbackBundleURL: URL? = Bundle.main.url(forResource: defaultFallbacksName, withExtension: "json")
        if let customURL = Helium.config.customFallbacksURL {
            // This is synchronous but very fast (typically < 1 ms).
            if !FileManager.default.fileExists(atPath: customURL.path) {
                HeliumLogger.log(.error, category: .fallback, "👷 Custom fallbacks URL not accessible ⚠️", metadata: ["name": customURL.lastPathComponent, "path": customURL.absoluteString])
            } else {
                fallbackBundleURL = customURL
                HeliumLogger.log(.info, category: .fallback, "👷 Custom fallbacks URL found", metadata: ["name": customURL.lastPathComponent])
            }
        }
        
        guard let fallbackBundleURL, FileManager.default.fileExists(atPath: fallbackBundleURL.path) else {
            HeliumLogger.log(.error, category: .fallback, "👷 Fallbacks file not accessible! ‼️⚠️‼️ See docs at https://docs.tryhelium.com/guides/fallback-bundle")
            return
        }
        
        let generation = loaded.generation
        Task {
            do {
                let data = try Data(contentsOf: fallbackBundleURL)
                let decodedConfig = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)
                let decodedJSON = try? JSON(data: data)

                let stored = _loaded.withValue { state -> Bool in
                    guard state.generation == generation else { return false }
                    state.config = decodedConfig
                    if let decodedJSON {
                        state.json = decodedJSON
                    }
                    return true
                }
                guard stored else { return }

                if let bundles = decodedConfig.bundles, !bundles.isEmpty {
                    HeliumAssetManager.shared.writeBundles(bundles: bundles)
                    let generatedAtDisplay = formatDateForDisplay(decodedConfig.generatedAt)
                    HeliumLogger.log(.info, category: .fallback, "👷 Successfully loaded paywalls from fallbacks file! 🎉", metadata: ["name": fallbackBundleURL.lastPathComponent, "generated at": generatedAtDisplay])
                    
                    if let date = parseISODate(decodedConfig.generatedAt),
                       let daysAgo = Calendar.current.dateComponents([.day], from: date, to: Date()).day,
                       daysAgo > 60 {
                        HeliumLogger.log(.warn, category: .fallback, "👷 Your fallbacks were generated \(daysAgo) days ago! ⚠️ Consider updating them\nhttps://docs.tryhelium.com/guides/fallback-bundle")
                    } else if generatedAtDisplay == invalidDateString {
                        HeliumLogger.log(.warn, category: .fallback, "👷 Your fallbacks are outdated! ⚠️ Consider updating them\nhttps://docs.tryhelium.com/guides/fallback-bundle")
                    }

                    if ObservabilitySampling.includesThisDevice(rate: ObservabilitySampling.fallbackBundleRate),
                       FallbackBundleFingerprint.markConfigured(decodedConfig) {
                        HeliumObservabilityManager.shared.track(
                            FallbackPaywallsConfigured(
                                generatedAt: decodedConfig.generatedAt,
                                organizationID: decodedConfig.organizationID,
                                triggerToPaywallUUID: decodedConfig.triggerToPaywalls.mapValues { $0.paywallUUID }
                            ),
                            scope: nil
                        )
                    }
                } else {
                    HeliumLogger.log(.error, category: .fallback, "👷 No bundles found in fallbacks file ‼️⚠️‼️")
                }
                
                let triggersMissingProducts = decodedConfig.getTriggersWithMissingProducts()
                if !triggersMissingProducts.isEmpty {
                    HeliumLogger.log(.error, category: .fallback, "👷 Some triggers in your fallbacks file have missing iOS products ‼️⚠️‼️", metadata: ["triggers": triggersMissingProducts.joined(separator: ", ")])
                }
                
                HeliumAnalyticsManager.shared.setUpAnalytics(
                    writeKey: decodedConfig.segmentBrowserWriteKey,
                    endpoint: decodedConfig.segmentAnalyticsEndpoint
                )
                
                await HeliumFetchedConfigManager.shared.buildLocalizedPriceMap(config: decodedConfig)
            } catch {
                HeliumLogger.log(.error, category: .fallback, "👷 Failed to load fallbacks file ‼️⚠️‼️", metadata: ["error": error.localizedDescription])
            }
        }
    }
    
    /// Returns the trigger to use - uses default if trigger doesn't exist or has invalid resolvedConfig
    private func resolvedTrigger(for trigger: String) -> String {
        let fallbackPaywallInfo = loadedConfig?.triggerToPaywalls[trigger]
        let resolvedConfigJson = loadedConfigJSON?["triggerToPaywalls"][trigger]["resolvedConfig"]
        let hasResolvedConfig = resolvedConfigJson?.exists() == true && resolvedConfigJson?.type != .null
        if fallbackPaywallInfo?.hasProducts == true && hasResolvedConfig {
            return trigger
        }
        return Self.defaultFallbackTrigger
    }
    
    func getFallbackInfo(trigger: String) -> HeliumPaywallInfo? {
        return loadedConfig?.triggerToPaywalls[resolvedTrigger(for: trigger)]
    }
    
    func getResolvedConfigJSONForTrigger(_ trigger: String) -> JSON? {
        return loadedConfigJSON?["triggerToPaywalls"][resolvedTrigger(for: trigger)]["resolvedConfig"]
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

