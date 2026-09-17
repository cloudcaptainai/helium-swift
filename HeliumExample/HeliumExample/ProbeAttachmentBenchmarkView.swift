//
//  ProbeAttachmentBenchmarkView.swift
//  HeliumExample
//
//  SPIKE (HEL-5834): measure whether putting the hidden probe webview in the
//  key window changes how long the Apple Pay answer takes.
//
//  On iOS a WKWebView counts as visible only when it is inside a window, so a
//  detached probe's WebKit processes run under a background RunningBoard
//  assertion. This screen times the same probe both ways.
//

import Foundation
import SwiftUI
import UIKit
import WebKit
import QuartzCore

private let benchmarkDefaultOrigin = "https://bundles.clickthrough.to"

enum ProbeAttachment: String, CaseIterable {
    case detached
    case inWindow

    var label: String {
        switch self {
        case .detached:
            return "Detached"
        case .inWindow:
            return "In window (alpha 0)"
        }
    }
}

struct BenchmarkRun: Identifiable {
    let id = UUID()
    let index: Int
    let attachment: ProbeAttachment
    let milliseconds: Double
    let answer: String
}

@MainActor
private final class AttachmentBenchmarkProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let messageName = "probe"
    private let attachment: ProbeAttachment
    private let timeout: TimeInterval

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<(Double, String), Never>?
    private var finished = false
    private var startedAt: CFTimeInterval = 0

    init(attachment: ProbeAttachment, timeout: TimeInterval = 20) {
        self.attachment = attachment
        self.timeout = timeout
    }

    func run(origin: URL) async -> (milliseconds: Double, answer: String) {
        let controller = WKUserContentController()
        controller.add(self, name: messageName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0
        if attachment == .inWindow {
            keyWindow()?.addSubview(webView)
        }
        self.webView = webView

        startedAt = CACurrentMediaTime()

        return await withCheckedContinuation { (continuation: CheckedContinuation<(Double, String), Never>) in
            self.continuation = continuation
            webView.loadHTMLString(Self.html, baseURL: origin)

            Task { [weak self, timeout] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(answer: "timeout")
            }
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == messageName else { return }
        finish(answer: String(describing: message.body))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(answer: "navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(answer: "navigation failed: \(error.localizedDescription)")
    }

    private func finish(answer: String) {
        guard !finished else { return }
        finished = true

        let elapsed = (CACurrentMediaTime() - startedAt) * 1000
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: (elapsed, answer))
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private static let html = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"></head>
    <body>
    <script>
    (function(){
      var post = function(v){ try { window.webkit.messageHandlers.probe.postMessage(String(v)); } catch(e){} };
      if (!window.ApplePaySession) { post('noApplePayAPI'); return; }
      var merchantId = 'merchant.' + window.location.hostname + '.stripe';
      try {
        Promise.resolve(window.ApplePaySession.canMakePaymentsWithActiveCard(merchantId))
          .then(function(v){ post(v); })
          .catch(function(e){ post('error: ' + e); });
      } catch (e) { post('error: ' + e); }
    })();
    </script>
    </body>
    </html>
    """
}

struct ProbeAttachmentBenchmarkView: View {
    @State private var origin = benchmarkDefaultOrigin
    @State private var runsPerMode = 5
    @State private var runs: [BenchmarkRun] = []
    @State private var isRunning = false
    @State private var copied = false

    var body: some View {
        Form {
            Section("Origin") {
                TextField("https://...", text: $origin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("benchmarkOrigin")
            }

            Section {
                Text("Cold numbers only come from the first run after a force quit. Use the single-run buttons for that, and the A/B loop for warm runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Run") {
                Stepper("Runs per mode: \(runsPerMode)", value: $runsPerMode, in: 1...20)

                Button(isRunning ? "Running..." : "Run warm A/B benchmark") {
                    Task { await runBenchmark(modes: ProbeAttachment.allCases, count: runsPerMode) }
                }
                .disabled(isRunning || URL(string: origin)?.scheme != "https")
                .accessibilityIdentifier("runBenchmark")

                ForEach(ProbeAttachment.allCases, id: \.self) { attachment in
                    Button("First run after launch: \(attachment.label)") {
                        Task { await runBenchmark(modes: [attachment], count: 1) }
                    }
                    .disabled(isRunning || URL(string: origin)?.scheme != "https")
                }

                Button("Clear results") { runs = [] }
                    .disabled(isRunning || runs.isEmpty)
            }

            if !runs.isEmpty {
                Section("Medians") {
                    ForEach(ProbeAttachment.allCases, id: \.self) { attachment in
                        if let median = median(for: attachment) {
                            LabeledContent(attachment.label, value: String(format: "%.0f ms", median))
                        }
                    }
                }

                Section("Runs") {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(run.index). \(run.attachment.label)")
                                .font(.subheadline.weight(.semibold))
                            Text(String(format: "%.0f ms, answer: %@", run.milliseconds, run.answer))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(copied ? "Copied" : "Copy results as text") {
                        UIPasteboard.general.string = resultsText
                        copied = true
                    }
                }
            }
        }
        .navigationTitle("Probe attachment")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runBenchmark(modes: [ProbeAttachment], count: Int) async {
        guard let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" else { return }

        isRunning = true
        copied = false
        defer { isRunning = false }

        for iteration in 0..<count {
            for attachment in modes {
                let result = await AttachmentBenchmarkProbe(attachment: attachment).run(origin: url)
                runs.append(
                    BenchmarkRun(
                        index: runs.count + 1,
                        attachment: attachment,
                        milliseconds: result.milliseconds,
                        answer: result.answer
                    )
                )
            }
            if iteration < count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func median(for attachment: ProbeAttachment) -> Double? {
        let values = runs.filter { $0.attachment == attachment }.map(\.milliseconds).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count % 2 == 1 { return values[middle] }
        return (values[middle - 1] + values[middle]) / 2
    }

    private var resultsText: String {
        var lines = ["origin: \(origin)"]
        for attachment in ProbeAttachment.allCases {
            if let median = median(for: attachment) {
                lines.append(String(format: "%@ median: %.0f ms", attachment.label, median))
            }
        }
        lines.append("")
        for run in runs {
            lines.append(String(format: "%d\t%@\t%.0f ms\t%@", run.index, run.attachment.label, run.milliseconds, run.answer))
        }
        return lines.joined(separator: "\n")
    }
}
