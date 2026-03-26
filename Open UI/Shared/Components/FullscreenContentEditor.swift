import SwiftUI

/// A fullscreen TextEditor sheet for editing large blocks of text content.
/// Presented as a sheet from SkillEditorView and PromptEditorView when the user
/// taps the expand button next to the content section header.
struct FullscreenContentEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let title: String
    let placeholder: String
    @Binding var content: String

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                // Background
                theme.background
                    .ignoresSafeArea()

                // Placeholder text when content is empty
                if content.isEmpty {
                    Text(placeholder)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md + 4)
                        .padding(.top, Spacing.md + 4)
                        .allowsHitTesting(false)
                }

                // Full-screen editor
                TextEditor(text: $content)
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.sm)
                    .focused($isFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isFocused = false
                        dismiss()
                    }
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Character count — useful feedback when writing long content
                    if !content.isEmpty {
                        Text("\(content.count) chars")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Auto-focus the editor when the sheet opens
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFocused = true
            }
        }
    }
}
