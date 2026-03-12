import SwiftUI
import UniformTypeIdentifiers
import QuickLook

// MARK: - Terminal Browser View

/// A slide-over file browser panel for the terminal server.
///
/// Displays a file list with breadcrumb navigation, action toolbar,
/// and a mini terminal command runner at the bottom.
/// Presented as an overlay panel that slides in from the right edge.
struct TerminalBrowserView: View {
    @Bindable var viewModel: TerminalBrowserViewModel
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var showFilePicker = false
    @State private var previewFileURL: URL?
    @State private var shareFileURL: URL?
    @State private var confirmDeleteItem: TerminalFileItem?
    @FocusState private var isCommandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))

            // Breadcrumb navigation
            breadcrumbBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))

            // Action toolbar
            actionToolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider().foregroundStyle(theme.cardBorder.opacity(0.3))

            // File list
            fileListArea

            // Mini terminal
            if viewModel.isTerminalExpanded {
                Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
                terminalSection
            }

            // Terminal toggle bar
            terminalToggleBar
        }
        .background(theme.background)
        .ignoresSafeArea(.keyboard)
        .task {
            await viewModel.loadDirectory()
        }
        .alert("New Folder", isPresented: $viewModel.showNewFolderAlert) {
            TextField("Folder name", text: $viewModel.newFolderName)
            Button("Cancel", role: .cancel) { viewModel.newFolderName = "" }
            Button("Create") {
                let name = viewModel.newFolderName
                viewModel.newFolderName = ""
                Task { await viewModel.createFolder(name: name) }
            }
        }
        .confirmationDialog(
            "Delete \(confirmDeleteItem?.name ?? "")?",
            isPresented: Binding(
                get: { confirmDeleteItem != nil },
                set: { if !$0 { confirmDeleteItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = confirmDeleteItem {
                    Task { await viewModel.deleteItem(item) }
                }
                confirmDeleteItem = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showFilePicker) {
            TerminalDocumentPicker { urls in
                for url in urls {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        Task {
                            await viewModel.uploadFile(data: data, fileName: url.lastPathComponent)
                        }
                    }
                }
            }
        }
        .quickLookPreview($previewFileURL)
        .sheet(item: $shareFileURL) { url in
            ShareSheetView(activityItems: [url])
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Files")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            Spacer()

            // Placeholder for symmetry
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Breadcrumb Navigation

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(viewModel.pathSegments.enumerated()), id: \.element.path) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }

                    Button {
                        viewModel.navigateToPath(segment.path)
                        Haptics.play(.light)
                    } label: {
                        Text(segment.name)
                            .font(.system(size: 13, weight: segment.path == viewModel.currentPath ? .bold : .medium))
                            .foregroundStyle(segment.path == viewModel.currentPath ? theme.brandPrimary : theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                segment.path == viewModel.currentPath
                                    ? theme.brandPrimary.opacity(0.1)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Action Toolbar

    private var actionToolbar: some View {
        HStack(spacing: 12) {
            // Refresh
            Button {
                viewModel.refresh()
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)

            // New folder
            Button {
                viewModel.showNewFolderAlert = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)

            // Upload
            Button {
                showFilePicker = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Item count
            Text("\(viewModel.items.count) items")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - File List

    private var fileListArea: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.error)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") { viewModel.refresh() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.brandPrimary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.sortedItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.textTertiary)
                    Text("Empty directory")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.sortedItems) { item in
                        fileRow(item)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.3))
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.loadDirectory() }
            }
        }
    }

    // MARK: - File Row

    private func fileRow(_ item: TerminalFileItem) -> some View {
        Button {
            if item.isDirectory {
                viewModel.navigateToDirectory(item.path)
                Haptics.play(.light)
            } else {
                // Preview file
                Task {
                    if let url = await viewModel.downloadFile(item) {
                        previewFileURL = url
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                // Icon
                Image(systemName: item.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(item.isDirectory ? theme.brandPrimary : iconColor(for: item))
                    .frame(width: 28)

                // Name + details
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: item.isDirectory ? .semibold : .regular))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let size = item.formattedSize {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer()

                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmDeleteItem = item
            } label: {
                Label("Delete", systemImage: "trash")
            }

            if !item.isDirectory {
                Button {
                    Task {
                        if let url = await viewModel.downloadFile(item) {
                            shareFileURL = url
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(theme.brandPrimary)
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button {
                    Task {
                        if let url = await viewModel.downloadFile(item) {
                            previewFileURL = url
                        }
                    }
                } label: {
                    Label("Preview", systemImage: "eye")
                }

                Button {
                    Task {
                        if let url = await viewModel.downloadFile(item) {
                            shareFileURL = url
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }

            Button {
                UIPasteboard.general.string = item.path
                Haptics.notify(.success)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                confirmDeleteItem = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func iconColor(for item: TerminalFileItem) -> Color {
        switch item.fileExtension {
        case "py", "js", "ts", "swift", "java", "cpp", "c", "go", "rs", "rb":
            return .orange
        case "json", "yaml", "yml", "xml", "toml":
            return .purple
        case "md", "txt", "log":
            return theme.textSecondary
        case "png", "jpg", "jpeg", "gif", "svg":
            return .green
        case "pdf":
            return .red
        case "sh", "bash", "zsh":
            return .green
        default:
            return theme.textTertiary
        }
    }

    // MARK: - Terminal Toggle

    private var terminalToggleBar: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.isTerminalExpanded.toggle()
            }
            if viewModel.isTerminalExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isCommandFocused = true
                }
            }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: viewModel.isTerminalExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(viewModel.isTerminalExpanded ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surfaceContainer.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Terminal Section

    private var terminalSection: some View {
        VStack(spacing: 0) {
            // Command output — uses flexible height to fill available space
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.commandHistory) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                // Prompt + command
                                HStack(spacing: 4) {
                                    Text("$")
                                        .foregroundStyle(.green)
                                    Text(entry.command)
                                        .foregroundStyle(theme.textPrimary)
                                }
                                .font(.system(size: 12, design: .monospaced))

                                // Output
                                if !entry.output.isEmpty {
                                    Text(entry.output)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(theme.textSecondary)
                                        .textSelection(.enabled)
                                }

                                if entry.isRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(.top, 2)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 200, maxHeight: 350)
                .background(Color.black.opacity(0.3))
                .onChange(of: viewModel.commandHistory.count) { _, _ in
                    if let last = viewModel.commandHistory.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // Command input — uses UIKit UITextField for proper return key handling.
            // Return key executes the command without dismissing the keyboard.
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.green)

                TerminalTextField(
                    text: $viewModel.commandInput,
                    textColor: UIColor(theme.textPrimary),
                    onReturn: {
                        let cmd = viewModel.commandInput
                        Task { await viewModel.executeCommand(cmd) }
                    }
                )
                .frame(height: 28)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.2))
        }
    }
}

// MARK: - Slide-Over Panel Container

/// A container that presents the terminal browser as a right-edge slide-over panel.
/// Manages the open/close animation and background dimming.
struct TerminalSlideOverPanel: View {
    @Binding var isOpen: Bool
    @Bindable var viewModel: TerminalBrowserViewModel

    @Environment(\.theme) private var theme
    @GestureState private var dragOffset: CGFloat = 0

    /// Panel width as percentage of screen.
    private let panelWidthRatio: CGFloat = 0.85

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = geometry.size.width * panelWidthRatio
            let offsetX = isOpen ? 0 : panelWidth

            ZStack(alignment: .trailing) {
                // Dim background
                if isOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                isOpen = false
                            }
                        }
                        .transition(.opacity)
                }

                // Panel
                TerminalBrowserView(
                    viewModel: viewModel,
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isOpen = false
                        }
                    }
                )
                .frame(width: panelWidth)
                .background(theme.background)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.25), radius: 20, x: -5)
                .offset(x: max(0, offsetX + dragOffset))
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            // Only allow dragging right (to dismiss)
                            if value.translation.width > 0 {
                                state = value.translation.width
                            }
                        }
                        .onEnded { value in
                            // If dragged more than 30% of panel width, dismiss
                            if value.translation.width > panelWidth * 0.3 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isOpen = false
                                }
                            }
                        }
                )
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isOpen)
        }
    }
}

// MARK: - Right Edge Swipe Gesture

/// A UIViewRepresentable that detects right-edge swipe gestures.
/// Triggers the file browser panel when the user swipes from the right edge.
struct RightEdgeSwipeGesture: UIViewRepresentable {
    var isEnabled: Bool
    var onSwipe: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = true

        let edgeGesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleEdgeSwipe(_:))
        )
        edgeGesture.edges = .right
        view.addGestureRecognizer(edgeGesture)
        context.coordinator.gesture = edgeGesture

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.gesture?.isEnabled = isEnabled
        context.coordinator.onSwipe = onSwipe
    }

    class Coordinator: NSObject {
        var onSwipe: () -> Void
        weak var gesture: UIScreenEdgePanGestureRecognizer?

        init(onSwipe: @escaping () -> Void) {
            self.onSwipe = onSwipe
        }

        @objc func handleEdgeSwipe(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            if recognizer.state == .recognized {
                onSwipe()
            }
        }
    }
}

// MARK: - Helper Views

/// Document picker for terminal file upload.
private struct TerminalDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

/// A UIKit-backed text field for the terminal command input.
///
/// Uses `UITextField` directly so we can intercept the return key via
/// `textFieldShouldReturn` and return `false` — this executes the command
/// **without** dismissing the keyboard, which SwiftUI's `TextField.onSubmit`
/// cannot do.
private struct TerminalTextField: UIViewRepresentable {
    @Binding var text: String
    var textColor: UIColor
    var onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.textColor = textColor
        field.tintColor = textColor
        field.attributedPlaceholder = NSAttributedString(
            string: "command…",
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .default
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        // Only update text if it actually changed (avoid cursor jump)
        if field.text != text {
            field.text = text
        }
        field.textColor = textColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onReturn: onReturn)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var onReturn: () -> Void

        init(text: Binding<String>, onReturn: @escaping () -> Void) {
            _text = text
            self.onReturn = onReturn
        }

        @objc func textChanged(_ field: UITextField) {
            text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            // Execute command, keep keyboard open
            onReturn()
            return false
        }
    }
}

