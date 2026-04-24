//
//  Utils.swift
//  Segment
//
//  Created by Brandon Sneed on 5/18/21.
//

import Foundation

#if os(Linux)
extension DispatchQueue {
    func asyncAndWait(execute workItem: DispatchWorkItem) {
        async {
            workItem.perform()
        }
        workItem.wait()
    }
}

// Linux doesn't have autoreleasepool.
func autoreleasepool(closure: () -> Void) {
    closure()
}
#endif


internal var isAppExtension: Bool = {
    if Bundle.main.bundlePath.hasSuffix(".appex") {
        return true
    }
    return false
}()

internal func exceptionFailure(_ message: String) {
    #if DEBUG
    assertionFailure(message)
    #endif
}

internal protocol Flattenable {
    func flattened() -> Any?
}

extension Optional: Flattenable {
    internal func flattened() -> Any? {
        switch self {
        case .some(let x as Flattenable): return x.flattened()
        case .some(let x): return x
        case .none: return nil
        }
    }
}

internal func eventStorageDirectory(writeKey: String) -> URL {
    // Application Support is always resolvable on real Apple devices; the guard is belt-and-suspenders
    // so this SDK can never trap inside a host app. Temp dir is a session-only safety net.
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let storageURL = baseURL.appendingPathComponent("Helium/analytics/\(writeKey)/")

    // Handle one-time migration from old locations
    migrateFromOldLocations(writeKey: writeKey, to: storageURL)

    // try to create it, will fail if already exists, nbd.
    // tvOS, watchOS regularly clear out data.
    try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: nil)
    return storageURL
}

private func migrateFromOldLocations(writeKey: String, to newLocation: URL) {
    let fm = FileManager.default

    guard !fm.fileExists(atPath: newLocation.path) else { return }

    guard let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let appSupportSegmentDir = appSupportURL.appendingPathComponent("segment/\(writeKey)/")

    #if (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    let legacySearchPath = FileManager.SearchPathDirectory.documentDirectory
    #else
    let legacySearchPath = FileManager.SearchPathDirectory.cachesDirectory
    #endif
    let legacySegmentDir = fm.urls(for: legacySearchPath, in: .userDomainMask)
        .first?
        .appendingPathComponent("segment/\(writeKey)/")

    let source: URL? = {
        if fm.fileExists(atPath: appSupportSegmentDir.path) { return appSupportSegmentDir }
        if let legacy = legacySegmentDir, fm.fileExists(atPath: legacy.path) { return legacy }
        return nil
    }()

    guard let sourceURL = source else { return }

    // moveItem requires the destination's parent to already exist.
    try? fm.createDirectory(at: newLocation.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

    do {
        try fm.moveItem(at: sourceURL, to: newLocation)
        Analytics.segmentLog(message: "Migrated analytics data from \(sourceURL.path) to \(newLocation.path)", kind: .debug)
    } catch {
        Analytics.segmentLog(message: "Failed to migrate analytics data from \(sourceURL.path): \(error)", kind: .error)
    }
}
