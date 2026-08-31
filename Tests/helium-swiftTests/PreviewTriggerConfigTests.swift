import XCTest
@testable import Helium

/// Tests for `HeliumFetchedConfigManager.setPreviewTriggerConfig`, which builds the
/// config for the paywall preview control panel by cloning an existing trigger's
/// config and overriding selected fields.
final class PreviewTriggerConfigTests: XCTestCase {

    private let previewTrigger = HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER
    private let donorBundleUrl = "https://cdn.example.com/bundles/bundle_donor123.html"
    private let donorWebCheckoutUrl = "https://checkout.example.com/donor-web-paywall"
    private let previewBundleUrl = "https://cdn.example.com/bundles/bundle_preview456.html"
    private let secondTryTrigger = HeliumFetchedConfigManager.HELIUM_PREVIEW_SECOND_TRY_TRIGGER
    private let secondTryBundleUrl = "https://cdn.example.com/bundles/bundle_secondtry789.html"

    override func setUp() {
        super.setUp()
        HeliumFetchedConfigManager.reset()
    }

    override func tearDown() {
        HeliumFetchedConfigManager.reset()
        super.tearDown()
    }

    private func makeDonorPaywallInfo() -> HeliumPaywallInfo {
        var info = makeTestPaywallInfo(paywallName: "donor_paywall", products: ["donor.product"])
        info.resolvedConfig = AnyCodable([
            "baseStack": [
                "componentProps": [
                    "bundleURL": donorBundleUrl,
                    "shouldEnableScroll": false
                ]
            ]
        ] as [String: Any])
        info.additionalPaywallFields = JSON([
            "paywallBundleUrl": donorBundleUrl,
            "webPaywallBundleUrl": donorWebCheckoutUrl,
        ])
        info.productsOfferedStripe = ["donor_stripe:price_1"]
        info.productsOfferedPaddle = ["donor_paddle:pri_1"]
        info.webProductsOfferedPaddle = ["donor_paddle_web:pri_2"]
        info.forceShowFallback = true
        return info
    }

    private func setPreviewConfig(
        productIds: [String] = ["preview.product"],
        productIdsStripe: [String] = [],
        productIdsPaddle: [String] = [],
        productIdsPaddleWeb: [String] = [],
        productIdsStripeWeb: [String] = [],
        webPaywallBundleUrl: String? = nil,
        shouldEnableScroll: Bool? = nil,
        identity: HeliumFetchedConfigManager.PreviewPaywallIdentity? = nil,
        secondTry: HeliumFetchedConfigManager.PreviewSecondTryBundle? = nil
    ) throws {
        try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
            bundleId: "preview456",
            bundleUrl: previewBundleUrl,
            bundleHtml: "<html>preview</html>",
            productIds: productIds,
            productIdsStripe: productIdsStripe,
            productIdsPaddle: productIdsPaddle,
            productIdsPaddleWeb: productIdsPaddleWeb,
            productIdsStripeWeb: productIdsStripeWeb,
            webPaywallBundleUrl: webPaywallBundleUrl,
            shouldEnableScroll: shouldEnableScroll,
            identity: identity,
            secondTry: secondTry
        )
    }

    private func makeSecondTryBundle(
        shouldEnableScroll: Bool? = nil,
        identity: HeliumFetchedConfigManager.PreviewPaywallIdentity? = nil
    ) -> HeliumFetchedConfigManager.PreviewSecondTryBundle {
        HeliumFetchedConfigManager.PreviewSecondTryBundle(
            bundleId: "secondtry789",
            bundleUrl: secondTryBundleUrl,
            bundleHtml: "<html>second try</html>",
            productIds: ["secondtry.product"],
            productIdsStripe: ["secondtry_stripe:price_2"],
            productIdsPaddle: [],
            shouldEnableScroll: shouldEnableScroll,
            identity: identity
        )
    }

    private var previewInfo: HeliumPaywallInfo? {
        HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls[previewTrigger]
    }

    private var previewComponentProps: [String: Any]? {
        guard let resolved = previewInfo?.resolvedConfig.value as? [String: Any],
              let baseStack = resolved["baseStack"] as? [String: Any] else {
            return nil
        }
        return baseStack["componentProps"] as? [String: Any]
    }

    func testPreviewDoesNotInheritWebCheckoutUrl() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig()

        XCTAssertNotNil(previewInfo)
        XCTAssertNil(previewInfo?.webPaywallBundleUrl)
    }

    func testPreviewUsesProvidedWebCheckoutUrl() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))
        let previewWebCheckoutUrl = "https://bundles-staging.clickthrough.to/x/bundle_1778610753360.html"

        try setPreviewConfig(webPaywallBundleUrl: previewWebCheckoutUrl)

        XCTAssertEqual(previewInfo?.webPaywallBundleUrl, previewWebCheckoutUrl)
    }

    func testPreviewTreatsEmptyWebCheckoutUrlAsMissing() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(webPaywallBundleUrl: "")

        XCTAssertNil(previewInfo?.webPaywallBundleUrl)
    }

    func testDonorTriggerKeepsItsWebCheckoutUrl() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig()

        let donorInfo = HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls["a_trigger"]
        XCTAssertEqual(donorInfo?.webPaywallBundleUrl, donorWebCheckoutUrl)
    }

    func testPreviewUsesProvidedBundleUrlAndProducts() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(
            productIds: ["preview.product"],
            productIdsStripe: ["preview_stripe:price_9"],
            productIdsPaddle: [],
            productIdsPaddleWeb: ["preview_paddle_web:pri_9"]
        )

        XCTAssertEqual(previewInfo?.extractedBundleUrl, previewBundleUrl)
        XCTAssertEqual(previewInfo?.productsOfferedIOS, ["preview.product"])
        XCTAssertEqual(previewInfo?.productsOfferedStripe, ["preview_stripe:price_9"])
        XCTAssertEqual(previewInfo?.productsOfferedPaddle, [])
        XCTAssertEqual(previewInfo?.webProductsOfferedPaddle, ["preview_paddle_web:pri_9"])
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.fetchedConfig?.bundles?["preview456"],
            "<html>preview</html>"
        )
    }

    func testPreviewDoesNotInheritDonorScrollSetting() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig()

        XCTAssertEqual(previewComponentProps?["shouldEnableScroll"] as? Bool, true)
    }

    func testPreviewUsesProvidedScrollSetting() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(shouldEnableScroll: false)

        XCTAssertEqual(previewComponentProps?["shouldEnableScroll"] as? Bool, false)
    }

    func testDonorTriggerKeepsItsScrollSetting() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig()

        let donorInfo = HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls["a_trigger"]
        let donorResolved = donorInfo?.resolvedConfig.value as? [String: Any]
        let donorBaseStack = donorResolved?["baseStack"] as? [String: Any]
        let donorProps = donorBaseStack?["componentProps"] as? [String: Any]
        XCTAssertEqual(donorProps?["shouldEnableScroll"] as? Bool, false)
    }

    func testPreviewCarriesPreviewedPaywallIdentity() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(identity: HeliumFetchedConfigManager.PreviewPaywallIdentity(
            paywallId: 42,
            paywallUuid: "f3e96335-f7df-4f28-b439-9506d37c793e",
            templateName: "Previewed Paywall"
        ))

        XCTAssertEqual(previewInfo?.paywallID, 42)
        XCTAssertEqual(previewInfo?.paywallUUID, "f3e96335-f7df-4f28-b439-9506d37c793e")
        XCTAssertEqual(previewInfo?.paywallTemplateName, "Previewed Paywall")
    }

    func testPreviewIdentityWithoutIntIdUsesZero() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(identity: HeliumFetchedConfigManager.PreviewPaywallIdentity(
            paywallId: nil,
            paywallUuid: "f3e96335-f7df-4f28-b439-9506d37c793e",
            templateName: "Previewed Paywall"
        ))

        XCTAssertEqual(previewInfo?.paywallID, 0)
    }

    func testPreviewWithoutIdentityKeepsDonorIdentity() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig()

        XCTAssertEqual(previewInfo?.paywallID, 1)
        XCTAssertEqual(previewInfo?.paywallTemplateName, "donor_paywall")
    }

    func testJsonMirrorCarriesPreviewedPaywallIdentity() throws {
        let config = makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()])
        let configJSON = try JSON(data: JSONEncoder().encode(config))
        injectConfig(config, json: configJSON)

        try setPreviewConfig(identity: HeliumFetchedConfigManager.PreviewPaywallIdentity(
            paywallId: 42,
            paywallUuid: "f3e96335-f7df-4f28-b439-9506d37c793e",
            templateName: "Previewed Paywall"
        ))

        let entryJSON = HeliumFetchedConfigManager.shared.fetchedConfigJSON?["triggerToPaywalls"][previewTrigger]
        XCTAssertEqual(entryJSON?["paywallID"].int, 42)
        XCTAssertEqual(entryJSON?["paywallUUID"].string, "f3e96335-f7df-4f28-b439-9506d37c793e")
        XCTAssertEqual(entryJSON?["paywallTemplateName"].string, "Previewed Paywall")
    }

    func testSecondTryCarriesItsOwnIdentity() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(
            identity: HeliumFetchedConfigManager.PreviewPaywallIdentity(
                paywallId: 42,
                paywallUuid: "f3e96335-f7df-4f28-b439-9506d37c793e",
                templateName: "Previewed Paywall"
            ),
            secondTry: makeSecondTryBundle(identity: HeliumFetchedConfigManager.PreviewPaywallIdentity(
                paywallId: 7,
                paywallUuid: "aa11bb22-cc33-4444-9555-666677778888",
                templateName: "Previewed Second Try"
            ))
        )

        XCTAssertEqual(secondTryInfo?.paywallID, 7)
        XCTAssertEqual(secondTryInfo?.paywallUUID, "aa11bb22-cc33-4444-9555-666677778888")
        XCTAssertEqual(secondTryInfo?.paywallTemplateName, "Previewed Second Try")
    }

    func testPreviewClearsForceShowFallback() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig()

        XCTAssertNil(previewInfo?.forceShowFallback)
    }

    func testPreviewClonesAlphabeticallyFirstTrigger() throws {
        var otherInfo = makeTestPaywallInfo(paywallName: "other_paywall")
        otherInfo.resolvedConfig = AnyCodable([
            "baseStack": ["componentProps": ["bundleURL": "https://cdn.example.com/bundles/bundle_other.html"]]
        ] as [String: Any])
        injectConfig(makeTestConfig(triggers: [
            "b_trigger": otherInfo,
            "a_trigger": makeDonorPaywallInfo(),
        ]))

        try setPreviewConfig()

        XCTAssertEqual(previewInfo?.paywallTemplateName, "donor_paywall")
    }

    func testPreviewWithoutAdditionalFieldsOnDonor() throws {
        var donor = makeDonorPaywallInfo()
        donor.additionalPaywallFields = nil
        injectConfig(makeTestConfig(triggers: ["a_trigger": donor]))

        try setPreviewConfig()

        XCTAssertNil(previewInfo?.webPaywallBundleUrl)
        XCTAssertEqual(previewInfo?.extractedBundleUrl, previewBundleUrl)
    }

    func testJsonMirrorUpdatesBundleUrl() throws {
        let config = makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()])
        let configJSON = try JSON(data: JSONEncoder().encode(config))
        injectConfig(config, json: configJSON)

        try setPreviewConfig()

        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(previewTrigger)?["baseStack"]["componentProps"]["bundleURL"].string,
            previewBundleUrl
        )
    }

    func testJsonMirrorUpdatesScrollSetting() throws {
        let config = makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()])
        let configJSON = try JSON(data: JSONEncoder().encode(config))
        injectConfig(config, json: configJSON)

        try setPreviewConfig(shouldEnableScroll: false)

        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(previewTrigger)?["baseStack"]["componentProps"]["shouldEnableScroll"].bool,
            false
        )
    }

    func testJsonMirrorDoesNotInheritDonorScrollSetting() throws {
        let config = makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()])
        let configJSON = try JSON(data: JSONEncoder().encode(config))
        injectConfig(config, json: configJSON)

        try setPreviewConfig()

        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(previewTrigger)?["baseStack"]["componentProps"]["shouldEnableScroll"].bool,
            true
        )
    }

    func testSecondPreviewClonesOriginalTriggerNotThePreview() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))
        let firstWebCheckoutUrl = "https://bundles-staging.clickthrough.to/x/bundle_first.html"

        try setPreviewConfig(webPaywallBundleUrl: firstWebCheckoutUrl)
        // Simulates backing out of the first preview and selecting another version,
        // now that helium_preview_trigger itself is in triggerToPaywalls.
        try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
            bundleId: "preview789",
            bundleUrl: "https://cdn.example.com/bundles/bundle_preview789.html",
            bundleHtml: "<html>second</html>",
            productIds: ["second.product"],
            productIdsStripe: [],
            productIdsPaddle: [],
            productIdsPaddleWeb: [],
            productIdsStripeWeb: [],
            webPaywallBundleUrl: nil
        )

        // Cloned from the original trigger, not from the first preview
        XCTAssertEqual(previewInfo?.paywallTemplateName, "donor_paywall")
        XCTAssertEqual(previewInfo?.extractedBundleUrl, "https://cdn.example.com/bundles/bundle_preview789.html")
        XCTAssertEqual(previewInfo?.productsOfferedIOS, ["second.product"])
        // First preview's checkout URL must not leak into the second
        XCTAssertNil(previewInfo?.webPaywallBundleUrl)
    }

    // MARK: - Second try preview trigger

    private var secondTryInfo: HeliumPaywallInfo? {
        HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls[secondTryTrigger]
    }

    func testSecondTryInstallsItsOwnTriggerEntry() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(secondTry: makeSecondTryBundle())

        XCTAssertEqual(secondTryInfo?.extractedBundleUrl, secondTryBundleUrl)
        XCTAssertEqual(secondTryInfo?.productsOfferedIOS, ["secondtry.product"])
        XCTAssertEqual(secondTryInfo?.productsOfferedStripe, ["secondtry_stripe:price_2"])
        XCTAssertEqual(secondTryInfo?.webProductsOfferedPaddle, [])
        XCTAssertNil(secondTryInfo?.webPaywallBundleUrl)
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.fetchedConfig?.bundles?["secondtry789"],
            "<html>second try</html>"
        )
    }

    func testPreviewWithoutSecondTryClearsStaleSecondTryEntry() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(secondTry: makeSecondTryBundle())
        try setPreviewConfig()

        XCTAssertNil(secondTryInfo)
    }

    func testDonorSelectionSkipsStaleSecondTryEntry() throws {
        // The second try trigger sorts before real triggers starting with letters > "h", so a
        // stale entry would win alphabetical donor selection if it weren't excluded.
        injectConfig(makeTestConfig(triggers: ["z_trigger": makeDonorPaywallInfo()]))

        try setPreviewConfig(secondTry: makeSecondTryBundle())
        try setPreviewConfig(secondTry: makeSecondTryBundle())

        XCTAssertEqual(previewInfo?.paywallTemplateName, "donor_paywall")
        XCTAssertEqual(secondTryInfo?.paywallTemplateName, "donor_paywall")
    }

    func testFallbackPreviewClearsSecondTryEntry() throws {
        injectConfig(makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()]))
        let fallbackConfig = makeTestConfig(
            triggers: [HeliumFallbackViewManager.defaultFallbackTrigger: makeDonorPaywallInfo()],
            bundles: ["donor123": "<html>fallback</html>"]
        )
        HeliumFallbackViewManager.shared.injectFallbackConfigForTesting(fallbackConfig)
        defer { HeliumFallbackViewManager.reset() }

        try setPreviewConfig(secondTry: makeSecondTryBundle())
        XCTAssertTrue(HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger())

        XCTAssertNil(secondTryInfo)
    }

    func testJsonMirrorInstallsAndClearsSecondTryEntry() throws {
        let config = makeTestConfig(triggers: ["a_trigger": makeDonorPaywallInfo()])
        let configJSON = try JSON(data: JSONEncoder().encode(config))
        injectConfig(config, json: configJSON)

        try setPreviewConfig(secondTry: makeSecondTryBundle(shouldEnableScroll: false))
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(secondTryTrigger)?["baseStack"]["componentProps"]["bundleURL"].string,
            secondTryBundleUrl
        )
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.getResolvedConfigJSONForTrigger(secondTryTrigger)?["baseStack"]["componentProps"]["shouldEnableScroll"].bool,
            false
        )

        try setPreviewConfig()
        XCTAssertEqual(
            HeliumFetchedConfigManager.shared.fetchedConfigJSON?["triggerToPaywalls"][secondTryTrigger],
            JSON.null
        )
    }

    func testThrowsWhenNoConfigAvailable() {
        XCTAssertThrowsError(try setPreviewConfig()) { error in
            guard case HeliumControlPanelError.noConfigAvailable = error else {
                return XCTFail("Expected noConfigAvailable, got \(error)")
            }
        }
    }

    // MARK: - /paywall-previews response decoding

    /// Trimmed real staging response shape (see HEL-6146 contract doc).
    private let previewsResponseJSON = """
    {
      "productIds": ["yearly_2999", "trial_monthly_499"],
      "paywalls": [
        {
          "paywallUuid": "f3e96335-f7df-4f28-b439-9506d37c793e",
          "paywallName": "Paddle Regular Paywall Test 1",
          "versions": [
            {
              "versionId": "1d9626d4-a8c8-40c1-8a59-c63c6f2b521e",
              "versionStatus": "published",
              "versionNumber": 6,
              "bundleUrl": "https://bundles-staging.heliumpaywall.com/x/bundle_1778611087914.html",
              "previewUrl": "https://res.cloudinary.com/x/screenshot.png",
              "productIds": ["yearly_2999", "trial_monthly_499"],
              "stripeProductIds": [],
              "paddleProductIds": ["pro_01knraky336brhcn1r0atkk2ac:pri_01knrarqkpxk9kvf785tny0y5e"],
              "webPaddleProductIds": ["pro_01kppzadma4mq2yx61e5spzgxe:pri_01kpsgnvzp69jyatar1znzxtex"],
              "webPaywallBundleUrl": "https://bundles-staging.clickthrough.to/x/bundle_1778610753360.html",
              "shouldEnableScroll": false,
              "lastSavedAt": "2026-05-12T18:38:24.345+00:00"
            },
            {
              "versionId": "32a1d295-60e1-425a-a4f7-c566e31a9f9c",
              "versionStatus": "draft",
              "versionNumber": 5,
              "bundleUrl": "https://bundles-staging.heliumpaywall.com/x/bundle_1776908502633.html",
              "previewUrl": "https://res.cloudinary.com/x/preview.png",
              "productIds": ["yearly_2999"],
              "stripeProductIds": [],
              "paddleProductIds": [],
              "webPaddleProductIds": [],
              "webPaywallBundleUrl": null,
              "lastSavedAt": "2026-04-23T01:41:50.897123+00:00"
            }
          ]
        }
      ]
    }
    """

    func testDecodesPreviewsResponseWithWebPaywallBundleUrl() throws {
        let response = try JSONDecoder().decode(
            HeliumControlPanelResponse.self,
            from: Data(previewsResponseJSON.utf8)
        )

        let versions = response.paywalls[0].versions
        XCTAssertEqual(
            versions[0].webPaywallBundleUrl,
            "https://bundles-staging.clickthrough.to/x/bundle_1778610753360.html"
        )
        XCTAssertEqual(versions[0].webPaddleProductIds, ["pro_01kppzadma4mq2yx61e5spzgxe:pri_01kpsgnvzp69jyatar1znzxtex"])
        XCTAssertEqual(versions[0].shouldEnableScroll, false)
        XCTAssertNil(versions[1].webPaywallBundleUrl)
        XCTAssertNil(versions[1].shouldEnableScroll)
        XCTAssertFalse(response.paywalls[0].isWebPaywall)
    }

    func testDecodesLegacyPreviewsResponseWithoutNewFields() throws {
        // Response shape before the endpoint change: no per-version webPaywallBundleUrl,
        // top-level stripeProductIds/paddleProductIds still present.
        let legacyJSON = """
        {
          "productIds": ["yearly_2999"],
          "stripeProductIds": [],
          "paddleProductIds": [],
          "paywalls": [
            {
              "paywallUuid": "f3e96335-f7df-4f28-b439-9506d37c793e",
              "paywallName": "Legacy Paywall",
              "versions": [
                {
                  "versionId": "1d9626d4-a8c8-40c1-8a59-c63c6f2b521e",
                  "versionStatus": "published",
                  "versionNumber": 1,
                  "bundleUrl": "https://bundles.heliumpaywall.com/x/bundle_1.html",
                  "previewUrl": null,
                  "productIds": ["yearly_2999"],
                  "stripeProductIds": [],
                  "lastSavedAt": null
                }
              ]
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            HeliumControlPanelResponse.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertNil(response.paywalls[0].versions[0].webPaywallBundleUrl)
        XCTAssertNil(response.paywalls[0].versions[0].paddleProductIds)
        XCTAssertNil(response.paywalls[0].versions[0].shouldEnableScroll)
        XCTAssertNil(response.paywalls[0].secondTry)
        XCTAssertFalse(response.paywalls[0].isWebPaywall)
        XCTAssertNil(response.paywalls[0].paywallTemplateName)
        XCTAssertNil(response.paywalls[0].paywallId)
    }

    func testDecodesPreviewedPaywallIdentityFields() throws {
        let json = """
        {
          "productIds": [],
          "paywalls": [
            {
              "paywallUuid": "f3e96335-f7df-4f28-b439-9506d37c793e",
              "paywallName": "Premium",
              "paywallTemplateName": "Premium",
              "paywallId": 42,
              "isWeb": false,
              "versions": [],
              "secondTry": {
                "paywallUuid": "aa11bb22-cc33-4444-9555-666677778888",
                "paywallName": "Premium Offer",
                "paywallTemplateName": "Premium Offer",
                "paywallId": 7,
                "versionStatus": "published",
                "bundleUrl": "https://bundles-staging.heliumpaywall.com/x/bundle_2nd.html",
                "productIds": [],
                "stripeProductIds": [],
                "paddleProductIds": []
              }
            },
            {
              "paywallUuid": "1c8d6e2b-7777-4888-9999-000011112222",
              "paywallName": "Legacy",
              "paywallTemplateName": "Legacy",
              "paywallId": null,
              "isWeb": false,
              "versions": []
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            HeliumControlPanelResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.paywalls[0].paywallTemplateName, "Premium")
        XCTAssertEqual(response.paywalls[0].paywallId, 42)
        XCTAssertEqual(response.paywalls[0].secondTry?.paywallTemplateName, "Premium Offer")
        XCTAssertEqual(response.paywalls[0].secondTry?.paywallId, 7)
        XCTAssertEqual(response.paywalls[1].paywallTemplateName, "Legacy")
        XCTAssertNil(response.paywalls[1].paywallId)
    }

    func testDecodesSecondTryEntry() throws {
        let json = """
        {
          "productIds": [],
          "paywalls": [
            {
              "paywallUuid": "f3e96335-f7df-4f28-b439-9506d37c793e",
              "paywallName": "Main Paywall",
              "versions": [],
              "secondTry": {
                "paywallUuid": "aa11bb22-cc33-4444-9555-666677778888",
                "paywallName": "Discount Offer",
                "versionStatus": "published",
                "bundleUrl": "https://bundles-staging.heliumpaywall.com/x/bundle_2nd.html",
                "productIds": ["yearly_1999"],
                "stripeProductIds": [],
                "paddleProductIds": [],
                "shouldEnableScroll": false
              }
            },
            {
              "paywallUuid": "1c8d6e2b-7777-4888-9999-000011112222",
              "paywallName": "No Second Try",
              "versions": [],
              "secondTry": null
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            HeliumControlPanelResponse.self,
            from: Data(json.utf8)
        )

        let secondTry = response.paywalls[0].secondTry
        XCTAssertEqual(secondTry?.paywallName, "Discount Offer")
        XCTAssertEqual(secondTry?.versionStatus, "published")
        XCTAssertEqual(secondTry?.bundleUrl, "https://bundles-staging.heliumpaywall.com/x/bundle_2nd.html")
        XCTAssertEqual(secondTry?.productIds, ["yearly_1999"])
        XCTAssertEqual(secondTry?.shouldEnableScroll, false)
        XCTAssertNil(response.paywalls[1].secondTry)
    }

    func testDecodesWebPaywallEntry() throws {
        let json = """
        {
          "productIds": [],
          "paywalls": [
            {
              "paywallUuid": "0b7f5c1a-1111-4222-8333-444455556666",
              "paywallName": "Web Checkout Paywall",
              "isWeb": true,
              "versions": [
                {
                  "versionId": "9d8c7b6a-aaaa-4bbb-8ccc-dddeeefff000",
                  "versionStatus": "published",
                  "versionNumber": 3,
                  "bundleUrl": "https://bundles-staging.clickthrough.to/x/bundle_1778610753360.html",
                  "previewUrl": null,
                  "productIds": [],
                  "stripeProductIds": [],
                  "paddleProductIds": ["pro_web:pri_web"],
                  "webPaddleProductIds": [],
                  "webPaywallBundleUrl": null,
                  "lastSavedAt": null
                }
              ]
            },
            {
              "paywallUuid": "1c8d6e2b-7777-4888-9999-000011112222",
              "paywallName": "Native Paywall",
              "isWeb": false,
              "versions": []
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            HeliumControlPanelResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(response.paywalls[0].isWebPaywall)
        XCTAssertEqual(
            response.paywalls[0].versions[0].bundleUrl,
            "https://bundles-staging.clickthrough.to/x/bundle_1778610753360.html"
        )
        XCTAssertFalse(response.paywalls[1].isWebPaywall)
    }

    func testRecognizesWebPaywallByBundleHostWhenIsWebIsMissing() throws {
        let json = """
        {
          "productIds": [],
          "paywalls": [
            {
              "paywallUuid": "0b7f5c1a-1111-4222-8333-444455556666",
              "paywallName": "Web Checkout Paywall",
              "versions": [
                {
                  "versionId": "9d8c7b6a-aaaa-4bbb-8ccc-dddeeefff000",
                  "versionStatus": "published",
                  "versionNumber": 3,
                  "bundleUrl": "https://bundles.clickthrough.to/x/bundle_1778610753360.html",
                  "previewUrl": null,
                  "productIds": [],
                  "stripeProductIds": [],
                  "paddleProductIds": ["pro_web:pri_web"],
                  "lastSavedAt": null
                }
              ]
            },
            {
              "paywallUuid": "1c8d6e2b-7777-4888-9999-000011112222",
              "paywallName": "Native Paywall",
              "versions": [
                {
                  "versionId": "32a1d295-60e1-425a-a4f7-c566e31a9f9c",
                  "versionStatus": "published",
                  "versionNumber": 1,
                  "bundleUrl": "https://bundles.heliumpaywall.com/x/bundle_1.html",
                  "previewUrl": null,
                  "productIds": ["yearly_2999"],
                  "stripeProductIds": [],
                  "lastSavedAt": null
                }
              ]
            },
            {
              "paywallUuid": "2d9e7f3c-8888-4999-aaaa-bbbbccccdddd",
              "paywallName": "Server Says Native",
              "isWeb": false,
              "versions": [
                {
                  "versionId": "43b2e3a6-71f2-4b36-b5c8-d77f42c0a1b2",
                  "versionStatus": "published",
                  "versionNumber": 2,
                  "bundleUrl": "https://bundles.clickthrough.to/x/bundle_2.html",
                  "previewUrl": null,
                  "productIds": [],
                  "stripeProductIds": [],
                  "lastSavedAt": null
                }
              ]
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            HeliumControlPanelResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(response.paywalls[0].isWebPaywall)
        XCTAssertFalse(response.paywalls[1].isWebPaywall)
        XCTAssertFalse(response.paywalls[2].isWebPaywall)
    }
}
