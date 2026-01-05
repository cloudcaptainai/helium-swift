//
//  AppConfig.swift
//  HeliumExample
//

import Foundation

/// Centralized configuration that reads from environment variables.
enum AppConfig {
    static var apiKey: String {
        ProcessInfo.processInfo.environment["HELIUM_API_KEY"] ?? "insert_api_key_here"
    }
    
    static var triggerKey: String {
        ProcessInfo.processInfo.environment["HELIUM_TRIGGER_KEY"] ?? "insert_trigger_here"
    }
}
