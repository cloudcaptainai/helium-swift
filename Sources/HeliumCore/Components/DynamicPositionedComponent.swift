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
    @EnvironmentObject var actionsDelegate: ActionsDelegateWrapper
    let componentId: Int
    let componentName: String
    let componentType: ComponentType
    let viewModifierProps: JSON
    let overlayComponent: ComponentWrapper?
    let backgroundComponent: ComponentWrapper?
    let actionConfig: ActionConfig?
    let geometryProxy: GeometryProxy?
    let isHighlighted: Bool
    

    public init(json: JSON, geometryProxy: GeometryProxy? = nil) {
        self.componentType = ComponentType(json: json, geometryProxy: geometryProxy)
        
        self.componentName = json["componentName"].string ?? "component_\(json["type"].string ?? "undefinedType")_no_name_\(UUID().uuidString)";
        self.componentId = json["componentId"].int ?? -1;
        
        self.viewModifierProps = json["viewModifierProps"]
        
        if let overlayJSON = json["overlayComponent"].dictionaryObject {
            self.overlayComponent = ComponentWrapper(json: JSON(overlayJSON), geometryProxy: geometryProxy)
        } else {
            self.overlayComponent = nil
        }
        
        if let backgroundJSON = json["backgroundComponent"].dictionaryObject {
            self.backgroundComponent = ComponentWrapper(json: JSON(backgroundJSON), geometryProxy: geometryProxy)
        } else {
            self.backgroundComponent = nil
        }
        
        if let actionJSON = json["actionConfig"].dictionaryObject {
            self.actionConfig = ActionConfig(json: JSON(actionJSON))
        } else {
            self.actionConfig = nil
        }
        
        self.geometryProxy = geometryProxy
        self.isHighlighted = json["isInteractive"].bool ?? false;
    }
    
    public var body: some View {
        componentView
            .background(backgroundComponent?.view)
            .overlay(overlayComponent?.view)
            .modifier(DynamicViewModifier(json: viewModifierProps, proxy: geometryProxy))
            .modifier(ActionModifier(actionConfig: self.actionConfig, actionsDelegate: actionsDelegate, contentComponentName: componentName))
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
        
    
    init(json: JSON, geometryProxy: GeometryProxy?) {
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
            self = .stack(.vStack, json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0, geometryProxy: geometryProxy) })
        case "hStack":
            self = .stack(.hStack, json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0, geometryProxy: geometryProxy) })
        case "zStack":
            self = .stack(.zStack, json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0, geometryProxy: geometryProxy) })
        case "spacer":
            self = .spacer(json["componentProps"])
        case "scrollView":
            self = .scrollView(json["componentProps"], json["componentProps"]["children"].arrayValue.map { ComponentWrapper(json: $0, geometryProxy: geometryProxy) })
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
    
    init(json: JSON, geometryProxy: GeometryProxy?) {
        self.component = DynamicPositionedComponent(json: json, geometryProxy: geometryProxy);
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


struct ActionModifier: ViewModifier {
    let actionConfig: ActionConfig?
    let actionsDelegate: ActionsDelegateWrapper
    let contentComponentName: String
    
    public init(actionConfig: ActionConfig?, actionsDelegate: ActionsDelegateWrapper, contentComponentName: String) {
        self.actionConfig = actionConfig
        self.actionsDelegate = actionsDelegate
        self.contentComponentName = contentComponentName
    }
    
    func body(content: Content) -> some View {
        if let actionConfig = self.actionConfig {
            Button(action: {
                performAction(actionConfig.actionEvent)
            }) {
                content
            }
        } else {
            content
        }
    }
    
    private func performAction(_ event: ActionConfig.ActionEvent) {
        actionsDelegate.onCTAPress(contentComponentName: contentComponentName)
        switch event {
            case .dismiss:
                actionsDelegate.dismiss();
            case .selectProduct(let productKey):
                actionsDelegate.selectProduct(productId: productKey)
            case .subscribe:
                Task {
                    await actionsDelegate.makePurchase()
                }
            case .showScreen(let screenId):
                actionsDelegate.showScreen(screenId: screenId);
            case .customAction(let actionKey):
                // Handled by cta pressed
                return;
            default:
                return;
                
        }
    }
}
