import Foundation

extension ExternalWebCheckoutManager {

    @MainActor
    func withFlowTelemetry(
        productKey: String,
        paywallSession: PaywallSession,
        _ body: () async throws -> WebCheckoutOutcome
    ) async throws -> WebCheckoutOutcome {
        let flowStart = Date()
        HeliumObservabilityManager.shared.track(
            WebCheckoutFlowStarted(provider: provider.providerSlug, productKey: productKey),
            paywallSession: paywallSession
        )
        do {
            let result = try await body()
            let outcomeKind: WebCheckoutFlowOutcomeKind
            switch result {
            case .opened: outcomeKind = .opened
            case .preCheckResolved: outcomeKind = .preCheckResolved
            }
            HeliumObservabilityManager.shared.track(
                WebCheckoutFlowResolved(
                    provider: provider.providerSlug,
                    productKey: productKey,
                    outcome: outcomeKind,
                    errorClass: nil, errorMessage: nil,
                    totalDurationMs: msSince(flowStart)
                ),
                paywallSession: paywallSession
            )
            return result
        } catch {
            let decomposed = decomposeError(error)
            HeliumObservabilityManager.shared.track(
                WebCheckoutFlowResolved(
                    provider: provider.providerSlug,
                    productKey: productKey,
                    outcome: .error,
                    errorClass: decomposed.errorClass,
                    errorMessage: decomposed.errorMessage,
                    totalDurationMs: msSince(flowStart)
                ),
                paywallSession: paywallSession
            )
            throw error
        }
    }

    func emitPaddleAwaitResolved(
        tappedPriceId: String,
        awaitDurationMs: Int,
        outcomes: [String: PaddlePrefetchOutcome],
        shortCircuited: Bool,
        paywallSession: PaywallSession
    ) {
        var ready = 0, alreadyEntitled = 0, failed = 0, caBlocked = 0, timedOut = 0, notStarted = 0
        for outcome in outcomes.values {
            switch outcome {
            case .ready: ready += 1
            case .alreadyEntitled: alreadyEntitled += 1
            case .failed(let error):
                if error is PaddleCaliforniaBlocked { caBlocked += 1 }
                else if error is PaddlePrefetchAwaitTimeout { timedOut += 1 }
                else { failed += 1 }
            case .notStarted: notStarted += 1
            }
        }
        HeliumObservabilityManager.shared.track(
            PaddlePrefetchAwaitResolved(
                tappedPriceId: tappedPriceId,
                awaitDurationMs: awaitDurationMs,
                readyCount: ready,
                alreadyEntitledCount: alreadyEntitled,
                failedCount: failed,
                caBlockedCount: caBlocked,
                timedOutCount: timedOut,
                notStartedCount: notStarted,
                shortCircuited: shortCircuited
            ),
            paywallSession: paywallSession
        )
    }
}
