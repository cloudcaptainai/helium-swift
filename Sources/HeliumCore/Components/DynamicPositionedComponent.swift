//
//  File.swift
//  
//
//  Created by Anish Doshi on 8/22/24.
//

import Foundation
import SwiftUI
import SwiftyJSON

public struct DynamicPositionedComponent: View {
    let type: String
    let componentProps: JSON
    let viewModifierProps: JSON
    
    public init(json: JSON) {
        self.type = json["type"].stringValue
        self.componentProps = json["componentProps"]
        self.viewModifierProps = json["viewModifierProps"]
    }
    
    public var body: some View {
        componentView
            .modifier(DynamicViewModifier(json: viewModifierProps))
    }
    
    @ViewBuilder
    private var componentView: some View {
        switch type {
        case "linearGradient":
            DynamicLinearGradient(json: componentProps)
        case "image":
            DynamicImage(json: componentProps)
        case "button":
            DynamicButtonComponent(json: componentProps, action: {
                // Action placeholder. You might want to pass this through the JSON or handle it externally.
                print("Button tapped")
            })
        case "text":
            DynamicTextComponent(json: componentProps)
        default:
            Text("Unsupported component type: \(type)")
        }
    }
}

struct DynamicViewModifier: ViewModifier {
    let frame: CGSize?
    let padding: EdgeInsets?
    let margin: EdgeInsets?
    let alignment: Alignment?
    let cornerRadius: CGFloat?
    let backgroundColor: Color?
    let overlay: OverlayConfig?
    
    struct OverlayConfig {
        let cornerRadius: CGFloat
        let inset: CGFloat
        let strokeColor: Color
        let strokeWidth: CGFloat
    }
    
    init(json: JSON) {
        print("~~~HERE");
        print(json);
        if let frameWidth = json["frame"]["width"].double,
           let frameHeight = json["frame"]["height"].double {
            self.frame = CGSize(width: frameWidth, height: frameHeight)
        } else {
            self.frame = nil
        }
        
        if json["padding"] != JSON.null {
            self.padding = EdgeInsets(
                top: CGFloat(json["padding"]["top"].doubleValue),
                leading: CGFloat(json["padding"]["leading"].doubleValue),
                bottom: CGFloat(json["padding"]["bottom"].doubleValue),
                trailing: CGFloat(json["padding"]["trailing"].doubleValue)
            )
        } else {
            self.padding = nil
        }
        
        if json["margin"] != JSON.null {
            self.margin = EdgeInsets(
                top: CGFloat(json["margin"]["top"].doubleValue),
                leading: CGFloat(json["margin"]["leading"].doubleValue),
                bottom: CGFloat(json["margin"]["bottom"].doubleValue),
                trailing: CGFloat(json["margin"]["trailing"].doubleValue)
            )
        } else {
            self.margin = nil
        }
        
        if json["alignment"] != JSON.null {
            self.alignment = Alignment(
                horizontal: HorizontalAlignment(json["alignment"]["horizontal"].string ?? "center"),
                vertical: VerticalAlignment(json["alignment"]["vertical"].string ?? "center")
            )
        } else {
            self.alignment = nil
        }
        
        self.cornerRadius = CGFloat(json["cornerRadius"].doubleValue)
        
        if let backgroundHex = json["background"].string {
            self.backgroundColor = Color(hex: backgroundHex)
        } else {
            self.backgroundColor = nil
        }
        
        if let overlayJSON = json["overlay"].dictionaryObject {
            self.overlay = OverlayConfig(
                cornerRadius: CGFloat(overlayJSON["cornerRadius"] as? Double ?? 0),
                inset: CGFloat(overlayJSON["inset"] as? Double ?? 0),
                strokeColor: Color(hex: overlayJSON["strokeColor"] as? String ?? "#000000") ?? .black,
                strokeWidth: CGFloat(overlayJSON["strokeWidth"] as? Double ?? 1)
            )
        } else {
            self.overlay = nil
        }
    }
    
    func body(content: Content) -> some View {
        content
            .frame(width: frame?.width, height: frame?.height, alignment: alignment ?? .center)
            .padding(padding ?? EdgeInsets())
            .margin(margin ?? EdgeInsets())
            .background(backgroundColor)
            .cornerRadius(cornerRadius ?? 0)
            .overlay(
                Group {
                    if let overlay = overlay {
                        RoundedRectangle(cornerRadius: overlay.cornerRadius)
                            .inset(by: overlay.inset)
                            .stroke(overlay.strokeColor, lineWidth: overlay.strokeWidth)
                    }
                }
            )
    }
}

extension View {
    func margin(_ edges: EdgeInsets) -> some View {
        padding(.top, edges.top)
            .padding(.leading, edges.leading)
            .padding(.bottom, edges.bottom)
            .padding(.trailing, edges.trailing)
    }
}

extension HorizontalAlignment {
    init(_ string: String?) {
        switch string?.lowercased() {
        case "leading": self = .leading
        case "trailing": self = .trailing
        default: self = .center
        }
    }
}

extension VerticalAlignment {
    init(_ string: String?) {
        switch string?.lowercased() {
        case "top": self = .top
        case "bottom": self = .bottom
        default: self = .center
        }
    }
}
