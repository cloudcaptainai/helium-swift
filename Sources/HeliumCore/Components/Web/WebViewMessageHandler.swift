//
//  File.swift
//  
//
//  Created by Anish Doshi on 11/26/24.
//

import Foundation
import WebKit



public class WebViewMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var delegateWrapper: ActionsDelegateWrapper?
    
    public init(delegateWrapper: ActionsDelegateWrapper) {
        self.delegateWrapper = delegateWrapper
    }
    
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        if message.name == "logging" {
            if let body = message.body as? String {
                print("[WebView Log]:", body)
            } else {
                print("[WebView Log]:", message.body)
            }
            replyHandler(nil, nil)
            return
        }
        
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String,
              let messageId = dict["messageId"] as? String,
              let data = dict["data"] as? [String: Any] else {
            replyHandler(nil, "Invalid message format")
            return
        }
        
        // Helper function that matches JS expected format
        let respond = { (responseData: [String: Any]) in
            let wrappedResponse: [String: Any] = [
                "messageId": messageId,
                "response": responseData
            ]
            replyHandler(wrappedResponse, nil)
        }

        Task { @MainActor in
            switch type {
            case "select-product":
                if let productId = data["product"] as? String {
                    self.delegateWrapper?.selectProduct(productId: productId)
                    respond(["status": "success", "selectedProduct": productId]);
                }
                
            case "subscribe":
                if let result = await self.delegateWrapper?.makePurchase() {
                    switch result {
                    case .purchased:
                        respond(["status": "purchased"])
                    case .cancelled:
                        respond(["status": "cancelled"])
                    case .pending:
                        respond(["status": "pending"])
                    case .restored:
                        respond(["status": "restored"])
                    case .failed:
                        respond(["status": "failed"])
                    }
                } else {
                    replyHandler(["status": "failed"], nil)
                }
                
            case "restore-purchases":
                if let result = await self.delegateWrapper?.restorePurchases() {
                    replyHandler(["status": "success"], nil)
                } else {
                    replyHandler(["status": "failed"], nil)
                }
                
            case "open-link":
                if let url = data["url"] as? String {
//                    self.delegateWrapper?.openLink(url: url, option: data["option"] as? String)
                    replyHandler(["status": "success"], nil)
                }
                
            case "set-variable":
                if let variable = data["variable"] as? String,
                   let value = data["value"] {
//                    self.delegateWrapper?.setVariable(name: variable, value: value)
                    replyHandler(["status": "success"], nil)
                }
                
            case "analytics-event":
                if let eventName = data["name"] as? String {
//                    self.delegateWrapper?.logAnalyticsEvent(
//                        name: eventName,
//                        properties: data["properties"] as? [String: Any]
//                    )
                    replyHandler(["status": "success"], nil)
                }
                
            case "navigate":
                if let target = data["target"] as? String {
//                    self.delegateWrapper?.navigate(
//                        to: target,
//                        params: data["params"] as? [String: Any]
//                    )
                    replyHandler(["status": "success"], nil)
                }
                
            case "custom":
                if let name = data["name"] as? String {
//                    self.delegateWrapper?.handleCustomAction(name: name)
                    replyHandler(["status": "success"], nil)
                }
                
            case "dismiss":
                self.delegateWrapper?.dismiss()
                replyHandler(["status": "success"], nil)
                
            default:
                replyHandler(nil, "Unknown message type")
            }
        }
    }
}
