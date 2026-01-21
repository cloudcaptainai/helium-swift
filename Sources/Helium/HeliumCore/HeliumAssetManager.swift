import Foundation
import Combine

public enum HeliumAssetDownloadStatus: String, Codable {
    case notStartedYet
    case inProgress
    case downloaded
    case failed
}

class HeliumAssetManager {
    public static let shared = HeliumAssetManager()
    private init() {}
    
    private static let bundleCacheKey = "helium_bundles_cache"
    
    static var bundleDir: URL {
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.bundleCacheKey, isDirectory: true)
    }
    
    func clearCache() {
        let bundleDir = HeliumAssetManager.bundleDir
        
        try? FileManager.default.removeItem(at: bundleDir)
    }
    
    func getBundleIdFromURL(_ url: String) -> String? {
        guard let filename = url.split(separator: "/").last?.split(separator: ".").first else {
            return nil
        }
        return filename.hasPrefix("bundle_") ? String(filename.dropFirst(7)) : String(filename)
    }
    
    func localPathForURL(bundleURL: String) -> String? {
        guard let bundleId = getBundleIdFromURL(bundleURL) else {
            HeliumLog.log(.warn, category: .core, "Could not get bundle ID from URL", metadata: ["url": bundleURL])
            return nil
        }

        let value = Self.bundleDir.appendingPathComponent("\(bundleId).html").path
        HeliumLog.log(.trace, category: .core, "Reading from value", metadata: ["value": value])
        return value;
    }
    
    func getExistingBundleIDs() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.bundleDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        
        return files
            .filter { $0.pathExtension == "html" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
    
    @discardableResult
    func writeBundles(bundles: [String: String]) -> Int {
        let bundleDir = HeliumAssetManager.bundleDir
        
        try? FileManager.default.createDirectory(
            at: bundleDir,
            withIntermediateDirectories: true
        )
        
        let existingBundleIds = getExistingBundleIDs()
        var totalBytesOfUncachedBundles = 0
        
        for (bundleId, content) in bundles {
            let fileName = "\(bundleId).html"
            let localURL = bundleDir.appendingPathComponent(fileName)
            
            let bundleWasAlreadyCached = existingBundleIds.contains(bundleId)
            
            // Always write asset even if cached, so asset is fresh and theoretically less likely to be cleared from cache
            // (not exactly sure what method iOS uses to clear from cache directory, hence the *theoretically*)
            
            let unescapedContent = content
            
            if let data = unescapedContent.data(using: .utf8) {
                if !bundleWasAlreadyCached {
                    totalBytesOfUncachedBundles += data.count
                }
                HeliumLog.log(.trace, category: .core, "Writing bundle", metadata: ["bundleId": bundleId])
                do {
                    try data.write(to: localURL)
                } catch {
                    HeliumLog.log(.error, category: .core, "Failed to write paywall bundle", metadata: ["bundleId": bundleId, "error": error.localizedDescription])
                }
            } else {
                HeliumLog.log(.error, category: .core, "Failed to encode paywall bundle content", metadata: ["bundleId": bundleId])
            }
            
            Task {
                await WebViewManager.shared.preLoad(filePath: localURL.path)
            }
        }
        
        return totalBytesOfUncachedBundles
    }
}
