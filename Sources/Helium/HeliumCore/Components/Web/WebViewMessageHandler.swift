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
    
    func setActionsDelegate(delegateWrapper: ActionsDelegateWrapper) {
        self.delegateWrapper = delegateWrapper
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {


        if message.name == "logging" {
            return
        }
        
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String,
              let messageId = dict["messageId"] as? String,
              let data = dict["data"] as? [String: Any] else {
            HeliumLog.log(.warn, category: .ui, "Invalid WebView message format received")
            replyHandler(nil, "Invalid message format")
            return
        }
        HeliumLog.log(.trace, category: .ui, "WebView message received", metadata: ["type": type])
        
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
                if let productId = data["productId"] as? String {
                    self.delegateWrapper?.selectProduct(productId: productId)
                    respond(["status": "success", "selectedProduct": productId]);
                }
            case "cta-pressed":
                if let componentName = data["componentName"] as? String {
                    self.delegateWrapper?.onCTAPress(contentComponentName: componentName)
                    respond(["status": "success"])
                }
                
            case "subscribe":
                if let productId = data["product"] as? String {
                    self.delegateWrapper?.selectProduct(productId: productId)
                }
                if let result = await self.delegateWrapper?.makePurchase() {
                    switch result {
                    case .purchased:
                        respond(["status": "purchased"]);
                        self.delegateWrapper?.dismissAll(dispatchEvent: false);
                    case .cancelled:
                        respond(["status": "cancelled"])
                    case .pending:
                        respond(["status": "pending"])
                    case .restored:
                        respond(["status": "restored"])
                        self.delegateWrapper?.dismissAll(dispatchEvent: false);
                    case .failed:
                        respond(["status": "failed"])
                    }
                } else {
                    respond(["status": "failed"])
                }
                
            case "restore-purchases":
                if let result = await self.delegateWrapper?.restorePurchases(), result == true {
                    respond(["status": "success"])
                    self.delegateWrapper?.dismissAll(dispatchEvent: false);
                } else {
                    respond(["status": "failed"])
                }
                
            case "navigate":
                if let target = data["target"] as? String {

                    await UIApplication.shared.open(URL(string: target)!);
                    respond(["status": "success"])
                }
                
            case "show-secondary-paywall":
                if let paywallUuid = data["uuid"] as? String {
                    self.delegateWrapper?.showSecondaryPaywall(uuid: paywallUuid)
                    respond(["status": "success"])
                }
                
            case "dismiss":
                self.delegateWrapper?.dismiss()
                respond(["status": "success"])
                
            case "dismiss-all":
                self.delegateWrapper?.dismissAll()
                respond(["status": "success"])
                
            case "custom-action":
                if let actionName = data["actionName"] as? String,
                   let params = data["params"] as? [String: Any] {
                    // Convert Objective-C types to Swift types
                    let swiftParams = convertToSwiftTypes(params) as? [String: Any] ?? params
                    self.delegateWrapper?.onCustomAction(actionName: actionName, params: swiftParams)
                    respond(["status": "success"])
                } else {
                    respond(["status": "error", "message": "Missing actionName or params"])
                }
                
            default:
                respond(["message": "Unknown message type"])
            }
        }
    }
    
    /// Converts Objective-C types from JavaScript bridge to native Swift types
    private func convertToSwiftTypes(_ value: Any) -> Any {
        // Handle NSArray -> Swift Array
        if let nsArray = value as? NSArray {
            return nsArray.map { convertToSwiftTypes($0) }
        }

        // Handle NSDictionary -> Swift Dictionary
        if let nsDict = value as? NSDictionary {
            var swiftDict = [String: Any]()
            for (key, val) in nsDict {
                if let keyStr = key as? String {
                    swiftDict[keyStr] = convertToSwiftTypes(val)
                }
            }
            return swiftDict
        }

        // Handle NSNumber (booleans come as 0/1 NSNumbers from JS)
        if let nsNumber = value as? NSNumber {
            // Check if it's a boolean by looking at the objCType
            let objCType = String(cString: nsNumber.objCType)
            if objCType == "c" || objCType == "B" {
                // It's a boolean
                return nsNumber.boolValue
            }

            // For all non-boolean numbers, return as Double
            // This matches JavaScript's single number type (64-bit float)
            return nsNumber.doubleValue
        }

        // Handle NSString -> Swift String
        if let nsString = value as? NSString {
            return nsString as String
        }

        // Handle NSDate -> Date
        if let nsDate = value as? NSDate {
            return nsDate as Date
        }

        // Return other types as-is (including NSNull)
        return value
    }
    
}


extension WebViewMessageHandler: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        HeliumLog.log(.trace, category: .ui, "WebView did commit navigation")
    }
    
    private func shouldOpenExternally(url: URL) -> Bool {
        // For now, open all urls externally.
        return true;
    }
    
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, shouldOpenExternally(url: url) {
            UIApplication.shared.open(url);
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        HeliumLog.log(.debug, category: .ui, "WebView finished loading")
        NotificationCenter.default.post(name: .webViewContentLoaded, object: self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        HeliumLog.log(.error, category: .ui, "WebView failed to load", metadata: ["error": error.localizedDescription])
        NotificationCenter.default.post(name: .webViewContentLoadFail, object: self)
    }
    
}

// Add notification name
extension Notification.Name {
   static let webViewContentLoaded = Notification.Name("webViewContentLoaded")
   static let webViewContentLoadFail = Notification.Name("webViewContentLoadFail")
}
