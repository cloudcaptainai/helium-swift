import SwiftUI
import WebKit
import SwiftyJSON

public struct DynamicWebView: View {
    let filePath: String
    let triggerName: String?
    let actionConfig: JSON
    let templateConfig: JSON
    var actionsDelegate: ActionsDelegateWrapper
    
    private var messageHandler: WebViewMessageHandler?
    @State private var webView: WKWebView?
    
    public init(json: JSON, actionsDelegate: ActionsDelegateWrapper, triggerName: String?) {
        self.filePath = HeliumAssetManager.shared.localPathForURL(bundleURL: json["bundleURL"].stringValue)!
        self.actionsDelegate = actionsDelegate
        self.messageHandler = WebViewMessageHandler(delegateWrapper: actionsDelegate)
        self.triggerName = triggerName
        self.actionConfig = json["actionConfig"].type == .null ? JSON([:]) : json["actionConfig"]
        self.templateConfig = json["templateConfig"].type == .null ? JSON([:]) : json["templateConfig"]
    }
    
    public var body: some View {
        Group {
            if let webView = webView {
                WebViewRepresentable(webView: webView)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            loadWebView()
        }
        .onDisappear {
            webView?.stopLoading()
            webView = nil
        }
    }

    private func loadWebView() {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        if (messageHandler == nil) { return }
        
        // Add message handlers
        contentController.addScriptMessageHandler(
            messageHandler!,
            contentWorld: .page,
            name: "paywallHandler"
        )
        contentController.addScriptMessageHandler(
            messageHandler!,
            contentWorld: .page,
            name: "logging"
        )
        
        // Create the combined script for context and logging
        do {
            let currentContext = createHeliumContext(triggerName: triggerName)
            let contextJSON = JSON(parseJSON: try currentContext.toJSON())
            let customContextValues = HeliumPaywallDelegateWrapper.shared.getCustomVariableValues()

            let customData = try JSONSerialization.data(withJSONObject: customContextValues.compactMapValues { $0 })
            let customJSON = try JSON(data: customData)

            var mergedContext = contextJSON
            for (key, value) in customJSON {
                mergedContext[key] = value
            }

            let combinedJSON = JSON([
                "contextualValues": mergedContext,
                "templateConfig": templateConfig,
                "actionConfig": actionConfig,
                "analyticsConfig": JSON([:])
            ])

            let combinedScript = WKUserScript(
                source: """
                // Set up console.log handler
                console.log = function(...args) {
                    window.webkit.messageHandlers.logging.postMessage(args.map(arg =>
                        typeof arg === 'object' ? JSON.stringify(arg) : String(arg)
                    ).join(' '));
                };
                
                // Set up console.error handler
                console.error = function(...args) {
                    window.webkit.messageHandlers.logging.postMessage('[ERROR] ' + args.map(arg =>
                        typeof arg === 'object' ? JSON.stringify(arg) : String(arg)
                    ).join(' '));
                };

                // Set up global error handler
                window.onerror = function(message, source, lineno, colno, error) {
                    const errorInfo = {
                        message: message,
                        source: source,
                        line: lineno,
                        column: colno,
                        stack: error?.stack
                    };
                    window.webkit.messageHandlers.logging.postMessage('[UNCAUGHT ERROR] ' + JSON.stringify(errorInfo));
                    return false; // Let the error propagate
                };

                // Set up unhandled promise rejection handler
                window.onunhandledrejection = function(event) {
                    const errorInfo = {
                        message: event.reason?.message || event.reason,
                        stack: event.reason?.stack
                    };
                    window.webkit.messageHandlers.logging.postMessage('[UNHANDLED PROMISE REJECTION] ' + JSON.stringify(errorInfo));
                };
                
                (function() {
                    try {
                        console.log('Assigning helium context...');
                        window.helium = \(combinedJSON);
                        console.log('Assignment successful');
                        console.log(window.helium);
                    } catch(e) {
                        console.error('Error in helium initialization:', e);
                    }
                    
                    document.addEventListener('DOMContentLoaded', function() {
                        document.body.style.backgroundColor = 'transparent';
                        document.documentElement.style.backgroundColor = 'transparent';
                        
                        // Additional error handling for runtime errors
                        window.addEventListener('error', function(event) {
                            const errorInfo = {
                                message: event.error?.message || event.message,
                                source: event.filename,
                                line: event.lineno,
                                column: event.colno,
                                stack: event.error?.stack
                            };
                            window.webkit.messageHandlers.logging.postMessage('[RUNTIME ERROR] ' + JSON.stringify(errorInfo));
                        });
                    });
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            
            contentController.addUserScript(combinedScript)
            config.userContentController = contentController
            
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false
            
            // Get the base directory for security scope access
            let fileURL = URL(fileURLWithPath: filePath)
            let baseDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("helium_bundles", isDirectory: true)
            
            // Security-scoped loading with proper base directory access
            if FileManager.default.fileExists(atPath: filePath) {
                webView.loadFileURL(fileURL, allowingReadAccessTo: baseDirectory)
            } else {
                print("Error: File not found at path: \(filePath)")
                // Optionally load an error page or handle the missing file case
            }
            
            self.webView = webView
        } catch {
            print("Error setting up WebView: \(error)")
        }
    }
}

fileprivate struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    
    func makeUIView(context: Context) -> WKWebView {
        webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
