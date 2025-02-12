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

public struct HeliumAssetStatus: Codable {
    public var downloadStatus: HeliumAssetDownloadStatus
    public var timeTakenMS: UInt64?
    public var errorMesssage: String?
    
    public static func initial() -> HeliumAssetStatus {
        return HeliumAssetStatus(downloadStatus: .notStartedYet)
    }
}

public class HeliumAssetManager: ObservableObject {
    public static let shared = HeliumAssetManager()
    private init() {}
    
    // Published properties for observing status
    @Published public var fontStatus = HeliumAssetStatus(downloadStatus: .notStartedYet)
    @Published public var imageStatus = HeliumAssetStatus(downloadStatus: .notStartedYet)
    @Published public var bundleStatus = HeliumAssetStatus.initial()
    
    // Bundle types
    public struct BundleConfig {
        let url: String
        let triggerName: String
    }
    
    public struct BundleCache: Codable {
        var bundles: [String: BundleInfo]
        
        struct BundleInfo: Codable {
            let localPath: String
            let originalUrl: String
        }
    }
    
    // Cache handling
    private static let bundleCacheKey = "helium_bundles_cache"
    
    private var bundleCache: BundleCache {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.bundleCacheKey),
                  let cache = try? JSONDecoder().decode(BundleCache.self, from: data) else {
                return BundleCache(bundles: [:])
            }
            return cache
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.bundleCacheKey)
        }
    }
    
    public func clearCache() {
        removeDownloadedBundles()
        UserDefaults.standard.removeObject(forKey: Self.bundleCacheKey);
    }
    
    // Bundle methods
    public func downloadBundles(configs: [BundleConfig]) async {
        let startTime = DispatchTime.now()
        
        await MainActor.run {
            bundleStatus = HeliumAssetStatus(downloadStatus: .inProgress)
        }
        
        var results: [(success: Bool, config: BundleConfig, localPath: String?)] = []
        
        await withTaskGroup(of: (Bool, BundleConfig, String?).self) { group in
            for config in configs {
                group.addTask {
                    do {
                        let localPath = try await self.downloadAndSaveBundle(
                            from: config.url,
                            into: config.triggerName
                        )
                        return (true, config, localPath)
                    } catch {
                        return (false, config, nil)
                    }
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        let endTime = DispatchTime.now()
        let timeTaken = UInt64(Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0)
        
        // Update cache with successful downloads
        var updatedCache = bundleCache
        for result in results where result.success {
            let info = BundleCache.BundleInfo(
                localPath: result.localPath!,
                originalUrl: result.config.url
            )
            updatedCache.bundles[result.config.url] = info
        }
        bundleCache = updatedCache
        let hasFailures = results.contains(where: { !$0.success })
        let failedConfig = results.first(where: { !$0.success })?.config;
        await MainActor.run {
            if hasFailures {
                bundleStatus = HeliumAssetStatus(
                    downloadStatus: .failed,
                    timeTakenMS: timeTaken,
                    errorMesssage: "At least one failure in downloading bundles: first failure \(failedConfig?.url) for trigger: \(failedConfig?.triggerName)"
                )
            } else {
                bundleStatus = HeliumAssetStatus(
                    downloadStatus: .downloaded,
                    timeTakenMS: timeTaken,
                    errorMesssage: nil
                )
            }
        }
    }
    
    public func localPathForURL(bundleURL: String) -> String? {
        return self.bundleCache.bundles[bundleURL]?.localPath;
    }
    
    func randomString(length: Int) -> String {
      let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      return String((0..<length).map{ _ in letters.randomElement()! })
    }

    
    private func downloadAndSaveBundle(from urlString: String, into triggerName: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url);
        
        let bundleDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("helium_bundles", isDirectory: true)
            .appendingPathComponent("\(triggerName)", isDirectory: true)
        
        try FileManager.default.createDirectory(
            at: bundleDir,
            withIntermediateDirectories: true
        )
        
        let fileName = url.lastPathComponent
        let localURL = bundleDir.appendingPathComponent(fileName)
        try data.write(to: localURL)
        
        return localURL.path
    }
    
    private func removeDownloadedBundles() {
        let bundleDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("helium_bundles", isDirectory: true)
        
        try? FileManager.default.removeItem(at: bundleDir)
    }
    
    // Existing font/image methods
    public func collectFontURLs(from json: JSON, into fontURLs: inout Set<String>) {
        switch json.type {
        case .dictionary:
            for (key, value) in json {
                if key == "fontURL", let url = value.string {
                    fontURLs.insert(url)
                } else {
                    collectFontURLs(from: value, into: &fontURLs)
                }
            }
        case .array:
            for item in json.arrayValue {
                collectFontURLs(from: item, into: &fontURLs)
            }
        default:
            break
        }
    }
    
    public func collectImageURLs(from json: JSON, into imageURLs: inout Set<String>) {
        switch json.type {
        case .dictionary:
            for (key, value) in json {
                if key == "imageURL", let url = value.string {
                    imageURLs.insert(url)
                } else {
                    collectImageURLs(from: value, into: &imageURLs)
                }
            }
        case .array:
            for item in json.arrayValue {
                collectImageURLs(from: item, into: &imageURLs)
            }
        default:
            break
        }
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
    
    public func downloadFonts(from fontURLs: Set<String>) async {
            let startTime = DispatchTime.now()
            
            await MainActor.run {
                fontStatus = HeliumAssetStatus(downloadStatus: .inProgress)
            }
            
            var results: [(success: Bool, url: String)] = []
            
            await withTaskGroup(of: (Bool, String).self) { group in
                for fontURL in fontURLs {
                    group.addTask {
                        if let url = URL(string: fontURL) {
                            let result = await downloadRemoteFont(fontURL: url)
                            return (result, fontURL)
                        }
                        return (false, fontURL)
                    }
                }
                
                for await result in group {
                    results.append(result)
                }
            }
            
            let endTime = DispatchTime.now()
            let timeTaken = UInt64(Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0);
            
            // Process results after all tasks are complete
            let firstFailedURL = results.first { !$0.success }?.url
            
            await MainActor.run {
                if let failedURL = firstFailedURL {
                    fontStatus = HeliumAssetStatus(
                        downloadStatus: .failed,
                        timeTakenMS: timeTaken,
                        errorMesssage: "Failed to download font: \(failedURL)"
                    )
                } else {
                    fontStatus = HeliumAssetStatus(
                        downloadStatus: .downloaded,
                        timeTakenMS: timeTaken,
                        errorMesssage: nil
                    )
                }
            }
        }
    
    public func downloadImages(from imageURLs: Set<String>) async {
        let startTime = DispatchTime.now()
        
        // Set status on main thread
        await MainActor.run {
            imageStatus = HeliumAssetStatus(downloadStatus: .inProgress)
        }
        
        let urlList = imageURLs.compactMap { URL(string: $0) }
        let totalExpectedImages = urlList.count
        
        // Create a continuation to wait for the prefetcher completion
        await withCheckedContinuation { [self] continuation in
            let prefetcher = ImagePrefetcher(urls: urlList) { [weak self] skippedResources, failedResources, completedResources in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                let endTime = DispatchTime.now()
                let timeTaken = UInt64(Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0);
                
                // Update status on main thread
                Task { @MainActor in
                    if !failedResources.isEmpty {
                        self.imageStatus = HeliumAssetStatus(
                            downloadStatus: .failed,
                            timeTakenMS: timeTaken,
                            errorMesssage: "Failed to download \(failedResources.count) images"
                        )
                        continuation.resume()
                    } else {
                        // Check if all images are accounted for
                        let totalProcessedImages = completedResources.count + skippedResources.count
                        if totalProcessedImages == totalExpectedImages {
                            self.imageStatus = HeliumAssetStatus(
                                downloadStatus: .downloaded,
                                timeTakenMS: timeTaken,
                                errorMesssage: nil
                            )
                            continuation.resume()
                        }
                        // Note: If totalProcessedImages != totalExpectedImages, we don't resume
                        // This ensures we wait for all images to complete or fail
                    }
                }
            }
            prefetcher.start()
        }
    }
}
