//
//  UserContext.swift
//  Helium
//
//  Created by Anish Doshi on 8/1/24.
//

import Foundation
import UIKit
import DeviceKit


struct CodableLocale: Codable {
    var currentCountry: String?
    var currentCurrency: String?
    var currentCurrencySymbol: String?
    var currentLanguage: String?
    var currentTimeZone: TimeZone?
    var currentTimeZoneName: String?
    var decimalSeparator: String?
    var usesMetricSystem: Bool
}

struct CodableScreenInfo: Codable {
    var brightness: Float
    var nativeBounds: CGRect
    var nativeScale: Float
    var bounds: CGRect
    var scale: Float
}

struct CodableApplicationInfo: Codable {
    var version: String?
    var build: String?
    var completeAppVersion: String?
    var appDisplayName: String?
}

struct CodableDeviceInfo: Codable {
    var currentDeviceIdentifier: String?
    var orientation: Int
    var systemName: String
    var systemVersion: String
    var deviceModel: String
    var userInterfaceIdiom: String
}

func createApplicationInfo() -> CodableApplicationInfo {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    
    let completeAppVersion: String?
    if let version = version, let build = build {
        completeAppVersion = "\(version) (\(build))"
    } else {
        completeAppVersion = nil
    }
    
    let appDisplayName: String?
    if let displayName = Bundle.main.displayName {
        appDisplayName = displayName;
    } else {
        appDisplayName = nil;
    }
    
    return CodableApplicationInfo(version: version, build: build, completeAppVersion: completeAppVersion, appDisplayName: appDisplayName);
}

struct CodableUserContext: Codable {
    var locale: CodableLocale
    var screenInfo: CodableScreenInfo
    var deviceInfo: CodableDeviceInfo
    var applicationInfo: CodableApplicationInfo
    var additionalParams: [String: String]
    
    public func asParams() -> [String: Any] {
        return [
            "locale": [
                "currentCountry": self.locale.currentCountry as Any,
                "currentCurrency": self.locale.currentCurrency as Any,
                "currentCurrencySymbol": self.locale.currentCurrencySymbol as Any,
                "currentLanguage": self.locale.currentLanguage as Any,
                "currentTimeZone": self.locale.currentTimeZone?.identifier as Any,
                "currentTimeZoneName": self.locale.currentTimeZoneName as Any,
                "decimalSeparator": self.locale.decimalSeparator as Any,
                "usesMetricSystem": self.locale.usesMetricSystem
            ],
            "screenInfo": [
                "brightness": self.screenInfo.brightness,
                "nativeBounds": [
                    "x": self.screenInfo.nativeBounds.origin.x,
                    "y": self.screenInfo.nativeBounds.origin.y,
                    "width": self.screenInfo.nativeBounds.size.width,
                    "height": self.screenInfo.nativeBounds.size.height
                ],
                "nativeScale": self.screenInfo.nativeScale,
                "bounds": [
                    "x": self.screenInfo.bounds.origin.x,
                    "y": self.screenInfo.bounds.origin.y,
                    "width": self.screenInfo.bounds.size.width,
                    "height": self.screenInfo.bounds.size.height
                ],
                "scale": self.screenInfo.scale
            ],
            "deviceInfo": [
                "currentDeviceIdentifier": self.deviceInfo.currentDeviceIdentifier as Any,
                "orientation": self.deviceInfo.orientation,
                "systemName": self.deviceInfo.systemName,
                "systemVersion": self.deviceInfo.systemVersion,
                "deviceModel": self.deviceInfo.deviceModel,
                "userInterfaceIdiom": self.deviceInfo.userInterfaceIdiom
            ],
            "applicationInfo": [
                "version": self.applicationInfo.version as Any,
                "build": self.applicationInfo.build as Any,
                "completeAppVersion": self.applicationInfo.completeAppVersion as Any,
                "appDisplayName": self.applicationInfo.appDisplayName as Any
            ],
            "additionalParams": self.additionalParams
        ]
    }

    static func create() -> CodableUserContext {
        let locale = CodableLocale(
            currentCountry: Locale.current.regionCode,
            currentCurrency: Locale.current.currencyCode,
            currentCurrencySymbol: Locale.current.currencySymbol,
            currentLanguage: Locale.current.languageCode,
            currentTimeZone: TimeZone.current,
            currentTimeZoneName: TimeZone.current.identifier,
            decimalSeparator: Locale.current.decimalSeparator,
            usesMetricSystem: Locale.current.usesMetricSystem
        )

        let screenInfo = CodableScreenInfo(
            brightness: Float(UIScreen.main.brightness),
            nativeBounds: UIScreen.main.nativeBounds,
            nativeScale: Float(UIScreen.main.nativeScale),
            bounds: UIScreen.main.bounds,
            scale: Float(UIScreen.main.scale)
        )
        
        let applicationInfo = createApplicationInfo()

        let deviceInfo = CodableDeviceInfo(
            currentDeviceIdentifier: UIDevice.current.identifierForVendor?.uuidString,
            orientation: UIDevice.current.orientation.rawValue,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: Device.current.safeDescription,
            userInterfaceIdiom: String(describing: UIDevice.current.userInterfaceIdiom)
        )

        return CodableUserContext(
            locale: locale,
            screenInfo: screenInfo,
            deviceInfo: deviceInfo,
            applicationInfo: applicationInfo,
            additionalParams: [:]
        )
    }
}


func createHeliumUserId() -> String {
    // Check if the User Id exists in UserDefaults
    if let existingUserId = UserDefaults.standard.string(forKey: "heliumUserId") {
        // Return the existing User Id
        return existingUserId;
    } else {
        // Create a new User Id
        let newUserId: String = UUID().uuidString;
        // Save the new User Id to UserDefaults
        return newUserId
    }
}

extension Bundle {
    var displayName: String? {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    }
}
