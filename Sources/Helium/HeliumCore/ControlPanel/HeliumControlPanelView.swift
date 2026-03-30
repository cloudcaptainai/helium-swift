import SwiftUI

struct HeliumControlPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: HeliumControlPanelState = .loading
    @State private var loadingVersionId: String? = nil
    @State private var fetchTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var searchText: String = ""
    @State private var paywallLoadError: String? = nil

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor { traitCollection in
                    traitCollection.userInterfaceStyle == .dark ? .black : .systemGroupedBackground
                })
                .ignoresSafeArea()

                switch state {
                case .loading:
                    ProgressView("Loading paywalls...")
                case .loaded(let response):
                    if response.paywalls.isEmpty {
                        Text("No paywalls found.")
                            .foregroundColor(.secondary)
                    } else {
                        let filtered = response.paywalls.filter {
                            searchText.isEmpty || $0.paywallName.localizedCaseInsensitiveContains(searchText)
                        }
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(filtered) { paywall in
                                    paywallCard(paywall)
                                }
                            }
                            .padding()
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
            .searchable(text: $searchText, prompt: "Search paywalls")
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
        .alert("Error", isPresented: Binding(
            get: { paywallLoadError != nil },
            set: { if !$0 { paywallLoadError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(paywallLoadError ?? "")
        }
        .onAppear {
            fetchTask = Task { await fetchPaywalls() }
        }
        .onDisappear {
            fetchTask?.cancel()
            previewTask?.cancel()
        }
    }

    @ViewBuilder
    private func paywallCard(_ paywall: HeliumPaywallPreviewEntry) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Single preview image spanning the full card height, from the first version
            let previewUrl = paywall.versions.first?.previewUrl
            if let previewUrl, let url = URL(string: previewUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        previewPlaceholder
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 80)
                .clipped()
            } else {
                previewPlaceholder
            }

            // Right side: header + version rows
            VStack(alignment: .leading, spacing: 0) {
                // Paywall name header
                Text(paywall.paywallName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(height: 1.4)
                    .padding(.leading, 2)

                // Version rows
                ForEach(Array(paywall.versions.enumerated()), id: \.element.id) { index, version in
                    let isEnabled = version.bundleUrl != nil && loadingVersionId == nil
                    let isLoading = loadingVersionId == version.id

                    if index > 0 {
                        Rectangle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(height: 1)
                            .padding(.leading, 4)
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(version.versionStatus == "published" ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.displayLabel)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                            if version.lastSavedAt != nil {
                                Text(version.formattedSavedDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if isLoading {
                            ProgressView()
                        } else if version.bundleUrl != nil {
                            Image(systemName: "magnifyingglass")
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isEnabled else { return }
                        selectVersion(version, paywall: paywall)
                    }
                    .opacity(isEnabled || isLoading ? 1.0 : 0.4)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(isEnabled ? .isButton : [])
                    .accessibilityAction {
                        guard isEnabled else { return }
                        selectVersion(version, paywall: paywall)
                    }
                }
            }
        }
        .background(Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemGroupedBackground : .white
        }))
        .cornerRadius(12)
        .clipped()
    }

    private var previewPlaceholder: some View {
        Rectangle()
            .fill(Color(UIColor.tertiarySystemFill))
            .frame(width: 80)
            .overlay(
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundColor(.secondary)
            )
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

        previewTask?.cancel()
        previewTask = Task {
            do {
                let (bundleId, html) = try await HeliumControlPanelService.shared.fetchSingleBundle(bundleURL: bundleUrl)

                try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
                    bundleId: bundleId,
                    bundleUrl: bundleUrl,
                    bundleHtml: html,
                    productIds: version.productIds ?? []
                )

                await MainActor.run { loadingVersionId = nil }
                guard !Task.isCancelled else { return }
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
                    paywallLoadError = "Failed to load paywall: \(error.localizedDescription)"
                }
            }
        }
    }
}
