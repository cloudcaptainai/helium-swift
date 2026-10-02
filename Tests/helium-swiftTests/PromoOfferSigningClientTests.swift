import XCTest
@testable import Helium
import StoreKit

private struct StubSigner: HeliumPromoOfferSigner {
    func signPromoOffer(productId: String, offerId: String, appTransactionId: String?) async throws -> String {
        return "stub.jws"
    }
}

final class PromoOfferSigningClientTests: HeliumTestCase {

    private var previousCustomEndpoint: String?
    private var previousSigner: HeliumPromoOfferSigner?

    override func setUp() {
        super.setUp()
        previousCustomEndpoint = Helium.config.customAPIEndpoint
        previousSigner = Helium.config.promoOfferSigner
    }

    override func tearDown() {
        Helium.config.customAPIEndpoint = previousCustomEndpoint
        Helium.config.promoOfferSigner = previousSigner
        super.tearDown()
    }

    // MARK: Endpoint derivation

    func testSignEndpointDefaultsToHeliumBase() {
        Helium.config.customAPIEndpoint = nil
        XCTAssertEqual(
            HeliumPromoOfferSigningClient.signEndpointURL(),
            "https://api-v2.tryhelium.com/promo-offer/sign"
        )
    }

    func testSignEndpointStripsOnLaunchFromCustomEndpoint() {
        Helium.config.customAPIEndpoint = "https://staging.example.com/on-launch"
        XCTAssertEqual(
            HeliumPromoOfferSigningClient.signEndpointURL(),
            "https://staging.example.com/promo-offer/sign"
        )
    }

    func testSignEndpointKeepsCustomBaseWithoutOnLaunchSuffix() {
        Helium.config.customAPIEndpoint = "https://staging.example.com/"
        XCTAssertEqual(
            HeliumPromoOfferSigningClient.signEndpointURL(),
            "https://staging.example.com/promo-offer/sign"
        )
    }

    // MARK: Request + response handling

    private func makeClient(
        statusCode: Int = 200,
        body: Data = Data(#"{"compactJWS":"a.b.c","keyId":"K1","nonce":"n1"}"#.utf8),
        captured: @escaping (URLRequest) -> Void = { _ in }
    ) -> HeliumPromoOfferSigningClient {
        return HeliumPromoOfferSigningClient(requestPerformer: { request in
            captured(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        })
    }

    func testPostsExpectedBodyToSignEndpoint() async throws {
        Helium.config.customAPIEndpoint = nil
        Helium.lastApiKeyUsed = "test-api-key"

        var capturedBody: [String: Any]?
        var capturedURL: String?
        var capturedMethod: String?
        let client = makeClient { request in
            capturedURL = request.url?.absoluteString
            capturedMethod = request.httpMethod
            capturedBody = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }

        let jws = try await client.signPromoOffer(
            productId: "com.example.yearly",
            offerId: "OFFER50",
            appTransactionId: "tx-1"
        )
        XCTAssertEqual(jws, "a.b.c")
        XCTAssertEqual(capturedURL, "https://api-v2.tryhelium.com/promo-offer/sign")
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedBody?["apiKey"] as? String, "test-api-key")
        XCTAssertEqual(capturedBody?["productId"] as? String, "com.example.yearly")
        XCTAssertEqual(capturedBody?["offerId"] as? String, "OFFER50")
        XCTAssertEqual(capturedBody?["appTransactionId"] as? String, "tx-1")
    }

    func testOmitsAppTransactionIdWhenNil() async throws {
        Helium.lastApiKeyUsed = "test-api-key"
        var capturedBody: [String: Any]?
        let client = makeClient { request in
            capturedBody = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }
        _ = try await client.signPromoOffer(productId: "p", offerId: "o", appTransactionId: nil)
        XCTAssertNil(capturedBody?["appTransactionId"])
    }

    func testNon200SurfacesServerErrorCode() async {
        Helium.lastApiKeyUsed = "test-api-key"
        let client = makeClient(
            statusCode: 404,
            body: Data(#"{"error":"no_signing_key"}"#.utf8)
        )
        do {
            _ = try await client.signPromoOffer(productId: "p", offerId: "o", appTransactionId: nil)
            XCTFail("expected throw")
        } catch let error as HeliumPromoOfferSigningClient.SigningError {
            XCTAssertEqual(error.code, "no_signing_key")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNon200WithoutErrorBodyUsesStatusCode() async {
        Helium.lastApiKeyUsed = "test-api-key"
        let client = makeClient(statusCode: 500, body: Data("oops".utf8))
        do {
            _ = try await client.signPromoOffer(productId: "p", offerId: "o", appTransactionId: nil)
            XCTFail("expected throw")
        } catch let error as HeliumPromoOfferSigningClient.SigningError {
            XCTAssertEqual(error.code, "http_500")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: Signer resolution

    func testResolvePromoOfferSignerPrefersCustomerHook() {
        Helium.config.promoOfferSigner = StubSigner()
        let delegate = StoreKitDelegate()
        XCTAssertTrue(delegate.resolvePromoOfferSigner() is StubSigner)
    }

    func testResolvePromoOfferSignerUsesBanditClientByDefault() {
        Helium.config.promoOfferSigner = nil
        let delegate = StoreKitDelegate()
        XCTAssertTrue(delegate.resolvePromoOfferSigner() is HeliumPromoOfferSigningClient)
    }

    // MARK: StoreKitDelegate surface

    func testStoreKitDelegateSupportsPromotionalOffers() {
        XCTAssertTrue(StoreKitDelegate().supportsPromotionalOffers)
    }

    func testMapPurchaseResultMapsUserCancelledAndPending() async {
        let delegate = StoreKitDelegate()
        let cancelled = await delegate.mapPurchaseResult(.userCancelled)
        guard case .cancelled = cancelled else {
            return XCTFail("expected cancelled")
        }
        let pending = await delegate.mapPurchaseResult(.pending)
        guard case .pending = pending else {
            return XCTFail("expected pending")
        }
    }
}
