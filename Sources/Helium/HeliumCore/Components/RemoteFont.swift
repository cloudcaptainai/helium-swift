import Foundation
import SwiftUI

public final class FontDownloader: ObservableObject {
    private let fontCacheKey = "heliumCachedFonts"
    
    @MainActor
    func cacheFontData(_ data: Data, for url: String) {
        var cachedFonts = UserDefaults.standard.dictionary(forKey: fontCacheKey) as? [String: Data] ?? [:]
        cachedFonts[url] = data
        UserDefaults.standard.set(cachedFonts, forKey: fontCacheKey)
    }
    
    @MainActor
    func getCachedFontData(for url: String) -> Data? {
        let cachedFonts = UserDefaults.standard.dictionary(forKey: fontCacheKey) as? [String: Data]
        return cachedFonts?[url]
    }
    
    static func downloadRemoteFont(url: URL) async throws -> (CGFont?, Data?) {
        let startTime = DispatchTime.now()
        let (data, _) = try await URLSession.shared.data(from: url)
        let endTime = DispatchTime.now()
        print()
        
        guard let dataProvider = CGDataProvider(data: data as CFData) else {
            return (nil, nil)
        }
        
        guard let font = CGFont(dataProvider) else {
            return (nil, nil)
        }
        
        let registrationResult = CTFontManagerRegisterGraphicsFont(font, nil)
        return (font, data)
    }
}

public func downloadRemoteFont(fontURL: URL) async -> Bool {
    let downloader = FontDownloader()
    
    // Check if font is already cached - needs to be on main thread
    if let cachedData = await downloader.getCachedFontData(for: fontURL.absoluteString) {
        guard let dataProvider = CGDataProvider(data: cachedData as CFData),
              let font = CGFont(dataProvider) else {
            return false
        }
        
        let _ = CTFontManagerRegisterGraphicsFont(font, nil)
        return true
    }
    
    // Download happens on background thread
    do {
        let (font, fontData) = try await FontDownloader.downloadRemoteFont(url: fontURL)
        
        guard let font = font,
              let postScriptName = font.postScriptName,
              let fontData = fontData else {
            return false
        }
        
        // Switch to main thread just for the caching
        await downloader.cacheFontData(fontData, for: fontURL.absoluteString)
        return true
    } catch {
        return false
    }
}
