import Foundation

extension PaddleCheckoutPrefetchCoordinator {

    enum PrefetchBanditStep {
        case success
        case alreadyEntitled(code: String, message: String)
        case failed(Error)
    }

    enum PrefetchBffStep {
        case success(rawBody: Data)
        case caBlocked(rawBody: Data)
        case failed(Error)
    }

    nonisolated static func trackBanditCompletion(
        priceId: String,
        discountId: String?,
        scope: PaywallObservabilityScope,
        startedAt: Date,
        chainStartedAt: Date,
        result: PrefetchBanditStep
    ) {
        let endpointCall: EndpointCallTelemetry
        let alreadyEntitledCode: String?
        let terminalOutcome: PaddlePrefetchOutcomeKind?
        let terminalErrorClass: String?

        switch result {
        case .success:
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt), success: true
            )
            alreadyEntitledCode = nil
            terminalOutcome = nil
            terminalErrorClass = nil
        case let .alreadyEntitled(code, message):
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt),
                success: false,
                errorClass: "PaddlePrefetchError.alreadyEntitled",
                errorMessage: message
            )
            alreadyEntitledCode = code
            terminalOutcome = .alreadyEntitled
            terminalErrorClass = nil
        case let .failed(error):
            let decomposed = decomposeError(error)
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt),
                success: false,
                httpStatus: decomposed.httpStatus,
                errorClass: decomposed.errorClass,
                errorMessage: decomposed.errorMessage
            )
            alreadyEntitledCode = nil
            terminalOutcome = .failed
            terminalErrorClass = decomposed.errorClass
        }

        HeliumObservabilityManager.shared.track(
            PaddlePrefetchBanditCompleted(
                priceId: priceId,
                discountId: discountId,
                endpointCall: endpointCall,
                alreadyEntitledCode: alreadyEntitledCode
            ),
            scope: scope
        )

        if let terminalOutcome {
            HeliumObservabilityManager.shared.track(
                PaddlePrefetchOutcomeFinalized(
                    priceId: priceId,
                    outcome: terminalOutcome,
                    errorClass: terminalErrorClass,
                    totalDurationMs: msSince(chainStartedAt),
                    ipGeoCountry: nil,
                    ipGeoRegion: nil,
                    ipGeoPostal: nil
                ),
                scope: scope
            )
        }
    }

    nonisolated static func trackBffCompletion(
        priceId: String,
        transactionId: String,
        scope: PaywallObservabilityScope,
        startedAt: Date,
        chainStartedAt: Date,
        result: PrefetchBffStep
    ) {
        let endpointCall: EndpointCallTelemetry
        let outcome: PaddlePrefetchOutcomeKind
        let errorClass: String?
        let ipGeo: (country: String?, region: String?, postal: String?)

        switch result {
        case let .success(rawBody):
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt), success: true
            )
            outcome = .ready
            errorClass = nil
            ipGeo = ipGeoFields(in: rawBody)
        case let .caBlocked(rawBody):
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt), success: true
            )
            outcome = .caBlocked
            errorClass = "PaddleCaliforniaBlocked"
            ipGeo = ipGeoFields(in: rawBody)
        case let .failed(error):
            let decomposed = decomposeError(error)
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt),
                success: false,
                httpStatus: decomposed.httpStatus,
                errorClass: decomposed.errorClass,
                errorMessage: decomposed.errorMessage
            )
            outcome = .failed
            errorClass = decomposed.errorClass
            ipGeo = (nil, nil, nil)
        }

        HeliumObservabilityManager.shared.track(
            PaddlePrefetchBffCompleted(
                priceId: priceId,
                transactionId: transactionId,
                endpointCall: endpointCall
            ),
            scope: scope
        )

        HeliumObservabilityManager.shared.track(
            PaddlePrefetchOutcomeFinalized(
                priceId: priceId,
                outcome: outcome,
                errorClass: errorClass,
                totalDurationMs: msSince(chainStartedAt),
                ipGeoCountry: ipGeo.country,
                ipGeoRegion: ipGeo.region,
                ipGeoPostal: ipGeo.postal
            ),
            scope: scope
        )
    }
}

private func ipGeoFields(in rawBody: Data) -> (country: String?, region: String?, postal: String?) {
    guard let parsed = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
          let data = parsed["data"] as? [String: Any] else {
        return (nil, nil, nil)
    }
    return (
        data["ip_geo_country_code"] as? String,
        data["ip_geo_region"] as? String,
        data["ip_geo_postal_code"] as? String
    )
}
