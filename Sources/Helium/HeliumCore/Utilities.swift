//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/16/24.
//

import Foundation
import SwiftUI

extension Encodable {
    /// Converting object to postable JSON
    func toJSON(_ encoder: JSONEncoder = JSONEncoder()) throws -> String {
        let data = try encoder.encode(self)
        let result = String(decoding: data, as: UTF8.self)
        return result
    }
    
    func toSwiftyJSON(_ encoder: JSONEncoder = JSONEncoder()) throws -> JSON {
        let data = try encoder.encode(self)
        let json = try JSON(data: data)
        return json
    }
    
    /// Convert Codable object to dictionary
    public func toDictionary() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            HeliumLogger.log(.error, category: .core, "Failed to encode \(type(of: self)) to dictionary")
            return [:]
        }
        return dict
    }
}

extension JSON {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        
        for (key, value) in self {
            switch value.type {
            case .array:
                dict[key] = value.arrayValue.map { subJson in
                    switch subJson.type {
                    case .dictionary:
                        return subJson.toDictionary() as Any
                    default:
                        return subJson.object
                    }
                }
            case .dictionary:
                dict[key] = value.toDictionary() as Any
            default:
                dict[key] = value.object
            }
        }
        
        return dict
    }
}

extension AnyCodable {
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

private let isoFormatterWithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func formatAsTimestamp(date: Date) -> String {
    return isoFormatterWithFractional.string(from: date)
}

func dispatchTimeDifferenceInMS(from: DispatchTime, to: DispatchTime = DispatchTime.now()) -> UInt64 {
    return UInt64(Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000.0)
}

func parseISODate(_ dateString: String?) -> Date? {
    guard let dateString = dateString else { return nil }
    // Try without fractional seconds first, then with
    if let date = isoFormatter.date(from: dateString) {
        return date
    }
    return isoFormatterWithFractional.date(from: dateString)
}

let invalidDateString = "unknown"

private let displayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

func formatDateForDisplay(_ dateString: String?) -> String {
    guard let date = parseISODate(dateString) else { return invalidDateString }
    return displayDateFormatter.string(from: date)
}


public func getVersionIndependentSafeAreaInsets(additionalTopPadding: CGFloat = 0, additionalBottomPadding: CGFloat = 0) -> EdgeInsets {
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let leftPadding: CGFloat
    let rightPadding: CGFloat

    if #unavailable(iOS 15) {
        topPadding = UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0
        bottomPadding = UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0
        leftPadding = UIApplication.shared.windows.first?.safeAreaInsets.left ?? 0
        rightPadding = UIApplication.shared.windows.first?.safeAreaInsets.right ?? 0
    } else {
        topPadding = UIApplication
            .shared
            .connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 0
        
        bottomPadding = UIApplication
            .shared
            .connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
        
        leftPadding = UIApplication
            .shared
            .connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }?.safeAreaInsets.left ?? 0
        
        rightPadding = UIApplication
            .shared
            .connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }?.safeAreaInsets.right ?? 0
    }
    return EdgeInsets(top: topPadding + additionalTopPadding, leading: leftPadding, bottom: bottomPadding + additionalBottomPadding, trailing: rightPadding);
}


@MainActor
class UIWindowHelper {
    
    static func findTopMostViewController() -> UIViewController? {
        guard let activeWindow = findActiveWindow(),
              var topController = activeWindow.rootViewController else {
            return nil
        }
        
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }
        
        return topController
    }
    
    static func findActiveWindow() -> UIWindow? {
        if let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            return windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        }
        
        if let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundInactive }) as? UIWindowScene {
            return windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        }
        
        let allWindows = UIApplication.shared.connectedScenes.flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
        return allWindows.first { $0.isKeyWindow } ?? allWindows.first
    }
    
}
