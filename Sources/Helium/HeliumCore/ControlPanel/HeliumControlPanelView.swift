import SwiftUI

struct HeliumControlPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: HeliumControlPanelState = .loading
    @State private var activity: HeliumControlPanelActivity = .idle
    @State private var fetchTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var searchText: String = ""
    @State private var paywallLoadError: String? = nil
    @State private var pendingWebPreviewURL: URL? = nil
    @State private var pendingConfiguration: HeliumPreviewConfigurationRequest? = nil
    /// Launch deferred until the configuration sheet has finished dismissing, so a preview is never
    /// presented on top of a sheet that is still on its way out.
    @State private var queuedLaunch: (() -> Void)? = nil
    private let previewSettings = HeliumPreviewConfigurationStore.shared

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor { traitCollection in
                    traitCollection.userInterfaceStyle == .dark ? .black : .systemGroupedBackground
                })
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        descriptionHeader
                        fallbackPreviewCard
                        stateContent
                    }
                    .padding()
                }
            }
            .navigationTitle("Helium Paywall Previews")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search paywalls")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Helium Paywall Previews")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if hasApp2webPaywalls {
                        Button {
                            pendingConfiguration = HeliumPreviewConfigurationRequest(target: .settings)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .disabled(activity != .idle)
                        .accessibilityLabel("App2Web preview settings")
                    }
                    Button {
                        state = .loading
                        activity = .idle
                        fetchTask?.cancel()
                        fetchTask = Task { await fetchPaywalls() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.isLoading || activity != .idle)
                }
            }
        }
        .alert("Preview Could Not Open", isPresented: Binding(
            get: { paywallLoadError != nil },
            set: { if !$0 { paywallLoadError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(paywallLoadError ?? "")
        }
        .alert("Open Web Paywall?", isPresented: Binding(
            get: { pendingWebPreviewURL != nil },
            set: { if !$0 { pendingWebPreviewURL = nil } }
        ), presenting: pendingWebPreviewURL) { url in
            Button("Cancel", role: .cancel) { }
            Button("Open in Browser") {
                UIApplication.shared.open(url, options: [:]) { opened in
                    if !opened {
                        paywallLoadError = "Failed to open web preview."
                    }
                }
            }
        } message: { _ in
            Text("Web paywalls open in your default browser for a display-only preview. Purchases won't work from this preview.")
        }
        .fullScreenCover(item: $pendingConfiguration, onDismiss: {
            let launch = queuedLaunch
            queuedLaunch = nil
            launch?()
        }) { request in
            HeliumPreviewConfigurationView(
                request: request,
                onStart: { _ in
                    if case .version(let version, let paywall) = request.target {
                        queuedLaunch = { selectVersion(version, paywall: paywall) }
                    }
                    pendingConfiguration = nil
                },
                onCancel: { pendingConfiguration = nil }
            )
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
    private var stateContent: some View {
        switch state {
        case .loading:
            ProgressView("Loading paywalls...")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case .loaded(let response):
            if response.paywalls.isEmpty {
                Text("No paywalls found.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 20)
            } else {
                let filtered = response.paywalls.filter {
                    searchText.isEmpty || $0.paywallName.localizedCaseInsensitiveContains(searchText)
                }
                if filtered.isEmpty {
                    Text("No paywalls match \"\(searchText)\".")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(filtered) { paywall in
                            paywallCard(paywall)
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
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }

    /// The settings entry only appears once the loaded list actually contains an
    /// app2web-capable paywall.
    private var hasApp2webPaywalls: Bool {
        if case .loaded(let response) = state {
            return response.paywalls.contains { $0.isApp2webCapable }
        }
        return false
    }

    @ViewBuilder
    private var fallbackPreviewCard: some View {
        let configured = HeliumFetchedConfigManager.shared.hasConfiguredFallbackPreview()
        let card = VStack(alignment: .leading, spacing: 2) {
            Text("Default Fallback Paywall")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.primary)
            if configured {
                Text("Tap to preview on this device")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("No fallback configured. [Set up a fallback paywall](https://docs.tryhelium.com/guides/fallback-bundle).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .tint(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemGroupedBackground : .white
        }))
        .cornerRadius(12)

        if configured {
            card
                .contentShape(Rectangle())
                .onTapGesture { presentFallbackPreview() }
                .opacity(activity == .idle ? 1.0 : 0.4)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { presentFallbackPreview() }
        } else {
            // Inert: the setup link inside the text must stay the only tap target.
            card
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
                HStack(spacing: 6) {
                    Text(paywall.paywallName)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if paywall.isWebPaywall {
                        Text("Web")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(height: 1.4)
                    .padding(.leading, 2)

                // Version rows
                ForEach(Array(paywall.versions.enumerated()), id: \.element.id) { index, version in
                    let isEnabled = version.bundleUrl != nil && activity == .idle
                    let isLoading = activity == .loadingVersion(id: version.id)

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
                            Image(systemName: paywall.isWebPaywall ? "safari" : "magnifyingglass")
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isEnabled else { return }
                        configurePreview(for: version, paywall: paywall)
                    }
                    .opacity(isEnabled || isLoading ? 1.0 : 0.4)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(isEnabled ? .isButton : [])
                    .accessibilityAction {
                        guard isEnabled else { return }
                        configurePreview(for: version, paywall: paywall)
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

    private var descriptionHeader: some View {
        Text("Preview your paywalls on device. Bring up this menu with a triple tap on any Helium paywall using a debug/TestFlight build. [Learn more](https://docs.tryhelium.com/guides/paywall-previews).")
            .font(.footnote)
            .foregroundColor(.secondary)
            .tint(.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
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

            guard HeliumControlPanelService.shared.applyServerProducts(from: response) else { return }

            previewSettings.forceExternalCheckoutSimulation = response.forceExternalCheckoutSimulation ?? true
            previewSettings.forcePaddleCaConsentModal = response.forcePaddleCaConsentModal ?? false

            state = .loaded(response)
        } catch {
            if !Task.isCancelled {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Non-app2web paywalls present directly; app2web paywalls stop at the configuration
    /// screen first only when the tester has turned that step on.
    private func configurePreview(for version: HeliumPaywallPreviewVersion, paywall: HeliumPaywallPreviewEntry) {
        guard activity == .idle else { return }
        if version.isApp2webCapable && !version.isApp2webBundleFresh {
            paywallLoadError = "Your paywall needs an update. Re-save it in your Helium dashboard, then reload."
            return
        }
        if version.isApp2webCapable && previewSettings.configureBeforeEachPreview {
            pendingConfiguration = HeliumPreviewConfigurationRequest(target: .version(version, paywall: paywall))
        } else {
            selectVersion(version, paywall: paywall)
        }
    }

    private func selectVersion(_ version: HeliumPaywallPreviewVersion, paywall: HeliumPaywallPreviewEntry) {
        guard activity == .idle else { return }
        guard let bundleUrl = version.bundleUrl else { return }

        // Web paywalls aren't renderable in-app — preview them in the browser
        // after the user confirms, since payments won't work from a preview.
        if paywall.isWebPaywall {
            guard HeliumFetchedConfigManager.shared.isValidURL(bundleUrl),
                  let url = URL(string: bundleUrl) else {
                paywallLoadError = "Invalid web paywall URL."
                return
            }
            HeliumLogger.log(.debug, category: .ui, "[HeliumControlPanel] Selected web paywall: \(paywall.paywallName) version: \(version.versionId)")
            pendingWebPreviewURL = url
            return
        }

        activity = .loadingVersion(id: version.id)
        HeliumLogger.log(.debug, category: .ui, "[HeliumControlPanel] Selected paywall: \(paywall.paywallName) version: \(version.versionId)")

        previewTask?.cancel()
        previewTask = Task {
            do {
                async let secondTryTask = fetchSecondTryBundle(for: paywall)
                let (bundleId, html) = try await HeliumControlPanelService.shared.fetchSingleBundle(bundleURL: bundleUrl)
                let secondTryBundle = await secondTryTask

                try HeliumFetchedConfigManager.shared.setPreviewTriggerConfig(
                    bundleId: bundleId,
                    bundleUrl: bundleUrl,
                    bundleHtml: html,
                    productIds: version.productIds ?? [],
                    productIdsStripe: version.stripeProductIds ?? [],
                    productIdsPaddle: version.paddleProductIds ?? [],
                    productIdsPaddleWeb: version.webPaddleProductIds ?? [],
                    productIdsStripeWeb: version.webStripeProductIds ?? [],
                    webPaywallBundleUrl: version.webPaywallBundleUrl,
                    shouldEnableScroll: version.shouldEnableScroll,
                    secondTry: secondTryBundle
                )

                guard !Task.isCancelled else {
                    await MainActor.run { activity = .idle }
                    return
                }
                await MainActor.run { activity = .presentingPaywall }
                HeliumPaywallPresenter.shared.presentUpsell(
                    trigger: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER,
                    presentationContext: previewPresentationContext()
                )
            } catch {
                await MainActor.run {
                    activity = .idle
                    paywallLoadError = "Failed to load paywall: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Resolves a paywall's second try flow into a preview bundle. The second try must not block
    /// or fail the main preview, so a failure only logs — the preview presents without a second
    /// try entry and a request for it surfaces the standard second-try-no-match diagnostic.
    private func fetchSecondTryBundle(
        for paywall: HeliumPaywallPreviewEntry
    ) async -> HeliumFetchedConfigManager.PreviewSecondTryBundle? {
        guard let secondTry = paywall.secondTry, let secondTryBundleUrl = secondTry.bundleUrl else {
            return nil
        }
        do {
            let (bundleId, html) = try await HeliumControlPanelService.shared.fetchSingleBundle(bundleURL: secondTryBundleUrl)
            return HeliumFetchedConfigManager.PreviewSecondTryBundle(
                bundleId: bundleId,
                bundleUrl: secondTryBundleUrl,
                bundleHtml: html,
                productIds: secondTry.productIds ?? [],
                productIdsStripe: secondTry.stripeProductIds ?? [],
                productIdsPaddle: secondTry.paddleProductIds ?? [],
                shouldEnableScroll: secondTry.shouldEnableScroll
            )
        } catch {
            HeliumLogger.log(.warn, category: .ui, "[HeliumControlPanel] Failed to load second try bundle for preview", metadata: [
                "secondTryPaywall": secondTry.paywallName,
                "error": "\(error)",
            ])
            return nil
        }
    }

    private func presentFallbackPreview() {
        guard activity == .idle else { return }
        guard HeliumFetchedConfigManager.shared.setFallbackPreviewTrigger() else {
            paywallLoadError = "No fallback paywall configured"
            return
        }
        activity = .presentingPaywall
        HeliumLogger.log(.debug, category: .ui, "[HeliumControlPanel] Selected fallback paywall preview")
        HeliumPaywallPresenter.shared.presentUpsell(
            trigger: HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER,
            presentationContext: previewPresentationContext()
        )
    }

    /// Context for presenting a preview from the panel. The activity lock is released only when
    /// the preview closes or reports it could not be shown, so both signals must re-enable the
    /// panel; every presenter path ends in exactly one of the two. Releasing at close rather than
    /// open keeps the panel inert the whole time a preview is on screen, so no tap can stack a
    /// second preview over it.
    private func previewPresentationContext() -> PaywallPresentationContext {
        PaywallPresentationContext(
            config: PaywallPresentationConfig(dontShowIfAlreadyEntitled: false),
            // A second try preview shares this context and closes back onto the main preview,
            // so only the main preview trigger closing releases the lock.
            eventHandlers: PaywallEventHandlers().onClose { event in
                if event.triggerName == HeliumFetchedConfigManager.HELIUM_PREVIEW_TRIGGER {
                    activity = .idle
                }
            },
            onEntitled: nil,
            onPaywallNotShown: { _ in activity = .idle }
        )
    }
}
