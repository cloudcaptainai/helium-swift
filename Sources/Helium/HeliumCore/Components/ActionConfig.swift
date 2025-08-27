
public struct ActionConfig {
    enum ActionEvent: Equatable {
        case dismiss
        case selectProduct(productKey: String)
        case subscribe
        case showScreen(screenId: String)
        case customAction(actionKey: String)
    }
    
    let actionEvent: ActionEvent
    
    public init?(json: JSON) {
        guard let actionType = json["type"].string else { return nil }
        
        switch actionType {
        case "dismiss":
            self.actionEvent = .dismiss
            break;
        case "selectProduct":
            guard let productKey = json["productKey"].string else { return nil }
            self.actionEvent = .selectProduct(productKey: productKey)
            break;
        case "subscribe":
            self.actionEvent = .subscribe
            break;
        case "showScreen":
            guard let screenId = json["screenId"].string else { return nil }
            self.actionEvent = .showScreen(screenId: screenId)
            break;
        case "customAction":
            guard let keyName = json["actionKey"].string else { return nil }
            self.actionEvent = .customAction(actionKey: keyName)
            break;
        default:
            self.actionEvent = .customAction(actionKey: "unsassigned");
        }
    }
}
