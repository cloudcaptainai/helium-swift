import XCTest
@testable import Helium

final class PaddleCheckoutPrefetchClientTests: XCTestCase {

    private var session: URLSession!
    private var client: HeliumPaymentAPIClient!

    override func setUp() {
        super.setUp()

        URLProtocol.registerClass(MockURLProtocol.self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = HeliumPaymentAPIClient(urlSession: session)

        Helium.lastApiKeyUsed = "test_api_key_for_prefetch_tests"

        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        URLProtocol.unregisterClass(MockURLProtocol.self)
        Helium.lastApiKeyUsed = nil
        super.tearDown()
    }

    // MARK: - createPaddleTransactionForPaywall — success path

    func testCreatePaddleTransactionForPaywall_decodesSuccessResponse() async throws {
        let bodyJSON = """
        {
            "transactionId": "txn_01knspnrb3drka149qnaceps9a",
            "paddleCustomerId": "ctm_01k77z6m9t3rs0aw23h9gpv61e",
            "isKnownCustomer": true,
            "requestId": "req_test_xyz"
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        let result = try await client.createPaddleTransactionForPaywall(priceId: "pri_01km39t4kt3rs0aw23h9gpv61e")

        XCTAssertEqual(result.transactionId, "txn_01knspnrb3drka149qnaceps9a")
        XCTAssertEqual(result.paddleCustomerId, "ctm_01k77z6m9t3rs0aw23h9gpv61e")
        XCTAssertTrue(result.isKnownCustomer)
        XCTAssertEqual(result.requestId, "req_test_xyz")
    }

    func testCreatePaddleTransactionForPaywall_extractsBanditTransactionDataObject() throws {
        let body = #"{"banditTransactionData":{"planChange":{"type":"upgrade"},"enabled":true}}"#
        let transactionData = try XCTUnwrap(
            HeliumPaymentAPIClient.extractBanditTransactionData(from: Data(body.utf8))
        )
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: transactionData) as? [String: Any])
        let planChange = try XCTUnwrap(context["planChange"] as? [String: Any])

        XCTAssertEqual(planChange["type"] as? String, "upgrade")
        XCTAssertEqual(context["enabled"] as? Bool, true)
    }

    func testCreatePaddleTransactionForPaywall_ignoresNonObjectBanditTransactionData() {
        let bodies = [
            #"{}"#,
            #"{"banditTransactionData":null}"#,
            #"{"banditTransactionData":[]}"#,
            #"{"banditTransactionData":"upgrade"}"#,
            "garbage",
        ]

        for body in bodies {
            XCTAssertNil(
                HeliumPaymentAPIClient.extractBanditTransactionData(from: Data(body.utf8)),
                "Expected no context for \(body)"
            )
        }
    }

    func testCreatePaddleTransactionForPaywall_decodes2xxWhenBanditTransactionDataIsNotAnObject() async throws {
        let bodyJSON = """
        {
            "transactionId": "txn_context",
            "isKnownCustomer": false,
            "requestId": "req_context",
            "banditTransactionData": ["not", "an object"]
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(bodyJSON.utf8))
        }

        let result = try await client.createPaddleTransactionForPaywall(priceId: "pri_context")

        XCTAssertEqual(result.transactionId, "txn_context")
        XCTAssertNil(result.banditTransactionData)
    }

    func testPaymentAPICallsIncludeApplicationInfo() async throws {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let responseBody: [String: Any]
            if path.hasSuffix("/check-entitlement") {
                responseBody = ["hasActiveEntitlement": false, "subscriptions": []]
            } else if path.hasSuffix("/update-customer-metadata") {
                responseBody = ["updated": true]
            } else if path.hasSuffix("/create-portal-session") {
                responseBody = ["portalUrl": "https://example.com/portal"]
            } else {
                responseBody = [
                    "transactionId": "txn_metadata",
                    "isKnownCustomer": false,
                    "requestId": "req_metadata",
                ]
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, try JSONSerialization.data(withJSONObject: responseBody))
        }

        _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_metadata")

        let providers: [PaymentProviderConfig] = [.paddle, .stripe]
        var sources: [HeliumPaymentEntitlementsSource] = []
        defer { sources.forEach { $0.clearEntitlements() } }
        for provider in providers {
            let source = HeliumPaymentEntitlementsSource(provider: provider)
            sources.append(source)
            await source.refreshEntitlementsJoiningInFlightFetch()

            let manager = ExternalWebCheckoutManager(provider: provider, entitlementsSource: source)
            let updated = try await manager.updateCustomerMetadata()
            XCTAssertTrue(updated)
            let portalURL = try await manager.createPortalSession()
            XCTAssertEqual(portalURL.absoluteString, "https://example.com/portal")
        }

        let requests = MockURLProtocol.capturedRequests
        let expectedPathSuffixes = [
            "paddle/create-transaction-for-paywall",
            "paddle/check-entitlement",
            "paddle/update-customer-metadata",
            "paddle/create-portal-session",
            "stripe/check-entitlement",
            "stripe/update-customer-metadata",
            "stripe/create-portal-session",
        ]
        let requestPathSuffixes = requests.compactMap { request in
            request.url?.path.split(separator: "/").suffix(2).joined(separator: "/")
        }
        XCTAssertEqual(requestPathSuffixes.count, expectedPathSuffixes.count)
        XCTAssertEqual(Set(requestPathSuffixes), Set(expectedPathSuffixes))
        for request in requests {
            try assertApplicationInfo(in: request)
        }
        let paddleRequest = try XCTUnwrap(
            requests.first { $0.url?.path.hasSuffix("paddle/create-transaction-for-paywall") == true }
        )
        let paddleBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(paddleRequest.httpBody)) as? [String: Any]
        )
        XCTAssertNil(paddleBody["paywallInfo"])
    }

    private func assertApplicationInfo(in request: URLRequest) throws {
        let requestBody = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let applicationInfo = try XCTUnwrap(body["applicationInfo"] as? [String: Any])
        XCTAssertEqual(applicationInfo["platform"] as? String, "ios")
        XCTAssertEqual(applicationInfo["heliumSdk"] as? String, HeliumSdkConfig.shared.heliumSdk)
        XCTAssertEqual(applicationInfo["heliumSdkVersion"] as? String, BuildConstants.version)
        XCTAssertEqual(
            applicationInfo["heliumWrapperSdkVersion"] as? String,
            HeliumSdkConfig.shared.heliumWrapperSdkVersion
        )
    }

    func testCreatePaddleTransactionForPaywall_includesPaywallInfoInRequestBody() async throws {
        let bodyJSON = """
        {
            "transactionId": "txn_paywall_info",
            "isKnownCustomer": false,
            "requestId": "req_paywall_info"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(bodyJSON.utf8))
        }

        _ = try await client.createPaddleTransactionForPaywall(
            priceId: "pri_paywall_info",
            paywallUUID: "paywall-uuid",
            triggerName: "summer-offer"
        )

        let request = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let requestBody = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let paywallInfo = try XCTUnwrap(body["paywallInfo"] as? [String: Any])
        XCTAssertEqual(paywallInfo["paywallUUID"] as? String, "paywall-uuid")
        XCTAssertEqual(paywallInfo["triggerName"] as? String, "summer-offer")
    }

    func testCreatePaddleTransactionForPaywall_paddleCustomerIdOptionalForUnknownCustomer() async throws {
        let bodyJSON = """
        {
            "transactionId": "txn_unknown",
            "isKnownCustomer": false,
            "requestId": "req_unknown"
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        let result = try await client.createPaddleTransactionForPaywall(priceId: "pri_xyz")

        XCTAssertEqual(result.transactionId, "txn_unknown")
        XCTAssertNil(result.paddleCustomerId)
        XCTAssertFalse(result.isKnownCustomer)
    }

    // MARK: - createPaddleTransactionForPaywall — 409 alreadyEntitled handling

    func testCreatePaddleTransactionForPaywall_throwsAlreadyEntitledOn409DuplicateSubscription() async throws {
        let envelope = """
        {
            "error": {
                "type": "request_error",
                "code": "duplicate_subscription",
                "detail": "You already have an active subscription for this product"
            },
            "meta": { "requestId": "req_dup_001" }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409 duplicate_subscription")
        } catch let PaddlePrefetchError.alreadyEntitled(code, message, existingSubscriptionId) {
            XCTAssertEqual(code, "duplicate_subscription")
            XCTAssertTrue(
                message.contains("already have an active subscription"),
                "Expected detail message to be preserved on alreadyEntitled error; got \(message)"
            )
            XCTAssertNil(existingSubscriptionId)
        } catch {
            XCTFail("Expected PaddlePrefetchError.alreadyEntitled but got \(type(of: error)): \(error)")
        }
    }

    // MARK: - existingSubscriptionId extraction

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromErrorSubscriptionId() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "subscription_id": "sub_01k_path1"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path1")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromErrorSubscriptionIdCamelCase() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "subscriptionId": "sub_01k_path2"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path2")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromErrorMeta() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "meta": { "subscription_id": "sub_01k_path3" }
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path3")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromTopLevelSnakeCase() async throws {
        let envelope = """
        {
            "error": { "code": "duplicate_subscription", "detail": "x" },
            "subscription_id": "sub_01k_path4"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path4")
        }
    }

    func testCreatePaddleTransactionForPaywall_extractsExistingSubscriptionId_fromTopLevelCamelCase() async throws {
        let envelope = """
        {
            "error": { "code": "duplicate_subscription", "detail": "x" },
            "subscriptionId": "sub_01k_path5"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_01k_path5")
        }
    }

    func testCreatePaddleTransactionForPaywall_existingSubscriptionId_prefersMoreSpecificPath() async throws {
        let envelope = """
        {
            "error": {
                "code": "duplicate_subscription",
                "detail": "x",
                "subscription_id": "sub_specific"
            },
            "subscription_id": "sub_top_level_should_lose"
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected to throw")
        } catch let PaddlePrefetchError.alreadyEntitled(_, _, existingSubscriptionId) {
            XCTAssertEqual(existingSubscriptionId, "sub_specific")
        }
    }

    func testCreatePaddleTransactionForPaywall_throwsAlreadyEntitledOn409TrialAlreadyUsed() async throws {
        let envelope = """
        {
            "error": {
                "type": "request_error",
                "code": "trial_already_used",
                "detail": "Customer has already consumed a trial on a different product"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409 trial_already_used")
        } catch let PaddlePrefetchError.alreadyEntitled(code, message, _) {
            XCTAssertEqual(code, "trial_already_used")
            XCTAssertTrue(message.contains("Customer has already consumed a trial"))
        } catch {
            XCTFail("Expected PaddlePrefetchError.alreadyEntitled but got \(type(of: error)): \(error)")
        }
    }

    func testCreatePaddleTransactionForPaywall_unknownNon409CodePassesThroughAsServerError() async throws {
        let envelope = """
        {
            "error": {
                "type": "request_error",
                "code": "some_future_paddle_code",
                "detail": "Hypothetical new failure mode"
            }
        }
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (response, envelope.data(using: .utf8)!)
        }

        do {
            _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_xxx")
            XCTFail("Expected createPaddleTransactionForPaywall to throw on 409")
        } catch HeliumPaymentAPIError.serverError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 409)
            XCTAssertTrue(
                message.contains("some_future_paddle_code"),
                "Expected unknown 409 code to surface as serverError preserving the code in the message; got \(message)"
            )
        } catch {
            XCTFail("Expected HeliumPaymentAPIError.serverError but got \(type(of: error)): \(error)")
        }
    }

    // MARK: - createPaddleTransactionForPaywall — request shape

    func testCreatePaddleTransactionForPaywall_sendsCorrectBanditContract() async throws {
        let bodyJSON = """
        {"transactionId": "txn_x", "isKnownCustomer": false, "requestId": "req_x"}
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_specific_price")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let captured = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertTrue(
            captured.url?.path.hasSuffix("/paddle/create-transaction-for-paywall") ?? false,
            "Expected URL path to end with /paddle/create-transaction-for-paywall, got \(captured.url?.absoluteString ?? "nil")"
        )

        let bodyData = captured.httpBody ?? Data()
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(bodyDict["priceId"] as? String, "pri_specific_price")
        XCTAssertEqual(bodyDict["apiKey"] as? String, "test_api_key_for_prefetch_tests")

        XCTAssertNil(bodyDict["productPriceId"])

        XCTAssertEqual(bodyDict["heliumPersistentId"] as? String, HeliumIdentityManager.shared.getHeliumPersistentId())
        XCTAssertEqual(bodyDict["environment"] as? String, AppReceiptsHelper.shared.getEnvironment())
    }

    // MARK: - baseRequestBody

    func testBaseRequestBody_sendsEnvironmentForEveryProvider() throws {
        let expected = AppReceiptsHelper.shared.getEnvironment()
        XCTAssertEqual(expected, "DEBUG")

        let paddleBody = try client.baseRequestBody(provider: .paddle)
        let stripeBody = try client.baseRequestBody(provider: .stripe)

        XCTAssertEqual(paddleBody["environment"] as? String, expected)
        XCTAssertEqual(stripeBody["environment"] as? String, expected)
    }

    // MARK: - createPaddleTransactionForPaywall discountId forwarding

    func testCreatePaddleTransactionForPaywall_includesDiscountIdWhenProvided() async throws {
        let bodyJSON = """
        {"transactionId": "txn_x", "isKnownCustomer": false, "requestId": "req_x"}
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        _ = try await client.createPaddleTransactionForPaywall(
            priceId: "pri_specific_price",
            discountId: "dsc_01kt7y5xsh94z97bwfq4de1f7k"
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(bodyDict["priceId"] as? String, "pri_specific_price")
        XCTAssertEqual(
            bodyDict["discountId"] as? String,
            "dsc_01kt7y5xsh94z97bwfq4de1f7k",
            "Expected the bucket-level discount id to be forwarded in the create-transaction request body"
        )
    }

    func testCreatePaddleTransactionForPaywall_omitsDiscountIdWhenNil() async throws {
        let bodyJSON = """
        {"transactionId": "txn_x", "isKnownCustomer": false, "requestId": "req_x"}
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_no_discount")

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any]
        )
        XCTAssertNil(
            bodyDict["discountId"],
            "discountId must be omitted (not sent empty) when the price has no configured discount"
        )
    }

    func testCreatePaddleTransactionForPaywall_omitsDiscountIdWhenEmptyString() async throws {
        let bodyJSON = """
        {"transactionId": "txn_x", "isKnownCustomer": false, "requestId": "req_x"}
        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, bodyJSON.data(using: .utf8)!)
        }

        _ = try await client.createPaddleTransactionForPaywall(priceId: "pri_empty", discountId: "")

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any]
        )
        XCTAssertNil(
            bodyDict["discountId"],
            "An empty discountId must not be sent; omit it entirely when no discount is configured"
        )
    }

    // MARK: - ServerProductPrice defaultDiscountId decoding

    func testServerProductPrice_decodesDefaultDiscountId() throws {
        let json = """
        {
            "id": "pro_01kt7406rbge4zkz8qx48dt7mh",
            "priceId": "pri_01kt740yd827h5dweb3yxpg2x5",
            "defaultDiscountId": "dsc_01kt7y5xsh94z97bwfq4de1f7k"
        }
        """
        let price = try JSONDecoder().decode(ServerProductPrice.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(price.defaultDiscountId, "dsc_01kt7y5xsh94z97bwfq4de1f7k")
    }

    func testServerProductPrice_defaultDiscountIdAbsentWhenOmitted() throws {
        let json = """
        { "id": "pro_x", "priceId": "pri_x" }
        """
        let price = try JSONDecoder().decode(ServerProductPrice.self, from: json.data(using: .utf8)!)
        XCTAssertNil(price.defaultDiscountId)
    }
}
