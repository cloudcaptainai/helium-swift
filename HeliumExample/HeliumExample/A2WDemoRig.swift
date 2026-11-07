import Combine
import Foundation
import Helium
import ObjectiveC
import SwiftUI
import UIKit

/// Demo-only rig for the App2Web Paddle sandbox demo. Activated by the
/// `A2W_DEMO_SCENE` launch environment variable; inert otherwise.
enum A2WDemoScene: String {
    case today
    case sandbox
    case live
    case entitledDebug = "entitled-debug"
    case entitledProduction = "entitled-production"

    static var current: A2WDemoScene? {
        ProcessInfo.processInfo.environment["A2W_DEMO_SCENE"].flatMap(A2WDemoScene.init(rawValue:))
    }

    var title: String {
        switch self {
        case .today: return "SCENE 1 · TODAY: GB buyer, DEBUG build, no #402 bandit follow-up"
        case .sandbox: return "SCENE 2 · AFTER #402 + bandit follow-up: GB buyer, sandbox Paddle account"
        case .live: return "SCENE 3 · LIVE STAYS PROTECTED: GB buyer, live Paddle account (pk_live_)"
        case .entitledDebug: return "SCENE 4a · ENTITLEMENT: paddleEnvironment=sandbox, SDK environment=DEBUG"
        case .entitledProduction: return "SCENE 4b · ENTITLEMENT: paddleEnvironment=sandbox, SDK environment=PRODUCTION"
        }
    }

    var simulatedLabels: [String] {
        switch self {
        case .today:
            return ["REAL: production on-launch (bandit #193 geo gate), no rig"]
        case .sandbox:
            return ["SIMULATED: bandit follow-up (on-launch sent with US locale)",
                    "SIMULATED: checkout ip_geo_country_code rewritten US→GB"]
        case .live:
            return ["SIMULATED: bandit follow-up (on-launch sent with US locale)",
                    "SIMULATED: live Paddle account (token live_…, BFF reply stubbed, pk_live_, GB)"]
        case .entitledDebug:
            return ["SIMULATED: check-entitlement reply (paddleEnvironment: \"sandbox\")"]
        case .entitledProduction:
            return ["SIMULATED: check-entitlement reply (paddleEnvironment: \"sandbox\")",
                    "SIMULATED: SDK environment forced to PRODUCTION (HELIUM_DEMO_FORCE_ENVIRONMENT)"]
        }
    }
}

enum A2WDemoRig {
    static let trigger = ProcessInfo.processInfo.environment["A2W_DEMO_TRIGGER"] ?? "hel7261_paddle_a2w"
    static let rigLiveToken = "live_DEMO_RIGGED_NOT_A_REAL_TOKEN"
    private static let eventListener = A2WDemoEventListener()

    static func installIfRequested() {
        guard let scene = A2WDemoScene.current else { return }
        URLProtocol.registerClass(A2WDemoURLProtocol.self)
        URLSessionConfiguration.a2wInstallProtocol()
        Helium.identify.userId = "a2w-demo-\(scene.rawValue)-\(Int(Date().timeIntervalSince1970))"
        A2WDemoOverlay.shared.show(scene: scene)
    }

    static func postInitialize() {
        guard let scene = A2WDemoScene.current else { return }
        Helium.shared.addHeliumEventListener(eventListener)
        switch scene {
        case .today, .sandbox, .live:
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                A2WDemoOverlay.shared.log("presentPaywall(trigger: \(trigger))")
                Helium.shared.presentPaywall(trigger: trigger) { reason in
                    A2WDemoOverlay.shared.log("paywall not shown: \(reason)")
                }
            }
        case .entitledDebug, .entitledProduction:
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await Helium.entitlements.invalidateCache()
                let paddle = await Helium.entitlements.hasActivePaddleEntitlement()
                let any = await Helium.entitlements.hasAny()
                A2WDemoOverlay.shared.result(
                    paddle ? "ENTITLED ✅  hasActivePaddleEntitlement() = true (hasAny = \(any))"
                           : "NOT ENTITLED ⛔  hasActivePaddleEntitlement() = false (hasAny = \(any))",
                    ok: paddle
                )
            }
        }
    }
}

final class A2WDemoEventListener: HeliumEventListener {
    func onHeliumEvent(event: HeliumEvent) {
        let name = String(describing: type(of: event))
        let interesting = ["PurchaseFailed", "PaywallOpen", "PaywallOpenFailed", "PaywallSkipped", "PurchasePressed", "PaywallClose"]
        guard interesting.contains(where: { name.contains($0) }) else { return }
        var text = name
        if name.contains("Failed") {
            let error = Mirror(reflecting: event).children.first { $0.label == "error" }?.value
            let errorText = error.map { String(describing: $0) } ?? "nil"
            text = "\(name) error: \(errorText.prefix(160))"
            DispatchQueue.main.async {
                A2WDemoOverlay.shared.result("BLOCKED ⛔ no Paddle checkout opened (\(errorText.prefix(60)))", ok: false)
            }
        }
        DispatchQueue.main.async { A2WDemoOverlay.shared.log("event: \(text)") }
    }
}

// MARK: - URLProtocol rig

final class A2WDemoURLProtocol: URLProtocol {
    private static let handledKey = "A2WDemoHandled"
    private static let forwardSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = (config.protocolClasses ?? []).filter { $0 != A2WDemoURLProtocol.self }
        return URLSession(configuration: config)
    }()

    static var sampleURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("a2w-demo-bff-sample.json")
    }

    private enum Kind { case onLaunch, paddleBFF, checkEntitlement }

    private static func kind(of request: URLRequest) -> Kind? {
        guard let url = request.url, let host = url.host else { return nil }
        if host.hasSuffix("checkout-service.paddle.com"), url.path.hasSuffix("/transaction-checkout") { return .paddleBFF }
        if host.contains("tryhelium.com") {
            if url.path.hasSuffix("/on-launch") { return .onLaunch }
            if url.path.hasSuffix("paddle/check-entitlement") { return .checkEntitlement }
        }
        return nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard A2WDemoScene.current != nil, URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        return kind(of: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scene = A2WDemoScene.current, let kind = Self.kind(of: request) else { return }
        switch kind {
        case .onLaunch: handleOnLaunch(scene: scene)
        case .paddleBFF: handleBFF(scene: scene)
        case .checkEntitlement: handleCheckEntitlement(scene: scene)
        }
    }

    override func stopLoading() {}

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func forward(body: Data?, transform: @escaping (Data, HTTPURLResponse) -> Data) {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        mutable.httpBodyStream = nil
        mutable.httpBody = body
        mutable.setValue(nil, forHTTPHeaderField: "Content-Length")
        if let body { print("[A2W demo] forwarding \(body.count) bytes to \(mutable.url?.path ?? "")") }
        Self.forwardSession.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            let out = transform(data ?? Data(), http)
            self.respond(status: http.statusCode, data: out, headers: http.allHeaderFields as? [String: String] ?? [:])
        }.resume()
    }

    private func respond(status: Int, data: Data, headers: [String: String] = [:]) {
        var headers = headers.filter { !["content-encoding", "content-length"].contains($0.key.lowercased()) }
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func handleOnLaunch(scene: A2WDemoScene) {
        var body = bodyData()
        if scene == .sandbox || scene == .live,
           let data = body,
           var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var userContext = json["userContext"] as? [String: Any] {
            var locale = userContext["locale"] as? [String: Any] ?? [:]
            let original = "\(locale["currentCountry"] ?? "nil")/\(locale["storeCountryCode"] ?? "nil")"
            locale["currentCountry"] = "US"
            locale["storeCountryCode"] = "US"
            userContext["locale"] = locale
            json["userContext"] = userContext
            body = try? JSONSerialization.data(withJSONObject: json)
            log("SIMULATED bandit follow-up: on-launch locale \(original) → US/US")
        }
        forward(body: body) { data, http in
            guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], json["error"] == nil else {
                self.log("on-launch HTTP \(http.statusCode): \(String(decoding: data.prefix(160), as: UTF8.self))")
                return data
            }
            let triggers = json["triggerToPaywalls"] as? [String: Any] ?? [:]
            let served = triggers[A2WDemoRig.trigger] != nil
            let token = (json["paddleClientToken"] as? String) ?? "nil"
            self.log("on-launch: Paddle trigger \(A2WDemoRig.trigger) \(served ? "SERVED" : "DROPPED (geo gate)") · \(triggers.count) triggers")
            if !served, [.today, .sandbox, .live].contains(scene) {
                DispatchQueue.main.async {
                    A2WDemoOverlay.shared.result("BLOCKED ⛔ bandit dropped the Paddle paywall → fallback only, no Paddle checkout", ok: false)
                }
            }
            if scene == .live {
                json["paddleClientToken"] = A2WDemoRig.rigLiveToken
                self.log("SIMULATED live account: paddleClientToken \(token.prefix(5))… → live_…")
                return (try? JSONSerialization.data(withJSONObject: json)) ?? data
            }
            if token != "nil" {
                self.log("on-launch paddleClientToken: \(token.prefix(5))… → #402 treats as sandbox Paddle account")
            }
            return data
        }
    }

    private static func rewriteCheckout(_ data: Data, applePayKeyPrefix: String?) -> (Data, String) {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var payload = json["data"] as? [String: Any] else { return (data, "unparsed") }
        let originalCountry = payload["ip_geo_country_code"] as? String ?? "nil"
        payload["ip_geo_country_code"] = "GB"
        payload["ip_geo_postal_code"] = "SW1A 1AA"
        var applePayKey = "none"
        if var payments = payload["payments"] as? [String: Any],
           var methods = payments["methods_available"] as? [[String: Any]] {
            for index in methods.indices {
                guard var stripe = methods[index]["stripe_options"] as? [String: Any],
                      let key = stripe["api_key"] as? String else { continue }
                var newKey = key
                if let applePayKeyPrefix {
                    newKey = applePayKeyPrefix + key.drop(while: { $0 != "_" }).dropFirst().drop(while: { $0 != "_" })
                }
                stripe["api_key"] = newKey
                applePayKey = String(newKey.prefix(8)) + "…"
                methods[index]["stripe_options"] = stripe
            }
            payments["methods_available"] = methods
            payload["payments"] = payments
        }
        json["data"] = payload
        let out = (try? JSONSerialization.data(withJSONObject: json)) ?? data
        return (out, "ip_geo \(originalCountry)→GB · Apple Pay key \(applePayKey)")
    }

    private func handleBFF(scene: A2WDemoScene) {
        let host = request.url?.host ?? ""
        switch scene {
        case .live:
            guard let sample = try? Data(contentsOf: Self.sampleURL) else {
                log("live rig needs a captured sample: run scene 'sandbox' first")
                respond(status: 500, data: Data("{}".utf8))
                return
            }
            let (out, summary) = Self.rewriteCheckout(sample, applePayKeyPrefix: "pk_live_")
            log("SIMULATED BFF reply from \(host): \(summary)")
            respond(status: 200, data: out)
        default:
            let body = bodyData()
            forward(body: body) { data, http in
                guard (200..<300).contains(http.statusCode) else {
                    self.log("BFF \(host) HTTP \(http.statusCode)")
                    return data
                }
                let (out, summary) = Self.rewriteCheckout(data, applePayKeyPrefix: nil)
                try? data.write(to: Self.sampleURL)
                self.log("REAL BFF \(host) · SIMULATED \(summary)")
                return out
            }
        }
    }

    private func handleCheckEntitlement(scene: A2WDemoScene) {
        guard scene == .entitledDebug || scene == .entitledProduction else {
            forward(body: bodyData()) { data, _ in data }
            return
        }
        let sentEnvironment = ((try? JSONSerialization.jsonObject(with: bodyData() ?? Data())) as? [String: Any])?["environment"] as? String ?? "nil"
        let reply: [String: Any] = [
            "hasActiveEntitlement": true,
            "customerId": "ctm_demo_sandbox_customer",
            "customerExists": true,
            "paddleEnvironment": "sandbox",
            "subscriptions": [[
                "subscriptionId": "sub_demo_sandbox_0001",
                "productId": "pro_01ksh12jzke0js52vf1a6tbpta",
                "priceId": "pri_01ksh16g6e9saxmgw5ydzavm5n",
                "status": "active",
                "productName": "Elite Plan",
                "startedAt": "2026-11-06T12:00:00Z",
                "currentPeriodEnd": "2026-12-06T12:00:00Z",
                "cancelAtPeriodEnd": false,
            ]],
        ]
        log("SIMULATED check-entitlement reply: paddleEnvironment=\"sandbox\", 1 active sub · request environment=\(sentEnvironment)")
        respond(status: 200, data: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
    }

    private func log(_ text: String) {
        print("[A2W demo] \(text)")
        DispatchQueue.main.async { A2WDemoOverlay.shared.log(text) }
    }
}

extension URLSessionConfiguration {
    private static var a2wInstalled = false

    static func a2wInstallProtocol() {
        guard !a2wInstalled else { return }
        a2wInstalled = true
        let pairs: [(Selector, Selector)] = [
            (#selector(getter: URLSessionConfiguration.default), #selector(URLSessionConfiguration.a2wDefault)),
            (#selector(getter: URLSessionConfiguration.ephemeral), #selector(URLSessionConfiguration.a2wEphemeral)),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getClassMethod(URLSessionConfiguration.self, original),
                  let b = class_getClassMethod(URLSessionConfiguration.self, replacement) else { continue }
            method_exchangeImplementations(a, b)
        }
    }

    @objc class func a2wDefault() -> URLSessionConfiguration {
        let config = a2wDefault()
        config.protocolClasses = [A2WDemoURLProtocol.self] + (config.protocolClasses ?? [])
        return config
    }

    @objc class func a2wEphemeral() -> URLSessionConfiguration {
        let config = a2wEphemeral()
        config.protocolClasses = [A2WDemoURLProtocol.self] + (config.protocolClasses ?? [])
        return config
    }
}

// MARK: - Overlay

final class A2WDemoOverlayModel: ObservableObject {
    @Published var scene: A2WDemoScene?
    @Published var lines: [String] = []
    @Published var result: String?
    @Published var resultOK = false
}

struct A2WDemoOverlayView: View {
    @ObservedObject var model: A2WDemoOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let scene = model.scene {
                Text(scene.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text("Paddle account = paddle_environment · SDK build = environment (\(environmentLabel))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                ForEach(scene.simulatedLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(label.hasPrefix("REAL") ? .green : .yellow)
                }
            }
            ForEach(Array(model.lines.suffix(5).enumerated()), id: \.offset) { _, line in
                Text("› " + line)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(3)
            }
            if let result = model.result {
                Text(result)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(model.resultOK ? .green : .red)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.82))
        .cornerRadius(10)
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 18)
        .allowsHitTesting(false)
    }

    private var environmentLabel: String {
        ProcessInfo.processInfo.environment["HELIUM_DEMO_FORCE_ENVIRONMENT"]?.uppercased() ?? "DEBUG"
    }
}

final class A2WDemoPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

final class A2WDemoOverlay {
    static let shared = A2WDemoOverlay()
    private let model = A2WDemoOverlayModel()
    private var window: UIWindow?

    func show(scene: A2WDemoScene) {
        model.scene = scene
        DispatchQueue.main.async { self.attachWhenReady() }
    }

    private func attachWhenReady() {
        guard window == nil else { return }
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.attachWhenReady() }
            return
        }
        let window = A2WDemoPassthroughWindow(windowScene: windowScene)
        window.windowLevel = .alert + 10
        let host = UIHostingController(rootView: A2WDemoOverlayView(model: model))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    func log(_ line: String) {
        model.lines.append(line)
    }

    func result(_ text: String, ok: Bool) {
        model.result = text
        model.resultOK = ok
    }
}
