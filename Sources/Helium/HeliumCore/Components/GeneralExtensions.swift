//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/22/24.
//

import Foundation
import SwiftUI

public struct ColorConfig {
    let colorHex: String
    let opacity: Double
    
    public init(colorHex: String, opacity: Double) {
        self.colorHex = colorHex
        self.opacity = opacity
    }
    
    init(json: JSON) {
        self.colorHex = json["colorHex"].stringValue
        self.opacity = json["opacity"].doubleValue
    }
    
    public static func createDefault() -> ColorConfig {
        return ColorConfig(colorHex: "#000000", opacity: 1.0)
    }
}

extension Color {
    init(hex: String, opacity: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: opacity
        )
    }
    
    init(colorConfig: ColorConfig) {
        self.init(hex: colorConfig.colorHex, opacity: colorConfig.opacity)
    }
    
    init(json: JSON) {
        let colorConfig = ColorConfig(json: json)
        self.init(colorConfig: colorConfig)
    }
}
