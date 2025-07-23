import Foundation
import SwiftyJSON
import Kingfisher
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
            .appendingPathComponent("helium_bundles_cache", isDirectory: true)
    }
    
    private var bundleIds: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.bundleCacheKey),
                  let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else {
                return []
            }
            return ids
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.bundleCacheKey)
        }
    }
    
    public func clearCache() {
        let bundleDir = HeliumAssetManager.bundleDir
        
        try? FileManager.default.removeItem(at: bundleDir)
        bundleIds = []
    }
    
    private func getBundleIdFromURL(_ url: String) -> String? {
        guard let filename = url.split(separator: "/").last?.split(separator: ".").first else {
            return nil
        }
        return filename.hasPrefix("bundle_") ? String(filename.dropFirst(7)) : String(filename)
    }
    
    public func localPathForURL(bundleURL: String) -> String? {
        print("Requesting local path")
        guard let bundleId = getBundleIdFromURL(bundleURL) else {
            print("couldnt get from url \(bundleURL)");
            return nil
        }
        
        let bundleDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("helium_bundles_cache", isDirectory: true)
        
        let value = bundleDir.appendingPathComponent("\(bundleId).html").path
        print("Reading from \(value)");
        return value;
    }
    
    public func collectBundleURLs(from json: JSON, into bundleURLs: inout Set<String>) {
        switch json.type {
        case .dictionary:
            for (key, value) in json {
                if key == "bundleURL", let url = value.string {
                    bundleURLs.insert(url)
                } else {
                    collectBundleURLs(from: value, into: &bundleURLs)
                }
            }
        case .array:
            for item in json.arrayValue {
                collectBundleURLs(from: item, into: &bundleURLs)
            }
        default:
            break
        }
    }
    
    public func getExistingBundleIDs() -> [String] {
        let bundleDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("helium_bundles_cache", isDirectory: true)
        
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
    
    public func writeBundles(bundles: [String: String]) throws {
        let bundleDir = HeliumAssetManager.bundleDir
        
        try FileManager.default.createDirectory(
            at: bundleDir,
            withIntermediateDirectories: true
        )
        
        var updatedIds = bundleIds
        
        for (bundleId, content) in bundles {
            let fileName = "\(bundleId).html"
            let localURL = bundleDir.appendingPathComponent(fileName)
            
            let unescapedContent = content
          
            if let data = unescapedContent.data(using: .utf8) {
                print("Writing to \(localURL)");
                try data.write(to: localURL)
                updatedIds.insert(bundleId)
            }
            
            WebViewManager.shared.preLoad(filePath: localURL.path)
        }
        
        bundleIds = updatedIds
    }
}
