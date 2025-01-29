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
                if let productId = data["product"] as? String {
                    self.delegateWrapper?.selectProduct(productId: productId)
                }
                if let result = await self.delegateWrapper?.makePurchase() {
                    switch result {
                    case .purchased:
                        respond(["status": "purchased"]);
                        self.delegateWrapper?.dismiss();
                    case .cancelled:
                        respond(["status": "cancelled"])
                    case .pending:
                        respond(["status": "pending"])
                    case .restored:
                        respond(["status": "restored"])
                        self.delegateWrapper?.dismiss();
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
                    respond(["status": "success"])
                }
                
            case "set-variable":
                if let variable = data["variable"] as? String,
                   let value = data["value"] {
                    respond(["status": "success"])
                }
                
            case "analytics-event":
                if let eventName = data["name"] as? String {

                    respond(["status": "success"])
                }
                
            case "navigate":
                if let target = data["target"] as? String {

                    await UIApplication.shared.open(URL(string: target)!);
                    respond(["status": "success"])
                }
                
            case "custom":
                if let name = data["name"] as? String {
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
          webView.evaluateJavaScript("document.readyState") { (result, error) in
              if let readyState = result as? String, readyState == "complete" {
                  NotificationCenter.default.post(name: .webViewContentLoaded, object: nil)
              }
          }
      }
}

// Add notification name
extension Notification.Name {
   static let webViewContentLoaded = Notification.Name("webViewContentLoaded")
}
