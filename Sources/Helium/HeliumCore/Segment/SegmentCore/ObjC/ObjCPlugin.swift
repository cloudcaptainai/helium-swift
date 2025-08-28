//
//  ObjCPlugin.swift
//  
//
//  Created by Brandon Sneed on 4/17/23.
//


#if !os(Linux)

import Foundation

@objc(SEGPlugin)
protocol ObjCPlugin {}

protocol ObjCPluginShim {
    func instance() -> EventPlugin
}

// NOTE: Destination plugins need something similar to the following to work/
/*

@objc(SEGMixpanelDestination)
class ObjCSegmentMixpanel: NSObject, ObjCPlugin, ObjCPluginShim {
    func instance() -> EventPlugin { return MixpanelDestination() }
}

*/

@objc(SEGEventPlugin)
class ObjCEventPlugin: NSObject, EventPlugin, ObjCPlugin {
    var type: PluginType = .enrichment
    weak var analytics: Analytics? = nil
    
    @objc(executeEvent:)
    func execute(event: ObjCRawEvent?) -> ObjCRawEvent? {
        #if DEBUG
        print("SEGEventPlugin's execute: method must be overridden!")
        #endif
        return event
    }
    
    func execute<T>(event: T?) -> T? where T : RawEvent {
        let objcEvent = objcEventFromEvent(event)
        let result = execute(event: objcEvent)
        let newEvent = eventFromObjCEvent(result)
        return newEvent as? T
    }
}

@objc(SEGBlockPlugin)
class ObjCBlockPlugin: ObjCEventPlugin {
    let block: (ObjCRawEvent?) -> ObjCRawEvent?
    
    @objc(executeEvent:)
    override func execute(event: ObjCRawEvent?) -> ObjCRawEvent? {
        return block(event)
    }
    
    @objc(initWithBlock:)
    init(block: @escaping (ObjCRawEvent?) -> ObjCRawEvent?) {
        self.block = block
    }
}

@objc
extension ObjCAnalytics {
    @objc(addPlugin:)
    func add(plugin: ObjCPlugin?) {
        if let p = plugin as? ObjCPluginShim {
            analytics.add(plugin: p.instance())
        } else if let p = plugin as? ObjCEventPlugin {
            analytics.add(plugin: p)
        }
    }
    
    @objc(addPlugin:destinationKey:)
    func add(plugin: ObjCPlugin?, destinationKey: String) {
        guard let d = analytics.find(key: destinationKey) else { return }
        
        if let p = plugin as? ObjCPluginShim {
            _ = d.add(plugin: p.instance())
        } else if let p = plugin as? ObjCEventPlugin {
            _ = d.add(plugin: p)
        }
    }
}

#endif

