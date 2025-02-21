import SwiftUI
import WebKit
import SwiftyJSON

public struct DynamicWebView: View {
    let filePath: String
    let triggerName: String?
    let actionConfig: JSON
    let templateConfig: JSON
    var actionsDelegate: ActionsDelegateWrapper
    let backgroundConfig: BackgroundConfig?
    let showShimmer: Bool
    let shimmerConfig: JSON
    let showProgressView: Bool
    var fallbackPaywall: AnyView?
    
    private var messageHandler: WebViewMessageHandler?
    @State private var webView: WKWebView?
    @State private var isContentLoaded = false
    @State private var viewLoadStartTime: Date?
    @State private var shouldShowFallback = false
    @State private var loadTimer: Timer?
    @EnvironmentObject private var presentationState: HeliumPaywallPresentationState
    
    public init(json: JSON, actionsDelegate: ActionsDelegateWrapper, triggerName: String?) {
        self.filePath = HeliumAssetManager.shared.localPathForURL(bundleURL: json["bundleURL"].stringValue)!
        self.fallbackPaywall = Helium.shared.getFallbackPaywall();
        self.actionsDelegate = actionsDelegate;
        self.messageHandler = WebViewMessageHandler(delegateWrapper: actionsDelegate);
        self.triggerName = triggerName;
        self.actionConfig = json["actionConfig"].type == .null ? JSON([:]) : json["actionConfig"];
        self.templateConfig = json["templateConfig"].type == .null ? JSON([:]) : json["templateConfig"];
        self.backgroundConfig = json["backgroundConfig"].type == .null ? nil : BackgroundConfig(json: json["backgroundConfig"]);
        self.showShimmer = json["showShimmer"].bool ?? false;
        self.shimmerConfig = json["shimmerConfig"] ?? JSON([:]);
        self.showProgressView = json["showProgress"].bool ?? false;
    }

    public var body: some View {
       ZStack {
           // Background always shows
          if let backgroundConfig = backgroundConfig {
              backgroundConfig.makeBackgroundView()
                  .ignoresSafeArea()
          }
           if shouldShowFallback, let fallback = fallbackPaywall {
               fallback
                   .ignoresSafeArea()
                   .frame(maxWidth: .infinity, maxHeight: .infinity)
               
        } else if webView != nil && isContentLoaded {
              WebViewRepresentable(webView: webView!)
                  .padding(.horizontal, -1)
                  .ignoresSafeArea()
                  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          } else if showShimmer {
              VStack {}
              .padding()
              .padding(.top, UIScreen.main.bounds.height * 0.2)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .shimmer(config: shimmerConfig)
              
          } else if showProgressView {
              ProgressView()
                  .ignoresSafeArea()
                  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
       }
       .edgesIgnoringSafeArea(.all)
       .onAppear {
           viewLoadStartTime = Date()
           startLoadTimer();
           loadWebView()
       }
       .onDisappear {
          loadTimer?.invalidate()
          loadTimer = nil
          webView?.stopLoading()
          webView = nil
      }
      .onReceive(NotificationCenter.default.publisher(for: .webViewContentLoaded)) { _ in
          loadTimer?.invalidate()
          loadTimer = nil
          isContentLoaded = true
          if let startTime = viewLoadStartTime {
              let timeInterval = Date().timeIntervalSince(startTime)
              let milliseconds = UInt64(timeInterval * 1000)
              Task {
                  self.actionsDelegate.logRenderTime(timeTakenMS: milliseconds)
              }
          }
      }
    }
    
    private func startLoadTimer() {
         loadTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
             if (!isContentLoaded && fallbackPaywall != nil) {
                 shouldShowFallback = true
             }
         }
     }

    private func loadWebView() {
        let totalStartTime = Date()
        
        // Initialization timing
        let configStartTime = Date()
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        if (messageHandler == nil && fallbackPaywall != nil) {
            shouldShowFallback = true
            return;
        }
        
        // Message handler setup timing
        let handlerStartTime = Date()
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
        
        // Context and script injection timing
        do {
//          let contextStartTime = Date()
            let currentContext = createHeliumContext(triggerName: triggerName)
            let contextJSON = JSON(parseJSON: try currentContext.toJSON())
            let customContextValues = HeliumPaywallDelegateWrapper.shared.getCustomVariableValues()
            

            let serializationStartTime = Date()
            let customData = try JSONSerialization.data(withJSONObject: customContextValues.compactMapValues { $0 })
            let customJSON = try JSON(data: customData)
            

            let mergeStartTime = Date()
            var mergedContext = contextJSON
            for (key, value) in customJSON {
                mergedContext[key] = value
            }
            
            
            let scriptStartTime = Date()
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
            
            let injectionStartTime = Date()
            contentController.addUserScript(combinedScript)
            config.userContentController = contentController
            config.websiteDataStore = WKWebsiteDataStore.default()
            
            // WebView creation timing
            let webviewCreateTime = Date()
            let webView = WKWebView(frame: .zero, configuration: config)
            
            // WebView configuration timing
            let webviewConfigStartTime = Date()
            webView.configuration.preferences.javaScriptEnabled = true
            webView.navigationDelegate = messageHandler
            webView.contentMode = .scaleToFill
            webView.backgroundColor = .clear
            webView.isOpaque = false
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.isOpaque = false
            
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
            
            // File loading timing
            let fileLoadStartTime = Date()
            let fileURL = URL(fileURLWithPath: filePath)
            let baseDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("helium_bundles_cache", isDirectory: true)
            
            if FileManager.default.fileExists(atPath: filePath) {
                let contents = try? String(contentsOfFile: filePath, encoding: .utf8)
                webView.loadFileURL(fileURL, allowingReadAccessTo: baseDirectory)
            } else {
            }
            
            self.webView = webView

        } catch {
            HeliumPaywallDelegateWrapper.shared.onHeliumPaywallEvent(event: .paywallOpenFailed(
                triggerName: triggerName ?? "",
                paywallTemplateName: "WebView"
            ));
            if (fallbackPaywall != nil) {
                shouldShowFallback = true;
            }
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
