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

    /// Emits `paddle_prefetch_bandit_completed` always, plus
    /// `paddle_prefetch_outcome_finalized` for terminal outcomes
    /// (alreadyEntitled, failed).
    nonisolated static func trackBanditCompletion(
        priceId: String,
        paywallSession: PaywallSession,
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
                endpointCall: endpointCall,
                alreadyEntitledCode: alreadyEntitledCode
            ),
            paywallSession: paywallSession
        )

        if let terminalOutcome {
            HeliumObservabilityManager.shared.track(
                PaddlePrefetchOutcomeFinalized(
                    priceId: priceId,
                    outcome: terminalOutcome,
                    errorClass: terminalErrorClass,
                    totalDurationMs: msSince(chainStartedAt),
                    ipGeoCountry: nil
                ),
                paywallSession: paywallSession
            )
        }
    }

    /// Emits `paddle_prefetch_bff_completed` always, plus
    /// `paddle_prefetch_outcome_finalized` (the BFF step is always terminal —
    /// success → .ready, caBlocked, or failed).
    nonisolated static func trackBffCompletion(
        priceId: String,
        transactionId: String,
        paywallSession: PaywallSession,
        startedAt: Date,
        chainStartedAt: Date,
        result: PrefetchBffStep
    ) {
        let endpointCall: EndpointCallTelemetry
        let outcome: PaddlePrefetchOutcomeKind
        let errorClass: String?
        let ipGeo: String?

        switch result {
        case let .success(rawBody):
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt), success: true
            )
            outcome = .ready
            errorClass = nil
            ipGeo = ipGeoCountryCode(in: rawBody)
        case let .caBlocked(rawBody):
            endpointCall = EndpointCallTelemetry(
                durationMs: msSince(startedAt), success: true
            )
            outcome = .caBlocked
            errorClass = "PaddleCaliforniaBlocked"
            ipGeo = ipGeoCountryCode(in: rawBody)
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
            ipGeo = nil
        }

        HeliumObservabilityManager.shared.track(
            PaddlePrefetchBffCompleted(
                priceId: priceId,
                transactionId: transactionId,
                endpointCall: endpointCall
            ),
            paywallSession: paywallSession
        )

        HeliumObservabilityManager.shared.track(
            PaddlePrefetchOutcomeFinalized(
                priceId: priceId,
                outcome: outcome,
                errorClass: errorClass,
                totalDurationMs: msSince(chainStartedAt),
                ipGeoCountry: ipGeo
            ),
            paywallSession: paywallSession
        )
    }
}

private func ipGeoCountryCode(in rawBody: Data) -> String? {
    guard let parsed = (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any],
          let data = parsed["data"] as? [String: Any],
          let cc = data["ip_geo_country_code"] as? String else {
        return nil
    }
    return cc
}
