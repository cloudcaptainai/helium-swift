//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/12/24.
//

import Foundation
import SwiftUI
import SwiftyJSON

import SwiftUI
import SwiftyJSON

// MARK: - Base Value Types
public enum DimensionValue: Equatable {
    case fixed(CGFloat)
    case percentage(CGFloat)
    
    init(json: JSON) {
        if let percentage = json["percentageOfParent"].double {
            self = .percentage(CGFloat(percentage))
        } else if let value = json.double {
            self = .fixed(CGFloat(value))
        } else {
            self = .fixed(0)
        }
    }
    
    func getValue(relativeTo total: CGFloat) -> CGFloat {
        switch self {
        case .fixed(let value):
            return value
        case .percentage(let percent):
            return total * (percent / 100.0)
        }
    }
}

public enum AnchorPoint {
    case center
    case point(x: DimensionValue, y: DimensionValue)
    
    init(json: JSON) {
        if let pointStr = json.string, pointStr == "center" {
            self = .center
        } else if let pointObj = json.dictionary {
            self = .point(
                x: DimensionValue(json: JSON(pointObj["x"] ?? [])),
                y: DimensionValue(json: JSON(pointObj["y"] ?? []))
            )
        } else {
            self = .center
        }
    }
    
    func toUnitPoint(in geometry: GeometryProxy?) -> UnitPoint {
        switch self {
        case .center:
            return .center
        case .point(let x, let y):
            return UnitPoint(
                x: x.getValue(relativeTo: geometry?.size.width ?? 0),
                y: y.getValue(relativeTo: geometry?.size.height ?? 0)
            )
        }
    }
}

// MARK: - Edge Values
public struct EdgeValues<T> {
    let top: T?
    let leading: T?
    let bottom: T?
    let trailing: T?
    
    init(json: JSON, valueType: (JSON) -> T) {
        self.top = json["top"].exists() ? valueType(json["top"]) : nil
        self.leading = json["leading"].exists() ? valueType(json["leading"]) : nil
        self.bottom = json["bottom"].exists() ? valueType(json["bottom"]) : nil
        self.trailing = json["trailing"].exists() ? valueType(json["trailing"]) : nil
    }
}


// MARK: - Border Configuration
public struct BorderConfig {
    enum BorderStyle: String {
        case solid, dashed, dotted
    }
    
    let width: CGFloat
    let color: ColorConfig
    let style: BorderStyle
    let radius: DimensionValue?
    let dashPattern: [CGFloat]?
    
    init(json: JSON) {
        self.width = CGFloat(json["width"].doubleValue)
        self.color = ColorConfig(json: json["color"])
        self.style = BorderStyle(rawValue: json["style"].stringValue) ?? .solid
        self.radius = json["radius"].exists() ? DimensionValue(json: json["radius"]) : nil
        
        if let pattern = json["dashPattern"].array {
            self.dashPattern = pattern.map { CGFloat($0.doubleValue) }
        } else {
            switch style {
            case .dashed: self.dashPattern = [6, 3]
            case .dotted: self.dashPattern = [1, 2]
            case .solid: self.dashPattern = nil
            }
        }
    }
}

// MARK: - Transform Configurations
public struct RotateConfig {
    let degrees: Double
    let anchor: AnchorPoint
    
    init(json: JSON) {
        self.degrees = json["degrees"].doubleValue
        self.anchor = AnchorPoint(json: json["anchor"])
    }
}

public struct ScaleConfig {
    let scaleX: Double
    let scaleY: Double
    let anchor: AnchorPoint
    
    init(json: JSON) {
        self.scaleX = json["x"].doubleValue
        self.scaleY = json["y"].doubleValue
        self.anchor = AnchorPoint(json: json["anchor"])
    }
}



// MARK: - Overlay Configuration
public struct OverlayConfig {
    let cornerRadius: DimensionValue
    let inset: DimensionValue
    let strokeColor: ColorConfig
    let strokeWidth: CGFloat
    
    init(json: JSON) {
        self.cornerRadius = DimensionValue(json: json["cornerRadius"])
        self.inset = DimensionValue(json: json["inset"])
        self.strokeColor = ColorConfig(json: json["strokeColor"])
        self.strokeWidth = CGFloat(json["strokeWidth"].doubleValue)
    }
}

// MARK: - Shadow Configuration
public struct ShadowConfig {
    let color: ColorConfig
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    
    init(json: JSON) {
        self.color = ColorConfig(json: json["color"])
        self.radius = CGFloat(json["radius"].doubleValue)
        self.x = CGFloat(json["x"].doubleValue)
        self.y = CGFloat(json["y"].doubleValue)
    }
}

//// MARK: - Frame Configuration
//public struct FrameConfig {
//    let width: DimensionValue?
//    let height: DimensionValue?
//    let alignment: Alignment?
//    
//    init?(json: JSON) {
//        guard json.exists() else { return nil }
//        
//        self.width = json["width"].exists() ? DimensionValue(json: json["width"]) : nil
//        self.height = json["height"].exists() ? DimensionValue(json: json["height"]) : nil
//        
//        if json["alignment"].exists() {
//            self.alignment = Alignment(
//                horizontal: HorizontalAlignment(json["alignment"]["horizontal"].string ?? "center"),
//                vertical: VerticalAlignment(json["alignment"]["vertical"].string ?? "center")
//            )
//        } else {
//            self.alignment = nil
//        }
//    }
//}

// MARK: - Position Configuration
public struct PositionConfig {
    let x: DimensionValue
    let y: DimensionValue
    
    init(json: JSON) {
        self.x = DimensionValue(json: json["x"])
        self.y = DimensionValue(json: json["y"])
    }
}
