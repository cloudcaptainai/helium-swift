//
//  File.swift
//  
//
//  Created by Anish Doshi on 1/27/25.
//

import Foundation
import SwiftUI
import UIKit

extension Color {
    /// WCAG relative luminance in sRGB. nil if components can't be resolved.
    var relativeLuminance: CGFloat? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }
}

// Represents a color stop in a gradient
public struct GradientStop: Equatable {
    let color: Color
    let location: CGFloat
    
    init(color: Color, location: CGFloat) {
        self.color = color
        self.location = max(0, min(1, location)) // Ensure location is between 0 and 1
    }
    
    // Initialize from JSON
    init?(json: JSON) {
        guard let colorString = json["color"].string,
              let location = json["location"].double else {
            return nil
        }
        
        self.color = Color(hex: colorString) ?? .clear
        self.location = CGFloat(location)
    }
}

// Main background configuration type
public struct BackgroundConfig {
    public enum BackgroundType {
        case color(Color)
        case linearGradient(stops: [GradientStop], startPoint: UnitPoint, endPoint: UnitPoint)
        case image(name: String, contentMode: ContentMode)
    }
    
    let type: BackgroundType
    
    // Initialize with a solid color
    public init(color: Color) {
        self.type = .color(color)
    }
    
    // Initialize with a linear gradient
    public init(gradientStops: [GradientStop], startPoint: UnitPoint = .top, endPoint: UnitPoint = .bottom) {
        self.type = .linearGradient(stops: gradientStops, startPoint: startPoint, endPoint: endPoint)
    }
    
    // Initialize with an image
    public init(imageName: String, contentMode: ContentMode = .fill) {
        self.type = .image(name: imageName, contentMode: contentMode)
    }
    
    // Initialize from JSON
    init(json: JSON) {
        switch json["type"].stringValue {
        case "color":
            if let colorString = json["value"].string {
                self.type = .color(Color(hex: colorString) ?? .clear)
            } else {
                self.type = .color(.clear)
            }
            
        case "linearGradient":
            let stops = json["stops"].arrayValue.compactMap { GradientStop(json: $0) }
            let startPoint = BackgroundConfig.parseUnitPoint(from: json["startPoint"]) ?? .top
            let endPoint = BackgroundConfig.parseUnitPoint(from: json["endPoint"]) ?? .bottom
            self.type = .linearGradient(stops: stops, startPoint: startPoint, endPoint: endPoint)
            
        case "image":
            let name = json["name"].stringValue
            let contentMode: ContentMode = json["contentMode"].stringValue == "fit" ? .fit : .fill
            self.type = .image(name: name, contentMode: contentMode)
            
        default:
            self.type = .color(.clear)
        }
    }
    
    // Helper function to parse UnitPoint from JSON
    private static func parseUnitPoint(from json: JSON) -> UnitPoint? {
        guard let x = json["x"].double,
              let y = json["y"].double else {
            return nil
        }
        return UnitPoint(x: x, y: y)
    }
    
    var representativeColor: Color? {
        switch type {
        case .color(let c):
            return c
        case .linearGradient(let stops, _, _):
            guard !stops.isEmpty else { return nil }
            return stops[stops.count / 2].color
        case .image:
            return nil
        }
    }

    var preferredContrastColor: Color {
        // Default to white for image backgrounds — photographic content varies
        // and white reads on more of it than black does.
        guard let color = representativeColor,
              let luminance = color.relativeLuminance else {
            return .white
        }
        return luminance > 0.5 ? .black : .white
    }

    // Generate the background view
    public func makeBackgroundView() -> some View {
        switch type {
        case .color(let color):
            return AnyView(color)
            
        case .linearGradient(let stops, let startPoint, let endPoint):
            let gradient = LinearGradient(
                stops: stops.map { Gradient.Stop(color: $0.color, location: $0.location) },
                startPoint: startPoint,
                endPoint: endPoint
            )
            return AnyView(gradient)
            
        case .image(let name, let contentMode):
            return AnyView(
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            )
        }
    }
}
