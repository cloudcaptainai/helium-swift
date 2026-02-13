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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await fetchPaywalls() }
    }

    private func fetchPaywalls() async {
        // TODO: Switch to fetchPreviewPaywalls() once the endpoint is live
        let response = await HeliumControlPanelService.shared.fetchPreviewPaywallsTest()

        // Fetch all products data
        await HeliumFetchedConfigManager.shared.buildLocalizedPriceMap(response.productIds)

        state = .loaded(response)
    }

    private func selectPaywall(_ paywall: HeliumPaywallPreview) {
        guard loadingPaywallId == nil else { return }
        loadingPaywallId = paywall.id
        print("[HeliumControlPanel] Selected paywall: \(paywall.paywallName) (\(paywall.paywallUuid))")

        Task {
            do {
                let (bundleId, html) = try await HeliumControlPanelService.shared.fetchSingleBundle(bundleURL: paywall.bundleUrl)

                HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
                    bundleId: bundleId,
                    bundleUrl: paywall.bundleUrl,
                    bundleHtml: html,
                    productIds: paywall.productIds
                )

                Helium.shared.presentPaywall(
                    trigger: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER,
                    onPaywallNotShown: { reason in
                        print("[HeliumControlPanel] Preview paywall not shown: \(reason)")
                    }
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
