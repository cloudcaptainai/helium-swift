import SwiftUI

struct HeliumControlPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: HeliumControlPanelState = .loading
    @State private var loadingVersionId: String? = nil
    @State private var fetchTask: Task<Void, Never>?

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
                        List {
                            ForEach(response.paywalls) { paywall in
                                Section(header: Text(paywall.paywallName)) {
                                    ForEach(paywall.versions) { version in
                                        Button {
                                            selectVersion(version, paywall: paywall)
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(version.displayLabel)
                                                        .font(.body)
                                                        .foregroundColor(.primary)
                                                    Text(version.formattedSavedDate)
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                                Spacer()
                                                if loadingVersionId == version.id {
                                                    ProgressView()
                                                }
                                            }
                                        }
                                        .disabled(loadingVersionId != nil || version.bundleUrl == nil)
                                    }
                                }
                            }
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
                            fetchTask?.cancel()
                            fetchTask = Task { await fetchPaywalls() }
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
                        loadingVersionId = nil
                        fetchTask?.cancel()
                        fetchTask = Task { await fetchPaywalls() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.isLoading || loadingVersionId != nil)
                }
            }
        }
        .onAppear {
            fetchTask = Task { await fetchPaywalls() }
        }
    }

    @MainActor
    private func fetchPaywalls() async {
        do {
            let response = try await HeliumControlPanelService.shared.fetchPreviewPaywalls()

            // Fetch all products data
            await HeliumFetchedConfigManager.shared.buildLocalizedPriceMap(response.productIds)

            state = .loaded(response)
        } catch {
            if !Task.isCancelled {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func selectVersion(_ version: HeliumPaywallPreviewVersion, paywall: HeliumPaywallPreviewEntry) {
        guard loadingVersionId == nil else { return }
        guard let bundleUrl = version.bundleUrl else { return }
        loadingVersionId = version.id
        HeliumLogger.log(.debug, category: .ui, "[HeliumControlPanel] Selected paywall: \(paywall.paywallName) version: \(version.versionId)")

        Task {
            do {
                let (bundleId, html) = try await HeliumControlPanelService.shared.fetchSingleBundle(bundleURL: bundleUrl)

                try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
                    bundleId: bundleId,
                    bundleUrl: bundleUrl,
                    bundleHtml: html,
                    productIds: version.productIds ?? []
                )

                await MainActor.run { loadingVersionId = nil }
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
                    loadingVersionId = nil
                    state = .error("Failed to load paywall: \(error.localizedDescription)")
                }
            }
        }
    }
}
