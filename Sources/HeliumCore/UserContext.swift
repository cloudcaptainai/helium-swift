//
//  UserContext.swift
//  Helium
//
//  Created by Anish Doshi on 8/1/24.
//

import Foundation
import UIKit

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
}

struct CodableDeviceInfo: Codable {
    var currentDeviceIdentifier: String?
    var orientation: Int
    var systemName: String
    var systemVersion: String
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
    
    return CodableApplicationInfo(version: version, build: build, completeAppVersion: completeAppVersion)
}

struct CodableUserContext: Codable {
    var locale: CodableLocale
    var screenInfo: CodableScreenInfo
    var deviceInfo: CodableDeviceInfo
    var applicationInfo: CodableApplicationInfo
    var additionalParams: [String: String]
    

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
            systemVersion: UIDevice.current.systemVersion
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


func createHeliumUserId() -> UUID {
    // Check if the UUID exists in UserDefaults
    if let existingUUID = UserDefaults.standard.string(forKey: "heliumUserId") {
        // Return the existing UUID
        return UUID(uuidString: existingUUID) ?? UUID()
    } else {
        // Create a new UUID
        let newUUID: UUID = UUID()
        // Save the new UUID to UserDefaults
        UserDefaults.standard.set(newUUID.uuidString, forKey: "heliumUserId")
        // Return the new UUID
        return newUUID
    }
}
