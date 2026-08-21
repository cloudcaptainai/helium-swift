//
//  HeliumPreviewContextEditors.swift
//  Helium
//
//  Editors reached from the preview configuration sheet for the context a paywall renders with.
//

import SwiftUI

/// Key/value editor backing both trait overrides and custom user attributes.
struct HeliumPreviewKeyValueEditor: View {
    let title: String
    let explanation: String
    let keyPlaceholder: String
    @Binding var entries: [HeliumPreviewKeyValue]

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text("Nothing set — the paywall renders with its published values.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach($entries) { $entry in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(keyPlaceholder, text: $entry.key)
                            .font(.subheadline.weight(.semibold))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("Value", text: $entry.value)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { entries.remove(atOffsets: $0) }

                Button {
                    entries.append(HeliumPreviewKeyValue())
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
            } footer: {
                Text(explanation)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
    }
}

struct HeliumPreviewLanguageEditor: View {
    @Binding var language: HeliumPreviewLanguage

    var body: some View {
        List {
            Section {
                ForEach(HeliumPreviewLanguage.allCases) { option in
                    Button {
                        language = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.displayName)
                                    .foregroundColor(.primary)
                                if option != .device {
                                    Text(option.rawValue)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if language == option {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } footer: {
                Text("Renders the paywall as a user with this language would see it. Device default leaves the choice to the paywall's own locale resolution.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}
