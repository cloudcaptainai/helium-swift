import SwiftUI

struct HeliumControlPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: HeliumControlPanelState = .loading

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
                                // TODO: Paywall selection/display logic
                                print("[HeliumControlPanel] Selected paywall: \(paywall.paywallName) (\(paywall.paywallUuid))")
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(paywall.paywallName)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(paywall.paywallUuid)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
        do {
            let response = try await HeliumControlPanelService.shared.fetchPreviewPaywalls()
            state = .loaded(response)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
