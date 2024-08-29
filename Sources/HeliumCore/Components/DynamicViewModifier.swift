import SwiftUI
import SwiftyJSON

public struct DynamicViewModifier: ViewModifier {
    let frame: CGSize?
    let padding: EdgeInsets?
    let margin: EdgeInsets?
    let alignment: Alignment?
    let cornerRadius: CGFloat?
    let backgroundColor: ColorConfig?
    let overlay: OverlayConfig?
    let shadow: ShadowConfig?
    let position: PositionConfig?
    let geometryPosition: GeometryPositionConfig?
    let geometryProxy: GeometryProxy?

    struct OverlayConfig {
        let cornerRadius: CGFloat
        let inset: CGFloat
        let strokeColor: ColorConfig
        let strokeWidth: CGFloat
    }

    struct ShadowConfig {
        let color: ColorConfig
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    struct PositionConfig {
        let x: CGFloat
        let y: CGFloat
    }

    struct GeometryPositionConfig {
        let xPercent: CGFloat
        let yPercent: CGFloat
    }

    init(json: JSON, proxy: GeometryProxy?) {
        self.geometryProxy = proxy

        if let frameWidth = json["frame"]["width"].double,
           let frameHeight = json["frame"]["height"].double {
            self.frame = CGSize(width: frameWidth, height: frameHeight)
        } else {
            self.frame = nil
        }

        if json["padding"].exists() {
            self.padding = EdgeInsets(
                top: CGFloat(json["padding"]["top"].doubleValue),
                leading: CGFloat(json["padding"]["leading"].doubleValue),
                bottom: CGFloat(json["padding"]["bottom"].doubleValue),
                trailing: CGFloat(json["padding"]["trailing"].doubleValue)
            )
        } else {
            self.padding = nil
        }

        if json["margin"].exists() {
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

        if (json["cornerRadius"] != JSON.null) {
            self.cornerRadius = CGFloat(json["cornerRadius"].doubleValue)
        } else {
            self.cornerRadius = nil
        }

        if let backgroundJSON = json["background"].dictionaryObject {
            self.backgroundColor = ColorConfig(json: JSON(backgroundJSON))
        } else {
            self.backgroundColor = nil
        }

        if let overlayJSON = json["overlay"].dictionaryObject {
            self.overlay = OverlayConfig(
                cornerRadius: CGFloat(overlayJSON["cornerRadius"] as? Double ?? 0),
                inset: CGFloat(overlayJSON["inset"] as? Double ?? 0),
                strokeColor: ColorConfig(json: JSON(overlayJSON["strokeColor"] ?? [:]) ),
                strokeWidth: CGFloat(overlayJSON["strokeWidth"] as? Double ?? 1)
            )
        } else {
            self.overlay = nil
        }

        if let shadowJSON = json["shadow"].dictionaryObject {
            self.shadow = ShadowConfig(
                color: ColorConfig(json: JSON(shadowJSON["color"] ?? [:]) ),
                radius: CGFloat(shadowJSON["radius"] as? Double ?? 0),
                x: CGFloat(shadowJSON["x"] as? Double ?? 0),
                y: CGFloat(shadowJSON["y"] as? Double ?? 0)
            )
        } else {
            self.shadow = nil
        }

        if let positionJSON = json["position"].dictionaryObject {
            self.position = PositionConfig(
                x: CGFloat(positionJSON["x"] as? Double ?? 0),
                y: CGFloat(positionJSON["y"] as? Double ?? 0)
            )
        } else {
            self.position = nil
        }

        if let geometryPositionJSON = json["geometryPosition"].dictionaryObject {
            self.geometryPosition = GeometryPositionConfig(
                xPercent: CGFloat(geometryPositionJSON["xPercent"] as? Double ?? 0),
                yPercent: CGFloat(geometryPositionJSON["yPercent"] as? Double ?? 0)
            )
        } else {
            self.geometryPosition = nil
        }
    }

    public func body(content: Content) -> some View {
        content
            .modify(frame: frame, alignment: alignment)
            .modify(padding: padding)
            .modify(margin: margin)
            .modify(background: backgroundColor)
            .modify(cornerRadius: cornerRadius)
            .modify(overlay: overlay)
            .modify(shadow: shadow)
            .modify(position: position)
            .modify(geometryPosition: geometryPosition, in: geometryProxy)
    }
}

extension View {
    func margin(_ edges: EdgeInsets) -> some View {
        padding(.top, edges.top)
            .padding(.leading, edges.leading)
            .padding(.bottom, edges.bottom)
            .padding(.trailing, edges.trailing)
    }

    @ViewBuilder
    func modify(position: DynamicViewModifier.PositionConfig?) -> some View {
        if let position = position {
            self.position(x: position.x, y: position.y)
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(geometryPosition: DynamicViewModifier.GeometryPositionConfig?, in geometry: GeometryProxy?) -> some View {
        if let geometryPosition = geometryPosition, let geometry = geometry {
            self.position(
                x: geometry.size.width * geometryPosition.xPercent,
                y: geometry.size.height * geometryPosition.yPercent
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(frame: CGSize?, alignment: Alignment?) -> some View {
        if let frame = frame {
            self.frame(width: frame.width, height: frame.height, alignment: alignment ?? .center)
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(padding: EdgeInsets?) -> some View {
        if let padding = padding {
            self.padding(padding)
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(margin: EdgeInsets?) -> some View {
        if let margin = margin {
            self.margin(margin)
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(background color: ColorConfig?) -> some View {
        if let color = color {
            self.background(Color(hex: color.colorHex).opacity(color.opacity))
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(cornerRadius: CGFloat?) -> some View {
        if let radius = cornerRadius {
            self.cornerRadius(radius)
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(overlay: DynamicViewModifier.OverlayConfig?) -> some View {
        if let overlay = overlay {
            self.overlay(
                RoundedRectangle(cornerRadius: overlay.cornerRadius)
                    .inset(by: overlay.inset)
                    .stroke(Color(hex: overlay.strokeColor.colorHex).opacity(overlay.strokeColor.opacity), lineWidth: overlay.strokeWidth)
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func modify(shadow: DynamicViewModifier.ShadowConfig?) -> some View {
        if let shadow = shadow {
            self.shadow(color: Color(hex: shadow.color.colorHex).opacity(shadow.color.opacity), radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            self
        }
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

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
