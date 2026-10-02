//
//  PromoOfferSigningClient.swift
//  helium-swift
//

import Foundation

/// Internal signer that asks Helium's server to produce the promotional offer JWS
/// with the org's App Store Connect In-App Purchase key.
final class HeliumPromoOfferSigningClient: HeliumPromoOfferSigner {

    static let shared = HeliumPromoOfferSigningClient()

    typealias RequestPerformer = (URLRequest) async throws -> (Data, URLResponse)

    private let requestPerformer: RequestPerformer
    private let timeoutInterval: TimeInterval

    init(
        requestPerformer: @escaping RequestPerformer = { request in
            try await URLSession.shared.data(for: request)
        },
        timeoutInterval: TimeInterval = 10
    ) {
        self.requestPerformer = requestPerformer
        self.timeoutInterval = timeoutInterval
    }

    struct SigningError: LocalizedError {
        /// Machine-readable code returned by the server, e.g. "no_signing_key".
        let code: String

        var errorDescription: String? { "promo offer signing failed: \(code)" }
    }

    private struct SignResponse: Decodable {
        let compactJWS: String
        let keyId: String
        let nonce: String
    }

    private struct SignErrorResponse: Decodable {
        let error: String
    }

    /// The sign endpoint URL. `customAPIEndpoint` points at the full on-launch
    /// URL, so the base is derived by stripping the trailing "on-launch".
    static func signEndpointURL() -> String {
        if let custom = Helium.config.customAPIEndpoint,
           var components = URLComponents(string: custom) {
            var pathParts = components.path.split(separator: "/").map(String.init)
            if pathParts.last == "on-launch" {
                pathParts.removeLast()
            }
            pathParts.append(contentsOf: ["promo-offer", "sign"])
            components.path = "/" + pathParts.joined(separator: "/")
            components.query = nil
            components.fragment = nil
            if let url = components.string {
                return url
            }
        }
        return HeliumAPIEndpoint.defaultBaseURL + "promo-offer/sign"
    }

    func signPromoOffer(productId: String, offerId: String, appTransactionId: String?) async throws -> String {
        guard let apiKey = Helium.shared.controller?.apiKey ?? Helium.lastApiKeyUsed else {
            throw SigningError(code: "not_initialized")
        }

        var body: [String: Any] = [
            "apiKey": apiKey,
            "productId": productId,
            "offerId": offerId,
        ]
        if let appTransactionId {
            body["appTransactionId"] = appTransactionId
        }

        guard let url = URL(string: Self.signEndpointURL()) else {
            throw SigningError(code: "invalid_endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await requestPerformer(request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let code = (try? JSONDecoder().decode(SignErrorResponse.self, from: data))?.error ?? "http_\(statusCode)"
            throw SigningError(code: code)
        }

        let decoded = try JSONDecoder().decode(SignResponse.self, from: data)
        return decoded.compactJWS
    }
}
