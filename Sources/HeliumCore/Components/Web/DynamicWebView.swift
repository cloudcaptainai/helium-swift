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
                    .padding(.horizontal, -1)
            } else {
                ProgressView()
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            
            let combinedScript = WKUserScript(
                source: """
                (function() {
                    // Set up initial console handlers (will be enhanced by TS)
                    console.log = function(...args) {
                        window.webkit.messageHandlers.logging.postMessage(args.map(arg =>
                            typeof arg === 'object' ? JSON.stringify(arg) : String(arg)
                        ).join(' '));
                    };
                    
                    console.error = function(...args) {
                        window.webkit.messageHandlers.logging.postMessage('[ERROR] ' + args.map(arg =>
                            typeof arg === 'object' ? JSON.stringify(arg) : String(arg)
                        ).join(' '));
                    };

                    // Initialize helium context
                    try {
                        window.helium = {};
                        window.heliumContextualValues = \(mergedContext.rawString() ?? "{}");
                    } catch(e) {
                        console.error('Error in helium initialization:', e);
                    }
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            
            contentController.addUserScript(combinedScript)
            config.userContentController = contentController
            
            // Inside loadWebView() function, after creating the webView:
            let webView = WKWebView(frame: .zero, configuration: config)
            
            webView.configuration.preferences.javaScriptEnabled = true
            
            webView.navigationDelegate = messageHandler;
            // Set content mode
            webView.contentMode = .scaleToFill
            webView.backgroundColor = .clear
            webView.isOpaque = false
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isOpaque = false
            
            // Existing scroll settings
            webView.scrollView.isScrollEnabled = true
            webView.scrollView.bouncesZoom = false
            webView.scrollView.minimumZoomScale = 1.0
            webView.scrollView.maximumZoomScale = 1.0
            webView.scrollView.isDirectionalLockEnabled = true
            webView.scrollView.bounces = true
            webView.scrollView.scrollsToTop = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.contentInset = .zero
            webView.scrollView.scrollIndicatorInsets = .zero
            webView.scrollView.showsVerticalScrollIndicator = false
            webView.scrollView.showsHorizontalScrollIndicator = false
            
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
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Ensure constraints are set properly
        if let superview = webView.superview {
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: -1),
                webView.trailingAnchor.constraint(equalTo: superview.trailingAnchor, constant: 1),
                webView.topAnchor.constraint(equalTo: superview.topAnchor),
                webView.bottomAnchor.constraint(equalTo: superview.bottomAnchor)
            ])
        }
    }
}
