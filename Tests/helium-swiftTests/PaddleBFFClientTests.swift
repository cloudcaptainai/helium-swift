import XCTest
@testable import Helium

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
            "https://sandbox-checkout-service.paddle.com/transaction-checkout"
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
            "https://checkout-service.paddle.com/transaction-checkout"
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
            "test_my_token_value"
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
            "txn_specific_id_for_test"
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

        XCTAssertEqual(settings["variant"] as? String, "express")
        XCTAssertEqual(settings["display_mode"] as? String, "inline")
        XCTAssertEqual(settings["theme"] as? String, "light")
        XCTAssertEqual(settings["locale"] as? String, "en")
        XCTAssertNotNil(settings["source_page"])
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

        XCTAssertEqual(
            settings["source_page"] as? String,
            "https://bundles-staging.clickthrough.to?helium_ios_bundle_id=com.example.testapp"
        )
    }

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

        let components = try XCTUnwrap(URLComponents(string: sourcePage))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.count, 1)
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

        let raw = try XCTUnwrap(String(data: result.rawBody, encoding: .utf8))
        XCTAssertTrue(raw.contains("che_test_session_id"))
        XCTAssertTrue(raw.contains("txn_test_id"))

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
