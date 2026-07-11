//
//  File.swift
//  
//
//  Created by Anish Doshi on 2/28/25.
//
import SwiftUI
import Foundation

/// Which entry of the fallback bundle a resolution picked: the requested trigger's own entry, or
/// the bundle's default entry that stands in for triggers without a usable one.
enum ResolvedFallbackEntry {
    case triggerOwnEntry
    case defaultEntry
}

/// What the loaded fallback bundle served for one requested trigger.
struct FallbackBundleStatus: Equatable {
    let resolvedTrigger: String
    let resolvedEntry: ResolvedFallbackEntry
    let paywallTemplateName: String?
    /// Number of triggers with their own bundle entry; the default entry is not one of them.
    let configuredTriggerCount: Int
}

/// One resolution of a trigger against the loaded fallback bundle, captured in a single read of
/// the bundle state so the paywall that renders and the diagnostics describing it cannot disagree.
struct ResolvedFallback {
    let paywallInfo: HeliumPaywallInfo?
    let resolvedConfigJSON: JSON?
    let status: FallbackBundleStatus
}

public class HeliumFallbackViewManager {
    // **MARK: - Singleton**
    public static let shared = HeliumFallbackViewManager()
    static func reset() {
        shared.setLoadedState(config: nil, json: nil)
    }

    // **MARK: - Properties**
    private let defaultFallbacksName = "helium-fallbacks"

    /// The bundle entry that stands in for any trigger without one of its own.
    static let defaultFallbackTrigger = "hlm_ios_default_flbk"

    /// Guards `loadedConfig`/`loadedConfigJSON`, which are written from `setUpFallbackBundle`'s
    /// background task while presentation code paths read them from other threads.
    private let stateLock = NSLock()
    private var loadedConfig: HeliumFetchedConfig?
    private var loadedConfigJSON: JSON?

    private var loadedState: (config: HeliumFetchedConfig?, json: JSON?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (loadedConfig, loadedConfigJSON)
    }

    private func setLoadedState(config: HeliumFetchedConfig?, json: JSON?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        loadedConfig = config
        loadedConfigJSON = json
    }

    /// Inject a fallback bundle for testing purposes only. Accessible via @testable import.
    func injectConfigForTesting(_ config: HeliumFetchedConfig?, json: JSON? = nil) {
        setLoadedState(config: config, json: json)
    }

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
        
        Task {
            do {
                let data = try Data(contentsOf: fallbackBundleURL)
                let decodedConfig = try JSONDecoder().decode(HeliumFetchedConfig.self, from: data)

                setLoadedState(config: decodedConfig, json: try? JSON(data: data))

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
    
    /// Picks the bundle entry serving `trigger`: the trigger's own entry when it is usable (has
    /// products and a resolved config), otherwise the bundle's default entry.
    private static func resolveEntry(for trigger: String, config: HeliumFetchedConfig, json: JSON?) -> (key: String, entry: ResolvedFallbackEntry) {
        let fallbackPaywallInfo = config.triggerToPaywalls[trigger]
        let resolvedConfigJson = json?["triggerToPaywalls"][trigger]["resolvedConfig"]
        let hasResolvedConfig = resolvedConfigJson?.exists() == true && resolvedConfigJson?.type != .null
        if fallbackPaywallInfo?.hasProducts == true && hasResolvedConfig {
            return (trigger, .triggerOwnEntry)
        }
        return (Self.defaultFallbackTrigger, .defaultEntry)
    }

    /// Resolves `trigger` against the loaded bundle, or nil when no bundle is loaded.
    func resolveFallback(for trigger: String) -> ResolvedFallback? {
        let state = loadedState
        guard let config = state.config else { return nil }

        let resolved = Self.resolveEntry(for: trigger, config: config, json: state.json)
        return ResolvedFallback(
            paywallInfo: config.triggerToPaywalls[resolved.key],
            resolvedConfigJSON: state.json?["triggerToPaywalls"][resolved.key]["resolvedConfig"],
            status: FallbackBundleStatus(
                resolvedTrigger: resolved.key,
                resolvedEntry: resolved.entry,
                paywallTemplateName: config.triggerToPaywalls[resolved.key]?.paywallTemplateName,
                configuredTriggerCount: config.triggerToPaywalls.keys.filter { $0 != Self.defaultFallbackTrigger }.count
            )
        )
    }

    func getFallbackInfo(trigger: String) -> HeliumPaywallInfo? {
        return resolveFallback(for: trigger)?.paywallInfo
    }

    func getResolvedConfigJSONForTrigger(_ trigger: String) -> JSON? {
        return resolveFallback(for: trigger)?.resolvedConfigJSON
    }

    public func getConfig() -> HeliumFetchedConfig? {
        return loadedState.config
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

