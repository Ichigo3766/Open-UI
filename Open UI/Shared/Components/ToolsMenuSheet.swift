import SwiftUI

// MARK: - Tool Item Model

/// Represents a tool available in the overflow menu.
struct ToolItem: Identifiable, Hashable {
    let id: String
    var name: String
    var description: String?
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
    }
}

// MARK: - Tools Menu Sheet

/// A bottom sheet presenting attachment actions, feature toggles (web search),
/// and an expandable list of available tools.
struct ToolsMenuSheet: View {
    @Binding var webSearchEnabled: Bool
    @Binding var imageGenerationEnabled: Bool
    @Binding var codeInterpreterEnabled: Bool
    var isWebSearchAvailable: Bool = true
    var isImageGenerationAvailable: Bool = true
    var isCodeInterpreterAvailable: Bool = true
    var tools: [ToolItem]
    @Binding var selectedToolIds: Set<String>
    var isLoadingTools: Bool = false
    var onFileAttachment: (() -> Void)?
    var onPhotoAttachment: (() -> Void)?
    var onCameraCapture: (() -> Void)?
    var onWebAttachment: (() -> Void)?
    /// Optional custom photo picker view (e.g. SwiftUI PhotosPicker).
    var photoPicker: AnyView?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var toolsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            sheetHandle
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)

            ScrollView {
                VStack(spacing: Spacing.md) {
                    // Attachment actions row
                    attachmentActionsRow
                        .padding(.horizontal, Spacing.md)

                    // Web search toggle (only shown when model has capability)
                    if isWebSearchAvailable {
                        webSearchToggle
                            .padding(.horizontal, Spacing.md)
                    }

                    // Image generation toggle (only shown when enabled on server)
                    if isImageGenerationAvailable {
                        imageGenerationToggle
                            .padding(.horizontal, Spacing.md)
                    }

                    // Code interpreter toggle (only shown when enabled on server)
                    if isCodeInterpreterAvailable {
                        codeInterpreterToggle
                            .padding(.horizontal, Spacing.md)
                    }

                    // Tools section
                    toolsSection
                        .padding(.horizontal, Spacing.md)
                }
                .padding(.bottom, Spacing.lg)
            }
        }
        .background(theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(CornerRadius.modal)
    }

    // MARK: - Sheet Handle

    private var sheetHandle: some View {
        Capsule()
            .fill(theme.textTertiary.opacity(0.4))
            .frame(width: 36, height: 5)
    }

    // MARK: - Attachment Actions Row

    private var attachmentActionsRow: some View {
        HStack(spacing: Spacing.sm) {
            attachmentActionButton(
                icon: "doc",
                label: String(localized: "File"),
                action: onFileAttachment
            )

            // Use custom PhotosPicker if provided, otherwise fall back to callback
            if let photoPicker {
                photoPicker
            } else {
                attachmentActionButton(
                    icon: "photo",
                    label: String(localized: "Photo"),
                    action: onPhotoAttachment
                )
            }

            attachmentActionButton(
                icon: "camera",
                label: String(localized: "Camera"),
                action: onCameraCapture
            )
            attachmentActionButton(
                icon: "globe",
                label: String(localized: "Webpage"),
                action: onWebAttachment
            )
        }
    }

    private func attachmentActionButton(
        icon: String,
        label: String,
        action: (() -> Void)?
    ) -> some View {
        let isEnabled = action != nil

        return Button {
            // Dismiss the tools sheet first, then trigger the action
            // after a small delay to avoid sheet presentation conflicts.
            dismiss()
            if let action {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    action()
                }
            }
        } label: {
            VStack(spacing: Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.brandPrimary.opacity(isEnabled ? 0.2 : 0.08),
                                    theme.brandPrimary.opacity(isEnabled ? 0.12 : 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(
                            isEnabled
                                ? theme.brandPrimary
                                : theme.iconDisabled
                        )
                }

                Text(label)
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        isEnabled
                            ? theme.textPrimary
                            : theme.textDisabled
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.92))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(
                        theme.cardBorder.opacity(isEnabled ? 0.5 : 0.25),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : OpacityLevel.disabled)
        .accessibilityLabel(label)
    }

    // MARK: - Feature Toggles

    private var webSearchToggle: some View {
        featureToggleTile(
            icon: "magnifyingglass",
            title: String(localized: "Web Search"),
            subtitle: String(localized: "Search the web and cite sources in replies"),
            isOn: $webSearchEnabled
        )
    }

    private var imageGenerationToggle: some View {
        featureToggleTile(
            icon: "photo.badge.plus",
            title: String(localized: "Image Generation"),
            subtitle: String(localized: "Generate images from text descriptions"),
            isOn: $imageGenerationEnabled
        )
    }

    private var codeInterpreterToggle: some View {
        featureToggleTile(
            icon: "chevron.left.forwardslash.chevron.right",
            title: String(localized: "Code Interpreter"),
            subtitle: String(localized: "Execute code and analyze data inline"),
            isOn: $codeInterpreterEnabled
        )
    }

    private func featureToggleTile(
        icon: String,
        title: String,
        subtitle: String?,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(MicroAnimation.snappy) {
                isOn.wrappedValue.toggle()
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Icon glyph
                toolGlyph(
                    systemImage: icon,
                    isSelected: isOn.wrappedValue
                )

                // Title and subtitle
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .scaledFont(size: 14)
                        .fontWeight(isOn.wrappedValue ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Toggle pill
                togglePill(isOn: isOn.wrappedValue)
            }
            .padding(Spacing.sm)
            .background(tileBackground(isOn: isOn.wrappedValue))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(
                        tileBorderColor(isOn: isOn.wrappedValue),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Tools Section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Section header with expand/collapse
            Button {
                withAnimation(MicroAnimation.snappy) {
                    toolsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Tools")
                        .scaledFont(size: 14, weight: .medium)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.textSecondary)

                    Spacer()

                    Image(systemName: toolsExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if toolsExpanded {
                if isLoadingTools {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading tools…")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(theme.cardBackground)
                    .clipShape(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
                    )
                } else if tools.isEmpty {
                    infoCard(message: "No tools available")
                } else {
                    ForEach(tools) { tool in
                        toolTile(tool: tool)
                    }
                }
            }
        }
    }

    private func toolTile(tool: ToolItem) -> some View {
        let isSelected = selectedToolIds.contains(tool.id)

        return Button {
            withAnimation(MicroAnimation.snappy) {
                if isSelected {
                    selectedToolIds.remove(tool.id)
                } else {
                    selectedToolIds.insert(tool.id)
                }
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: Spacing.sm) {
                toolGlyph(
                    systemImage: toolIcon(for: tool),
                    isSelected: isSelected
                )

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(tool.name)
                        .scaledFont(size: 14)
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let desc = tool.description, !desc.isEmpty {
                        Text(desc)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                togglePill(isOn: isSelected)
            }
            .padding(Spacing.sm)
            .background(tileBackground(isOn: isSelected))
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(
                        tileBorderColor(isOn: isSelected),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.name)
        .accessibilityValue(isSelected ? "Enabled" : "Disabled")
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Shared Sub-Views

    private func toolGlyph(systemImage: String, isSelected: Bool) -> some View {
        let accentStart = theme.brandPrimary.opacity(
            isSelected ? 0.7 : 0.15
        )
        let accentEnd = theme.brandPrimary.opacity(
            isSelected ? 0.5 : 0.08
        )
        let iconColor = isSelected
            ? theme.brandOnPrimary
            : theme.iconPrimary.opacity(OpacityLevel.strong)

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accentStart, accentEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)

            Image(systemName: systemImage)
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(iconColor)
        }
    }

    private func togglePill(isOn: Bool) -> some View {
        let trackColor = isOn
            ? theme.brandPrimary.opacity(0.9)
            : theme.cardBorder.opacity(0.5)
        let thumbColor = isOn
            ? theme.brandOnPrimary
            : theme.background.opacity(0.9)

        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
                .frame(width: 42, height: 22)

            Circle()
                .fill(thumbColor)
                .frame(width: 18, height: 18)
                .shadow(
                    color: theme.brandPrimary.opacity(0.25),
                    radius: 3,
                    y: 1
                )
                .padding(.horizontal, 2)
        }
        .animation(MicroAnimation.snappy, value: isOn)
    }

    private func tileBackground(isOn: Bool) -> Color {
        isOn
            ? theme.brandPrimary.opacity(theme.isDark ? 0.28 : 0.16)
            : theme.surfaceContainer.opacity(theme.isDark ? 0.32 : 0.12)
    }

    private func tileBorderColor(isOn: Bool) -> Color {
        isOn
            ? theme.brandPrimary.opacity(0.7)
            : theme.cardBorder.opacity(0.55)
    }

    private func infoCard(message: String) -> some View {
        Text(message)
            .scaledFont(size: 14)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(theme.cardBackground)
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
    }

    private func toolIcon(for tool: ToolItem) -> String {
        let name = tool.name.lowercased()
        if name.contains("image") || name.contains("vision") {
            return "photo"
        }
        if name.contains("code") || name.contains("python") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if name.contains("calc") || name.contains("math") {
            return "function"
        }
        if name.contains("file") || name.contains("document") {
            return "doc"
        }
        if name.contains("api") || name.contains("request") {
            return "cloud"
        }
        if name.contains("search") {
            return "magnifyingglass"
        }
        return "square.grid.2x2"
    }
}

// MARK: - Preview

#Preview("Tools Menu Sheet") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ToolsMenuSheet(
                webSearchEnabled: .constant(false),
                imageGenerationEnabled: .constant(false),
                codeInterpreterEnabled: .constant(false),
                tools: [
                    ToolItem(
                        name: "Web Search",
                        description: "Search the web for fresh context."
                    ),
                    ToolItem(
                        name: "Code Interpreter",
                        description: "Execute code snippets inline."
                    ),
                    ToolItem(
                        name: "Image Generator",
                        description: "Generate images from text."
                    ),
                ],
                selectedToolIds: .constant(["1"]),
                onFileAttachment: {},
                onPhotoAttachment: {},
                onCameraCapture: {},
                onWebAttachment: {}
            )
        }
        .themed()
}
