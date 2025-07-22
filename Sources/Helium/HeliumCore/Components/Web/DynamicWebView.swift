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
    @State private var webView: WKWebView? = nil
    @State private var viewLoadStartTime: Date?
    @State private var shouldShowFallback = false
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    @Environment(\.colorScheme) private var colorScheme
    
    public init(json: JSON, actionsDelegate: ActionsDelegateWrapper, triggerName: String?) {
        self.filePath = HeliumAssetManager.shared.localPathForURL(bundleURL: json["bundleURL"].stringValue)!
        self.fallbackPaywall = HeliumFallbackViewManager.shared.getFallbackForTrigger(trigger: triggerName ?? "");
        self.actionsDelegate = actionsDelegate;
        
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
               
        } else if let webView {
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
           webView?.stopLoading()
      }
      .onReceive(NotificationCenter.default.publisher(for: .webViewContentLoaded)) { res in
          if res.object as? WKNavigationDelegate === webView?.navigationDelegate {
              isContentLoaded = true
              if let startTime = viewLoadStartTime {
                  let timeInterval = Date().timeIntervalSince(startTime)
                  let milliseconds = UInt64(timeInterval * 1000)
                  Task {
                      self.actionsDelegate.logRenderTime(timeTakenMS: milliseconds)
                  }
              }
              lowPowerModeAutoPlayVideoWorkaround()
          }
      }
    }

    private func loadWebView() {
        if webView != nil {
            return
        }
        
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
            
            Task {
                // WebView creation timing
                _ = Date()
                let preparedWebView = await WebViewManager.shared.prepareForShowing(filePath: filePath, delegateWrapper: actionsDelegate, heliumViewController: presentationState.heliumViewController)
                guard let preparedWebView else {
                    print("Failed to retrieve preparedWebView!")
                    shouldShowFallback = true
                    return
                }
                
                _ = Date()
                preparedWebView.configuration.userContentController.addUserScript(combinedScript)
                
                // File loading timing
                _ = Date()
                
                await WebViewManager.shared.loadFilePath(filePath, toWebView: preparedWebView)
                webView = preparedWebView
            }
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                // try here to try and make autoplay more smooth
                lowPowerModeAutoPlayVideoWorkaround(multipleAttempts: false)
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
    
    private func lowPowerModeAutoPlayVideoWorkaround(multipleAttempts: Bool = true) {
        // Video autoplayback is disabled if in Low Power Mode. This is a workaroudn to
        // force explicit auto-play. Note that using img element instead of video in the
        // html also seems to work in limited testing but feels hacky.
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            Task {
//                // Can extra delay here if needed but in testing doesn't seem needed
//                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                
                // First attempt to play the video
                let firstAttemptResult = await forceVideoPlay()
                
                if !multipleAttempts {
                    return
                }
                
                // If first attempt failed or couldn't find video, try one more time
                if !firstAttemptResult {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    
                    // Second attempt
                    await forceVideoPlay()
                }
            }
        }
    }
    private func forceVideoPlay() async -> Bool {
        guard let webView else {
            return false
        }
        let result = try? await webView.evaluateJavaScript("""
            (function() {
                const video = document.querySelector('video');
                if (video) {
                    video.play().catch(e => console.log('First play attempt failed:', e));
                    return true;
                }
                return false;
            })();
        """) as? Bool
        return result == true
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
    
    private var preloadWebViewBundle: PaywallWebViewBundle? = nil
    private(set) var preparedWebViewBundles: [PaywallWebViewBundle] = []
    private var preloadCounter: Int = 0
    
    func preCreateFirstWebView() {
        Task {
            let bundle = await createWebViewBundle(filePath: nil)
            preloadWebViewBundle = bundle
        }
    }
    
    fileprivate func createWebViewBundle(filePath: String? = nil) async -> PaywallWebViewBundle {
        let messageHandler = WebViewMessageHandler()
        
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
        
        return PaywallWebViewBundle(
            filePath: filePath, webView: webView, msgHandler: messageHandler
        )
    }
    
    @MainActor
    fileprivate func prepareForShowing(filePath: String, delegateWrapper: ActionsDelegateWrapper, heliumViewController: HeliumViewController?) async -> WKWebView? {
        var webViewBundle = preparedWebViewBundles.first { $0.filePath == filePath && !$0.isInUse }
        if webViewBundle == nil {
            webViewBundle = preparedWebViewBundles.first { $0.filePath == nil } // see if there's one available
            if let webViewBundle {
                webViewBundle.filePath = filePath
            } else {
                let newBundle = await createWebViewBundle(filePath: filePath)
                preparedWebViewBundles.append(newBundle)
                webViewBundle = newBundle
            }
        }
        guard let webViewBundle else { return nil }
        webViewBundle.heliumViewController = heliumViewController
        webViewBundle.messageHandler.setActionsDelegate(delegateWrapper: delegateWrapper)
        
        let webView = webViewBundle.preparedWebView
        
        webView.navigationDelegate = webViewBundle.messageHandler
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
        
        return webView
    }
    
    func preLoad(filePath: String) {
        let startTime = Date()
        
        preloadCounter += 1
        Task {
            await preloadFilePath(filePath)
            print("WebViewManager preload in ms \(Date().timeIntervalSince(startTime) * 1000)")
            preloadCounter -= 1
            if preloadCounter == 0 {
                completePreloads()
            }
        }
    }
    
    @MainActor
    fileprivate func preloadFilePath(_ filePath: String) {
        guard let webView = preloadWebViewBundle?.preparedWebView else {
            return
        }
        loadFilePath(filePath, toWebView: webView)
    }
    
    @MainActor
    fileprivate func loadFilePath(_ filePath: String, toWebView: WKWebView) {
        let fileURL = URL(fileURLWithPath: filePath)
        let baseDirectory = HeliumAssetManager.bundleDir
        
        if FileManager.default.fileExists(atPath: filePath) {
            _ = try? String(contentsOfFile: filePath, encoding: .utf8)
            toWebView.loadFileURL(fileURL, allowingReadAccessTo: baseDirectory)
        }
    }
    
    private func completePreloads() {
        guard let preloadWebViewBundle else { return }
        // Can re-use the preload bundle now
        preparedWebViewBundles.append(preloadWebViewBundle)
    }
    
}

class PaywallWebViewBundle {
    var filePath: String? = nil
    let preparedWebView: WKWebView
    let messageHandler: WebViewMessageHandler
    weak var heliumViewController: HeliumViewController?
    var isInUse: Bool {
        return heliumViewController != nil
    }
    
    init(filePath: String? = nil, webView: WKWebView, msgHandler: WebViewMessageHandler) {
        self.filePath = filePath
        preparedWebView = webView
        messageHandler = msgHandler
    }
}
