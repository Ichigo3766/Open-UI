import SwiftUI

/// Server configuration management view for viewing and editing server settings.
struct ServerManagementView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var editingURL: String = ""
    @State private var editingName: String = ""
    @State private var editingSelfSigned: Bool = false
    @State private var editingHeaderEntries: [CustomHeaderEntry] = []
    @State private var isEditing: Bool = false
    @State private var showDeleteConfirmation = false
    @State private var serverHealthy: Bool?
    @State private var isCheckingHealth: Bool = false
    @State private var refreshedConfig: BackendConfig?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // Connection status
                connectionStatusSection

                // Server details
                SettingsSection(header: "Server Details") {
                    detailRow(icon: "globe", label: "URL", value: activeServer?.url ?? "—")
                    detailRow(icon: "tag", label: "Name", value: displayedConfig?.name ?? activeServer?.name ?? "—")
                    if let version = displayedConfig?.version ?? viewModel.serverVersion {
                        detailRow(icon: "number", label: "Version", value: version)
                    }
                    detailRow(
                        icon: "lock.shield",
                        label: "Self-Signed Certs",
                        value: activeServer?.allowSelfSignedCertificates == true ? "Allowed" : "Not Allowed",
                        showDivider: false
                    )
                }

                // Actions
                SettingsSection(header: "Actions") {
                    SettingsCell(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Check Connection",
                        subtitle: isCheckingHealth ? "Checking..." : nil,
                        accessory: isCheckingHealth ? .none : .chevron
                    ) {
                        Task { await checkHealth() }
                    }

                    SettingsCell(
                        icon: "pencil",
                        title: "Edit Server",
                        showDivider: false,
                        accessory: .chevron
                    ) {
                        startEditing()
                    }
                }

                // Danger zone
                SettingsSection(header: "Danger Zone") {
                    DestructiveSettingsCell(
                        icon: "trash",
                        title: "Remove Server"
                    ) {
                        showDeleteConfirmation = true
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await checkHealth()
        }
        .sheet(isPresented: $isEditing) {
            editServerSheet
        }
        .confirmationDialog(
            "Remove Server",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove & Sign Out", role: .destructive) {
                Task { await viewModel.signOutAndDisconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will sign you out and remove the server configuration.")
        }
    }

    // MARK: - Active Server

    @Environment(AppDependencyContainer.self) private var dependencies

    private var activeServer: ServerConfig? {
        dependencies.serverConfigStore.activeServer
    }

    /// The most up-to-date backend config: prefer what we refreshed during health check,
    /// fall back to what the view model already has.
    private var displayedConfig: BackendConfig? {
        refreshedConfig ?? viewModel.backendConfig
    }

    // MARK: - Connection Status

    private var connectionStatusSection: some View {
        SettingsSection {
            HStack(spacing: Spacing.md) {
                serverLogoView
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.divider, lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(statusTitle)
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)

                    Text(statusSubtitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            .padding(Spacing.md)
        }
    }

    @ViewBuilder
    private var serverLogoView: some View {
        if let urlString = activeServer?.url,
           let faviconURL = URL(string: "\(urlString)/favicon.ico") {
            CachedAsyncImage(url: faviconURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .background(Color.white)
            } placeholder: {
                fallbackServerIcon
            }
        } else {
            fallbackServerIcon
        }
    }

    private var fallbackServerIcon: some View {
        Image(systemName: "server.rack")
            .scaledFont(size: 20, weight: .medium)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surfaceContainer)
    }

    private var statusColor: Color {
        switch serverHealthy {
        case .some(true): return theme.success
        case .some(false): return theme.error
        case .none: return theme.textTertiary
        }
    }

    private var statusTitle: String {
        if isCheckingHealth { return "Checking…" }
        switch serverHealthy {
        case .some(true): return "Connected"
        case .some(false): return "Connection Issue"
        case .none: return "Unknown"
        }
    }

    private var statusSubtitle: String {
        activeServer?.url ?? "No server configured"
    }

    // MARK: - Health Check

    private func checkHealth() async {
        guard let config = activeServer else { return }
        isCheckingHealth = true
        let client = APIClient(serverConfig: config)
        // Re-use the existing auth token so the request is authenticated
        if let token = dependencies.apiClient?.network.authToken {
            client.updateAuthToken(token)
        }
        async let healthTask = client.checkHealth()
        async let configTask: BackendConfig? = try? await client.getBackendConfig()
        let (healthy, freshConfig) = await (healthTask, configTask)
        serverHealthy = healthy
        if let fresh = freshConfig {
            refreshedConfig = fresh
            // Keep the view model in sync too
            viewModel.backendConfig = fresh
        }
        isCheckingHealth = false
    }

    // MARK: - Detail Row

    private func detailRow(
        icon: String,
        label: String,
        value: String,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: IconSize.lg)

                Text(label)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Text(value)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md + IconSize.lg + Spacing.md)
            }
        }
    }

    // MARK: - Edit Sheet

    private func startEditing() {
        editingURL = activeServer?.url ?? ""
        editingName = activeServer?.name ?? ""
        editingSelfSigned = activeServer?.allowSelfSignedCertificates ?? false
        // Convert persisted [String:String] dict back to editable entries.
        // Skip system-managed headers (User-Agent set by CF/proxy flows).
        let systemKeys: Set<String> = ["User-Agent"]
        editingHeaderEntries = (activeServer?.customHeaders ?? [:])
            .filter { !systemKeys.contains($0.key) }
            .map { CustomHeaderEntry(id: UUID().uuidString, key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        isEditing = true
    }

    private var editServerSheet: some View {
        NavigationStack {
            Form {
                Section("Server URL") {
                    TextField("https://your-server.com", text: $editingURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Display Name") {
                    TextField("My Server", text: $editingName)
                }

                Section("Security") {
                    Toggle("Allow Self-Signed Certificates", isOn: $editingSelfSigned)
                }

                Section {
                    CustomHeadersEditor(entries: $editingHeaderEntries)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Custom Headers")
                } footer: {
                    Text("HTTP headers sent with every request to this server. Useful for reverse proxies or services that require extra authentication headers.")
                        .font(.caption)
                }
            }
            .navigationTitle("Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isEditing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEdits()
                        isEditing = false
                    }
                    .disabled(editingURL.isEmpty)
                }
            }
        }
    }

    private func saveEdits() {
        guard var config = activeServer else { return }
        config.url = editingURL
        config.name = editingName
        config.allowSelfSignedCertificates = editingSelfSigned

        // Merge user-edited headers back in. Preserve system-managed headers
        // (CF User-Agent etc.) that were stripped out of the editing UI.
        let systemKeys: Set<String> = ["User-Agent"]
        var updatedHeaders: [String: String] = config.customHeaders.filter { systemKeys.contains($0.key) }
        for entry in editingHeaderEntries {
            let trimmedKey = entry.key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty else { continue }
            updatedHeaders[trimmedKey] = entry.value
        }
        config.customHeaders = updatedHeaders

        dependencies.serverConfigStore.updateServer(config)
        dependencies.refreshServices()
    }
}
