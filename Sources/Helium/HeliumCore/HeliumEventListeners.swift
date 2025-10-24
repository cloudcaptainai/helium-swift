//
//  HeliumEventListeners.swift
//  helium-swift
//
//  Created by Kyle Gorlick on 10/23/25.
//

public protocol HeliumEventListener : AnyObject {
    func onHeliumEvent(event: HeliumEvent)
}

class HeliumEventListeners {
    static let shared = HeliumEventListeners()
    
    private var listeners: [HeliumEventListener] = []
    
    public func addListener(_ listener: HeliumEventListener) {
        listeners.append(listener)
    }
    
    public func removeListener(_ listener: HeliumEventListener) {
        listeners.removeAll { $0 === listener }
    }
    
    public func onHeliumEvent(event: HeliumEvent) {
        listeners.forEach {
            $0.onHeliumEvent(event: event)
        }
    }
}
