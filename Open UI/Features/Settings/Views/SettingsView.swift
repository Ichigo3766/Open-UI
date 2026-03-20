import SwiftUI
import AVFoundation
import Speech
import UserNotifications

/// Main settings view with profile, appearance, server, privacy, and about sections.
/// Matches the Flutter app's "You" / profile page layout with all customization options.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @Bindable var viewModel: AuthViewModel
    @Bindable var appearanceManager: AppearanceManager
    @State private var showSignOutConfirmation = false
    @State private var navigationPath = NavigationPath()
    @State private var showDefaultModelPicker = false
    @State private var availableModels: [AIModel] = []
    @State private var defaultModelId: String?
    @State private var isLoadingModels = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: Spacing.sectionGap) {
                    // Profile header
                    if let user = viewModel.currentUser {
                        SettingsSection(header: "Account") {
                            SettingsProfileHeader(
                                name: user.displayName,
                                email: user.email,
                                avatarURL: profileImageURL(for: user),
                                authToken: dependencies.apiClient?.network.authToken
                            ) {
                                navigationPath.append(SettingsDestination.profile)
                            }
                        }
                    }

                    // Admin Console (only visible to admin users — placed prominently)
                    if viewModel.currentUser?.role == .admin {
                        SettingsSection(header: "Administration") {
                            SettingsCell(
                                icon: "shield.lefthalf.filled",
                                title: "Admin Console",
                                subtitle: "Manage users & roles",
                                iconColor: .orange,
                                showDivider: false,
                                accessory: .chevron
                            ) {
                                navigationPath.append(SettingsDestination.adminConsole)
                            }
                        }
                    }

                    // Default Model
                    SettingsSection(header: "Default Model") {
                        SettingsCell(
                            icon: "cpu",
                            title: "Default Model",
                            subtitle: defaultModelDisplayName,
                            showDivider: false,
                            accessory: isLoadingModels ? .loading : .chevron
                        ) {
                            showDefaultModelPicker = true
                        }
                    }

                                    // Display & Customization
                    SettingsSection(header: "Display") {
                        SettingsCell(
                            icon: "paintbrush",
                            title: "Appearance",
                            subtitle: appearanceManager.colorSchemeMode.displayName,
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.appearance)
                        }
                        SettingsCell(
                            icon: "textformat.size",
                            title: "Accessibility",
                            subtitle: dependencies.accessibilityManager.isCustomized
                                ? (dependencies.accessibilityManager.matchingPreset?.displayName ?? "Custom")
                                : "Standard",
                            iconColor: .purple,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.accessibility)
                        }
                    }

                    // Chat Settings
                    SettingsSection(header: "Chat") {
                        SettingsCell(
                            icon: "bubble.left.and.bubble.right",
                            title: "Chat Behavior",
                            subtitle: "Haptics, titles, suggestions",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.chatSettings)
                        }
                    }

                    // Voice
                    SettingsSection(header: "Voice") {
                        SettingsCell(
                            icon: "waveform",
                            title: "Text-to-Speech",
                            subtitle: "Voice & speed settings",
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.ttsSettings)
                        }
                        SettingsCell(
                            icon: "mic",
                            title: "Speech-to-Text",
                            subtitle: "Voice input settings",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.sttSettings)
                        }
                    }

                    // Notifications
                    SettingsSection(header: "Notifications") {
                        SettingsCell(
                            icon: "bell.badge",
                            title: "Notifications",
                            subtitle: notificationStatusSubtitle,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.notifications)
                        }
                    }

                    // Server & Connection
                    SettingsSection(header: "Server") {
                        SettingsCell(
                            icon: "server.rack",
                            title: "Server Configuration",
                            subtitle: viewModel.serverURL,
                            showDivider: true,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.serverManagement)
                        }

                        SettingsCell(
                            icon: "arrow.left.arrow.right.circle",
                            title: "Manage Servers",
                            subtitle: viewModel.savedServers.count == 1
                                ? "1 server saved"
                                : "\(viewModel.savedServers.count) servers saved",
                            iconColor: .teal,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.serverSwitcher)
                        }
                    }

                    // Personalization
                    SettingsSection(header: "Personalization") {
                        SettingsCell(
                            icon: "brain",
                            title: "Memories",
                            subtitle: "What the AI remembers about you",
                            iconColor: .purple,
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.memories)
                        }
                    }

                    // Privacy & Security
                    SettingsSection(header: "Privacy & Security") {
                        SettingsCell(
                            icon: "lock.shield",
                            title: "Privacy & Security",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.privacySecurity)
                        }
                    }

                    // About
                    SettingsSection(header: "About") {
                        SettingsCell(
                            icon: "info.circle",
                            title: "About Open UI",
                            showDivider: false,
                            accessory: .chevron
                        ) {
                            navigationPath.append(SettingsDestination.about)
                        }
                    }

                    // Sign out
                    SettingsSection {
                        DestructiveSettingsCell(
                            icon: "rectangle.portrait.and.arrow.right",
                            title: "Sign Out"
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSignOutConfirmation = true
                            }
                            Haptics.play(.medium)
                        }
                    }
                }
                .padding(.vertical, Spacing.lg)
            }
            .background(theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .profile:
                    ProfileView(viewModel: viewModel)
                case .appearance:
                    AppearanceSettingsView(manager: appearanceManager)
                case .accessibility:
                    AccessibilitySettingsView(manager: dependencies.accessibilityManager)
                case .serverManagement:
                    ServerManagementView(viewModel: viewModel)
                case .serverSwitcher:
                    ScrollView {
                        SavedServersView(viewModel: viewModel, showAddServerButton: true)
                    }
                    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                    .navigationTitle("Manage Servers")
                    .navigationBarTitleDisplayMode(.large)
                case .privacySecurity:
                    PrivacySecurityView()
                case .about:
                    AboutView(viewModel: viewModel)
                case .chatSettings:
                    ChatSettingsView()
                case .ttsSettings:
                    TTSSettingsView()
                case .sttSettings:
                    STTSettingsView()
                case .notifications:
                    NotificationSettingsView()
                case .adminConsole:
                    AdminConsoleView()
                case .memories:
                    MemoriesView()
                }
            }
            .sheet(isPresented: $showDefaultModelPicker) {
                DefaultModelPickerView(
                    models: availableModels,
                    selectedModelId: $defaultModelId,
                    onSave: saveDefaultModel
                )
            }
            .sheet(isPresented: $showSignOutConfirmation) {
                SignOutConfirmationSheet(
                    onSignOut: {
                        showSignOutConfirmation = false
                        Task {
                            await viewModel.signOut()
                            dismiss()
                        }
                    },
                    onSignOutAndRemove: {
                        showSignOutConfirmation = false
                        Task {
                            await viewModel.signOutAndDisconnect()
                            dismiss()
                        }
                    },
                    onCancel: {
                        showSignOutConfirmation = false
                    }
                )
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
            }
            .task {
                await loadModels()
            }
        }
    }

    private var notificationStatusSubtitle: String {
        NotificationService.shared.isAuthorized ? "Enabled" : "Disabled"
    }

    private var defaultModelDisplayName: String {
        if isLoadingModels { return "Loading…" }
        if let id = defaultModelId, let model = availableModels.first(where: { $0.id == id }) {
            return model.name
        }
        return "Auto-select"
    }

    private func loadModels() async {
        guard let manager = dependencies.conversationManager else { return }
        isLoadingModels = true
        do {
            availableModels = try await manager.fetchModels()
            defaultModelId = await manager.fetchDefaultModel()
        } catch {}
        isLoadingModels = false
    }

    private func saveDefaultModel(_ modelId: String?) {
        // Save to user settings on server
        Task {
            guard let api = dependencies.apiClient else { return }
            do {
                var settings: [String: Any] = [:]
                if let id = modelId {
                    settings["ui"] = ["models": [id]]
                } else {
                    settings["ui"] = ["models": [String]()]
                }
                try await api.updateUserSettings(settings)
                defaultModelId = modelId
            } catch {}
        }
    }

    private func profileImageURL(for user: User) -> URL? {
        guard let urlString = user.profileImageURL, !urlString.isEmpty else { return nil }
        if urlString.hasPrefix("http") {
            return URL(string: urlString)
        }
        return URL(string: "\(viewModel.serverURL)\(urlString)")
    }
}

// MARK: - Settings Navigation Destinations

enum SettingsDestination: Hashable {
    case profile
    case appearance
    case accessibility
    case serverManagement
    case serverSwitcher
    case privacySecurity
    case about
    case chatSettings
    case ttsSettings
    case sttSettings
    case notifications
    case adminConsole
    case memories
}

// MARK: - Default Model Picker

struct DefaultModelPickerView: View {
    let models: [AIModel]
    @Binding var selectedModelId: String?
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @State private var localSelection: String?

    private var filteredModels: [AIModel] {
        if searchText.isEmpty { return models }
        let q = searchText.lowercased()
        return models.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Auto-select option
                Button {
                    localSelection = nil
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(theme.brandPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-select")
                                .scaledFont(size: 16)
                                .fontWeight(.semibold)
                            Text("Use the server default model. ")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer()
                        if localSelection == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                }
                .listRowBackground(
                    localSelection == nil ? theme.brandPrimary.opacity(0.08) : Color.clear
                )

                // Model list
                ForEach(filteredModels) { model in
                    Button {
                        localSelection = model.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                                HStack(spacing: 4) {
                                    if model.isMultimodal {
                                        Label("Vision", systemImage: "photo")
                                            .scaledFont(size: 10)
                                            .foregroundStyle(theme.brandPrimary)
                                    }
                                }
                            }
                            Spacer()
                            if localSelection == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.brandPrimary)
                            }
                        }
                    }
                    .listRowBackground(
                        localSelection == model.id ? theme.brandPrimary.opacity(0.08) : Color.clear
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search models")
            .navigationTitle("Default Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(localSelection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            localSelection = selectedModelId
        }
    }
}

// MARK: - Chat Settings View

struct ChatSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @AppStorage("sendOnEnter") private var sendOnEnter = true
    @AppStorage("streamingHaptics") private var streamingHaptics = true
    @AppStorage("titleGenerationEnabled") private var titleGenerationEnabled = true
    @AppStorage("suggestionsEnabled") private var suggestionsEnabled = true
    @AppStorage("temporaryChatDefault") private var temporaryChatDefault = false
    @AppStorage("quickPills") private var quickPillsData: String = ""
    @State private var availableTools: [ToolItem] = []
    @State private var isLoadingTools = false

    /// Whether the server admin has enabled title generation globally.
    private var serverTitleGenEnabled: Bool {
        dependencies.taskConfig.enableTitleGeneration
    }

    /// Whether the server admin has enabled follow-up generation globally.
    private var serverFollowUpGenEnabled: Bool {
        dependencies.taskConfig.enableFollowUpGeneration
    }

    private var selectedPillIds: Set<String> {
        Set(quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    private func togglePill(_ id: String) {
        var ids = quickPillsData.components(separatedBy: ",").filter { !$0.isEmpty }
        if ids.contains(id) {
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        quickPillsData = ids.joined(separator: ",")
        Haptics.play(.light)
    }

    var body: some View {
        List {
            Section("Input Behavior") {
                Toggle("Send on Enter", isOn: $sendOnEnter)
                    .tint(theme.brandPrimary)
                Text("When enabled, pressing Enter sends the message. When disabled, Enter creates a new line.")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .listRowSeparator(.hidden)
            }

            Section {
                Toggle("Haptic feedback while streaming", isOn: $streamingHaptics)
                    .tint(theme.brandPrimary)
            } header: {
                Text("Haptics")
            } footer: {
                Text("Provides a subtle haptic pulse as each token streams in. May increase battery usage.")
            }

            Section {
                Toggle("Auto-generate chat titles", isOn: $titleGenerationEnabled)
                    .tint(theme.brandPrimary)
                    .disabled(!serverTitleGenEnabled)
                Toggle("Show follow-up suggestions", isOn: $suggestionsEnabled)
                    .tint(theme.brandPrimary)
                    .disabled(!serverFollowUpGenEnabled)
            } header: {
                Text("Generation")
            } footer: {
                if !serverTitleGenEnabled || !serverFollowUpGenEnabled {
                    Text("Some options are disabled by your server administrator.")
                } else {
                    Text("Disabling title generation reduces server load. Follow-up suggestions appear at the end of each response.")
                }
            }

            Section {
                Toggle("Temporary chats by default", isOn: $temporaryChatDefault)
                    .tint(theme.brandPrimary)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Temporary chats are not saved to the server. You can still save a temporary chat manually.")
            }

            Section {
                Text("Choose which quick actions appear below the message input. Tap to toggle.")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .listRowSeparator(.hidden)

                // Built-in pills
                quickPillToggle(id: "web", icon: "magnifyingglass", name: "Web Search")
                quickPillToggle(id: "image", icon: "photo", name: "Image Generation")

                // Server tools
                if isLoadingTools {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading tools…")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                } else {
                    ForEach(availableTools, id: \.id) { tool in
                        quickPillToggle(id: tool.id, icon: "wrench", name: tool.name)
                    }
                }

                if !selectedPillIds.isEmpty {
                    Button(role: .destructive) {
                        quickPillsData = ""
                        Haptics.play(.medium)
                    } label: {
                        Label("Clear All Quick Actions", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text("Quick Actions")
            } footer: {
                Text("\(selectedPillIds.count) action\(selectedPillIds.count == 1 ? "" : "s") selected")
            }
        }
        .navigationTitle("Chat Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTools()
        }
    }

    private func quickPillToggle(id: String, icon: String, name: String) -> some View {
        let isSelected = selectedPillIds.contains(id)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                togglePill(id)
            }
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        (isSelected ? theme.brandPrimary : theme.textSecondary).opacity(0.12)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(name)
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 20)
                    .foregroundStyle(isSelected ? theme.brandPrimary : theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func loadTools() async {
        guard let manager = dependencies.conversationManager else { return }
        isLoadingTools = true
        do {
            availableTools = try await manager.fetchTools()
        } catch {}
        isLoadingTools = false
    }
}

// MARK: - TTS Settings View

struct TTSSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @AppStorage("ttsSpeechRate") private var speechRate = 1.0
    @AppStorage("ttsVoiceIdentifier") private var voiceIdentifier: String = ""
    @AppStorage("ttsEngine") private var selectedEngine: String = "system"
    @AppStorage("ttsMarvisVoice") private var marvisVoice: String = "conversationalA"
    @AppStorage("ttsMarvisQuality") private var marvisQuality: Int = 32
    @State private var isSpeaking = false
    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var isDownloadingModel = false
    @State private var marvisModelSize: String = "–"

    private var ttsService: TextToSpeechService {
        dependencies.textToSpeechService
    }

    private var engineOptions: [(String, String, String)] {
        var options: [(String, String, String)] = [
            ("auto", "Auto", "Best available: Marvis → Server → System"),
            ("system", "System (Apple)", "Built-in AVSpeechSynthesizer")
        ]
        if ttsService.isServerAvailable {
            options.insert(
                ("server", "Server", "OpenWebUI server-side TTS"),
                at: options.count - 1
            )
        }
        if ttsService.isMarvisAvailable {
            options.insert(
                ("marvis", "Marvis Neural (On-Device)", "On-device AI voice — Marvis TTS"),
                at: 1
            )
        }
        return options
    }

    var body: some View {
        List {
            // Engine Selection
            Section {
                ForEach(engineOptions, id: \.0) { value, label, description in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedEngine = value
                        }
                        syncEngineToService()
                        Haptics.play(.light)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Spacing.xs) {
                                    Text(label)
                                        .scaledFont(size: 16)
                                        .fontWeight(.medium)
                                        .foregroundStyle(theme.textPrimary)

                                    if value == "marvis" {
                                        Text("NEW")
                                            .scaledFont(size: 9, weight: .heavy)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule().fill(
                                                    LinearGradient(
                                                        colors: [theme.brandPrimary, theme.brandPrimary.opacity(0.7)],
                                                        startPoint: .leading,
                                                        endPoint: .trailing
                                                    )
                                                )
                                            )
                                    }
                                }

                                Text(description)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }

                            Spacer()

                            Image(systemName: selectedEngine == value ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 22)
                                .foregroundStyle(
                                    selectedEngine == value ? theme.brandPrimary : theme.textTertiary.opacity(0.4)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("TTS Engine")
            } footer: {
                if selectedEngine == "auto" {
                    Text("Auto mode prefers the Marvis neural voice when the model is downloaded and ready, otherwise uses the system voice.")
                } else if selectedEngine == "marvis" {
                    Text("Marvis TTS runs locally on your device. Downloads on first use (~250MB).")
                }
            }

            // Marvis Model Settings (shown when Marvis is selected)
            if (selectedEngine == "marvis" || selectedEngine == "auto") && ttsService.isMarvisAvailable {
                Section {
                    // Model status
                    HStack {
                        Text("Status")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        marvisStatusBadge
                    }

                    // Voice picker
                    Picker("Voice", selection: $marvisVoice) {
                        Text("Conversational A").tag("conversationalA")
                        Text("Conversational B").tag("conversationalB")
                    }
                    .onChange(of: marvisVoice) { _, _ in
                        syncMarvisConfig()
                    }

                    // Quality picker
                    Picker("Quality", selection: $marvisQuality) {
                        Text("Low (fastest)").tag(8)
                        Text("Medium").tag(16)
                        Text("High").tag(24)
                        Text("Maximum (best)").tag(32)
                    }
                    .onChange(of: marvisQuality) { _, _ in
                        syncMarvisConfig()
                    }

                    // Download / Preload button
                    if case .unloaded = ttsService.marvisState {
                        Button {
                            preloadMarvisModel()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.down.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Download & Load Model")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    } else if case .downloading(let progress) = ttsService.marvisState {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            HStack(spacing: Spacing.sm) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Downloading model…")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textSecondary)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .scaledFont(size: 12, weight: .medium)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                            ProgressView(value: progress)
                                .tint(theme.brandPrimary)
                            Text("Please keep the app open")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    } else if case .ready = ttsService.marvisState {
                        Button(role: .destructive) {
                            ttsService.unloadMarvisModel()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "xmark.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Unload Model (Free Memory)")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                        }

                        // STORAGE FIX: Option to delete the downloaded model files
                        // from disk, freeing ~250MB of storage.
                        Button(role: .destructive) {
                            ttsService.marvisService.unloadAndDeleteModel()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "trash.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Delete Downloaded Model (~250MB)")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                        }
                    } else if case .error = ttsService.marvisState {
                        Button {
                            retryMarvisLoad()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Retry Download")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.warning)
                        }
                    }
                } header: {
                    Text("Marvis Neural Voice")
                } footer: {
                    Text("The model downloads from HuggingFace on first use (~250MB) and is cached locally. Unloading frees memory.")
                }
            }

            // System Voice Settings (only when system engine is selected)
            if selectedEngine == "system" || selectedEngine == "auto" {
                Section {
                    NavigationLink {
                        TTSVoicePickerView(
                            voiceIdentifier: $voiceIdentifier,
                            voices: availableVoices
                        )
                        .onChange(of: voiceIdentifier) { _, _ in
                            syncSettingsToService()
                        }
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(
                                voiceIdentifier.isEmpty
                                    ? "Auto (detect language)"
                                    : (AVSpeechSynthesisVoice(identifier: voiceIdentifier)?.name ?? voiceIdentifier)
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(Int(speechRate * 100))%")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        Slider(value: $speechRate, in: 0.25...2.0, step: 0.05)
                            .tint(theme.brandPrimary)
                            .onChange(of: speechRate) { _, _ in
                                syncSettingsToService()
                            }
                    }
                } header: {
                    Text("System Voice")
                } footer: {
                    Text("These settings apply when using Apple's built-in speech synthesizer.")
                }
            }

            // Preview
            Section("Preview") {
                Button {
                    previewVoice()
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: isSpeaking ? "stop.fill" : "play.fill")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(isSpeaking ? theme.error : theme.brandPrimary)
                        Text(isSpeaking ? "Stop Preview" : "Preview Voice")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if isSpeaking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            let engineLabel: String = {
                                switch selectedEngine {
                                case "marvis": return "Marvis"
                                case "server": return "Server"
                                case "system": return "System"
                                default: return "Auto"
                                }
                            }()
                            Text(engineLabel)
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
            }
        }

        // Model Storage Management
        Section {
            HStack {
                Text("Marvis TTS")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(marvisModelSize)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    ttsService.marvisService.unloadAndDeleteModel()
                    refreshMarvisModelSize()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } header: {
            Text("Model Storage")
        } footer: {
            Text("Swipe left on a model row to delete it from disk and free storage.")
        }
        .navigationTitle("Text-to-Speech")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            availableVoices = dependencies.textToSpeechService.availableVoices()
            syncSettingsToService()
            syncEngineToService()
            syncMarvisConfig()
            refreshMarvisModelSize()
        }
    }

    // MARK: - Marvis Status Badge

    @ViewBuilder
    private var marvisStatusBadge: some View {
        switch ttsService.marvisState {
        case .unloaded:
            statusPill("Not Downloaded", color: theme.textTertiary)
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading… \(Int(progress * 100))%")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.warning)
                }
                ProgressView(value: progress)
                    .tint(theme.brandPrimary)
                    .frame(width: 100)
            }
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        case .ready:
            statusPill("Ready", color: theme.success)
        case .generating:
            statusPill("Generating…", color: theme.brandPrimary)
        case .error(let msg):
            statusPill("Error", color: theme.error)
                .help(msg)
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func syncSettingsToService() {
        let service = dependencies.textToSpeechService
        service.speechRate = Float(speechRate) * AVSpeechUtteranceDefaultSpeechRate
        service.voiceIdentifier = voiceIdentifier.isEmpty ? nil : voiceIdentifier
    }

    private func syncEngineToService() {
        let service = dependencies.textToSpeechService
        switch selectedEngine {
        case "marvis", "mlx":
            service.preferredEngine = .marvis
        case "server":
            service.preferredEngine = .server
        case "system":
            service.preferredEngine = .system
        default:
            service.preferredEngine = .auto
        }
    }

    private func syncMarvisConfig() {
        let service = dependencies.textToSpeechService
        service.marvisConfig.voice = marvisVoice
        service.marvisConfig.qualityLevel = marvisQuality
    }

    private func preloadMarvisModel() {
        isDownloadingModel = true
        Task {
            await ttsService.preloadMarvisModel()
            isDownloadingModel = false
        }
    }

    private func retryMarvisLoad() {
        ttsService.unloadMarvisModel()
        isDownloadingModel = true
        Task {
            await ttsService.preloadMarvisModel()
            isDownloadingModel = false
        }
    }

    private func previewVoice() {
        let service = dependencies.textToSpeechService
        if isSpeaking {
            service.stop()
            isSpeaking = false
        } else {
            syncSettingsToService()
            syncEngineToService()
            syncMarvisConfig()
            isSpeaking = true
            service.onComplete = { [self] in
                isSpeaking = false
            }
            service.speak(
                "Hello! This is a preview of the text-to-speech voice. I can read your AI assistant's responses aloud."
            )
        }
    }

    private func refreshMarvisModelSize() {
        let size = StorageManager.shared.marvisTTSModelSize()
        if size > 0 {
            marvisModelSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            marvisModelSize = "Not downloaded"
        }
    }

}

// MARK: - STT Settings View

struct STTSettingsView: View {
@Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @AppStorage("sttEngine") private var selectedSTTEngine: String = "device"
    @AppStorage("audioFileTranscriptionMode") private var audioFileMode: String = "server"
    @AppStorage("voiceSilenceDuration") private var silenceDuration: Double = 2.0
    @AppStorage("sttLocale") private var sttLocale: String = ""
    @State private var micPermissionGranted = false
    @State private var speechPermissionGranted = false
    @State private var parakeetModelSize: String = "–"

    private var asr: OnDeviceASRService { dependencies.asrService }

    /// All locales supported by Apple's on-device speech recognizer, sorted by display name.
    private var supportedSTTLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted {
                (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                    < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
            }
    }

    private var hasServerSTT: Bool {
        dependencies.apiClient != nil
    }

    var body: some View {
        List {
            // Live Voice Transcription (microphone / call)
            Section {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedSTTEngine = "device"
                    }
                    Haptics.play(.light)
                } label: {
                    engineRow(
                        value: "device",
                        label: "On-Device (Apple)",
                        description: "Apple Speech framework — fast, private, no internet required",
                        selected: selectedSTTEngine == "device"
                    )
                }
                .buttonStyle(.plain)

                if hasServerSTT {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedSTTEngine = "server"
                        }
                        Haptics.play(.light)
                    } label: {
                        engineRow(
                            value: "server",
                            label: "Server (OpenWebUI)",
                            description: "Server-side transcription via /api/v1/audio/transcriptions",
                            selected: selectedSTTEngine == "server"
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Voice Transcription Engine")
            } footer: {
                if selectedSTTEngine == "device" {
                    Text("Used for live microphone input. Apple's Speech framework works offline with no data sent to external servers.")
                } else if selectedSTTEngine == "server" {
                    Text("Used for live microphone input. Sends audio to your OpenWebUI server for transcription. Requires internet.")
                } else {
                    Text("Select the engine used for live microphone input and voice calls.")
                }
            }

            // Audio File Transcription (attach audio file in chat)
            Section {
                // Server option (default)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        audioFileMode = "server"
                    }
                    Haptics.play(.light)
                } label: {
                    engineRow(
                        value: "server",
                        label: "Server",
                        description: "Uploads audio to your OpenWebUI server — transcription happens automatically",
                        selected: audioFileMode == "server"
                    )
                }
                .buttonStyle(.plain)

                // On-device option (only shown if Parakeet is available)
                if asr.isAvailable {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            audioFileMode = "device"
                            asr.switchVariant(.parakeet)
                        }
                        Haptics.play(.light)
                    } label: {
                        HStack(spacing: Spacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Spacing.xs) {
                                    Text("On-Device (Parakeet)")
                                        .scaledFont(size: 16)
                                        .fontWeight(.medium)
                                        .foregroundStyle(theme.textPrimary)
                                    Text("NEW")
                                        .scaledFont(size: 9, weight: .heavy)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(
                                                LinearGradient(
                                                    colors: [theme.brandPrimary, theme.brandPrimary.opacity(0.7)],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                        )
                                }
                                Text("parakeet-tdt-0.6b-v3 — English, fully on-device")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: audioFileMode == "device" ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 22)
                                .foregroundStyle(
                                    audioFileMode == "device" ? theme.brandPrimary : theme.textTertiary.opacity(0.4)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Audio File Transcription")
            } footer: {
                if audioFileMode == "server" {
                    Text("Audio files attached in chat are uploaded to your server, which handles transcription automatically. No extra downloads needed.")
                } else {
                    Text("Audio files are transcribed locally on your device using Parakeet. Fully private — no audio sent to the server. Downloads once.")
                }
            }

            // On-Device Model Settings (Parakeet) — only when device mode is selected
            if audioFileMode == "device" && asr.isAvailable {
                let activeVariant: ASRModelVariant = .parakeet
                let currentModelSize = parakeetModelSize
                let modelLabel = activeVariant.displayName
                Section {
                    HStack {
                        Text("Status")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        asrStatusBadge
                    }

                    if currentModelSize != "–" {
                        HStack {
                            Text("Model Size on Disk")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(currentModelSize)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    if case .unloaded = asr.state {
                        Button {
                            Task { try? await asr.loadModel() }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.down.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Download & Load Model")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                    } else if case .loading = asr.state {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading model…")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textSecondary)
                        }
                    } else if case .ready = asr.state {
                        Button(role: .destructive) {
                            asr.unloadModel()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "xmark.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Unload Model (Free Memory)")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                        }

                        Button(role: .destructive) {
                            asr.unloadAndDeleteVariant(activeVariant)
                            refreshModelSizes()
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "trash.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Delete Downloaded Model")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                        }
                    } else if case .error = asr.state {
                        Button {
                            asr.unloadModel()
                            Task { try? await asr.loadModel() }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .scaledFont(size: 16, weight: .medium)
                                Text("Retry Download")
                                    .scaledFont(size: 16)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(theme.warning)
                        }
                    }
                } header: {
                    Text("\(modelLabel)")
                } footer: {
                    Text("The model downloads from HuggingFace on first use and is cached locally. Unloading frees memory; deleting removes the download.")
                }
            }

            // Language (only for on-device Apple STT)
            if selectedSTTEngine == "device" {
                Section {
                    NavigationLink {
                        STTLanguagePickerView(
                            sttLocale: $sttLocale,
                            locales: supportedSTTLocales
                        )
                        .onChange(of: sttLocale) { _, newValue in
                            dependencies.speechRecognitionService.updateLocale(newValue)
                        }
                    } label: {
                        HStack {
                            Text("Language")
                            Spacer()
                            Text(
                                sttLocale.isEmpty
                                    ? "Auto"
                                    : (Locale.current.localizedString(forIdentifier: sttLocale) ?? sttLocale)
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Choose the language you'll speak. \"Auto\" uses your device's current language.")
                }
            }

            // Voice Activity Detection
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Silence Duration")
                        Spacer()
                        Text("\(String(format: "%.1f", silenceDuration))s")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                    }
                    Slider(value: $silenceDuration, in: 0.5...5.0, step: 0.5)
                        .tint(theme.brandPrimary)
                }
            } header: {
                Text("Voice Activity Detection")
            } footer: {
                Text("How long to wait after you stop speaking before finalizing the transcript. Shorter = faster, longer = catches pauses mid-sentence.")
            }

            // Permissions
            Section {
                HStack {
                    Image(systemName: "mic.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("Microphone")
                        .scaledFont(size: 16)
                    Spacer()
                    if micPermissionGranted {
                        statusPill("Granted", color: theme.success)
                    } else {
                        statusPill("Not Granted", color: theme.warning)
                    }
                }

                HStack {
                    Image(systemName: "waveform")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("Speech Recognition")
                        .scaledFont(size: 16)
                    Spacer()
                    if speechPermissionGranted {
                        statusPill("Granted", color: theme.success)
                    } else {
                        statusPill("Not Granted", color: theme.warning)
                    }
                }

                if !micPermissionGranted || !speechPermissionGranted {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "gear")
                                .scaledFont(size: 14, weight: .medium)
                            Text("Open Settings to Grant Permissions")
                                .scaledFont(size: 16)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
            } header: {
                Text("Permissions")
            }
            // Model Storage Management
            Section {
                HStack {
                    Text("Parakeet ASR")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(parakeetModelSize)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        asr.unloadAndDeleteVariant(.parakeet)
                        refreshModelSizes()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

            } header: {
                Text("Model Storage")
            } footer: {
                Text("Swipe left on a model row to delete it from disk and free storage.")
            }
        }
        .navigationTitle("Audio & Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshPermissions()
            refreshModelSizes()
        }
    }

    /// Checks microphone and speech recognition permissions independently.
    private func refreshPermissions() {
        // Check microphone permission
        if #available(iOS 17.0, *) {
            micPermissionGranted = AVAudioApplication.shared.recordPermission == .granted
        } else {
            micPermissionGranted = AVAudioSession.sharedInstance().recordPermission == .granted
        }

        // Check speech recognition permission
        speechPermissionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - ASR Status Badge (shared for both variants)

    @ViewBuilder
    private var asrStatusBadge: some View {
        switch asr.state {
        case .unloaded:
            statusPill("Not Downloaded", color: theme.textTertiary)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        case .ready:
            statusPill("Ready", color: theme.success)
        case .transcribing:
            statusPill("Transcribing…", color: theme.brandPrimary)
        case .paused:
            statusPill("Paused", color: theme.textTertiary)
        case .error(let msg):
            statusPill("Error", color: theme.error)
                .help(msg)
        }
    }

    private func engineRow(value: String, label: String, description: String, selected: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .scaledFont(size: 16)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textPrimary)
                Text(description)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .scaledFont(size: 22)
                .foregroundStyle(selected ? theme.brandPrimary : theme.textTertiary.opacity(0.4))
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func refreshModelSizes() {
        let p = asr.modelSize(for: .parakeet)
        parakeetModelSize = p > 0 ? ByteCountFormatter.string(fromByteCount: p, countStyle: .file) : "Not downloaded"
    }

}

// MARK: - STT Language Picker

/// Full-screen scrollable list of all SFSpeechRecognizer-supported locales.
/// Uses a plain List so there's no nested-scroll conflict with the parent.
struct STTLanguagePickerView: View {
    @Binding var sttLocale: String
    let locales: [Locale]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredLocales: [Locale] {
        guard !searchText.isEmpty else { return locales }
        let q = searchText.lowercased()
        return locales.filter { locale in
            let name = (Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).lowercased()
            return name.contains(q) || locale.identifier.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Button {
                    sttLocale = ""
                    dismiss()
                } label: {
                    HStack {
                        Text("Auto (Device Language)")
                        Spacer()
                        if sttLocale.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }

            ForEach(filteredLocales, id: \.identifier) { locale in
                Button {
                    sttLocale = locale.identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        Spacer()
                        if sttLocale == locale.identifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $searchText, prompt: "Search language…")
        .navigationTitle("STT Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TTS Voice Picker

/// Full-screen scrollable list of all installed AVSpeechSynthesisVoice entries.
/// Uses a plain List so there's no nested-scroll conflict with the parent.
struct TTSVoicePickerView: View {
    @Binding var voiceIdentifier: String
    let voices: [AVSpeechSynthesisVoice]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        guard !searchText.isEmpty else { return voices }
        let q = searchText.lowercased()
        return voices.filter { voice in
            voice.name.lowercased().contains(q) || voice.language.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Button {
                    voiceIdentifier = ""
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto (detect language)")
                                .fontWeight(.medium)
                            Text("Picks the best voice for each message's language")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if voiceIdentifier.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }

            ForEach(filteredVoices, id: \.identifier) { voice in
                Button {
                    voiceIdentifier = voice.identifier
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                                .fontWeight(.medium)
                            Text(voice.language)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if voiceIdentifier == voice.identifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $searchText, prompt: "Search voice or language…")
        .navigationTitle("TTS Voice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Notification Settings View

struct NotificationSettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var systemPermissionGranted = NotificationService.shared.isAuthorized

    var body: some View {
        List {
            Section {
                Toggle("Generation Complete", isOn: $notificationsEnabled)
                    .tint(theme.brandPrimary)
            } header: {
                Text("Notification Types")
            } footer: {
                Text("Receive a notification when an AI response finishes generating. Works both when the app is in the background and when you're on a different screen.")
            }

            Section {
                HStack {
                    Image(systemName: "bell.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("System Permission")
                        .scaledFont(size: 16)
                    Spacer()
                    if systemPermissionGranted {
                        permissionPill("Granted", color: theme.success)
                    } else {
                        permissionPill("Not Granted", color: theme.warning)
                    }
                }

                if !systemPermissionGranted {
                    Button {
                        Task {
                            let granted = await NotificationService.shared.requestPermission()
                            systemPermissionGranted = granted
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "bell.badge")
                                .scaledFont(size: 14, weight: .medium)
                            Text("Request Permission")
                                .scaledFont(size: 16)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "gear")
                                .scaledFont(size: 14, weight: .medium)
                            Text("Open iOS Settings")
                                .scaledFont(size: 16)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                if systemPermissionGranted {
                    Text("Notifications are authorized. You can manage notification style in iOS Settings.")
                } else {
                    Text("Notifications require system permission. Tap \"Request Permission\" or enable them in iOS Settings → Open UI → Notifications.")
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Refresh permission state
            Task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                systemPermissionGranted = settings.authorizationStatus == .authorized
            }
        }
    }

    private func permissionPill(_ text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Sign Out Confirmation Sheet

/// A beautiful bottom sheet for sign-out confirmation, replacing the system confirmationDialog.
struct SignOutConfirmationSheet: View {
    let onSignOut: () -> Void
    let onSignOutAndRemove: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(theme.error.opacity(0.1))
                        .frame(width: 56, height: 56)
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .scaledFont(size: 22, weight: .medium)
                        .foregroundStyle(theme.error)
                }
                .scaleEffect(appeared ? 1 : 0.7)
                .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.05), value: appeared)

                Text("Sign Out")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text("Are you sure you want to sign out?")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.2).delay(0.05), value: appeared)

            Divider()
                .background(theme.divider)
                .padding(.horizontal, Spacing.screenPadding)

            // Action buttons
            VStack(spacing: Spacing.sm) {
                signOutButton(
                    title: "Sign Out",
                    subtitle: "Keep server connection",
                    icon: "arrow.right.circle",
                    action: onSignOut,
                    index: 0
                )

                signOutButton(
                    title: "Sign Out & Remove Server",
                    subtitle: "Clear all connection data",
                    icon: "trash.circle",
                    action: onSignOutAndRemove,
                    index: 1
                )

                // Cancel
                Button(action: onCancel) {
                    Text("Cancel")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .background(theme.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.2).delay(0.25), value: appeared)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.md)
        }
        .background(theme.background)
        .onAppear { appeared = true }
    }

    private func signOutButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void,
        index: Int
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(theme.error)
                    .frame(width: 36, height: 36)
                    .background(theme.error.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.error)
                    Text(subtitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(theme.error.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                    .strokeBorder(theme.error.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.98)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(0.1 + Double(index) * 0.05), value: appeared)
    }
}
