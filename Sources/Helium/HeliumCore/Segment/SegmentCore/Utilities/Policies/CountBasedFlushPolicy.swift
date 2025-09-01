//
//  CountBasedFlushPolicy.swift
//  
//
//  Created by Alan Charles on 3/21/23.
//

import Foundation

class CountBasedFlushPolicy: FlushPolicy {
    weak var analytics: Analytics?
    internal var desiredCount: Int?
    @Atomic internal var count: Int = 0
    
    init() { }
    
    init(count: Int) {
        desiredCount = count
    }
    
    func configure(analytics: Analytics) {
        self.analytics = analytics
        if let desiredCount = desiredCount {
            analytics.flushAt = desiredCount
        }
    }
    
    func shouldFlush() -> Bool {
        guard let a = analytics else {
            return false
        }
        if a.configuration.values.flushAt > 0 && count >= a.configuration.values.flushAt {
            return true
        } else {
            return false
        }
    }
    
   func updateState(event: RawEvent) {
       _count.withValue { value in
           value += 1
       }
    }
    
    func reset() {
        count = 0
    }
}
