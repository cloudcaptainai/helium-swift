import XCTest
@testable import Helium

/// Tests for `PaddleBFFClient` — the second half of the SDK pre-fetch chain
/// (HEL-5326). This client calls Paddle's checkout-service BFF directly
/// (`POST /transaction-checkout`), mirroring exactly what the bundler does
/// at runtime so the JSON body returned by Paddle is identical whether we
/// fetched it from the SDK or the bundle.
///
/// Bundler reference (server/heliumStandalonePaddle.ts and server/builder.js):
///   * URL selection: paddleClientToken.startsWith("test_") → sandbox host,
///     otherwise prod host. SDK uses the same convention so a sandbox token
///     never accidentally hits prod (and vice versa).
///   * Headers: `Content-Type: application/json`, `Paddle-Clienttoken: <token>`.
///   * Body: `{ data: { settings: { variant: "express", ... }, transaction_id } }`.
///
/// Network is intercepted via MockURLProtocol so the tests are offline.
final class PaddleBFFClientTests: XCTestCase {

    private var session: URLSession!
    private var client: PaddleBFFClient!

    override func setUp() {
        super.setUp()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = PaddleBFFClient(urlSession: session)

        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // Helper: minimum well-formed BFF response body. Real Paddle response is
    // far richer (items, totals, methods_available, ip_geo_*, etc.), but
    // these tests only need to confirm the SDK parses the basic envelope —
    // the rich body gets forwarded raw to the bundle via `rawBody`.
    private static let stubResponseBody = """
    {
        "data": {
            "id": "che_test_session_id",
            "transaction_id": "txn_test_id",
            "status": "draft"
        }
    }
    """

    private func okResponseHandler(echoBody: String = stubResponseBody) -> ((URLRequest) throws -> (HTTPURLResponse, Data?)) {
        return { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, echoBody.data(using: .utf8)!)
        }
    }

    // MARK: - URL selection

    func testCreateTransactionCheckout_usesSandboxURL_whenClientTokenIsSandboxToken() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "test_abc123",
            iosBundleId: nil
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(
            captured.url?.absoluteString,
            "https://sandbox-checkout-service.paddle.com/transaction-checkout",
            "Sandbox tokens (prefix `test_`) must route to sandbox-checkout-service.paddle.com — must mirror the bundler's URL selection."
        )
    }

    func testCreateTransactionCheckout_usesProductionURL_whenClientTokenIsProductionToken() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "live_abc123",
            iosBundleId: nil
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(
            captured.url?.absoluteString,
            "https://checkout-service.paddle.com/transaction-checkout",
            "Non-`test_` tokens must route to production checkout-service.paddle.com."
        )
    }

    // MARK: - Headers

    func testCreateTransactionCheckout_sendsPaddleClienttokenHeader() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "test_my_token_value",
            iosBundleId: nil
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        XCTAssertEqual(
            captured.value(forHTTPHeaderField: "Paddle-Clienttoken"),
            "test_my_token_value",
            "Paddle-Clienttoken header is the seller-auth mechanism for the BFF — wrong token → 401."
        )
        XCTAssertEqual(
            captured.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
    }

    // MARK: - Body shape

    func testCreateTransactionCheckout_sendsTransactionIdInBody() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_specific_id_for_test",
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any])
        let data = try XCTUnwrap(bodyDict["data"] as? [String: Any])
        XCTAssertEqual(
            data["transaction_id"] as? String,
            "txn_specific_id_for_test",
            "transaction_id must be the bandit's response — Paddle uses it to bind the checkout session."
        )
    }

    func testCreateTransactionCheckout_sendsRequiredSettings() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any])
        let data = try XCTUnwrap(bodyDict["data"] as? [String: Any])
        let settings = try XCTUnwrap(data["settings"] as? [String: Any])

        // These fields are what Paddle's BFF expects for the express checkout
        // variant (see Paddle BFF doc and server/heliumStandalonePaddle.ts).
        XCTAssertEqual(settings["variant"] as? String, "express")
        XCTAssertEqual(settings["display_mode"] as? String, "inline")
        XCTAssertEqual(settings["theme"] as? String, "light")
        XCTAssertEqual(settings["locale"] as? String, "en")
        XCTAssertNotNil(settings["source_page"], "source_page is strict-validated by Paddle — required.")
    }

    func testCreateTransactionCheckout_sourcePageDerivesFromTokenEnvironment_appendsBundleIdWhenProvided() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "test_xyz",
            iosBundleId: "com.example.testapp"
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any])
        let data = try XCTUnwrap(bodyDict["data"] as? [String: Any])
        let settings = try XCTUnwrap(data["settings"] as? [String: Any])

        // For sandbox tokens, source_page must hit the staging-allowlisted
        // origin (bundles-staging.clickthrough.to). The iosBundleId rides
        // along as a query param so Paddle can attribute transactions per
        // app for AUP enforcement.
        XCTAssertEqual(
            settings["source_page"] as? String,
            "https://bundles-staging.clickthrough.to?helium_ios_bundle_id=com.example.testapp"
        )
    }

    /// `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`
    /// leaves reserved query delimiters like `?`, `&`, `=` unescaped when
    /// they appear in the *value*. A bundle id like
    /// "com.example.app?evil=1" would produce a URL where the second `?`
    /// terminates the source_page query string, fragmenting the URL Paddle
    /// validates against its allow-list. We use URLComponents/URLQueryItem
    /// so the value is escaped correctly; this test locks that in.
    func testCreateTransactionCheckout_sourcePage_escapesReservedCharsInBundleId() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "test_xyz",
            iosBundleId: "com.example.app?evil=1&"
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any])
        let data = try XCTUnwrap(bodyDict["data"] as? [String: Any])
        let settings = try XCTUnwrap(data["settings"] as? [String: Any])
        let sourcePage = try XCTUnwrap(settings["source_page"] as? String)

        // Reserved query delimiters MUST be percent-encoded in the value
        // portion. After encoding, the URL should still parse cleanly via
        // URLComponents into a single query item with the original raw value.
        let components = try XCTUnwrap(URLComponents(string: sourcePage))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.count, 1, "Reserved chars must not split the value into multiple query items")
        XCTAssertEqual(items[0].name, "helium_ios_bundle_id")
        XCTAssertEqual(items[0].value, "com.example.app?evil=1&")
    }

    func testCreateTransactionCheckout_sourcePage_omitsBundleIdQueryWhenNotProvided() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        _ = try await client.createTransactionCheckout(
            transactionId: "txn_xxx",
            paddleClientToken: "live_xyz",
            iosBundleId: nil
        )

        let captured = try XCTUnwrap(MockURLProtocol.capturedRequests.first)
        let bodyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.httpBody ?? Data()) as? [String: Any])
        let data = try XCTUnwrap(bodyDict["data"] as? [String: Any])
        let settings = try XCTUnwrap(data["settings"] as? [String: Any])

        // No bundle id → bare origin (prod, since token isn't `test_`).
        XCTAssertEqual(
            settings["source_page"] as? String,
            "https://bundles.clickthrough.to"
        )
    }

    // MARK: - Response decoding

    func testCreateTransactionCheckout_decodesResponseAndPreservesRawBody() async throws {
        MockURLProtocol.requestHandler = okResponseHandler()

        let result = try await client.createTransactionCheckout(
            transactionId: "txn_test_id",
            paddleClientToken: "test_xyz",
            iosBundleId: nil
        )

        // The coordinator + ctx encoder both rely on preserving the FULL
        // response body — Paddle returns rich data the bundle parses into
        // its own PaddleCheckoutContext. Locking in that the raw bytes
        // are accessible (not just a few decoded fields) protects against
        // accidental "save space, drop fields" refactors later.
        let raw = try XCTUnwrap(String(data: result.rawBody, encoding: .utf8))
        XCTAssertTrue(raw.contains("che_test_session_id"))
        XCTAssertTrue(raw.contains("txn_test_id"))

        // Decoded fields for the SDK's own bookkeeping (cache keying,
        // sanity checks).
        XCTAssertEqual(result.checkoutId, "che_test_session_id")
        XCTAssertEqual(result.transactionId, "txn_test_id")
    }

    // MARK: - Error path

    func testCreateTransactionCheckout_throwsOnNon2xxResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, "{\"errors\":[{\"code\":\"unauthorized\"}]}".data(using: .utf8)!)
        }

        do {
            _ = try await client.createTransactionCheckout(
                transactionId: "txn_xxx",
                paddleClientToken: "test_xyz",
                iosBundleId: nil
            )
            XCTFail("Expected createTransactionCheckout to throw on 401")
        } catch let PaddleBFFError.requestFailed(statusCode, _) {
            XCTAssertEqual(statusCode, 401)
        } catch {
            XCTFail("Expected PaddleBFFError.requestFailed but got \(type(of: error)): \(error)")
        }
    }
}
