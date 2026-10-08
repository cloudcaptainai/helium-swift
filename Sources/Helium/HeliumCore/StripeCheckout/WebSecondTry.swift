import Foundation

/// The second try of a paywall's linked web paywall: a separately published web paywall that the
/// bundler compiles into the same web bundle, so the page can switch to it in place. The server
/// sends it only while the install's gate is on and both paywalls use the same payment provider.
struct WebSecondTryInfo: Codable, Equatable {
    var paywallUUID: String
    var paywallVersionUUID: String
    var paywallTemplateName: String?
    /// Absent means the page uses the conditions compiled into its bundle.
    var conditions: [String]?
    var productsOfferedPaddle: [String]?
    var productsOfferedStripe: [String]?

    func productsOffered(by provider: HeliumPaymentProcessor) -> [String] {
        switch provider {
        case .paddle: return productsOfferedPaddle ?? []
        case .stripe: return productsOfferedStripe ?? []
        case .appStore: return []
        }
    }
}

extension KeyedDecodingContainer {
    /// A malformed second try is treated as absent, with a warning so a shape mismatch with the
    /// server shows up. It decodes alongside the rest of the paywall, so throwing would fail the
    /// entire config over a feature the page can do without.
    func decodeIfPresent(
        _ type: WebSecondTryInfo.Type,
        forKey key: Key
    ) throws -> WebSecondTryInfo? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        do {
            return try decode(WebSecondTryInfo.self, forKey: key)
        } catch {
            HeliumLogger.log(.warn, category: .config,
                             "Ignoring a malformed webSecondTry, so this paywall has no web second try: \(error)")
            return nil
        }
    }
}

extension HeliumPaywallInfo {
    /// The web second try, while the SDK's flag for it is on.
    var activeWebSecondTry: WebSecondTryInfo? {
        HeliumFetchedConfigManager.shared.isFeatureEnabled(.webSecondTry) ? webSecondTry : nil
    }
}

/// The web second try as one external web checkout hands it to its page, fixed when the
/// checkout opens.
struct WebSecondTryCheckout {
    let info: WebSecondTryInfo
    let provider: HeliumPaymentProcessor
    /// The page's kill switch: it shows the second try only when this is true.
    let enabled: Bool

    init(
        info: WebSecondTryInfo,
        provider: HeliumPaymentProcessor,
        paddleOutcomes: [String: PaddlePrefetchOutcome]
    ) {
        self.info = info
        self.provider = provider
        switch provider {
        case .stripe:
            enabled = true
        case .paddle:
            // The page can only render a Paddle price from a bootstrap prefetched for this checkout.
            let priceIds = PaddleCheckoutPrefetchCoordinator.extractPriceIds(
                from: info.productsOffered(by: .paddle)
            )
            enabled = !priceIds.isEmpty && priceIds.allSatisfy { priceId in
                if case .ready = paddleOutcomes[priceId] ?? .notStarted { return true }
                return false
            }
        case .appStore:
            enabled = false
        }
    }

    /// The second try's products, while its page may sell them.
    var purchasableProducts: [String] {
        enabled ? info.productsOffered(by: provider) : []
    }

    /// The `secondTry` ctx block.
    var ctx: [String: Any] {
        var ctx: [String: Any] = [
            "enabled": enabled,
            "paywallUUID": info.paywallUUID,
            "paywallVersionUUID": info.paywallVersionUUID,
        ]
        if let conditions = info.conditions {
            ctx["conditions"] = conditions
        }
        return ctx
    }
}
