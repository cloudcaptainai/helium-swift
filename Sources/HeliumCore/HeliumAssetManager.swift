import Foundation
import SwiftyJSON
import Kingfisher
import Combine

public enum HeliumAssetDownloadStatus: Codable {
    case notStartedYet
    case inProgress
    case downloaded
    case failed
}

// Status structure
public struct HeliumAssetStatus: Codable {
    public var downloadStatus: HeliumAssetDownloadStatus
    public var timeTakenMS: UInt64?
    public var errorMesssage: String?
}

public class HeliumAssetManager: ObservableObject {
    // Singleton instance
    public static let shared = HeliumAssetManager()
    private init() {}
    
    // Published properties for observing status
    @Published public var fontStatus = HeliumAssetStatus(downloadStatus: .notStartedYet)
    @Published public var imageStatus = HeliumAssetStatus(downloadStatus: .notStartedYet)
    
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
