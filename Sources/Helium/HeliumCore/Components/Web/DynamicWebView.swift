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
    let postLoadBackgroundConfig: BackgroundConfig?
    let showShimmer: Bool
    let shimmerConfig: JSON
    let showProgressView: Bool
    var fallbackPaywall: AnyView?
    
    @State private var isContentLoaded = false
    @State private var viewLoadStartTime: Date?
    @State private var shouldShowFallback = false
    @State private var loadTimer: Timer?
    @EnvironmentObject private var presentationState: HeliumPaywallPresentationState
    
    public init(json: JSON, actionsDelegate: ActionsDelegateWrapper, triggerName: String?) {
        self.filePath = HeliumAssetManager.shared.localPathForURL(bundleURL: json["bundleURL"].stringValue)!
        self.fallbackPaywall = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: triggerName ?? "");
        self.actionsDelegate = actionsDelegate;
        
        WebViewManager.shared.messageHandler.setActionsDelegate(delegateWrapper: actionsDelegate)
        
        self.triggerName = triggerName;
        self.actionConfig = json["actionConfig"].type == .null ? JSON([:]) : json["actionConfig"];
        self.templateConfig = json["templateConfig"].type == .null ? JSON([:]) : json["templateConfig"];
        self.backgroundConfig = json["backgroundConfig"].type == .null ? nil : BackgroundConfig(json: json["backgroundConfig"]);
        self.postLoadBackgroundConfig = json["postLoadBackgroundConfig"].type == .null ? nil : BackgroundConfig(json: json["postLoadBackgroundConfig"]);
        self.showShimmer = json["showShimmer"].bool ?? false;
        self.shimmerConfig = json["shimmerConfig"].type == .null ? JSON([:]) : json["shimmerConfig"];
        self.showProgressView = json["showProgress"].bool ?? false;
    }

    public var body: some View {
       ZStack {
           // Background view - shows either initial background or post-load background when content is loaded
           if isContentLoaded, let postLoadBg = postLoadBackgroundConfig {
               // Show post-load background if content is loaded and postLoadBackgroundConfig exists
               postLoadBg.makeBackgroundView()
                   .ignoresSafeArea()
                   .transition(.opacity)
           } else if let backgroundConfig = backgroundConfig {
               // Show initial background
               backgroundConfig.makeBackgroundView()
                   .ignoresSafeArea()
           }
           
           if shouldShowFallback, let fallback = fallbackPaywall {
               fallback
                   .ignoresSafeArea()
                   .frame(maxWidth: .infinity, maxHeight: .infinity)
               
        } else if isContentLoaded {
            WebViewRepresentable(webView: WebViewManager.shared.preparedWebView!)
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
        
        let messageHandler = WebViewManager.shared.messageHandler
        
        // Initialization timing
        let configStartTime = Date()
        
        // Context and script injection timing
        do {
            let contextJSON = createHeliumContext(triggerName: triggerName)
                        
            let customContextValues = HeliumPaywallDelegateWrapper.shared.getCustomVariableValues()

            let serializationStartTime = Date()
            let customData = try JSONSerialization.data(withJSONObject: customContextValues.compactMapValues { $0 })
            let customJSON = try JSON(data: customData)

            let mergeStartTime = Date()
            var mergedContext = contextJSON
            for (key, value) in customJSON {
                mergedContext[key] = value
            }
            
            // Get localized prices from HeliumFetchedConfigManager
            // Only fetch prices for products associated with this trigger
            let localizedPrices = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger(triggerName)
            
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
                        window.heliumContext = \(mergedContext.rawString() ?? "{}");
                        window.heliumLocalizedPrices = \(JSON(localizedPrices.mapValues { $0.json }).rawString() ?? "{}");
                    } catch(e) {
                        console.error('Error in helium initialization:', e);
                    }
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            
            // WebView creation timing
            let webviewCreateTime = Date()
            WebViewManager.shared.prepareForShowing()
            guard let webView = WebViewManager.shared.preparedWebView else {
                print("Failed to retrieve preparedWebView!")
                shouldShowFallback = true
                return
            }
            
            let injectionStartTime = Date()
            webView.configuration.userContentController.addUserScript(combinedScript)
            
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

/**
 Preload as much as possible for smoother rendering/display. Note that simply creating any WKWebView creates notable initialization performance improvements for future WKWebView, but doing more here including setting up WKWebViewConfiguration, basic scripts, etc.
 */
class WebViewManager {
    
    static let shared: WebViewManager = WebViewManager()
    
    private(set) var preparedWebView: WKWebView? = nil
    
    private(set) var messageHandler: WebViewMessageHandler = WebViewMessageHandler()
    
    func createWebView() {
        Task {
            do {
                preparedWebView?.stopLoading()
                preparedWebView = nil
                
                let config = WKWebViewConfiguration()
                let contentController = WKUserContentController()
                
                // Message handler setup timing
                let handlerStartTime = Date()
                contentController.addScriptMessageHandler(
                    messageHandler,
                    contentWorld: .page,
                    name: "paywallHandler"
                )
                contentController.addScriptMessageHandler(
                    messageHandler,
                    contentWorld: .page,
                    name: "logging"
                )
                
                config.userContentController = contentController
                
                let webView = WKWebView(frame: .zero, configuration: config)
                webView.configuration.preferences.javaScriptEnabled = true
                
                preparedWebView = webView
            } catch {
                print("failed to warm up WKWebView")
            }
        }
    }
    
    func prepareForShowing() {
        guard let webView = preparedWebView else { return }
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
    }
    
}
