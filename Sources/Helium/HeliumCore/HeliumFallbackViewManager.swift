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
        shared.loadedConfig = nil
        shared.loadedConfigJSON = nil
    }
    
    // **MARK: - Properties**
    private let defaultFallbacksName = "helium-fallbacks"
    private let defaultFallbackTrigger = "hlm_ios_default_flbk"
    static let invalidDateString = "unknown"
    
    private var loadedConfig: HeliumFetchedConfig?
    private var loadedConfigJSON: JSON?
    
    // **MARK: - Public Methods**
    public func setUpFallbackBundle() {
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

                loadedConfig = decodedConfig
                if let json = try? JSON(data: data) {
                    loadedConfigJSON = json
                }

                if let bundles = loadedConfig?.bundles, !bundles.isEmpty {
                    HeliumAssetManager.shared.writeBundles(bundles: bundles)
                    let generatedAtDisplay = formatDateForDisplay(decodedConfig.generatedAt)
                    HeliumLogger.log(.info, category: .fallback, "👷 Successfully loaded paywalls from fallbacks file! 🎉", metadata: ["name": fallbackBundleURL.lastPathComponent, "generated at": generatedAtDisplay])
                    
                    if let date = parseISODate(decodedConfig.generatedAt),
                       let daysAgo = Calendar.current.dateComponents([.day], from: date, to: Date()).day,
                       daysAgo > 30 {
                        HeliumLogger.log(.warn, category: .fallback, "👷 Your fallbacks were generated \(daysAgo) days ago! ⚠️ Consider updating them\nhttps://docs.tryhelium.com/guides/fallback-bundle")
                    } else if generatedAtDisplay == HeliumFallbackViewManager.invalidDateString {
                        HeliumLogger.log(.warn, category: .fallback, "👷 Your fallbacks are outdated! ⚠️ Consider updating them\nhttps://docs.tryhelium.com/guides/fallback-bundle")
                    }
                } else {
                    HeliumLogger.log(.error, category: .fallback, "👷 No bundles found in fallbacks file ‼️⚠️‼️")
                }
                
                if let config = loadedConfig {
                    HeliumAnalyticsManager.shared.setUpAnalytics(
                        writeKey: config.segmentBrowserWriteKey,
                        endpoint: config.segmentAnalyticsEndpoint
                    )
                }
                
                await HeliumFetchedConfigManager.shared.buildLocalizedPriceMap(config: loadedConfig)
            } catch {
                HeliumLogger.log(.error, category: .fallback, "👷 Failed to load fallbacks file ‼️⚠️‼️", metadata: ["error": error.localizedDescription])
            }
        }
    }
    
    /// Returns the trigger to use - uses default if trigger doesn't exist or has invalid resolvedConfig
    private func resolvedTrigger(for trigger: String) -> String {
        // Check if trigger exists in config AND has valid resolvedConfig JSON
        if loadedConfig?.triggerToPaywalls[trigger] != nil,
           let json = loadedConfigJSON?["triggerToPaywalls"][trigger]["resolvedConfig"],
           json.exists() {
            return trigger
        }
        return defaultFallbackTrigger
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

// MARK: - Date Helpers

private func parseISODate(_ dateString: String?) -> Date? {
    guard let dateString = dateString else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    // Try without fractional seconds first, then with
    if let date = formatter.date(from: dateString) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: dateString)
}

private func formatDateForDisplay(_ dateString: String?) -> String {
    guard let date = parseISODate(dateString) else { return HeliumFallbackViewManager.invalidDateString }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
