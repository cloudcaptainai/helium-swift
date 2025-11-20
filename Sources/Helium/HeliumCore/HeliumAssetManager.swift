import Foundation
import Combine

public enum HeliumAssetDownloadStatus: String, Codable {
    case notStartedYet
    case inProgress
    case downloaded
    case failed
}

public class HeliumAssetManager: ObservableObject {
    public static let shared = HeliumAssetManager()
    private init() {}
    
    private static let bundleCacheKey = "helium_bundles_cache"
    
    static var bundleDir: URL {
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.bundleCacheKey, isDirectory: true)
    }
    
    public func clearCache() {
        let bundleDir = HeliumAssetManager.bundleDir
        
        try? FileManager.default.removeItem(at: bundleDir)
    }
    
    func getBundleIdFromURL(_ url: String) -> String? {
        guard let filename = url.split(separator: "/").last?.split(separator: ".").first else {
            return nil
        }
        return filename.hasPrefix("bundle_") ? String(filename.dropFirst(7)) : String(filename)
    }
    
    public func localPathForURL(bundleURL: String) -> String? {
        guard let bundleId = getBundleIdFromURL(bundleURL) else {
            print("couldnt get from url \(bundleURL)");
            return nil
        }
        
        let bundleDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.bundleCacheKey, isDirectory: true)
        
        let value = bundleDir.appendingPathComponent("\(bundleId).html").path
//        print("Reading from \(value)");
        return value;
    }
    
    public func getExistingBundleIDs() -> [String] {
        let bundleDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.bundleCacheKey, isDirectory: true)
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bundleDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        
        return files
            .filter { $0.pathExtension == "html" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
    
    public func writeBundles(bundles: [String: String]) -> Int {
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
                print("[Helium] Writing to \(localURL)")
                do {
                    try data.write(to: localURL)
                } catch {
                    print("[Helium] Failed to write paywall bundle with id \(bundleId)")
                }
            } else {
                print("[Helium] Failed to write paywall bundle with id \(bundleId)")
            }
            
            Task {
                await WebViewManager.shared.preLoad(filePath: localURL.path)
            }
        }
        
        return totalBytesOfUncachedBundles
    }
}
