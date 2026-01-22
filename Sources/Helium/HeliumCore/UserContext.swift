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
    var preferredLanguages: [String]?
    var currentTimeZone: TimeZone?
    var currentTimeZoneName: String?
    var decimalSeparator: String?
    var usesMetricSystem: Bool
    var storeCountryCode: String?  // 2-letter alpha-2 code
}

struct CodableScreenInfo: Codable {
    var brightness: Float
    var nativeBoundsWidth: Int
    var nativeBoundsHeight: Int
    var nativeScale: Float
    var boundsWidth: Int
    var boundsHeight: Int
    var scale: Float
    var isDarkModeEnabled: Bool
}

struct CodableApplicationInfo: Codable {
    var version: String?
    var build: String?
    var completeAppVersion: String?
    var appDisplayName: String?
    var platform: String
    var heliumSdk: String
    var heliumSdkVersion: String
    var heliumWrapperSdkVersion: String
    var purchaseDelegate: String
    var environment: String
    var latestInstallTimestamp: String?
    var firstInstallTimestamp: String?
}

struct CodableDeviceInfo: Codable {
    var currentDeviceIdentifier: String?
    var orientation: Int
    var systemName: String
    var systemVersion: String
    var deviceModel: String
    var userInterfaceIdiom: String
    var totalCapacity: Int?
    var availableCapacity: Int64?
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
    
    var latestInstallTime: String? = nil
    if let latestInstallDate = AppReceiptsHelper.shared.getDocumentsDirectoryCreationDate() {
        latestInstallTime = formatAsTimestamp(date: latestInstallDate)
    }
    
    var firstInstallTime: String? = nil
    if let installDate = AppReceiptsHelper.shared.getFirstInstallTime() {
        firstInstallTime = formatAsTimestamp(date: installDate)
    }
    
    return CodableApplicationInfo(
        version: version,
        build: build,
        completeAppVersion: completeAppVersion,
        appDisplayName: appDisplayName,
        platform: HeliumSdkConfig.shared.heliumPlatform,
        heliumSdk: HeliumSdkConfig.shared.heliumSdk,
        heliumSdkVersion: HeliumSdkConfig.shared.heliumSdkVersion,
        heliumWrapperSdkVersion: HeliumSdkConfig.shared.heliumWrapperSdkVersion,
        purchaseDelegate: HeliumSdkConfig.shared.purchaseDelegate,
        environment: AppReceiptsHelper.shared.getEnvironment(),
        latestInstallTimestamp: latestInstallTime,
        firstInstallTimestamp: firstInstallTime
    )
}

public struct CodableUserContext: Codable {
    var locale: CodableLocale
    var screenInfo: CodableScreenInfo
    var deviceInfo: CodableDeviceInfo
    var applicationInfo: CodableApplicationInfo
    var additionalParams: HeliumUserTraits
    
    public func buildRequestPayload() -> [String: Any] {
        let localeDict: [String: Any] = [
            "currentCountry": self.locale.currentCountry ?? "",
            "currentCurrency": self.locale.currentCurrency ?? "",
            "currentCurrencySymbol": self.locale.currentCurrencySymbol ?? "",
            "preferredLanguages": self.locale.preferredLanguages ?? [],
            "currentLanguage": self.locale.currentLanguage ?? "",
            "currentTimeZone": self.locale.currentTimeZone?.identifier ?? "",
            "currentTimeZoneName": self.locale.currentTimeZoneName ?? "",
            "decimalSeparator": self.locale.decimalSeparator ?? "",
            "usesMetricSystem": self.locale.usesMetricSystem,
            "storeCountryCode": self.locale.storeCountryCode ?? "",
            "iosStoreCountryCode": AppStoreCountryHelper.shared.getStoreCountryCode3() ?? ""
        ]
        
        let nativeBoundsDict: [String: Any] = [
            "x": 0,
            "y": 0,
            "width": self.screenInfo.nativeBoundsWidth,
            "height": self.screenInfo.nativeBoundsHeight
        ]
        
        let boundsDict: [String: Any] = [
            "x": 0,
            "y": 0,
            "width": self.screenInfo.boundsWidth,
            "height": self.screenInfo.boundsHeight
        ]
        
        let screenInfoDict: [String: Any] = [
            "brightness": self.screenInfo.brightness,
            "nativeBounds": nativeBoundsDict,
            "nativeBoundsWidth": self.screenInfo.nativeBoundsWidth,
            "nativeBoundsHeight": self.screenInfo.nativeBoundsHeight,
            "nativeScale": self.screenInfo.nativeScale,
            "bounds": boundsDict,
            "boundsWidth": self.screenInfo.boundsWidth,
            "boundsHeight": self.screenInfo.boundsHeight,
            "scale": self.screenInfo.scale,
            "isDarkModeEnabled": self.screenInfo.isDarkModeEnabled
        ]
        
        let deviceInfoDict: [String: Any] = [
            "currentDeviceIdentifier": self.deviceInfo.currentDeviceIdentifier ?? "",
            "orientation": self.deviceInfo.orientation,
            "systemName": self.deviceInfo.systemName,
            "systemVersion": self.deviceInfo.systemVersion,
            "deviceModel": self.deviceInfo.deviceModel,
            "userInterfaceIdiom": self.deviceInfo.userInterfaceIdiom
        ]
        
        let applicationInfoDict: [String: Any] = [
            "version": self.applicationInfo.version ?? "",
            "build": self.applicationInfo.build ?? "",
            "completeAppVersion": self.applicationInfo.completeAppVersion ?? "",
            "appDisplayName": self.applicationInfo.appDisplayName ?? "",
            "platform": self.applicationInfo.platform,
            "heliumSdk": self.applicationInfo.heliumSdk,
            "heliumSdkVersion": self.applicationInfo.heliumSdkVersion,
            "heliumWrapperSdkVersion": self.applicationInfo.heliumWrapperSdkVersion,
            "purchaseDelegate": self.applicationInfo.purchaseDelegate,
            "environment": self.applicationInfo.environment,
            "latestInstallTimestamp": self.applicationInfo.latestInstallTimestamp ?? "",
            "firstInstallTimestamp": self.applicationInfo.firstInstallTimestamp ?? ""
        ]
        
        return [
            "heliumSessionId": HeliumIdentityManager.shared.getHeliumSessionId(),
            "heliumInitializeId": HeliumIdentityManager.shared.heliumInitializeId,
            "heliumPersistentId": HeliumIdentityManager.shared.getHeliumPersistentId(),
            "userId": HeliumIdentityManager.shared.getUserId(),
            "organizationId": HeliumFetchedConfigManager.shared.getOrganizationID() ?? "unknown",
            "appTransactionId": HeliumIdentityManager.shared.appTransactionID ?? "",
            "locale": localeDict,
            "screenInfo": screenInfoDict,
            "deviceInfo": deviceInfoDict,
            "applicationInfo": applicationInfoDict,
            "experimentAllocationHistory": ExperimentAllocationTracker.shared.buildAllocationHistoryRequestPayload(),
            "additionalParams": self.additionalParams.dictionaryRepresentation
        ]
    }

    static func create(userTraits: HeliumUserTraits?, skipDeviceCapacity: Bool = false) -> CodableUserContext {
        
        let locale = CodableLocale(
            currentCountry: Locale.current.regionCode,
            currentCurrency: Locale.current.currencyCode,
            currentCurrencySymbol: Locale.current.currencySymbol,
            currentLanguage: Locale.current.languageCode,
            preferredLanguages: Locale.preferredLanguages,
            currentTimeZone: TimeZone.current,
            currentTimeZoneName: TimeZone.current.identifier,
            decimalSeparator: Locale.current.decimalSeparator,
            usesMetricSystem: Locale.current.usesMetricSystem,
            storeCountryCode: AppStoreCountryHelper.shared.getStoreCountryCode()
        )

        let screenInfo = CodableScreenInfo(
            brightness: Float(UIScreen.main.brightness),
            nativeBoundsWidth: UIScreen.main.nativeBounds.width.toInt() ?? -1,
            nativeBoundsHeight: UIScreen.main.nativeBounds.height.toInt() ?? -1,
            nativeScale: Float(UIScreen.main.nativeScale),
            boundsWidth: min(
                UIScreen.main.bounds.width.toInt() ?? -1,
                UIScreen.main.bounds.height.toInt() ?? -1,
            ),
            boundsHeight: max(
                UIScreen.main.bounds.width.toInt() ?? -1,
                UIScreen.main.bounds.height.toInt() ?? -1,
            ),
            scale: Float(UIScreen.main.scale),
            isDarkModeEnabled: UITraitCollection.current.userInterfaceStyle == .dark
        )
        
        let applicationInfo = createApplicationInfo()

        let deviceInfo = CodableDeviceInfo(
            currentDeviceIdentifier: UIDevice.current.identifierForVendor?.uuidString,
            orientation: UIDevice.current.orientation.rawValue,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: DeviceHelpers.current.getDeviceModel(),
            userInterfaceIdiom: String(describing: UIDevice.current.userInterfaceIdiom),
            totalCapacity: skipDeviceCapacity ? -1 : DeviceHelpers.current.totalCapacity,
            availableCapacity: skipDeviceCapacity ? -1 : DeviceHelpers.current.availableCapacity
        )

        return CodableUserContext(
            locale: locale,
            screenInfo: screenInfo,
            deviceInfo: deviceInfo,
            applicationInfo: applicationInfo,
            additionalParams: userTraits ?? HeliumUserTraits([:])
        )
    }
}

extension Bundle {
    var displayName: String? {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    }
}

extension CGFloat {
    func toInt() -> Int? {
        if self >= CGFloat(Int.min) && self <= CGFloat(Int.max) {
            return Int(self)
        } else {
            return nil
        }
    }
}
