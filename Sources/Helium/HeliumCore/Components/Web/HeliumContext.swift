//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/26/24.
//

import Foundation

public let weekdays = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]


func createHeliumContext(triggerName: String?) -> JSON {
    do {
        // Get product IDs if trigger name is provided
        var productIds: [String] = []
        if let triggerName = triggerName {
            productIds = HeliumFetchedConfigManager.shared.getProductIDsForTrigger(triggerName) ?? []
        }
        
        // Get current date components
        let currentDate = Date()
        let currentCalendar = Calendar.current
        let weekdayIndex = currentCalendar.component(.weekday, from: currentDate) - 1
        let safeDayIndex = max(0, min(weekdayIndex, weekdays.count - 1))
        
        // Get user context from identity manager
        let userContext = HeliumIdentityManager.shared.getUserContext(
            skipDeviceCapacity: true
        )
        
        // Create the base context JSON from user context params
        var contextJSON = JSON(userContext.asParams())
        
        // Add trigger information
        contextJSON["trigger"] = JSON(triggerName ?? "")
        
        // Add datetime information
        contextJSON["datetime"] = JSON([
            "month": currentCalendar.component(.month, from: currentDate),
            "dayOfWeek": weekdays[safeDayIndex],
            "dayOfMonth": currentCalendar.component(.day, from: currentDate),
            "hour": currentCalendar.component(.hour, from: currentDate),
            "minute": currentCalendar.component(.minute, from: currentDate)
        ])
        
        // Add products information
        contextJSON["products"] = JSON([
            "productIds": productIds
        ])
        
        return contextJSON
    } catch {
        return JSON()
    }
}

