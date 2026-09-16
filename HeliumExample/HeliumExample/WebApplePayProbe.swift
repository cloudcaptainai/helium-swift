//
//  WebApplePayProbe.swift
//  HeliumExample
//
//  SPIKE (HEL-5834): probe whether Stripe.js `canMakePayment()` returns a
//  truthful Apple Pay availability answer from a hidden WKWebView.
//
//  Finding: it works - but ONLY from an https document whose hostname is
//  registered for Apple Pay with the Stripe account behind the publishable
//  key. `file://` and `about:blank` are rejected by Apple Pay as "insecure
//  documents", so a probe cannot ride Helium's file://-loaded bundle webview;
//  it needs its own https origin (here we spoof one via `loadHTMLString`'s
//  baseURL, which sets the document origin without hosting anything).
//

import Foundation
import WebKit
import UIKit
import QuartzCore

struct ProbeConfig {
    /// A Stripe *publishable* key (safe client-side). Must belong to the same
    /// Stripe account that has `httpsBaseURL`'s host registered for Apple Pay.
    var publishableKey: String
    var country: String
    var currency: String
    /// Minor units (cents). Any positive throwaway amount is fine for the check.
    var amount: Int
    /// An https origin registered for Apple Pay with the key's Stripe account.
    var httpsBaseURL: String
}

struct ProbeResult {
    /// Decoded JS payload (see the HTML script for the shape).
    var payload: [String: Any]
    /// Swift wall-clock: load-initiated -> message-received. Includes WebKit
    /// content-process startup + the postMessage IPC hop, which the JS-side
    /// `totalMs` does not.
    var swiftWallClockMs: Double
    var timedOut: Bool
    var loadError: String?

    var applePayReady: Bool { (payload["applePayReady"] as? Bool) ?? false }
    var hasApplePaySession: Bool { (payload["hasApplePaySession"] as? Bool) ?? false }
    var merchantId: String { (payload["merchantId"] as? String) ?? "" }
    var secureContext: Bool { (payload["secureContext"] as? Bool) ?? false }
    var stage: String { (payload["stage"] as? String) ?? (timedOut ? "timeout" : "unknown") }
}

/// One-shot resume guard so the continuation is resumed exactly once
/// (message vs. timeout vs. load-error race).
private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false
    func tryClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
final class WebApplePayProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    private let messageName = "probe"
    private let timeout: TimeInterval

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ProbeResult, Never>?
    private var guardOnce = ResumeOnce()
    private var startTime: CFTimeInterval = 0

    init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    func run(config: ProbeConfig) async -> ProbeResult {
        self.guardOnce = ResumeOnce()

        let html = Self.buildHTML(config: config)

        let controller = WKUserContentController()
        controller.add(self, name: messageName)

        let webConfig = WKWebViewConfiguration()
        webConfig.userContentController = controller
        webConfig.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: webConfig)
        webView.navigationDelegate = self
        webView.alpha = 0.01
        attachOffscreen(webView)
        self.webView = webView

        startTime = CACurrentMediaTime()

        return await withCheckedContinuation { (cont: CheckedContinuation<ProbeResult, Never>) in
            self.continuation = cont

            let trimmed = config.httpsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.scheme == "https" {
                webView.loadHTMLString(html, baseURL: url)
            } else {
                finish(payload: [:], loadError: "invalid https baseURL: '\(config.httpsBaseURL)' (must be a valid https URL)")
            }

            // Hard timeout safety net.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 15) * 1_000_000_000))
                self?.finish(payload: [:], timedOut: true)
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == messageName else { return }
        let payload = (message.body as? [String: Any]) ?? ["raw": String(describing: message.body)]
        finish(payload: payload)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(payload: [:], loadError: "didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(payload: [:], loadError: "didFailProvisional: \(error.localizedDescription)")
    }

    // MARK: - Completion

    private func finish(payload: [String: Any], timedOut: Bool = false, loadError: String? = nil) {
        guard guardOnce.tryClaim() else { return }
        let elapsed = (CACurrentMediaTime() - startTime) * 1000

        // Break the userContentController -> self strong reference and tear down.
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil

        let result = ProbeResult(
            payload: payload,
            swiftWallClockMs: elapsed,
            timedOut: timedOut,
            loadError: loadError
        )
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    private func attachOffscreen(_ view: UIView) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        window?.addSubview(view)
    }

    // MARK: - HTML

    private static func buildHTML(config: ProbeConfig) -> String {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "'", with: "") }
        let pk = trim(config.publishableKey)
        let country = trim(config.country)
        let currency = trim(config.currency)
        let amount = String(config.amount)

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body>
        <script src="https://js.stripe.com/v3/"></script>
        <script>
        (function(){
          var post = function(obj){ try { window.webkit.messageHandlers.probe.postMessage(obj); } catch(e){} };
          var t0 = (window.performance && performance.now) ? performance.now() : 0;
          var now = function(){ return (window.performance && performance.now) ? performance.now() : 0; };

          var diag = {
            href: String(window.location.href),
            protocol: String(window.location.protocol),
            secureContext: (window.isSecureContext === true),
            hasApplePaySession: (typeof window.ApplePaySession !== 'undefined'),
            applePayCanMakePayments: null,
            applePaySupportsV3: null,
            // Stripe.js derives its Apple Pay merchant id from the page hostname;
            // any other id makes canMakePaymentsWithActiveCard() answer false.
            merchantId: 'merchant.' + window.location.hostname + '.stripe',
            activeCard: 'pending',
            paymentCredentialStatus: 'pending'
          };
          try {
            if (window.ApplePaySession) {
              try { diag.applePayCanMakePayments = window.ApplePaySession.canMakePayments(); } catch(e){ diag.applePayCanMakePaymentsError = String(e); }
              try { diag.applePaySupportsV3 = window.ApplePaySession.supportsVersion(3); } catch(e){}
            }
          } catch(e) { diag.applePaySessionError = String(e); }

          function assign(base, extra){ for (var k in extra){ base[k]=extra[k]; } return base; }

          function collectRawApplePay(){
            if (!window.ApplePaySession) {
              diag.activeCard = 'no-ApplePaySession';
              diag.paymentCredentialStatus = 'no-ApplePaySession';
              return Promise.resolve();
            }
            var jobs = [];
            try {
              jobs.push(Promise.resolve(window.ApplePaySession.canMakePaymentsWithActiveCard(diag.merchantId))
                .then(function(v){ diag.activeCard = String(v); })
                .catch(function(e){ diag.activeCard = 'error: ' + String(e); }));
            } catch(e) { diag.activeCard = 'throw: ' + String(e); }
            try {
              if (window.ApplePaySession.applePayCapabilities) {
                jobs.push(Promise.resolve(window.ApplePaySession.applePayCapabilities(diag.merchantId))
                  .then(function(c){ diag.paymentCredentialStatus = String(c && c.paymentCredentialStatus); })
                  .catch(function(e){ diag.paymentCredentialStatus = 'error: ' + String(e); }));
              } else {
                diag.paymentCredentialStatus = 'unsupported';
              }
            } catch(e) { diag.paymentCredentialStatus = 'throw: ' + String(e); }
            return Promise.all(jobs);
          }

          function runStripe(){
            var tStripeLoaded = now();
            var stripe;
            try { stripe = Stripe('__PK__'); }
            catch(e){ post(assign(diag, { stage:'stripe-init-failed', error:String(e), totalMs: now()-t0 })); return; }

            var pr;
            try {
              pr = stripe.paymentRequest({
                country: '__COUNTRY__',
                currency: '__CURRENCY__',
                total: { label: 'Helium Probe', amount: __AMOUNT__ },
                requestPayerName: false,
                requestPayerEmail: false
              });
            } catch(e){ post(assign(diag, { stage:'payment-request-failed', error:String(e), totalMs: now()-t0 })); return; }

            var tPR = now();
            pr.canMakePayment().then(function(result){
              post(assign(diag, {
                stage: 'complete',
                canMakePayment: result,
                applePayReady: !!(result && result.applePay),
                stripeLoadMs: tStripeLoaded - t0,
                canMakePaymentMs: now() - tPR,
                totalMs: now() - t0
              }));
            }).catch(function(e){
              post(assign(diag, { stage:'canMakePayment-error', error:String(e), totalMs: now()-t0 }));
            });
          }

          collectRawApplePay().then(function(){
            if (typeof Stripe !== 'undefined') { runStripe(); }
            else {
              var tries = 0;
              var iv = setInterval(function(){
                if (typeof Stripe !== 'undefined'){ clearInterval(iv); runStripe(); }
                else if (++tries > 100){ clearInterval(iv); post(assign(diag, { stage:'stripe-load-timeout', error:'Stripe.js did not load', totalMs: now()-t0 })); }
              }, 50);
            }
          });
        })();
        </script>
        </body>
        </html>
        """
        .replacingOccurrences(of: "__PK__", with: pk)
        .replacingOccurrences(of: "__COUNTRY__", with: country)
        .replacingOccurrences(of: "__CURRENCY__", with: currency)
        .replacingOccurrences(of: "__AMOUNT__", with: amount)
    }
}
