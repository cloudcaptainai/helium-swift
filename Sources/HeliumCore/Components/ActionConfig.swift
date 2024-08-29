import SwiftyJSON

public struct ActionConfig {
    enum ActionEvent {
        case dismiss
        case selectProduct(productKey: String)
        case subscribe(productKey: String)
        case showScreen(screenId: String)
    }
    
    let actionEvent: ActionEvent
    
    public init?(json: JSON) {
        guard let actionType = json["type"].string else { return nil }
        
        switch actionType {
        case "dismiss":
            self.actionEvent = .dismiss
        case "selectProduct":
            guard let productKey = json["productKey"].string else { return nil }
            self.actionEvent = .selectProduct(productKey: productKey)
        case "subscribe":
            guard let productKey = json["productKey"].string else { return nil }
            self.actionEvent = .subscribe(productKey: productKey)
        case "showScreen":
            guard let screenId = json["screenId"].string else { return nil }
            self.actionEvent = .showScreen(screenId: screenId)
        default:
            return nil
        }
    }
}