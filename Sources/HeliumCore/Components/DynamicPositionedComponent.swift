import Foundation
import SwiftUI
import SwiftyJSON

public struct DynamicPositionedComponent: View {
    let type: String
    let componentProps: JSON
    let viewModifierProps: JSON
    let overlayComponent: OverlayBackgroundWrapper?
    let backgroundComponent: OverlayBackgroundWrapper?
    let actionConfig: ActionConfig?
    let geometryProxy: GeometryProxy?
    
    public init(json: JSON, geometryProxy: GeometryProxy? = nil) {
        self.type = json["type"].stringValue
        self.componentProps = json["componentProps"]
        self.viewModifierProps = json["viewModifierProps"]
        
        if let overlayJSON = json["overlayComponent"].dictionaryObject {
            self.overlayComponent = OverlayBackgroundWrapper(json: JSON(overlayJSON))
        } else {
            self.overlayComponent = nil
        }
        
        if let backgroundJSON = json["backgroundComponent"].dictionaryObject {
            self.backgroundComponent = OverlayBackgroundWrapper(json: JSON(backgroundJSON))
        } else {
            self.backgroundComponent = nil
        }
        
        if let actionJSON = json["actionConfig"].dictionaryObject {
            self.actionConfig = ActionConfig(json: JSON(actionJSON))
        } else {
            self.actionConfig = nil
        }
        self.geometryProxy = geometryProxy;
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
        case "rectangle":
            DynamicRectangle(json: componentProps)
        case "roundedRectangle":
            DynamicRoundedRectangle(json: componentProps)
        case "text":
            DynamicTextComponent(json: componentProps)
        case "vStack", "hStack", "zStack":
            DynamicStackComponent(json: JSON(["type": type, "children": componentProps]))
        default:
            Text("Unsupported component type: \(type)")
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
