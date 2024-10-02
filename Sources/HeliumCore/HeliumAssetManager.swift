//
//  File.swift
//  
//
//  Created by Anish Doshi on 10/1/24.
//

import Foundation
import SwiftyJSON
import Kingfisher

// TODO - move this into a singleton class that stores state related to if assets are downloaded

public func downloadFonts(from jsonData: Data) async throws {
    // Parse JSON data
    let json = try! JSON(data: jsonData)
    
    // Collect fontURLs
    var fontURLs = Set<String>()
    collectFontURLs(from: json, into: &fontURLs)
    
    // Download fonts in parallel
    await withTaskGroup(of: Void.self) { group in
        for fontURL in fontURLs {
            group.addTask {
                if let url = URL(string: fontURL) {
                    let result = await downloadRemoteFont(fontURL: url);
                    print(result);
                }
            }
        }
    }
    print("Successfully downloaded \(fontURLs.count) fonts");
}

func collectFontURLs(from json: JSON, into fontURLs: inout Set<String>) {
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

func collectImageURLs(from json: JSON, into imageURLs: inout Set<String>) {
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

public func downloadImages(from jsonData: Data) {
    // Parse JSON data
    let json = try! JSON(data: jsonData)
    // Collect imageURLs
    var imageURLs = Set<String>()
    collectImageURLs(from: json, into: &imageURLs)
    
    let urlList = imageURLs.compactMap { URL(string: $0) }
    
    // Prefetch images
    let prefetcher = ImagePrefetcher(urls: urlList) {
        skippedResources, failedResources, completedResources in
        print("Successfully downloaded images: \(completedResources)")
        print("Failed downloaded images: \(failedResources)")
        print("Skipped: \(skippedResources)")
    }
    prefetcher.start()
}

