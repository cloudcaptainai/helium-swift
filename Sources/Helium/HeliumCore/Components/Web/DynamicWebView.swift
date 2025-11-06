import SwiftUI
import WebKit

enum FileLoadAttempt {
    case initialLoad
    case secondLoad
    case backupLoad
}

public struct DynamicWebView: View {
    let bundleId: String?
    let filePath: String
    let backupBundleId: String?
    let backupFilePath: String?
    @State private var fileLoadAttempt: FileLoadAttempt = .initialLoad
    
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
    let shouldEnableScroll: Bool
    
    @State private var isContentLoaded = false
    @State private var webView: WKWebView? = nil
    @State private var viewLoadStartTime: Date?
    @State private var shouldShowFallback = false
    @Environment(\.paywallPresentationState) var presentationState: HeliumPaywallPresentationState
    @Environment(\.colorScheme) private var colorScheme
    
    private var effectiveColorScheme: ColorScheme {
        switch Helium.shared.lightDarkModeOverride {
        case .light: return .light
        case .dark: return .dark
        case .system: return colorScheme // fall back to environment
        }
    }
    
    init(json: JSON, backupJson: JSON?, actionsDelegate: ActionsDelegateWrapper, triggerName: String?) {
        let bundleURL = json["bundleURL"].stringValue
        self.bundleId = HeliumAssetManager.shared.getBundleIdFromURL(bundleURL)
        self.filePath = HeliumAssetManager.shared.localPathForURL(bundleURL: bundleURL)!
        if let backupJson {
            let backupBundleURL = backupJson["bundleURL"].stringValue
            backupBundleId = HeliumAssetManager.shared.getBundleIdFromURL(backupBundleURL)
            backupFilePath = HeliumAssetManager.shared.localPathForURL(bundleURL: backupBundleURL)
        } else {
            backupBundleId = nil
            backupFilePath = nil
        }
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
        
        shouldEnableScroll = json["shouldEnableScroll"].bool ?? true
    }

    public var body: some View {
       ZStack {
           // Background view - shows either initial background or post-load background when content is loaded
           if isContentLoaded {
               if let postLoadBg = effectiveColorScheme == .dark && darkModePostLoadBackgroundConfig != nil ?
                   darkModePostLoadBackgroundConfig : postLoadBackgroundConfig {
                   // Show post-load background if content is loaded and postLoadBackgroundConfig exists
                   postLoadBg.makeBackgroundView()
                       .ignoresSafeArea()
                       .transition(.opacity)
               }
           } else if let bg = effectiveColorScheme == .dark && darkModeBackgroundConfig != nil ?
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
          if !isContentLoaded && res.object as? WKNavigationDelegate === webView?.navigationDelegate {
              isContentLoaded = true
              if let startTime = viewLoadStartTime {
                  let timeInterval = Date().timeIntervalSince(startTime)
                  let milliseconds = UInt64(timeInterval * 1000)
                  let isFallback = fileLoadAttempt == .backupLoad
                  Task {
                      self.actionsDelegate.logRenderTime(
                        timeTakenMS: milliseconds,
                        isFallback: isFallback
                      )
                  }
              }
              lowPowerModeAutoPlayVideoWorkaround()
          }
      }
      .onReceive(NotificationCenter.default.publisher(for: .webViewContentLoadFail)) { res in
          if !isContentLoaded && res.object as? WKNavigationDelegate === webView?.navigationDelegate {
              webViewLoadFail(reason: "Failed to render paywall.")
          }
      }
    }

    private func loadWebView(useBackup: Bool = false) {
        if webView != nil {
            return
        }
        print("[Helium] WebView loading html - \(fileLoadAttempt)")
        
        guard let filePathToLoad = useBackup ? backupFilePath : filePath else {
            webViewLoadFail(reason: "NoBackupFilePath")
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
                let preparedWebView = await WebViewManager.shared.prepareForShowing(
                    filePath: filePathToLoad,
                    shouldEnableScroll: shouldEnableScroll,
                    delegateWrapper: actionsDelegate,
                    heliumViewController: presentationState.heliumViewController
                )
                guard let preparedWebView else {
                    print("Failed to retrieve preparedWebView!")
                    webViewLoadFail(reason: "NoPreparedWebView") // logically this should never be possible
                    return
                }
                
                _ = Date()
                preparedWebView.configuration.userContentController.addUserScript(combinedScript)
                
                // File loading timing
                _ = Date()
                
                do {
                    var htmlStringIfNeeded: String? = nil
                    if !useBackup, let bundleId {
                        htmlStringIfNeeded = HeliumFetchedConfigManager.shared.fetchedConfig?.bundles?[bundleId]
                        if htmlStringIfNeeded == nil && backupFilePath == nil {
                            // This can happen if bundleId is actually for a fallback bundle
                            htmlStringIfNeeded = HeliumFallbackViewManager.shared.getConfig()?.bundles?[bundleId]
                        }
                    } else if useBackup, let backupBundleId {
                        htmlStringIfNeeded = HeliumFallbackViewManager.shared.getConfig()?.bundles?[backupBundleId]
                    }
                    
                    try WebViewManager.shared.loadFilePath(
                        filePathToLoad,
                        toWebView: preparedWebView,
                        htmlStringIfNeeded: htmlStringIfNeeded
                    )
                    webView = preparedWebView
                } catch {
                    webViewLoadFail(reason: "WebViewLoadFail")
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                // try here to try and make autoplay more smooth
                lowPowerModeAutoPlayVideoWorkaround(multipleAttempts: false)
            }
        } catch {
            webViewLoadFail(reason: "WebViewContextError")
        }
    }
    
    private func webViewLoadFail(reason: String) {
        print("[Helium] WebView failed to load - \(reason)")
        switch fileLoadAttempt {
        case .initialLoad:
            advanceFileLoadAttempt(to: .secondLoad, useBackup: false)
            return
        case .secondLoad:
            if backupFilePath != nil {
                advanceFileLoadAttempt(to: .backupLoad, useBackup: true)
                return
            }
        default:
            break
        }
        let trigger = triggerName ?? ""
        let paywallName = HeliumFetchedConfigManager.shared.getPaywallInfoForTrigger(trigger)?.paywallTemplateName ?? HeliumFallbackViewManager.shared.getFallbackInfo(trigger: trigger)?.paywallTemplateName ?? "unknown"
        if fallbackPaywall != nil {
            shouldShowFallback = true
            // technically not a "web" render but it's still useful to capture this data and not worthy of a new event
            let event = PaywallWebViewRenderedEvent(
                triggerName: trigger,
                paywallName: paywallName,
                paywallUnavailableReason: .webviewRenderFail
            )
            HeliumPaywallDelegateWrapper.shared.fireEvent(event)
        } else {
            let openFailEvent = PaywallOpenFailedEvent(
                triggerName: trigger,
                paywallName: paywallName,
                error: "WebView failed to load - \(reason)",
                paywallUnavailableReason: .webviewRenderFail
            )
            if presentationState.viewType == .presented {
                HeliumPaywallPresenter.shared.hideUpsell {
                    HeliumPaywallDelegateWrapper.shared.fireEvent(openFailEvent)
                }
            } else {
                HeliumPaywallDelegateWrapper.shared.fireEvent(openFailEvent)
            }
        }
    }
    
    private func advanceFileLoadAttempt(to attempt: FileLoadAttempt, useBackup: Bool) {
        Task { @MainActor in
            fileLoadAttempt = attempt
            webView = nil
            // give time for SwiftUI to update otherwise any existing webview display might remain
            await Task.yield()
            loadWebView(useBackup: useBackup)
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
                    let _ = await forceVideoPlay()
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
        
        guard let window = UIWindowHelper.findActiveWindow() else {
            return
        }
        let insets = window.safeAreaInsets
        
        let js = """
            if (window.heliumUpdateSafeAreaInsets) {
                window.heliumUpdateSafeAreaInsets({
                    top: \(insets.top),
                    bottom: \(insets.bottom),
                    left: \(insets.left),
                    right: \(insets.right)
                });
            }
        """
        webView.evaluateJavaScript(js)
    }
}

/**
 Preload as much as possible for smoother rendering/display. Note that simply creating any WKWebView creates notable initialization performance improvements for future WKWebViews, but doing more here including setting up WKWebViewConfiguration, basic scripts, etc.
 */
@MainActor
class WebViewManager {
    
    static let shared: WebViewManager = WebViewManager()
    
    private var preloadWebViewHolder: PaywallWebViewHolder? = nil
    private(set) var preparedWebViewHolders: [PaywallWebViewHolder] = []
    
    func preCreateFirstWebView() async {
        // Just use this one for preloading purposes
        preloadWebViewHolder = await createWebViewHolder(filePath: nil)
        // Speed things up slightly by having first one ready for use
        let initialWebViewHolder = await createWebViewHolder(filePath: nil)
        preparedWebViewHolders.append(initialWebViewHolder)
    }
    
    fileprivate func createWebViewHolder(filePath: String? = nil) async -> PaywallWebViewHolder {
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
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        return PaywallWebViewHolder(
            filePath: filePath, webView: webView, msgHandler: messageHandler
        )
    }
    
    fileprivate func prepareForShowing(
        filePath: String,
        shouldEnableScroll: Bool,
        delegateWrapper: ActionsDelegateWrapper,
        heliumViewController: HeliumViewController?
    ) async -> WKWebView? {
        var webViewHolder = preparedWebViewHolders.first { $0.filePath == filePath && !$0.isInUse }
        if webViewHolder == nil {
            webViewHolder = preparedWebViewHolders.first { $0.filePath == nil } // see if there's one available
            if let webViewHolder {
                webViewHolder.filePath = filePath
            } else {
                let newWebViewHolder = await createWebViewHolder(filePath: filePath)
                preparedWebViewHolders.append(newWebViewHolder)
                webViewHolder = newWebViewHolder
            }
        }
        guard let webViewHolder else { return nil }
        webViewHolder.heliumViewController = heliumViewController
        webViewHolder.messageHandler.setActionsDelegate(delegateWrapper: delegateWrapper)
        
        let webView = webViewHolder.preparedWebView
        
        webView.navigationDelegate = webViewHolder.messageHandler
        webView.contentMode = .scaleToFill
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false
        
        switch Helium.shared.lightDarkModeOverride {
        case .light:
            webView.overrideUserInterfaceStyle = .light
        case .dark:
            webView.overrideUserInterfaceStyle = .dark
        case .system:
            webView.overrideUserInterfaceStyle = .unspecified
        }
        
        webView.scrollView.isScrollEnabled = shouldEnableScroll
        webView.scrollView.bounces = shouldEnableScroll
        webView.scrollView.bouncesZoom = false
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.isDirectionalLockEnabled = true
        webView.scrollView.scrollsToTop = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        
        return webView
    }
    
    func preLoad(filePath: String) async {
        let startTime = Date()
        
        preloadFilePath(filePath)
        print("WebViewManager preload in ms \(Date().timeIntervalSince(startTime) * 1000)")
    }
    
    fileprivate func preloadFilePath(_ filePath: String) {
        guard let webView = preloadWebViewHolder?.preparedWebView else {
            return
        }
        try? loadFilePath(filePath, toWebView: webView)
    }
    
    fileprivate func loadFilePath(_ filePath: String, toWebView: WKWebView, htmlStringIfNeeded: String? = nil) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        let baseDirectory = HeliumAssetManager.bundleDir
        
        if FileManager.default.fileExists(atPath: filePath) {
            _ = try? String(contentsOfFile: filePath, encoding: .utf8)
            toWebView.loadFileURL(fileURL, allowingReadAccessTo: baseDirectory)
        } else if let htmlStringIfNeeded {
            toWebView.loadHTMLString(htmlStringIfNeeded, baseURL: nil)
        } else {
            throw WebViewError.bundleNotFound
        }
    }
    
}

class PaywallWebViewHolder {
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

public enum WebViewError: Error {
    case bundleNotFound
}
