import SwiftUI

struct HeliumControlPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: HeliumControlPanelState = .loading
    @State private var loadingPaywallId: String? = nil

    var body: some View {
        NavigationView {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading paywalls...")
                case .loaded(let response):
                    if response.paywalls.isEmpty {
                        Text("No paywalls found.")
                            .foregroundColor(.secondary)
                    } else {
                        List(response.paywalls) { paywall in
                            Button {
                                selectPaywall(paywall)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(paywall.paywallName)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("v\(paywall.versionNumber) · \(paywall.formattedPublishedDate)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if loadingPaywallId == paywall.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(loadingPaywallId != nil)
                        }
                    }
                case .error(let message):
                    VStack(spacing: 16) {
                        Text(message)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") {
                            state = .loading
                            Task { await fetchPaywalls() }
                        }
                    }
                }
            }
            .navigationTitle("Paywall Previews")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        state = .loading
                        loadingPaywallId = nil
                        Task { await fetchPaywalls() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.isLoading || loadingPaywallId != nil)
                }
            }
        }
        .task { await fetchPaywalls() }
    }

    private func fetchPaywalls() async {
        do {
            let response = try await HeliumControlPanelService.shared.fetchPreviewPaywalls()
            
            // Fetch all products data
            await HeliumFetchedConfigManager.shared.buildLocalizedPriceMap(response.productIds)
            
            state = .loaded(response)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func selectPaywall(_ paywall: HeliumPaywallPreview) {
        guard loadingPaywallId == nil else { return }
        loadingPaywallId = paywall.id
        HeliumLogger.log(.debug, category: .ui, "[HeliumControlPanel] Selected paywall: \(paywall.paywallName) (\(paywall.paywallUuid))")

        Task {
            do {
                let (bundleId, html) = try await HeliumControlPanelService.shared.fetchSingleBundle(bundleURL: paywall.bundleUrl)

                try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
                    bundleId: bundleId,
                    bundleUrl: paywall.bundleUrl,
                    bundleHtml: html,
                    productIds: paywall.productIds
                )

                await MainActor.run { loadingPaywallId = nil }
                HeliumPaywallPresenter.shared.presentUpsell(
                    trigger: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER,
                    presentationContext: PaywallPresentationContext(
                        config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: false),
                        eventHandlers: nil,
                        onEntitled: nil,
                        onPaywallNotShown: nil
                    )
                )
            } catch {
                await MainActor.run {
                    loadingPaywallId = nil
                    state = .error("Failed to load paywall: \(error.localizedDescription)")
                }
            }
        }
    }
}
