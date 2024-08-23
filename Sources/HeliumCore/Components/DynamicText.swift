import SwiftUI
import SwiftyJSON
import Foundation

public struct FontConfig {
    let fontType: String
    let fontName: String?
    
    init(json: JSON) {
        fontType = json["fontType"].stringValue
        fontName = json["fontName"].string
    }
}

public struct TextComponent {
    let text: String
    let color: String
    let size: Int
    let weight: String
    let fontConfig: FontConfig
    
    public init?(json: JSON) {
        guard let text = json["text"].string,
              let color = json["color"].string,
              let size = json["size"].int,
              let weight = json["weight"].string else {
            return nil
        }
        
        self.text = text
        self.color = color
        self.size = size
        self.weight = weight
        self.fontConfig = FontConfig(json: json["fontConfig"])
    }
}

public struct DynamicTextComponent: View {
    let components: [TextComponent]
    let multilineTextAlignment: TextAlignment
    let frameWidth: CGFloat?
    let frameHeight: CGFloat?
    let frameAlignment: Alignment?
    
    public init(json: JSON) {
        self.components = json["components"].arrayValue.compactMap { TextComponent(json: $0) }
        self.multilineTextAlignment = .center
        self.frameWidth = nil
        self.frameHeight = nil
        self.frameAlignment = nil
    }
    
    public var body: some View {
        components.reduce(Text("")) { result, component in
            result + Text(component.text)
                .foregroundColor(Color(hex: component.color))
                .font(font(for: component))
        }
        .multilineTextAlignment(multilineTextAlignment)
        .modifier(OptionalFrameModifier(width: frameWidth, height: frameHeight, alignment: frameAlignment))
    }
    
    private func font(for component: TextComponent) -> Font {
        let size = CGFloat(component.size)
        let weight = fontWeight(from: component.weight)
        
        switch component.fontConfig.fontType.lowercased() {
        case "system":
            return .system(size: size, weight: weight)
        case "bold":
            return .system(size: size, weight: .bold)
        case "italic":
            return .system(size: size, weight: weight).italic()
        case "custom":
            if let customFontName = component.fontConfig.fontName {
                return .custom(customFontName, size: size)
            } else {
                return .system(size: size, weight: weight)
            }
        default:
            return .system(size: size, weight: weight)
        }
    }
    
    private func fontWeight(from string: String) -> Font.Weight {
        switch string.lowercased() {
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
}

struct OptionalFrameModifier: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment?
    
    func body(content: Content) -> some View {
        if let width = width, let height = height, let alignment = alignment {
            content.frame(width: width, height: height, alignment: alignment)
        } else if let width = width, let height = height {
            content.frame(width: width, height: height)
        } else if let width = width, let alignment = alignment {
            content.frame(width: width, alignment: alignment)
        } else if let height = height, let alignment = alignment {
            content.frame(height: height, alignment: alignment)
        } else if let width = width {
            content.frame(width: width)
        } else if let height = height {
            content.frame(height: height)
        } else if let alignment = alignment {
            content.frame(alignment: alignment)
        } else {
            content
        }
    }
}

