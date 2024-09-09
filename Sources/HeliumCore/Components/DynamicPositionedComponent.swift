import Foundation
import SwiftUI
import SwiftyJSON

func parseAlignment(_ string: String) -> Alignment {
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

public struct DynamicPositionedComponent: View {
    let componentType: ComponentType
    let viewModifierProps: JSON
    let overlayComponent: ComponentWrapper?
    let backgroundComponent: ComponentWrapper?
    let actionConfig: ActionConfig?
    let geometryProxy: GeometryProxy?

    public init(json: JSON, geometryProxy: GeometryProxy? = nil) {
        self.componentType = ComponentType(json: json)
        self.viewModifierProps = json["viewModifierProps"]
        
        if let overlayJSON = json["overlayComponent"].dictionaryObject {
            self.overlayComponent = ComponentWrapper(json: JSON(overlayJSON))
        } else {
            self.overlayComponent = nil
        }
        
        if let backgroundJSON = json["backgroundComponent"].dictionaryObject {
            self.backgroundComponent = ComponentWrapper(json: JSON(backgroundJSON))
        } else {
            self.backgroundComponent = nil
        }
        
        if let actionJSON = json["actionConfig"].dictionaryObject {
            self.actionConfig = ActionConfig(json: JSON(actionJSON))
        } else {
            self.actionConfig = nil
        }
        
        self.geometryProxy = geometryProxy
    }
    
    public var body: some View {
        componentView
            .background(backgroundComponent?.view)
            .overlay(overlayComponent?.view)
            .modifier(DynamicViewModifier(json: viewModifierProps, proxy: geometryProxy))
            .modifier(ActionModifier(config: actionConfig))
    }
    
    @ViewBuilder
    private var componentView: some View {
        switch componentType {
        case .linearGradient(let props):
            DynamicLinearGradient(json: props)
        case .image(let props):
            DynamicImage(json: props)
        case .rectangle(let props):
            DynamicRectangle(json: props)
        case .roundedRectangle(let props):
            DynamicRoundedRectangle(json: props)
        case .text(let props):
            DynamicTextComponent(json: props)
        case .stack(let type, let props, let children):
            createStack(type: type, props: props, children: children)
        case .animation(let props):
            DynamicAnimation(json: props)
        case .spacer(let props):
            DynamicSpacer(json: props)
        case .scrollView(let props, let children):
            DynamicScrollView(json: props) {
                ForEach(children.indices, id: \.self) { index in
                    children[index].view
                }
            }
        }
        }
    }
    
    @ViewBuilder
   private func createStack(type: StackType, props: JSON, children: [ComponentWrapper]) -> some View {
       let spacing = props["spacing"].double.map { CGFloat($0) }
       let alignment = parseAlignment(props["alignment"].stringValue)
       
       switch type {
       case .vStack:
           VStack(alignment: alignment.horizontal, spacing: spacing) {
               ForEach(children.indices, id: \.self) { index in
                   children[index].view
               }
           }
       case .hStack:
           HStack(alignment: alignment.vertical, spacing: spacing) {
               ForEach(children.indices, id: \.self) { index in
                   children[index].view
               }
           }
       case .zStack:
           ZStack(alignment: alignment) {
               ForEach(children.indices, id: \.self) { index in
                   children[index].view
               }
           }
       }
}

indirect enum ComponentType {
    case linearGradient(JSON)
    case image(JSON)
    case rectangle(JSON)
    case roundedRectangle(JSON)
    case text(JSON)
    case stack(StackType, JSON, [ComponentWrapper])
    case animation(JSON)
    case spacer(JSON)
    case scrollView(JSON, [ComponentWrapper])
        
    
    init(json: JSON) {
        switch json["type"].stringValue {
        case "linearGradient":
            self = .linearGradient(json["componentProps"])
        case "image":
            self = .image(json["componentProps"])
        case "rectangle":
            self = .rectangle(json["componentProps"])
        case "roundedRectangle":
            self = .roundedRectangle(json["componentProps"])
        case "text":
            self = .text(json["componentProps"])
        case "animation":
            self = .animation(json["componentProps"])
        case "vStack":
            self = .stack(.vStack, json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0) })
        case "hStack":
            self = .stack(.hStack, json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0) })
        case "zStack":
            self = .stack(.zStack, json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0) })
        case "spacer":
            self = .spacer(json["componentProps"])
        case "scrollView":
            self = .scrollView(json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0) })
        default:
            self = .text(JSON(["text": "Unsupported component type"]))
        }
    }
}

enum StackType {
    case vStack, hStack, zStack
}

class ComponentWrapper {
    let component: DynamicPositionedComponent
    
    init(json: JSON) {
        self.component = DynamicPositionedComponent(json: json)
    }
    
    var view: some View {
        component
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


class OverlayBackgroundWrapper {
    let component: DynamicPositionedComponent
    
    init(json: JSON) {
        self.component = DynamicPositionedComponent(json: json)
    }
    
    var view: some View {
        component
    }
}


struct ActionModifier: ViewModifier {
    let config: ActionConfig?
    
    func body(content: Content) -> some View {
        if let config = config {
            Button(action: {
                performAction(config.actionEvent)
            }) {
                content
            }
        } else {
            content
        }
    }
    
    private func performAction(_ event: ActionConfig.ActionEvent) {
        switch event {
        case .dismiss:
            print("Dismiss action")
        case .selectProduct(let productKey):
            print("Select product: \(productKey)")
        case .subscribe(let productKey):
            print("Subscribe to product: \(productKey)")
        case .showScreen(let screenId):
            print("Show screen: \(screenId)")
        }
    }
}
