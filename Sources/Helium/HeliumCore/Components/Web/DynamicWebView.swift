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
    let darkModeBackgroundConfig: BackgroundConfig?
    let darkModePostLoadBackgroundConfig: BackgroundConfig?
    let showShimmer: Bool
    let shimmerConfig: JSON
    let showProgressView: Bool
    var fallbackPaywall: AnyView?
    
    @State private var isContentLoaded = false
    @State private var webViewReady = false
    @State private var viewLoadStartTime: Date?
    @State private var shouldShowFallback = false
    @EnvironmentObject private var presentationState: HeliumPaywallPresentationState
    @Environment(\.colorScheme) private var colorScheme
    
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

        self.darkModeBackgroundConfig = json["darkModeBackgroundConfig"].type == .null ? nil : BackgroundConfig(json: json["darkModeBackgroundConfig"]);
        self.darkModePostLoadBackgroundConfig = json["darkModePostLoadBackgroundConfig"].type == .null ? nil : BackgroundConfig(json: json["darkModePostLoadBackgroundConfig"]);
        self.showShimmer = json["showShimmer"].bool ?? false;
        self.shimmerConfig = json["shimmerConfig"].type == .null ? JSON([:]) : json["shimmerConfig"];
        self.showProgressView = json["showProgress"].bool ?? false;
    }

    public var body: some View {
       ZStack {
           // Background view - shows either initial background or post-load background when content is loaded
           if isContentLoaded {
               if let postLoadBg = colorScheme == .dark && darkModePostLoadBackgroundConfig != nil ? 
                   darkModePostLoadBackgroundConfig : postLoadBackgroundConfig {
                   // Show post-load background if content is loaded and postLoadBackgroundConfig exists
                   postLoadBg.makeBackgroundView()
                       .ignoresSafeArea()
                       .transition(.opacity)
               }
           } else if let bg = colorScheme == .dark && darkModeBackgroundConfig != nil ? 
               darkModeBackgroundConfig : backgroundConfig {
               // Show initial background
               bg.makeBackgroundView()
                   .ignoresSafeArea()
           }
           
           if shouldShowFallback, let fallback = fallbackPaywall {
               fallback
                   .ignoresSafeArea()
                   .frame(maxWidth: .infinity, maxHeight: .infinity)
               
        } else if webViewReady, let webView = WebViewManager.shared.preparedWebView {
              WebViewRepresentable(webView: webView)
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
           loadWebView()
       }
       .onDisappear {
          WebViewManager.shared.stopLoading()
      }
      .onReceive(NotificationCenter.default.publisher(for: .webViewContentLoaded)) { _ in
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

    private func loadWebView() {
        
        _ = Date()
        
        _ = WebViewManager.shared.messageHandler
        
        // Initialization timing
        _ = Date()
        
        // Context and script injection timing
        do {
            let contextJSON = createHeliumContext(triggerName: triggerName)
                        
            let customContextValues = HeliumPaywallDelegateWrapper.shared.getCustomVariableValues()

            _ = Date()
            let customData = try JSONSerialization.data(withJSONObject: customContextValues.compactMapValues { $0 })
            let customJSON = try JSON(data: customData)

            _ = Date()
            var mergedContext = contextJSON
            for (key, value) in customJSON {
                mergedContext[key] = value
            }
            
            // Get localized prices from HeliumFetchedConfigManager
            // Only fetch prices for products associated with this trigger
            let localizedPrices = HeliumFetchedConfigManager.shared.getLocalizedPriceMapForTrigger(triggerName)
            
            _ = Date()
            let stringSource = """
            (function() {
                // Create properties on window object directly
                Object.defineProperty(window, 'heliumContext', {
                    value: \(mergedContext.rawString() ?? "{}"),
                    writable: false,
                    enumerable: true,
                    configurable: false
                });
                
                Object.defineProperty(window, 'heliumLocalizedPrices', {
                    value: \(JSON(localizedPrices.mapValues { $0.json }).rawString() ?? "{}"),
                    writable: false,
                    enumerable: true,
                    configurable: false
                });
                
                 Object.defineProperty(window, 'heliumReady', {
                    value: true,
                    writable: false,
                    enumerable: true,
                    configurable: false
                });
            })();
            """
            
            let combinedScript = WKUserScript(
                source: stringSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            
            // WebView creation timing
            _ = Date()
            WebViewManager.shared.prepareForShowing()
            guard let webView = WebViewManager.shared.preparedWebView else {
                print("Failed to retrieve preparedWebView!")
                shouldShowFallback = true
                return
            }
            
            _ = Date()
            webView.configuration.userContentController.addUserScript(combinedScript)
            
            // File loading timing
            _ = Date()
            Task {
                await WebViewManager.shared.loadFilePath(filePath)
                webViewReady = true
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
 Preload as much as possible for smoother rendering/display. Note that simply creating any WKWebView creates notable initialization performance improvements for future WKWebViews, but doing more here including setting up WKWebViewConfiguration, basic scripts, etc.
 */
class WebViewManager {
    
    static let shared: WebViewManager = WebViewManager()
    
    private(set) var preparedWebView: WKWebView? = nil
    
    private(set) var messageHandler: WebViewMessageHandler = WebViewMessageHandler()
    
    func createWebView() {
        Task {
            do {
                await preparedWebView?.stopLoading()
                preparedWebView = nil
                
                let config = WKWebViewConfiguration()
                // allow video autoplay
                config.allowsInlineMediaPlayback = true
                // for all media types (regardless of whether video has audio)
                config.mediaTypesRequiringUserActionForPlayback = []
                let contentController = WKUserContentController()
                
                // Message handler setup timing
                _ = Date()
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
                config.websiteDataStore = WKWebsiteDataStore.default()
                
                let webView = await WKWebView(frame: .zero, configuration: config)
                await webView.configuration.preferences.javaScriptEnabled = true
                
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
    
    func preLoad(filePath: String) {
        let startTime = Date()
        
        Task {
            await loadFilePath(filePath)
            print("WebViewManager preload in ms \(Date().timeIntervalSince(startTime) * 1000)")
        }
    }
    
    @MainActor
    func loadFilePath(_ filePath: String) async {
        guard let webView = preparedWebView else {
            return
        }
        let fileURL = URL(fileURLWithPath: filePath)
        let baseDirectory = HeliumAssetManager.bundleDir
        
        if FileManager.default.fileExists(atPath: filePath) {
            _ = try? String(contentsOfFile: filePath, encoding: .utf8)
            webView.loadFileURL(fileURL, allowingReadAccessTo: baseDirectory)
        }
    }
    
    func stopLoading() {
        preparedWebView?.stopLoading()
    }
    
}
