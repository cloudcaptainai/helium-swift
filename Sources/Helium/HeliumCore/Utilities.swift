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

func formatAsTimestamp(date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX" // ISO 8601 format
    formatter.locale = Locale.current // Use user's current locale
    formatter.timeZone = TimeZone.current // Use user's current timezone
    return formatter.string(from: date)
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
