import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Chat Attachment

struct ChatAttachment: Identifiable {
    let id = UUID()
    let type: AttachmentType
    let name: String
    var thumbnail: Image?
    var data: Data?

    /// Whether this audio attachment is currently being transcribed.
    var isTranscribing: Bool = false

    /// The transcribed text from an audio attachment (set after ASR processing).
    var transcribedText: String?

    // MARK: - Upload & Processing State

    /// Current upload/processing status for this attachment.
    var uploadStatus: UploadStatus = .pending

    /// The server-assigned file ID after successful upload + processing.
    var uploadedFileId: String?

    /// Error message if upload or processing failed.
    var uploadError: String?

    /// Whether this attachment is still being uploaded or processed.
    var isUploading: Bool {
        switch uploadStatus {
        case .uploading, .processing: return true
        default: return false
        }
    }

    /// Whether this attachment is ready to be sent (uploaded + processed).
    var isReady: Bool {
        uploadStatus == .completed && uploadedFileId != nil
    }

    enum AttachmentType: Sendable {
        case image
        case file
        case audio
    }

    enum UploadStatus: Sendable {
        case pending      // Not yet started
        case uploading    // Uploading to server
        case processing   // Server is processing (text extraction, embeddings)
        case completed    // Ready to use
        case error        // Upload or processing failed
    }
}

// MARK: - Chat Input Field

struct ChatInputField: View {
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    var placeholder: String = "Message"
    var isEnabled: Bool = true
    var onSend: () -> Void
    var onStopGenerating: (() -> Void)?

    // Tools menu bindings
    @Binding var webSearchEnabled: Bool
    @Binding var imageGenerationEnabled: Bool
    @Binding var codeInterpreterEnabled: Bool
    var isWebSearchAvailable: Bool = true
    var isImageGenerationAvailable: Bool = true
    var isCodeInterpreterAvailable: Bool = true
    var tools: [ToolItem]
    @Binding var selectedToolIds: Set<String>
    var isLoadingTools: Bool = false

    // Terminal bindings
    var terminalEnabled: Bool = false
    var isTerminalAvailable: Bool = false
    var terminalServerName: String = ""
    var availableTerminalServers: [TerminalServer] = []
    var onTerminalToggle: (() -> Void)?
    var onTerminalServerSelected: ((TerminalServer) -> Void)?
    var onBrowseFiles: (() -> Void)?

    // Model mention bindings (@ trigger)
    @Binding var mentionedModel: AIModel?
    var mentionedModelImageURL: URL?
    var mentionedModelAuthToken: String?
    var onAtTrigger: ((String) -> Void)?
    var onAtDismiss: (() -> Void)?

    // Knowledge base bindings
    @Binding var selectedKnowledgeItems: [KnowledgeItem]
    var onHashTrigger: ((String) -> Void)?
    var onHashDismiss: (() -> Void)?

    // Prompt slash command bindings (/ trigger)
    var onSlashTrigger: ((String) -> Void)?
    var onSlashDismiss: (() -> Void)?

    // Skills bindings ($ trigger)
    var onDollarTrigger: ((String) -> Void)?
    var onDollarDismiss: (() -> Void)?

    // Attachment callbacks
    var onFileAttachment: (() -> Void)?
    var onPhotoAttachment: (() -> Void)?
    var onCameraCapture: (() -> Void)?
    var onWebAttachment: (() -> Void)?
    var onVoiceInput: (() -> Void)?
    /// Called when the tools/overflow sheet is about to appear.
    var onToolsSheetPresented: (() -> Void)?

    /// Optional custom photo picker view (SwiftUI PhotosPicker).
    var photoPicker: AnyView?

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool
    @State private var showToolsSheet = false
    @State private var previewingTranscript: ChatAttachment? = nil

    /// Quick pills preference from UserDefaults
    @AppStorage("quickPills") private var quickPillsData: String = ""

    /// Whether any audio attachment is still being transcribed.
    private var isTranscribing: Bool {
        attachments.contains { $0.type == .audio && $0.isTranscribing }
    }

    /// Whether any attachment is still uploading or being processed on the server.
    private var hasUploadingAttachments: Bool {
        attachments.contains { $0.isUploading }
    }

    private var canSend: Bool {
        isEnabled && !isTranscribing && !hasUploadingAttachments &&
            (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    /// Whether any tool/feature is currently active.
    private var hasActiveFeatures: Bool {
        webSearchEnabled || !selectedToolIds.isEmpty
    }

    /// Saved quick pill IDs from settings.
    private var savedQuickPillIds: [String] {
        guard !quickPillsData.isEmpty else { return [] }
        return quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    private var hasQuickPills: Bool {
        !activeQuickPills.isEmpty
    }

    /// Whether the voice icon button should appear in the pills row.
    private var showBottomVoiceButton: Bool {
        onVoiceInput != nil && isEnabled && !canSend && hasQuickPills
    }

    var body: some View {
        VStack(spacing: 0) {
            // Attachment previews
            if !attachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, Spacing.xs)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Composer
            composerShell
                .padding(.horizontal, Spacing.screenPadding)
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm)
        // Widget deep link — focus the text field and show keyboard when
        // the user taps the "New Chat" action button on the home screen widget.
        .onReceive(NotificationCenter.default.publisher(for: .chatInputFieldRequestFocus)) { _ in
            isFocused = true
        }
        .sheet(isPresented: $showToolsSheet) {
            ToolsMenuSheet(
                webSearchEnabled: $webSearchEnabled,
                imageGenerationEnabled: $imageGenerationEnabled,
                codeInterpreterEnabled: $codeInterpreterEnabled,
                isWebSearchAvailable: isWebSearchAvailable,
                isImageGenerationAvailable: isImageGenerationAvailable,
                isCodeInterpreterAvailable: isCodeInterpreterAvailable,
                tools: tools,
                selectedToolIds: $selectedToolIds,
                isLoadingTools: isLoadingTools,
                onFileAttachment: onFileAttachment,
                onPhotoAttachment: onPhotoAttachment,
                onCameraCapture: onCameraCapture,
                onWebAttachment: onWebAttachment,
                photoPicker: photoPicker
            )
        }
        .onChange(of: showToolsSheet) { _, isPresented in
            if isPresented { onToolsSheetPresented?() }
        }
        .animation(.easeOut(duration: 0.2), value: attachments.count)
        .sheet(item: $previewingTranscript) { attachment in
            TranscriptPreviewSheet(attachment: attachment)
        }
    }

    // MARK: - Composer Shell

    private var composerShell: some View {
        VStack(spacing: 0) {
            // Model override chip (above text input)
            if mentionedModel != nil {
                mentionedModelChip
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Knowledge items chips (above text input)
            if !selectedKnowledgeItems.isEmpty {
                knowledgeChipsStrip
                    .padding(.horizontal, 10)
                    .padding(.top, mentionedModel != nil ? 4 : 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Main text input row — center alignment keeps + and send/voice
            // button symmetrically aligned with the text on all line counts.
            HStack(alignment: .center, spacing: 8) {
                inlinePlusButton
                textField
                inlineTerminalButton
                trailingButton
            }
            .padding(.horizontal, 12)
            .padding(.top, selectedKnowledgeItems.isEmpty ? 10 : 6)
            .padding(.bottom, hasQuickPills ? 6 : 10)

            // Quick pills row (only when pills are configured)
            if hasQuickPills {
                pillsRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                .strokeBorder(composerBorderColor, lineWidth: 0.5)
        )
        // Subtle shadow — upward only, no competing directions
        .shadow(
            color: theme.isDark
                ? Color.black.opacity(isFocused ? 0.3 : 0.2)
                : Color.black.opacity(isFocused ? 0.1 : 0.06),
            radius: 8,
            x: 0,
            y: 2
        )
    }

    private var composerCornerRadius: CGFloat {
        // Shrink corners slightly for multiline content
        text.contains("\n") || text.count > 60 ? 18 : 22
    }

    private var composerBackground: Color {
        theme.isDark
            ? theme.cardBackground.opacity(0.95)
            : theme.inputBackground
    }

    private var composerBorderColor: Color {
        isFocused
            ? theme.brandPrimary.opacity(0.35)
            : theme.cardBorder.opacity(0.4)
    }

    // MARK: - Inline Plus Button

    private var inlinePlusButton: some View {
        Button {
            Haptics.play(.light)
            isFocused = false
            showToolsSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        hasActiveFeatures
                            ? theme.brandPrimary.opacity(0.12)
                            : Color.clear
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "plus")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(hasActiveFeatures ? theme.brandPrimary : theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.4)
        .accessibilityLabel("Attachments & tools")
        .animation(.easeInOut(duration: 0.15), value: hasActiveFeatures)
    }

    // MARK: - Text Field

    @AppStorage("sendOnEnter") private var sendOnEnter = true

    /// Rounded system font for a softer, modern chat feel.
    private static let inputFont: UIFont = {
        let base = UIFont.systemFont(ofSize: 14, weight: .regular)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: rounded, size: 14)
        }
        return base
    }()

    private var textField: some View {
        PasteableTextView(
            text: $text,
            placeholder: placeholder,
            font: Self.inputFont,
            textColor: UIColor(theme.textPrimary),
            placeholderColor: UIColor(theme.textTertiary),
            tintColor: UIColor(theme.brandPrimary),
            isEnabled: isEnabled,
            onPasteAttachments: { pastedAttachments in
                withAnimation(.easeOut(duration: 0.15)) {
                    attachments.append(contentsOf: pastedAttachments)
                }
                Haptics.play(.light)
            },
            onSubmit: {
                if sendOnEnter && canSend { onSend() }
            },
            onHashTrigger: onHashTrigger,
            onHashDismiss: onHashDismiss,
            onAtTrigger: onAtTrigger,
            onAtDismiss: onAtDismiss,
            onSlashTrigger: onSlashTrigger,
            onSlashDismiss: onSlashDismiss,
            onDollarTrigger: onDollarTrigger,
            onDollarDismiss: onDollarDismiss,
            sendOnReturn: sendOnEnter
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(placeholder)
    }

    // MARK: - Inline Terminal Button

    /// Compact terminal icon that sits inline in the text row.
    /// - Single server: tap toggles on/off
    /// - Multiple servers: tap opens a Menu for server selection
    @ViewBuilder
    private var inlineTerminalButton: some View {
        if isTerminalAvailable, let onTerminalToggle {
            let hasMultiple = availableTerminalServers.count > 1

            if hasMultiple {
                Menu {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { onTerminalToggle() }
                        Haptics.play(.light)
                    } label: {
                        Label(
                            terminalEnabled ? "Disable Terminal" : "Enable Terminal",
                            systemImage: terminalEnabled ? "xmark.circle" : "checkmark.circle"
                        )
                    }

                    if terminalEnabled, let onBrowseFiles {
                        Button {
                            onBrowseFiles()
                            Haptics.play(.light)
                        } label: {
                            Label("Browse Files", systemImage: "folder")
                        }
                    }

                    Divider()

                    ForEach(availableTerminalServers) { server in
                        Button {
                            onTerminalServerSelected?(server)
                            if !terminalEnabled {
                                withAnimation(.easeOut(duration: 0.15)) { onTerminalToggle() }
                            }
                            Haptics.play(.light)
                        } label: {
                            HStack {
                                Text(server.displayName)
                                if server.id == (availableTerminalServers.first(where: { $0.displayName == terminalServerName })?.id ?? "") {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    terminalIconLabel
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .animation(.easeInOut(duration: 0.15), value: terminalEnabled)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { onTerminalToggle() }
                    Haptics.play(.light)
                } label: {
                    terminalIconLabel
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .animation(.easeInOut(duration: 0.15), value: terminalEnabled)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// The compact circular terminal icon used in the inline position.
    private var terminalIconLabel: some View {
        Circle()
            .fill(
                terminalEnabled
                    ? theme.brandPrimary.opacity(0.12)
                    : Color.clear
            )
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "terminal")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(
                        terminalEnabled
                            ? theme.brandPrimary
                            : theme.textTertiary
                    )
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        terminalEnabled
                            ? theme.brandPrimary.opacity(0.4)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.4)
            .accessibilityLabel("Terminal")
            .accessibilityValue(terminalEnabled ? "Enabled" : "Disabled")
    }

    // MARK: - Trailing Button (Send / Stop / Voice)

    private var trailingButton: some View {
        Group {
            if onStopGenerating != nil && !isEnabled {
                // Stop generating
                Button {
                    Haptics.play(.light)
                    onStopGenerating?()
                } label: {
                    Circle()
                        .fill(theme.error.opacity(0.15))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "stop.fill")
                                .scaledFont(size: 11, weight: .bold)
                                .foregroundStyle(theme.error)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop generating")
                .transition(.scale.combined(with: .opacity))

            } else if canSend {
                // Send message
                Button {
                    Haptics.play(.light)
                    onSend()
                } label: {
                    Circle()
                        .fill(theme.brandPrimary)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(theme.brandOnPrimary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send message")
                .transition(.scale.combined(with: .opacity))

            } else if !hasQuickPills, let onVoiceInput {
                // Voice button — only in inline position when no pill row exists
                Button {
                    Haptics.play(.light)
                    onVoiceInput()
                } label: {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.brandPrimary.opacity(0.5),
                                    theme.brandPrimary.opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "waveform")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voice call")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeInOut(duration: 0.15), value: isEnabled)
    }

    // MARK: - Pills Row

    private var pillsRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activeQuickPills, id: \.id) { pill in
                        pillButton(pill)
                    }
                }
            }

            Spacer(minLength: 0)

            // Voice icon button (no text label) in pill row position
            if showBottomVoiceButton, let onVoiceInput {
                Button {
                    Haptics.play(.light)
                    onVoiceInput()
                } label: {
                    Image(systemName: "waveform")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .frame(width: 30, height: 26)
                        .background(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            theme.brandPrimary.opacity(0.5),
                                            theme.brandPrimary.opacity(0.2)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Voice call")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showBottomVoiceButton)
    }

    // MARK: - Quick Pills

    private var activeQuickPills: [QuickPill] {
        var pills: [QuickPill] = []

        for id in savedQuickPillIds {
            switch id {
            case "web":
                if isWebSearchAvailable {
                    pills.append(QuickPill(
                        id: "web",
                        icon: "magnifyingglass",
                        label: "Web",
                        isActive: webSearchEnabled,
                        action: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                webSearchEnabled.toggle()
                            }
                            Haptics.play(.light)
                        }
                    ))
                }
            case "image":
                // Image Generation is a native feature toggle, not a tool.
                // Sync the pill with imageGenerationEnabled so it matches
                // the toggle in the tools sheet.
                if isImageGenerationAvailable {
                    pills.append(QuickPill(
                        id: "image",
                        icon: "photo",
                        label: "Image",
                        isActive: imageGenerationEnabled,
                        action: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                imageGenerationEnabled.toggle()
                            }
                            Haptics.play(.light)
                        }
                    ))
                }
            default:
                if let tool = tools.first(where: { $0.id == id }) {
                    let isSelected = selectedToolIds.contains(tool.id)
                    pills.append(QuickPill(
                        id: tool.id,
                        icon: "wrench",
                        label: tool.name,
                        isActive: isSelected,
                        action: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if isSelected {
                                    selectedToolIds.remove(tool.id)
                                } else {
                                    selectedToolIds.insert(tool.id)
                                }
                            }
                            Haptics.play(.light)
                        }
                    ))
                }
            }
        }

        return pills
    }

    private func pillButton(_ pill: QuickPill) -> some View {
        Button(action: pill.action) {
            HStack(spacing: 4) {
                Image(systemName: pill.icon)
                    .scaledFont(size: 11, weight: .semibold)
                Text(pill.label)
                    .scaledFont(size: 12, weight: pill.isActive ? .semibold : .medium)
            }
            .foregroundStyle(pill.isActive ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        pill.isActive
                            ? theme.brandPrimary.opacity(0.12)
                            : theme.surfaceContainer.opacity(0.6)
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        pill.isActive
                            ? theme.brandPrimary.opacity(0.4)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.15), value: pill.isActive)
    }

    // MARK: - Mentioned Model Chip

    private var mentionedModelChip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if let model = mentionedModel {
                    ModelAvatar(
                        size: 18,
                        imageURL: mentionedModelImageURL,
                        label: model.shortName,
                        authToken: mentionedModelAuthToken
                    )
                }
                Text(mentionedModel?.shortName ?? "")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        mentionedModel = nil
                    }
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.brandPrimary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5)
            )

            Spacer()
        }
    }

    // MARK: - Knowledge Chips Strip

    private var knowledgeChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedKnowledgeItems) { item in
                    knowledgeChip(item)
                }
            }
        }
    }

    private func knowledgeChip(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.iconName)
                .scaledFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
            Text(item.name)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(item.typeBadge)
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(theme.surfaceContainer.opacity(0.8))
                )
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    selectedKnowledgeItems.removeAll { $0.id == item.id }
                }
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(theme.brandPrimary.opacity(0.08))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Attachment Strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(attachments) { attachment in
                    attachmentThumbnail(attachment)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func attachmentThumbnail(_ attachment: ChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if attachment.type == .audio {
                    // Determine audio mode: server or on-device
                    let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
                    let isServerMode = audioFileMode == "server"
                    let hasTranscript = attachment.transcribedText != nil
                    let isError = attachment.uploadStatus == .error
                    let isComplete = attachment.uploadStatus == .completed || hasTranscript

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            isError
                                ? theme.error.opacity(0.12)
                                : isComplete
                                    ? theme.brandPrimary.opacity(0.15)
                                    : theme.brandPrimary.opacity(0.1)
                        )
                        .frame(width: 56, height: 56)
                        .overlay(
                            VStack(spacing: 3) {
                                if isServerMode {
                                    // Server mode: show upload/processing status
                                    if attachment.isUploading {
                                        ProgressView().controlSize(.small)
                                            .tint(theme.brandPrimary)
                                    } else if isError {
                                        Button {
                                            // Retry upload by posting notification
                                            NotificationCenter.default.post(
                                                name: .retryAttachmentUpload,
                                                object: attachment.id
                                            )
                                            Haptics.play(.light)
                                        } label: {
                                            Image(systemName: "arrow.clockwise.circle.fill")
                                                .scaledFont(size: 16)
                                                .foregroundStyle(theme.error)
                                        }
                                        .buttonStyle(.plain)
                                    } else if attachment.uploadStatus == .completed {
                                        Image(systemName: "checkmark.circle.fill")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.success)
                                    } else {
                                        Image(systemName: "waveform")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.brandPrimary)
                                    }
                                } else {
                                    // On-device mode: show transcription status
                                    if attachment.isTranscribing {
                                        ProgressView().controlSize(.small)
                                    } else if hasTranscript {
                                        Image(systemName: "checkmark.circle.fill")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.success)
                                    } else {
                                        Image(systemName: "waveform")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.brandPrimary)
                                    }
                                }
                                Text(attachment.name)
                                    .scaledFont(size: 7)
                                    .foregroundStyle(isError ? theme.error : theme.textTertiary)
                                    .lineLimit(1)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isError
                                        ? theme.error.opacity(0.5)
                                        : isComplete
                                            ? theme.success.opacity(0.4)
                                            : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture {
                            if hasTranscript {
                                Haptics.play(.light)
                                previewingTranscript = attachment
                            }
                        }
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.surfaceContainer)
                        .frame(width: 56, height: 56)
                        .overlay(
                            VStack(spacing: 3) {
                                if attachment.isUploading {
                                    ProgressView().controlSize(.small)
                                } else if attachment.uploadStatus == .error {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(theme.error)
                                } else if attachment.isReady {
                                    Image(systemName: "checkmark.circle.fill")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(theme.success)
                                } else {
                                    Image(systemName: attachment.type == .image ? "photo" : "doc")
                                        .scaledFont(size: 16)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Text(attachment.name)
                                    .scaledFont(size: 7)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 4)
                            }
                        )
                }
            }
            // Upload status overlay for image thumbnails
            .overlay {
                if attachment.thumbnail != nil && attachment.isUploading {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 56, height: 56)
                        .overlay(ProgressView().controlSize(.small).tint(.white))
                } else if attachment.thumbnail != nil && attachment.uploadStatus == .error {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Image(systemName: "exclamationmark.triangle.fill")
                                .scaledFont(size: 18)
                                .foregroundStyle(.red)
                        )
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    attachments.removeAll { $0.id == attachment.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 18)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.55))
            }
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove \(attachment.name)")
        }
    }
}

// MARK: - Quick Pill Model

private struct QuickPill: Identifiable {
    let id: String
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
}

// MARK: - Transcript Preview Sheet

struct TranscriptPreviewSheet: View {
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let text = attachment.transcribedText, !text.isEmpty {
                        Text(text)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .textSelection(.enabled)
                    } else {
                        ContentUnavailableView(
                            "No Transcript",
                            systemImage: "waveform.slash",
                            description: Text("This audio file has no transcribed text.")
                        )
                        .padding(.top, 60)
                    }
                }
            }
            .background(theme.background)
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(theme.brandPrimary)
                }
                if let text = attachment.transcribedText, !text.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            UIPasteboard.general.string = text
                            Haptics.play(.light)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
