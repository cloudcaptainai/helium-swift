//
//  HeliumRuntimeEnvironment.swift
//  Helium
//

import Foundation

enum HeliumRuntimeEnvironment {
    static var isSimulator: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }
}
