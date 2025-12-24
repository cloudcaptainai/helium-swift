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
    #if (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    let searchPathDirectory = FileManager.SearchPathDirectory.documentDirectory
    #else
    let searchPathDirectory = FileManager.SearchPathDirectory.cachesDirectory
    #endif
    
    let urls = FileManager.default.urls(for: searchPathDirectory, in: .userDomainMask)
    let docURL = urls[0]
    let segmentURL = docURL.appendingPathComponent("segment/\(writeKey)/")
    // try to create it, will fail if already exists, nbd.
    // tvOS, watchOS regularly clear out data.
    try? FileManager.default.createDirectory(at: segmentURL, withIntermediateDirectories: true, attributes: nil)
    return segmentURL
}
