//
//  ObjCEvents.swift
//  
//
//  Created by Brandon Sneed on 4/17/23.
//

#if !os(Linux)

import Foundation

internal protocol ObjCEvent {
    associatedtype EventType
    var _event: EventType { get set }
}

@objc(SEGDestinationMetadata)
class ObjCDestinationMetadata: NSObject {
    internal var _metadata: DestinationMetadata
    
    var bundled: [String] {
        get { return _metadata.bundled }
        set(v) { _metadata.bundled = v }
    }
    
    var unbundled: [String] {
        get { return _metadata.unbundled }
        set(v) { _metadata.unbundled = v }
    }
    
    var bundledIds: [String] {
        get { return _metadata.bundledIds }
        set(v) { _metadata.bundledIds = v }
    }
    
    internal init?(_metadata: DestinationMetadata?) {
        guard let m = _metadata else { return nil }
        self._metadata = m
    }
    
    init(bundled: [String], unbundled: [String], bundledIds: [String]) {
        _metadata = DestinationMetadata(bundled: bundled, unbundled: unbundled, bundledIds: bundledIds)
    }
}

@objc(SEGRawEvent)
protocol ObjCRawEvent: NSObjectProtocol {
    var type: String? { get }
    var messageId: String? { get }
    var timestamp: String? { get }
    var anonymousId: String? { get set }
    var userId: String? { get set }
    
    var context: [String: Any]? { get set }
    var integrations: [String: Any]? { get set }

    var metadata: ObjCDestinationMetadata? { get set }
}

internal func eventFromObjCEvent(_ event: ObjCRawEvent?) -> RawEvent? {
    guard let event = event as? (any ObjCEvent) else { return nil }
    return event._event as? RawEvent
}

internal func objcEventFromEvent<T: RawEvent>(_ event: T?) -> ObjCRawEvent? {
    guard let event = event else { return nil }
    switch event {
    case let e as TrackEvent:
        return ObjCTrackEvent(event: e)
    case let e as IdentifyEvent:
        return ObjCIdentifyEvent(event: e)
    case let e as ScreenEvent:
        return ObjCScreenEvent(event: e)
    case let e as GroupEvent:
        return ObjCGroupEvent(event: e)
    case let e as AliasEvent:
        return ObjCAliasEvent(event: e)
    default:
        return nil
    }
}

@objc(SEGTrackEvent)
class ObjCTrackEvent: NSObject, ObjCEvent, ObjCRawEvent {
    internal var _event: TrackEvent
    
    // RawEvent components
    
    var type: String? { return _event.type }
    var messageId: String? { return _event.messageId }
    var timestamp: String? { return _event.timestamp }
    
    var anonymousId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var userId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var context: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var integrations: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var metadata: ObjCDestinationMetadata? {
        get { return ObjCDestinationMetadata(_metadata: _event._metadata) }
        set(v) { _event._metadata = v?._metadata }
    }
    
    // Event Specific
    
    @objc
    var event: String {
        get { return _event.event }
        set(v) { _event.event = v }
    }
    
    @objc
    var properties: [String: Any]? {
        get { return _event.properties?.dictionaryValue }
        set(v) { _event.properties = try? JSON(nilOrObject: v)}
    }

    @objc
    init(name: String, properties: [String: Any]? = nil) {
        _event = TrackEvent(event: name, properties: try? JSON(nilOrObject: properties))
    }
    
    internal init(event: EventType) {
        self._event = event
    }
}

@objc(SEGIdentifyEvent)
class ObjCIdentifyEvent: NSObject, ObjCEvent, ObjCRawEvent {
    internal var _event: IdentifyEvent
    
    // RawEvent components
    
    var type: String? { return _event.type }
    var messageId: String? { return _event.messageId }
    var timestamp: String? { return _event.timestamp }

    var anonymousId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var userId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var context: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var integrations: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var metadata: ObjCDestinationMetadata? {
        get { return ObjCDestinationMetadata(_metadata: _event._metadata) }
        set(v) { _event._metadata = v?._metadata }
    }
    
    // Event Specific
    
    @objc
    var traits: [String: Any]? {
        get { return _event.traits?.dictionaryValue }
        set(v) { _event.traits = try? JSON(nilOrObject: v)}
    }

    @objc
    init(userId: String, traits: [String: Any]? = nil) {
        _event = IdentifyEvent(userId: userId, traits: try? JSON(nilOrObject: traits))
    }
    
    internal init(event: EventType) {
        self._event = event
    }
}

@objc(SEGScreenEvent)
class ObjCScreenEvent: NSObject, ObjCEvent, ObjCRawEvent {
    internal var _event: ScreenEvent
    
    // RawEvent components
    
    var type: String? { return _event.type }
    var messageId: String? { return _event.messageId }
    var timestamp: String? { return _event.timestamp }

    var anonymousId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var userId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var context: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var integrations: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var metadata: ObjCDestinationMetadata? {
        get { return ObjCDestinationMetadata(_metadata: _event._metadata) }
        set(v) { _event._metadata = v?._metadata }
    }
    
    // Event Specific
    
    @objc
    var name: String? {
        get { return _event.name }
        set(v) { _event.name = v}
    }
    
    @objc
    var category: String? {
        get { return _event.category }
        set(v) { _event.category = v}
    }
    
    @objc
    var properties: [String: Any]? {
        get { return _event.properties?.dictionaryValue }
        set(v) { _event.properties = try? JSON(nilOrObject: v)}
    }

    @objc
    init(name: String, category: String?, properties: [String: Any]? = nil) {
        _event = ScreenEvent(title: name, category: category, properties: try? JSON(nilOrObject: properties))
    }
    
    internal init(event: EventType) {
        self._event = event
    }
}

@objc(SEGGroupEvent)
class ObjCGroupEvent: NSObject, ObjCEvent, ObjCRawEvent {
    internal var _event: GroupEvent
    
    // RawEvent components
    
    var type: String? { return _event.type }
    var messageId: String? { return _event.messageId }
    var timestamp: String? { return _event.timestamp }

    var anonymousId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var userId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var context: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var integrations: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var metadata: ObjCDestinationMetadata? {
        get { return ObjCDestinationMetadata(_metadata: _event._metadata) }
        set(v) { _event._metadata = v?._metadata }
    }
    
    // Event Specific
    
    @objc
    var groupId: String? {
        get { return _event.groupId }
        set(v) { _event.groupId = v}
    }
    
    @objc
    var traits: [String: Any]? {
        get { return _event.traits?.dictionaryValue }
        set(v) { _event.traits = try? JSON(nilOrObject: v)}
    }

    @objc
    init(groupId: String?, traits: [String: Any]? = nil) {
        _event = GroupEvent(groupId: groupId, traits: try? JSON(nilOrObject: traits))
    }
    
    internal init(event: EventType) {
        self._event = event
    }
}

@objc(SEGAliasEvent)
class ObjCAliasEvent: NSObject, ObjCEvent, ObjCRawEvent {
    internal var _event: AliasEvent
    
    // RawEvent components
    
    var type: String? { return _event.type }
    var messageId: String? { return _event.messageId }
    var timestamp: String? { return _event.timestamp }

    var anonymousId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var userId: String? {
        get { return _event.anonymousId }
        set(v) { _event.anonymousId = v}
    }
    
    var context: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var integrations: [String: Any]? {
        get { return _event.context?.dictionaryValue }
        set(v) { _event.context = try? JSON(nilOrObject: v)}
    }
    
    var metadata: ObjCDestinationMetadata? {
        get { return ObjCDestinationMetadata(_metadata: _event._metadata) }
        set(v) { _event._metadata = v?._metadata }
    }
    
    // Event Specific
    
    @objc
    var previousId: String? {
        get { return _event.previousId }
        set(v) { _event.previousId = v}
    }

    @objc
    init(newId: String?) {
        _event = AliasEvent(newId: newId)
    }
    
    internal init(event: EventType) {
        self._event = event
    }
}

#endif
