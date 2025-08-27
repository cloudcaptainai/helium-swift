import SwiftUI
import Foundation

public struct FontConfig {
    let fontType: String
    let fontName: String?
    let designString: String?
    let fontURL: String?
    
    init(json: JSON) {
        fontType = json["fontType"].stringValue
        fontName = json["fontName"].string
        designString = json["design"].string
        fontURL = json["fontURL"].string
    }
}

public struct TextComponent {
    let text: String
    let colorConfig: ColorConfig
    let size: Int
    let weight: String
    let fontConfig: FontConfig

    public init?(json: JSON) {
        guard let text = json["text"].string,
              let size = json["size"].int,
              let weight = json["weight"].string else {
            return nil
        }

        self.text = text
        self.colorConfig = ColorConfig(json: json["colorConfig"])
        self.size = size
        self.weight = weight
        self.fontConfig = FontConfig(json: json["fontConfig"])
    }
}

public struct DynamicTextComponent: View {
    let components: [TextComponent]
    let multilineTextAlignment: TextAlignment
    let lineSpacing: CGFloat?

    public init(json: JSON) {
        self.components = json["components"].arrayValue.compactMap { TextComponent(json: $0) }
        self.multilineTextAlignment = Self.textAlignment(from: json["multilineTextAlignment"].stringValue)
        self.lineSpacing = json["lineSpacing"].int.map { CGFloat($0) }
    }

    public var body: some View {
        let text = if components.count == 1 {
            Text(verbatim: components[0].text)
                .foregroundColor(Color(hex: components[0].colorConfig.colorHex, opacity: components[0].colorConfig.opacity))
                .font(font(for: components[0]))
        } else {
            components.reduce(Text("")) { result, component in
                result + Text(component.text)
                    .foregroundColor(Color(hex: component.colorConfig.colorHex, opacity: component.colorConfig.opacity))
                    .font(font(for: component))
            }
        }
        
        return text
            .multilineTextAlignment(multilineTextAlignment)
            .lineSpacing(lineSpacing ?? 0)
            .fixedSize(horizontal: false, vertical: true)  // This line was added
    }

    private func font(for component: TextComponent) -> Font {
        let size = CGFloat(component.size)
        let weight = fontWeight(from: component.weight)

        var font: Font

        switch component.fontConfig.fontType.lowercased() {
        case "system":
            font = .system(size: size, weight: weight, design: fontDesign(from: component.fontConfig.designString))
        case "custom":
            if let customFontName = component.fontConfig.fontName {
                font = .custom(customFontName, size: size).weight(weight)
            } else {
                font = .system(size: size, weight: weight)
            }
        default:
            font = .system(size: size, weight: weight)
        }

        // Apply italic if needed
        if component.fontConfig.fontType.lowercased() == "italic" {
            font = font.italic()
        }

        return font
    }

    private func fontWeight(from string: String) -> Font.Weight {
        switch string.lowercased() {
        case "heavy":
            return .heavy
        case "bold":
            return .bold
        case "semibold":
            return .semibold
        case "medium":
            return .medium
        case "light":
            return .light
        default:
            return .regular
        }
    }

    private func fontDesign(from string: String?) -> Font.Design {
        guard let string = string else { return .default }
        switch string.lowercased() {
        case "monospaced":
            return .monospaced
        case "rounded":
            return .rounded
        case "serif":
            return .serif
        default:
            return .default
        }
    }

    private static func textAlignment(from string: String) -> TextAlignment {
        switch string.lowercased() {
        case "leading":
            return .leading
        case "trailing":
            return .trailing
        case "center":
            return .center
        default:
            return .center
        }
    }
}
