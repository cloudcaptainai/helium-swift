import SwiftUI
import SwiftyJSON

public struct DynamicStackComponent: View {
    let stackType: StackType
    let spacing: CGFloat?
    let alignment: Alignment
    let children: [StackChild]
    let viewModifierProps: JSON
    let actionConfig: ActionConfig?
    let geometryProxy: GeometryProxy?
    
    enum StackType: String {
        case vStack, hStack, zStack
    }
    
    enum StackChild {
        case stack(DynamicStackComponent)
        case component(DynamicPositionedComponent)
    }
    
    public init(json: JSON, geometryProxy: GeometryProxy? = nil) {
        stackType = StackType(rawValue: json["type"].stringValue) ?? .vStack
        spacing = json["spacing"].double.map { CGFloat($0) }
        alignment = DynamicStackComponent.parseAlignment(json["alignment"].stringValue)
        viewModifierProps = json["viewModifierProps"]
        self.geometryProxy = geometryProxy;
        
        children = json["children"].arrayValue.map { childJSON in
            if childJSON["type"].string == "vStack" || childJSON["type"].string == "hStack" || childJSON["type"].string == "zStack" {
                return .stack(DynamicStackComponent(json: childJSON))
            } else {
                return .component(DynamicPositionedComponent(json: childJSON))
            }
        }
        if let actionJSON = json["actionConfig"].dictionaryObject {
            self.actionConfig = ActionConfig(json: JSON(actionJSON))
        } else {
            self.actionConfig = nil
        }
    }
    
    static func parseAlignment(_ string: String) -> Alignment {
        switch string.lowercased() {
        case "topleft", "topleading": return .topLeading
        case "top": return .top
        case "topright", "toptrailing": return .topTrailing
        case "left", "leading": return .leading
        case "center": return .center
        case "right", "trailing": return .trailing
        case "bottomleft", "bottomleading": return .bottomLeading
        case "bottom": return .bottom
        case "bottomright", "bottomtrailing": return .bottomTrailing
        default: return .center
        }
    }
    
    public var body: some View {
        Group {
            switch stackType {
            case .vStack:
                VStack(alignment: alignment.horizontal, spacing: spacing) {
                    childrenView
                }
            case .hStack:
                HStack(alignment: alignment.vertical, spacing: spacing) {
                    childrenView
                }
            case .zStack:
                ZStack(alignment: alignment) {
                    childrenView
                }
            }
        }
        .modifier(ActionModifier(config: actionConfig))
        .modifier(DynamicViewModifier(json: viewModifierProps, proxy: geometryProxy))
    }
    
    @ViewBuilder
    var childrenView: some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            switch child {
            case .stack(let stackComponent):
                stackComponent
            case .component(let component):
                component
            }
        }
    }
}

extension Alignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading, .topLeading, .bottomLeading: return .leading
        case .trailing, .topTrailing, .bottomTrailing: return .trailing
        default: return .center
        }
    }
    
    var vertical: VerticalAlignment {
        switch self {
        case .top, .topLeading, .topTrailing: return .top
        case .bottom, .bottomLeading, .bottomTrailing: return .bottom
        default: return .center
        }
    }
}
