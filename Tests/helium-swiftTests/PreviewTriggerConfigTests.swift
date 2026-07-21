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
                    "bundleURL": donorBundleUrl
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
        webPaywallBundleUrl: String? = nil
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
            webPaywallBundleUrl: webPaywallBundleUrl
        )
    }

    private var previewInfo: HeliumPaywallInfo? {
        HeliumFetchedConfigManager.shared.fetchedConfig?.triggerToPaywalls[previewTrigger]
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
        XCTAssertNil(versions[1].webPaywallBundleUrl)
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
    }
}
