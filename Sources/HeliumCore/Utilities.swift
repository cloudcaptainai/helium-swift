//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/16/24.
//

import Foundation
import AnyCodable

public extension Encodable {
    /// Converting object to postable JSON
    func toJSON(_ encoder: JSONEncoder = JSONEncoder()) throws -> String {
        let data = try encoder.encode(self)
        let result = String(decoding: data, as: UTF8.self)
        return result
    }
}

public extension AnyCodable {
    func value<T>(at path: String, default defaultValue: T) -> T {
        let components = path.components(separatedBy: CharacterSet(charactersIn: ".[]"))
                            .filter { !$0.isEmpty }
        
        var current: Any = self
        
        for component in components {
            if let index = Int(component) {
                guard let array = current as? [Any], index < array.count else { return defaultValue }
                current = array[index]
            } else {
                guard let dict = current as? [String: Any], let value = dict[component] else { return defaultValue }
                current = value
            }
        }
        
        return (current as? T) ?? defaultValue
    }
}

func formatAsTimestamp(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX" // ISO 8601 format
    formatter.locale = Locale.current // Use user's current locale
    formatter.timeZone = TimeZone.current // Use user's current timezone
    return formatter.string(from: date)
}
