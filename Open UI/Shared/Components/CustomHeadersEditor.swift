import SwiftUI

// MARK: - Model

/// A single editable HTTP header entry.
struct CustomHeaderEntry: Identifiable {
    var id: String = UUID().uuidString
    var key: String = ""
    var value: String = ""
}

// MARK: - Editor

/// A reusable editor for HTTP header key–value pairs.
///
/// Used in both the initial server setup (``ServerConnectionView``) and the
/// server management edit sheet (``ServerManagementView``) so users can supply
/// headers that must be sent with every request (e.g. `X-Custom-Auth`, `CF-Access-Client-Id`).
struct CustomHeadersEditor: View {
    @Binding var entries: [CustomHeaderEntry]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Headers")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)

                    Text("Added to every request to this server")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        entries.append(CustomHeaderEntry())
                    }
                } label: {
                    Label("Add Header", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                        .scaledFont(size: 20)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("Add custom header")
            }

            if entries.isEmpty {
                // Empty state hint
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "info.circle")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                    Text("No custom headers. Tap + to add one.")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, Spacing.xs)
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach($entries) { $entry in
                        HeaderEntryRow(entry: $entry) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                entries.removeAll { $0.id == entry.id }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, Spacing.xs)
    }
}

// MARK: - Header Entry Row

private struct HeaderEntryRow: View {
    @Binding var entry: CustomHeaderEntry
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @FocusState private var keyFocused: Bool
    @FocusState private var valueFocused: Bool

    private var isEitherFocused: Bool { keyFocused || valueFocused }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(spacing: 4) {
                // Key / Name field
                TextField("Header name", text: $entry.key)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($keyFocused)
                    .accessibilityLabel("Header name")

                Rectangle()
                    .fill(keyFocused ? theme.brandPrimary : theme.divider)
                    .frame(height: keyFocused ? 2 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: keyFocused)
            }

            VStack(spacing: 4) {
                // Value field
                TextField("Value", text: $entry.value)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($valueFocused)
                    .accessibilityLabel("Header value")

                Rectangle()
                    .fill(valueFocused ? theme.brandPrimary : theme.divider)
                    .frame(height: valueFocused ? 2 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: valueFocused)
            }

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.error.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove header")
            .padding(.bottom, 4) // align with text fields
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                .fill(isEitherFocused ? theme.brandPrimary.opacity(0.05) : theme.surfaceContainer.opacity(0.5))
        )
        .animation(.easeInOut(duration: 0.15), value: isEitherFocused)
    }
}
