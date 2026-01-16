//
//  PerformanceTimer.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 9/5/25.
//

import Foundation
#if DEBUG
import QuartzCore
#endif

class PerformanceTimer {
    static let shared = PerformanceTimer()
    
    #if DEBUG
    private var startTime: CFTimeInterval?
    private var lastPrintTime: CFTimeInterval?
    #endif
    
    private init() {}
    
    func reset() {
        #if DEBUG
        startTime = nil
        lastPrintTime = nil
        #endif
    }
    
    func printElapsedTime(_ label: String = "") {
        #if DEBUG
        let currentTime = CACurrentMediaTime()
        
        if startTime == nil {
            startTime = currentTime
            lastPrintTime = currentTime
            let labelText = label.isEmpty ? "" : "[\(label)] "
            let dateFormatter = DateFormatter()
            dateFormatter.timeStyle = .medium
            dateFormatter.dateStyle = .none
            let readableTime = dateFormatter.string(from: Date())
            print("[PerformanceTimer] \(labelText)Timer started at \(readableTime)")
            return
        }
        
        let totalElapsedTime = (currentTime - startTime!) * 1000
        let timeSinceLastPrint = lastPrintTime != nil ? (currentTime - lastPrintTime!) * 1000 : totalElapsedTime
        
        let labelText = label.isEmpty ? "" : "[\(label)] "
        print("[PerformanceTimer] \(labelText)Elapsed time: \(String(format: "%.0f", totalElapsedTime)) ms (Δ \(String(format: "%.0f", timeSinceLastPrint)) ms)")
        
        lastPrintTime = currentTime
        #endif
    }
}

// Usage example:
// PerformanceTimer.shared.printElapsedTime("App Launch") // First call sets the start time
// PerformanceTimer.shared.printElapsedTime("Data Loaded") // Shows total elapsed time and time since last print
// PerformanceTimer.shared.printElapsedTime("View Rendered") // Shows total elapsed time and time since "Data Loaded"
// PerformanceTimer.shared.printElapsedTime() // Shows elapsed time without label
