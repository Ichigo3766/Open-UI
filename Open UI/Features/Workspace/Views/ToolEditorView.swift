import SwiftUI

// MARK: - Valves Sheet

/// Dynamic form for configuring a tool's user-facing valves.
/// Fetches the JSON schema (spec) and current values from the server, renders
/// a field per property, and saves back via the update endpoint.
struct ValvesSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let toolId: String

    @State private var spec: [String: Any] = [:]       // JSON Schema object
    @State private var values: [String: Any] = [:]     // current saved values
    @State private var editValues: [String: String] = [:] // text field state
    /// Keys the user has explicitly toggled to "Default" — sent as NSNull() to clear the override.
    @State private var defaultKeys: Set<String> = []
    /// Property keys in server-preserved insertion order (parsed from raw JSON bytes).
    @State private var specKeyOrder: [String]? = nil
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var manager: ToolsManager? { dependencies.toolsManager }

    // Ordered property keys from spec — use server-preserved insertion order when available
    private var propertyKeys: [String] {
        guard let props = spec["properties"] as? [String: Any] else { return [] }
        // Prefer explicit "order" array (server may include it)
        if let order = spec["order"] as? [String] {
            return order.filter { props[$0] != nil }
        }
        // Fall back to the order we captured from raw JSON bytes
        if let orderedKeys = specKeyOrder, !orderedKeys.isEmpty {
            let keySet = Set(props.keys)
            let ordered = orderedKeys.filter { keySet.contains($0) }
            if !ordered.isEmpty { return ordered }
        }
        return props.keys.sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: Spacing.lg) {
                        Spacer()
                        ProgressView().controlSize(.large).tint(theme.brandPrimary)
                        Text("Loading valves…")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                } else if propertyKeys.isEmpty {
                    VStack(spacing: Spacing.lg) {
                        Spacer()
                        Image(systemName: "slider.horizontal.3")
                            .scaledFont(size: 44)
                            .foregroundStyle(theme.textTertiary)
                        Text("No Valves")
                            .scaledFont(size: 18, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("This tool has no user-configurable settings.")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.xl)
                        Spacer()
                    }
                } else {
                    valvesForm
                }
            }
            .background(theme.background)
            .navigationTitle("Valves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView().tint(theme.brandPrimary)
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .disabled(propertyKeys.isEmpty)
                    }
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task { await loadValves() }
        .presentationBackground(theme.background)
    }

    // MARK: - Valves Form

    private var valvesForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                let props = spec["properties"] as? [String: Any] ?? [:]

                // Description from spec
                if let desc = spec["description"] as? String, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, Spacing.md)
                }

                VStack(spacing: 0) {
                    ForEach(propertyKeys, id: \.self) { key in
                        let propSchema = props[key] as? [String: Any] ?? [:]
                        valveField(key: key, schema: propSchema)

                        if key != propertyKeys.last {
                            Divider()
                                .background(theme.inputBorder.opacity(0.3))
                                .padding(.leading, Spacing.md)
                        }
                    }
                }
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, Spacing.md)
            }
            .padding(.vertical, Spacing.md)
        }
    }

    @ViewBuilder
    private func valveField(key: String, schema: [String: Any]) -> some View {
        let title = schema["title"] as? String ?? key
        let description = schema["description"] as? String
        let type = schema["type"] as? String ?? "string"
        let currentText = editValues[key] ?? ""

        // "Default" if this key has no server override (or user toggled it back)
        let isDefault = defaultKeys.contains(key)
        // "Custom" whenever it is NOT in defaultKeys
        let isCustom = !isDefault

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(isDefault ? theme.textTertiary : theme.textPrimary)
                Spacer()
                // Tappable badge: always tappable to toggle Default ↔ Custom
                Button {
                    Haptics.play(.light)
                    if isDefault {
                        // Switch to Custom — editValues already has spec default seeded
                        defaultKeys.remove(key)
                        // If server had a value, restore it; otherwise keep the spec default
                        if let v = values[key] { editValues[key] = "\(v)" }
                    } else {
                        // Switch back to Default — hide input, will clear on save if server had a value
                        defaultKeys.insert(key)
                    }
                } label: {
                    HStack(spacing: 3) {
                        if isCustom {
                            Image(systemName: "xmark")
                                .scaledFont(size: 9, weight: .bold)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        Text(isDefault ? "Default" : "Custom")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(isCustom ? theme.brandPrimary : theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isCustom
                            ? theme.brandPrimary.opacity(0.12)
                            : theme.surfaceContainerHighest.opacity(0.6)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 12)

            if let desc = description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 3)
            }

            // Input — only shown when Custom (hidden entirely when Default)
            if !isDefault {
                if type == "boolean" {
                    HStack {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { currentText == "true" || currentText == "1" },
                            set: { editValues[key] = $0 ? "true" : "false" }
                        ))
                        .tint(theme.brandPrimary)
                        .labelsHidden()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                } else {
                    TextEditor(text: Binding(
                        get: { editValues[key] ?? "" },
                        set: { editValues[key] = $0 }
                    ))
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 50, maxHeight: 120)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.inputBorder.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                    .keyboardType(type == "integer" ? .numberPad : .default)
                    .autocorrectionDisabled()
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Load

    private func loadValves() async {
        guard !toolId.isEmpty, let manager else { isLoading = false; return }
        isLoading = true
        do {
            // Fetch spec first (required) — also captures insertion-order of keys
            let (fetchedSpec, keyOrder) = try await manager.getValvesSpecWithOrder(id: toolId)
            spec = fetchedSpec
            specKeyOrder = keyOrder.isEmpty ? nil : keyOrder

            // Fetch current user values independently — empty dict means no overrides.
            let fetchedValues = (try? await manager.getValves(id: toolId)) ?? [:]
            values = fetchedValues

            // Seed edit fields from spec defaults + any server-stored overrides.
            // /valves ONLY returns keys the user has explicitly overridden.
            // So: if key is in fetchedValues → Custom; otherwise → Default (use spec default).
            let props = fetchedSpec["properties"] as? [String: Any] ?? [:]
            for key in props.keys {
                let propSchema = props[key] as? [String: Any] ?? [:]
                if let v = fetchedValues[key] {
                    // Server has an override for this key — show it as Custom
                    editValues[key] = "\(v)"
                } else {
                    // No server override → seed spec default, mark as Default
                    defaultKeys.insert(key)
                    if let defVal = propSchema["default"] {
                        editValues[key] = "\(defVal)"
                    } else {
                        editValues[key] = ""
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        // Build payload with three rules:
        //   1. Key was previously custom on server AND user toggled it to Default
        //      → send NSNull() to clear the server override
        //   2. Key was already default (no server override) AND user left it as Default
        //      → skip entirely (don't send anything)
        //   3. Key is not in defaultKeys (user has a custom value set)
        //      → send the coerced value
        var payload: [String: Any] = [:]
        let props = spec["properties"] as? [String: Any] ?? [:]
        for key in propertyKeys {
            if defaultKeys.contains(key) {
                if values[key] != nil {
                    // Was custom on server, user reset it → send null to clear
                    payload[key] = NSNull()
                }
                // Was already default → skip (don't touch the server value)
                continue
            }
            // User has set a custom value — coerce and send
            let propSchema = props[key] as? [String: Any] ?? [:]
            let type = propSchema["type"] as? String ?? "string"
            let raw = editValues[key] ?? ""
            switch type {
            case "integer":
                payload[key] = Int(raw) ?? 0
            case "number":
                payload[key] = Double(raw) ?? 0.0
            case "boolean":
                payload[key] = raw == "true" || raw == "1"
            default:
                payload[key] = raw
            }
        }
        // Only make the network call if there's actually something to update
        guard !payload.isEmpty else {
            dismiss()
            isSaving = false
            return
        }
        do {
            _ = try await manager.updateValves(id: toolId, values: payload)
            Haptics.notify(.success)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.notify(.error)
        }
        isSaving = false
    }
}

// MARK: - ToolEditorView

/// Sheet for creating or editing a Tool.
/// Mirrors SkillEditorView in structure; key differences:
///  - No is_active toggle
///  - Content is Python code (not Markdown)
///  - Has ValvesSheet for configuring user valves
///  - Name/ID/description + Manifest section
struct ToolEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    // MARK: - Input

    var existingTool: ToolDetail?
    var prefillDetail: ToolDetail?   // pre-populated from URL import
    var onSave: ((ToolDetail) -> Void)?

    // MARK: - Form State

    @State private var toolId = ""              // slug / API id
    @State private var name = ""
    @State private var description = ""
    @State private var content = ""             // Python code
    @State private var manifestTitle = ""
    @State private var manifestAuthor = ""
    @State private var manifestVersion = ""
    @State private var manifestLicense = ""
    @State private var manifestRequirements = ""

    // Access control
    @State private var isPrivate: Bool = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var showUserPicker = false
    @State private var isUpdatingAccess = false
    @State private var accessUpdateError: String?

    // UI
    @State private var isSaving = false
    @State private var validationError: String? = nil
    @State private var idManuallyEdited = false
    @State private var isContentExpanded = false
    @State private var isAutoSettingId = false
    @State private var showDiscardConfirm = false
    @State private var showManifestSection = false

    @FocusState private var focusedField: Field?
    private enum Field { case name, toolId, description, content }

    private var manager: ToolsManager? { dependencies.toolsManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }
    private var isEditing: Bool { existingTool != nil }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    private var accessedUsers: [ChannelMember] {
        let ids = Set(localAccessGrants.compactMap { $0.userId })
        return allUsers.filter { ids.contains($0.id) }
    }

    private var hasChanges: Bool {
        guard let existing = existingTool else {
            return !name.isEmpty || !toolId.isEmpty || !content.isEmpty
        }
        let grantIds = Set(localAccessGrants.compactMap { $0.userId })
        let existingIds = Set(existing.accessGrants.compactMap { $0.userId })
        return name != existing.name
            || toolId != existing.id
            || description != existing.description
            || content != existing.content
            || grantIds != existingIds
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    basicInfoSection
                    codeSection
                    manifestSection
                    settingsSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Tool" : "New Tool")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showUserPicker) {
                WorkspaceAddAccessSheet(
                    existingUserIds: Set(localAccessGrants.compactMap { $0.userId }),
                    allUsers: allUsers,
                    isLoading: isUpdatingAccess,
                    serverBaseURL: serverBaseURL,
                    authToken: authToken,
                    onAdd: { selectedIds in
                        showUserPicker = false
                        Task { await addUsers(selectedIds) }
                    },
                    onCancel: { showUserPicker = false }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Discard Changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your unsaved changes will be lost.")
            }
            .alert("Validation Error", isPresented: .init(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError ?? "")
            }
            .alert("Access Error", isPresented: .init(
                get: { accessUpdateError != nil },
                set: { if !$0 { accessUpdateError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accessUpdateError ?? "")
            }
        }
        .onAppear {
            populateFields()
            Task { await manager?.fetchAllUsers() }
        }
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Tool Info")
            fieldCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. Weather Tool", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                if !idManuallyEdited {
                                    isAutoSettingId = true
                                    toolId = generateId(from: newValue)
                                    isAutoSettingId = false
                                }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("ID")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. weather_tool", text: $toolId)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .toolId)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .onChange(of: toolId) { _, _ in
                                if !isAutoSettingId { idManuallyEdited = true }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("Short description", text: $description)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .description)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, Spacing.md)
            }
        }
    }

    // MARK: - Code Section

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Python Code")
                Spacer()
                Button {
                    Haptics.play(.light)
                    isContentExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(6)
                        .background(theme.surfaceContainer.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text("Write Python code defining the tool's functions. The class must inherit from `Tools`.")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textTertiary)
            fieldCard {
                TextEditor(text: $content)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 220, maxHeight: 440)
                    .focused($focusedField, equals: .content)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
                    .fontDesign(.monospaced)
            }
        }
        .sheet(isPresented: $isContentExpanded) {
            FullscreenContentEditor(
                title: "Python Code",
                placeholder: "# Write your Python tool code here…\n\nclass Tools:\n    def __init__(self):\n        pass\n",
                content: $content
            )
        }
    }

    // MARK: - Manifest Section

    private var manifestSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showManifestSection.toggle()
                }
            } label: {
                HStack {
                    sectionHeader("Manifest (Optional)")
                    Spacer()
                    Image(systemName: showManifestSection ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if showManifestSection {
                fieldCard {
                    VStack(spacing: 0) {
                        manifestRow(label: "Title", placeholder: "Tool display title", text: $manifestTitle)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "Author", placeholder: "Author name", text: $manifestAuthor)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "Version", placeholder: "e.g. 1.0.0", text: $manifestVersion)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "License", placeholder: "e.g. MIT", text: $manifestLicense)
                        Divider().background(theme.inputBorder.opacity(0.4))
                        manifestRow(label: "Requirements", placeholder: "pip packages, comma-separated", text: $manifestRequirements)
                    }
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
    }

    @ViewBuilder
    private func manifestRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            TextField(placeholder, text: text)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
                .autocapitalization(.none)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Settings Section (Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                accessControlSection
            }
        }
    }

    // MARK: - Access Control Section

    @ViewBuilder
    private var accessControlSection: some View {
        VStack(spacing: 0) {
            // Visibility Picker row
            HStack(spacing: Spacing.sm) {
                Image(systemName: isPrivate ? "lock.fill" : "globe")
                    .scaledFont(size: 16)
                    .foregroundStyle(isPrivate ? theme.textSecondary : theme.brandPrimary)
                    .frame(width: 20)

                Text("Access")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                if isUpdatingAccess {
                    ProgressView().controlSize(.mini).tint(theme.brandPrimary)
                        .padding(.trailing, 4)
                }

                Picker("", selection: $isPrivate) {
                    Text("Private").tag(true)
                    Text("Public").tag(false)
                }
                .pickerStyle(.menu)
                .tint(theme.brandPrimary)
                .scaledFont(size: 15)
                .onChange(of: isPrivate) { _, newVal in
                    Task { await handleAccessModeChange(isPrivate: newVal) }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)

            Divider().background(theme.inputBorder.opacity(0.4))

            accessListSection
        }
    }

    @ViewBuilder
    private var accessListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Access List")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if localAccessGrants.isEmpty {
                Text("No access grants. Private to you.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 10)
            } else {
                ForEach(accessedUsers) { user in
                    accessUserRow(user)
                    Divider()
                        .background(theme.inputBorder.opacity(0.3))
                        .padding(.leading, Spacing.md + 42)
                }
            }

            Button {
                Haptics.play(.light)
                showUserPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("Add Access")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.brandPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func accessUserRow(_ user: ChannelMember) -> some View {
        HStack(spacing: Spacing.sm) {
            UserAvatar(
                size: 30,
                imageURL: user.resolveAvatarURL(serverBaseURL: serverBaseURL),
                name: user.displayName,
                authToken: authToken
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                if let role = user.role {
                    Text(role.capitalized)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()

            if let grant = localAccessGrants.first(where: { $0.userId == user.id }) {
                Button {
                    Task { await toggleUserPermission(userId: user.id, currentlyWrite: grant.write) }
                } label: {
                    Text(grant.write ? "WRITE" : "READ")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(grant.write ? theme.brandOnPrimary : theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(grant.write ? theme.brandPrimary : theme.surfaceContainerHighest)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(grant.write ? Color.clear : theme.inputBorder.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isUpdatingAccess)
            }

            Button {
                Task { await removeUser(user.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isUpdatingAccess)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
                if hasChanges { showDiscardConfirm = true } else { dismiss() }
            }
            .scaledFont(size: 16)
            .foregroundStyle(theme.textSecondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(theme.brandPrimary)
            } else {
                Button("Save") {
                    Task { await save() }
                }
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || toolId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Access Control Actions

    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existingTool?.id, let manager else { return }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(toolId: id, grants: localAccessGrants, isPublic: !isPrivate)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            self.isPrivate = !isPrivate
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func addUsers(_ userIds: [String]) async {
        guard let id = existingTool?.id, let manager else {
            for userId in userIds {
                if !localAccessGrants.contains(where: { $0.userId == userId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
                }
            }
            Haptics.notify(.success)
            return
        }
        isUpdatingAccess = true
        var newGrants = localAccessGrants
        for userId in userIds {
            if !newGrants.contains(where: { $0.userId == userId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
            }
        }
        do {
            let updated = try await manager.updateAccessGrants(toolId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func toggleUserPermission(userId: String, currentlyWrite: Bool) async {
        guard let idx = localAccessGrants.firstIndex(where: { $0.userId == userId }) else { return }
        let existing = localAccessGrants[idx]
        let newGrant = AccessGrant(id: existing.id, userId: existing.userId, groupId: existing.groupId, read: true, write: !currentlyWrite)
        var newGrants = localAccessGrants
        newGrants[idx] = newGrant

        guard let id = existingTool?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(toolId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeUser(_ userId: String) async {
        guard let id = existingTool?.id, let manager else {
            localAccessGrants.removeAll { $0.userId == userId }
            Haptics.play(.light)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            localAccessGrants.removeAll { $0.userId == userId }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(toolId: id, grants: localAccessGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            if let detail = try? await manager.getDetail(id: id) {
                localAccessGrants = detail.accessGrants.filter { $0.userId != "*" }
            }
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }

    private func populateFields() {
        // Prefer prefill (URL import) over existing (edit mode)
        let source = existingTool ?? prefillDetail
        guard let tool = source else { return }

        name = tool.name
        toolId = tool.id
        description = tool.description
        content = tool.content
        manifestTitle = tool.manifest.title
        manifestAuthor = tool.manifest.author
        manifestVersion = tool.manifest.version
        manifestLicense = tool.manifest.license
        manifestRequirements = tool.manifest.requirements

        let hasWildcard = tool.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = tool.accessGrants.filter { $0.userId != "*" }
        isPrivate = !hasWildcard
        idManuallyEdited = true  // Never auto-generate ID when editing or pre-filling

        // Show manifest section if any manifest fields are filled
        if !manifestTitle.isEmpty || !manifestAuthor.isEmpty || !manifestVersion.isEmpty {
            showManifestSection = true
        }
    }

    private func generateId(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedId = toolId.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the tool."
            isSaving = false
            return
        }
        guard !trimmedId.isEmpty else {
            validationError = "Please enter an ID for the tool."
            isSaving = false
            return
        }

        var allGrants = localAccessGrants.filter { $0.userId != "*" }
        if !isPrivate {
            allGrants.append(AccessGrant(id: UUID().uuidString, userId: "*", groupId: nil, read: true, write: false))
        }

        let manifest = ToolManifest(
            title: manifestTitle,
            author: manifestAuthor,
            version: manifestVersion,
            license: manifestLicense,
            requirements: manifestRequirements
        )

        do {
            if let existing = existingTool {
                let detail = ToolDetail(
                    id: trimmedId,
                    name: trimmedName,
                    content: content,
                    description: description,
                    manifest: manifest,
                    specs: existing.specs,
                    hasUserValves: existing.hasUserValves,
                    accessGrants: allGrants,
                    userId: existing.userId,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt
                )
                var updated = try await manager.updateTool(detail)

                // Update access grants via dedicated endpoint
                let updatedGrants = try await manager.updateAccessGrants(
                    toolId: trimmedId,
                    grants: localAccessGrants.filter { $0.userId != "*" },
                    isPublic: !isPrivate
                )
                updated.accessGrants = updatedGrants

                onSave?(updated)
            } else {
                let detail = ToolDetail(
                    id: trimmedId,
                    name: trimmedName,
                    content: content,
                    description: description,
                    manifest: manifest,
                    accessGrants: allGrants
                )
                let created = try await manager.createTool(from: detail)
                onSave?(created)
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
        isSaving = false
    }
}
