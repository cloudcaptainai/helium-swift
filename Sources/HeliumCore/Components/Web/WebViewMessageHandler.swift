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
//    private var lastScrollPosition: CGPoint = .zero
    
    public init(delegateWrapper: ActionsDelegateWrapper) {
        self.delegateWrapper = delegateWrapper
    }
    
//    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
//        lastScrollPosition = scrollView.contentOffset
//    }
//    
//    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
//        if !decelerate {
//            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
//        }
//    }
    
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
//        // Store current scroll position before handling message
//        if let scrollView = (message.webView as? WKWebView)?.scrollView {
//            lastScrollPosition = scrollView.contentOffset
//        }
        print("Message received: \(message.name) at scroll position: \(message.webView?.scrollView.contentOffset ?? .zero)")

        if message.name == "logging" {
            if let body = message.body as? String {
                print("[WebView Log]:", body)
            } else {
                print("[WebView Log]:", message.body)
            }
            replyHandler(nil, nil)
//            DispatchQueue.main.async {
//                if let scrollView = (message.webView as? WKWebView)?.scrollView {
//                    scrollView.setContentOffset(self.lastScrollPosition, animated: false)
//                }
//            }
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
                    respond(["status": "failed"])
                }
                
            case "restore-purchases":
                if let result = await self.delegateWrapper?.restorePurchases() {
                    respond(["status": "success"])
                } else {
                    respond(["status": "failed"])
                }
                
            case "open-link":
                if let url = data["url"] as? String {
//                    self.delegateWrapper?.openLink(url: url, option: data["option"] as? String)
                    respond(["status": "success"])
                }
                
            case "set-variable":
                if let variable = data["variable"] as? String,
                   let value = data["value"] {
//                    self.delegateWrapper?.setVariable(name: variable, value: value)
                    respond(["status": "success"])
                }
                
            case "analytics-event":
                if let eventName = data["name"] as? String {
//                    self.delegateWrapper?.logAnalyticsEvent(
//                        name: eventName,
//                        properties: data["properties"] as? [String: Any]
//                    )
                    respond(["status": "success"])
                }
                
            case "navigate":
                if let target = data["target"] as? String {
//                    self.delegateWrapper?.navigate(
//                        to: target,
//                        params: data["params"] as? [String: Any]
//                    )
                    respond(["status": "success"])
                }
                
            case "custom":
                if let name = data["name"] as? String {
//                    self.delegateWrapper?.handleCustomAction(name: name)
                    respond(["status": "success"])
                }
                
            case "dismiss":
                self.delegateWrapper?.dismiss()
                respond(["status": "success"])
                
            default:
                respond(["message": "Unknown message type"])
            }
        }
        print("Message handling complete for: \(message.name)")
    }
}

// Add to your MessageHandler class to capture scroll behavior
extension WebViewMessageHandler: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        print("Scroll position changed: \(scrollView.contentOffset)")
    }
    
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        print("Begin dragging at: \(scrollView.contentOffset)")
    }
    
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        print("End dragging at: \(scrollView.contentOffset), will decelerate: \(decelerate)")
    }
}

extension WebViewMessageHandler: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        print("WebView did commit navigation")
    }
    
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        print("Navigation requested: \(navigationAction.navigationType)")
        return .allow
    }
}