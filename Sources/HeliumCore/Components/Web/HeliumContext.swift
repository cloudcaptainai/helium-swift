//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/26/24.
//

import Foundation

public struct HeliumContextProductInfo: Codable {
    var productIds: [String]
}

public struct HeliumContextDatetimeInfo: Codable {
    var month: Int?
    var dayOfWeek: String?
    var dayOfMonth: Int?
    var hour: Int?
    var minute: Int?
}

public struct HeliumContext: Codable {
    var trigger: String?
    var app: CodableApplicationInfo?
    var locale: CodableLocale?
    var screen: CodableScreenInfo?
    var userContext: CodableUserContext?
    var datetime: HeliumContextDatetimeInfo?
    var products: HeliumContextProductInfo
}

public let weekdays = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]

public func createHeliumContext(triggerName: String?) -> HeliumContext {
    var productIds: [String]? = nil;
    if (triggerName != nil) {
        productIds = HeliumFetchedConfigManager.shared.getProductIDsForTrigger(triggerName!);
    }
    let currentDate = Date()
    let currentCalendar = Calendar.current;
    let userContext = HeliumIdentityManager.shared.getUserContext();
    
    return HeliumContext(
        trigger: triggerName,
        app: userContext.applicationInfo,
        locale: userContext.locale,
        screen: userContext.screenInfo,
        datetime: HeliumContextDatetimeInfo(
            month: currentCalendar.component(.month, from: currentDate),
            dayOfWeek: weekdays[currentCalendar.component(.weekday, from: currentDate) - 1],
            dayOfMonth: currentCalendar.component(.day, from: currentDate),
            hour: currentCalendar.component(.hour, from: currentDate),
            minute: currentCalendar.component(.minute, from: currentDate)
        ),
        products: HeliumContextProductInfo(
            productIds: productIds ?? []
        )
    );
}
