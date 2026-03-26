import SwiftUI

// MARK: - Prompt Editor View

/// Create or edit a prompt.
/// - `existing` nil  → create mode
/// - `existing` non-nil → edit mode
struct PromptEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let existing: PromptDetail?
    let onSave: (PromptDetail, String?) -> Void

    // MARK: Form state
    @State private var name: String = ""
    @State private var command: String = ""
    @State private var content: String = ""
    @State private var tags: [String] = []
    @State private var isActive: Bool = true
    /// isPrivate: true = Private (restricted to access list), false = Public (everyone)
    /// Default is always true (Private). Grants can exist within Private mode.
    @State private var isPrivate: Bool = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var commitMessage: String = ""

    // MARK: Access picker state
    @State private var showUserPicker: Bool = false
    @State private var isUpdatingAccess: Bool = false
    @State private var accessUpdateError: String?

    // MARK: UI state
    @State private var newTag: String = ""
    @State private var showTagSuggestions: Bool = false
    @State private var isSaving: Bool = false
    @State private var isTogglingActive: Bool = false
    @State private var validationError: String?
    @State private var showHistory: Bool = false
    @State private var historyVersions: [PromptVersion] = []
    @State private var loadingHistory: Bool = false
    @State private var historyError: String?
    /// The version_id from the prompt detail — identifies which history entry is currently live.
    @State private var currentVersionId: String?
    @State private var showDiscardConfirm: Bool = false
    /// Tracks the isActive value at population time so onChange doesn't fire on initial load.
    @State private var initialIsActive: Bool = true
    @State private var isContentExpanded: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, command, content, newTag, commitMessage }

    private var isEditMode: Bool { existing != nil }
    private var manager: PromptManager? { dependencies.promptManager }
    private var allTags: [String] { manager?.allTags ?? [] }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }

    private var filteredTagSuggestions: [String] {
        guard !newTag.isEmpty else { return allTags.filter { !tags.contains($0) } }
        return allTags.filter { $0.lowercased().contains(newTag.lowercased()) && !tags.contains($0) }
    }

    /// Users who currently have access, resolved from allUsers for display names.
    private var accessedUsers: [ChannelMember] {
        let ids = Set(localAccessGrants.compactMap { $0.userId })
        return allUsers.filter { ids.contains($0.id) }
    }

    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    private var hasChanges: Bool {
        guard let existing else {
            return !name.isEmpty || !command.isEmpty || !content.isEmpty || !tags.isEmpty
        }
        let grantIds = Set(localAccessGrants.compactMap { $0.userId })
        let existingIds = Set(existing.accessGrants.compactMap { $0.userId })
        return name != existing.name
            || command != existing.command
            || content != existing.content
            || tags != existing.tags
            || isActive != existing.isActive
            || grantIds != existingIds
            || !commitMessage.isEmpty
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    basicInfoSection
                    contentSection
                    settingsSection
                    commitSection
                    if isEditMode {
                        historyButton
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditMode ? "Edit Prompt" : "New Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showHistory) {
                PromptHistoryView(
                    promptId: existing?.id,
                    versions: historyVersions,
                    isLoading: loadingHistory,
                    currentVersionId: currentVersionId,
                    manager: manager
                )
            }
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
            populateFromExisting()
            Task { await manager?.fetchAllUsers() }
        }
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Basic Info")
            fieldCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 72, alignment: .leading)
                        TextField("e.g. Summarize Text", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("Command")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 72, alignment: .leading)
                        HStack(spacing: 2) {
                            Text("/")
                                .scaledFont(size: 15, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                            TextField("summarize", text: $command)
                                .scaledFont(size: 15)
                                .foregroundStyle(theme.textPrimary)
                                .focused($focusedField, equals: .command)
                                .autocorrectionDisabled()
                                .autocapitalization(.none)
                                .onChange(of: command) { _, new in
                                    if new.hasPrefix("/") { command = String(new.dropFirst()) }
                                    command = command.replacingOccurrences(of: " ", with: "")
                                }
                        }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Tags row — inline inside Basic Info card
                    tagsRow
                        .padding(.vertical, 10)
                }
                .padding(.horizontal, Spacing.md)
            }
        }
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Content")
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
            Text("Use {{variable}} placeholders for user input.")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textTertiary)
            fieldCard {
                TextEditor(text: $content)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 160, maxHeight: 320)
                    .focused($focusedField, equals: .content)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
            }
        }
        .sheet(isPresented: $isContentExpanded) {
            FullscreenContentEditor(
                title: "Content",
                placeholder: "Write prompt content here…",
                content: $content
            )
        }
    }

    /// Inline tags row rendered inside the Basic Info card.
    @ViewBuilder
    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Existing tag chips
            if !tags.isEmpty {
                PromptFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        tagChip(tag)
                    }
                }
                .padding(.bottom, 4)
            }
            // Input row
            HStack(spacing: Spacing.xs) {
                Image(systemName: "tag")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                TextField("Add tag…", text: $newTag)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .focused($focusedField, equals: .newTag)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .onChange(of: newTag) { _, _ in
                        showTagSuggestions = !newTag.isEmpty || focusedField == .newTag
                    }
                    .onSubmit { addCurrentTag() }
                if !newTag.isEmpty {
                    Button { addCurrentTag() } label: {
                        Image(systemName: "return")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.brandPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Suggestion chips
            if showTagSuggestions && !filteredTagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filteredTagSuggestions.prefix(10), id: \.self) { suggestion in
                            Button {
                                tags.append(suggestion)
                                newTag = ""
                                Haptics.play(.light)
                            } label: {
                                Text(suggestion)
                                    .scaledFont(size: 13)
                                    .foregroundStyle(theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(theme.surfaceContainer.opacity(0.8))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .onChange(of: focusedField) { _, newField in
            showTagSuggestions = newField == .newTag
        }
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                VStack(spacing: 0) {
                    // Active toggle — in edit mode, call the dedicated toggle endpoint immediately.
                    Toggle(isOn: $isActive) {
                        HStack(spacing: Spacing.sm) {
                            if isTogglingActive {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Inactive prompts won't appear in the chat picker.")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .tint(theme.brandPrimary)
                    .disabled(isTogglingActive)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .onChange(of: isActive) { oldVal, newVal in
                        // In edit mode, call the toggle endpoint immediately.
                        // Guard against the initial population firing this.
                        guard isEditMode, newVal != initialIsActive else { return }
                        initialIsActive = newVal
                        Task { await persistActiveToggle(id: existing?.id) }
                    }

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Access Control Picker
                    accessControlSection
                }
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
            // Header
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

            // Add Access button
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

            // READ / WRITE permission toggle button
            if let grant = localAccessGrants.first(where: { $0.userId == user.id }) {
                Button {
                    Task { await toggleUserPermission(userId: user.id, currentlyWrite: grant.write) }
                } label: {
                    Text(grant.write ? "WRITE" : "READ")
                        .scaledFont(size: 11, weight: .semibold)
                        // WRITE: accent-colored pill (brandOnPrimary text on brandPrimary bg)
                        // READ:  subtle surface pill (textSecondary text on surfaceContainerHighest bg)
                        .foregroundStyle(grant.write ? theme.brandOnPrimary : theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(grant.write ? theme.brandPrimary : theme.surfaceContainerHighest)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(grant.write ? Color.clear : theme.inputBorder.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isUpdatingAccess)
            }

            // Remove button
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

    private var commitSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Version Note")
            fieldCard {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                    TextField("Optional: describe what changed…", text: $commitMessage)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textPrimary)
                        .focused($focusedField, equals: .commitMessage)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 12)
            }
        }
    }

    private var historyButton: some View {
        Button {
            Haptics.play(.light)
            showHistory = true
            Task { await loadHistory() }
        } label: {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
                Text("View Version History")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 14)
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
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
                Button("Save") { save() }
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Access Control Actions

    /// Called when user switches between Private / Public.
    /// Immediately calls the API to persist the change (edit mode only).
    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existing?.id, let manager else { return }
        let grantsToSend = localAccessGrants
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(promptId: id, grants: grantsToSend, isPublic: !isPrivate)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            // Revert on failure
            self.isPrivate = !isPrivate
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func addUsers(_ userIds: [String]) async {
        guard let id = existing?.id, let manager else {
            // In create mode, just add locally with read permission
            for userId in userIds {
                if !localAccessGrants.contains(where: { $0.userId == userId }) {
                    localAccessGrants.append(AccessGrant(
                        id: UUID().uuidString,
                        userId: userId,
                        groupId: nil,
                        read: true,
                        write: false
                    ))
                }
            }
            Haptics.notify(.success)
            return
        }

        isUpdatingAccess = true
        var newGrants = localAccessGrants
        for userId in userIds {
            if !newGrants.contains(where: { $0.userId == userId }) {
                newGrants.append(AccessGrant(
                    id: UUID().uuidString,
                    userId: userId,
                    groupId: nil,
                    read: true,
                    write: false
                ))
            }
        }
        do {
            let updated = try await manager.updateAccessGrants(promptId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    /// Toggles a user's permission between READ and WRITE.
    private func toggleUserPermission(userId: String, currentlyWrite: Bool) async {
        guard let idx = localAccessGrants.firstIndex(where: { $0.userId == userId }) else { return }
        let existing = localAccessGrants[idx]
        let newGrant = AccessGrant(
            id: existing.id,
            userId: existing.userId,
            groupId: existing.groupId,
            read: true,
            write: !currentlyWrite
        )
        var newGrants = localAccessGrants
        newGrants[idx] = newGrant

        guard let id = self.existing?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }

        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(promptId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeUser(_ userId: String) async {
        guard let id = existing?.id, let manager else {
            localAccessGrants.removeAll { $0.userId == userId }
            Haptics.play(.light)
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            localAccessGrants.removeAll { $0.userId == userId }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(promptId: id, grants: localAccessGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            // Restore on failure
            if let detail = try? await manager.getPromptDetail(id: id) {
                localAccessGrants = detail.accessGrants
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

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .scaledFont(size: 13)
                .foregroundStyle(theme.textSecondary)
            Button {
                tags.removeAll { $0 == tag }
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.surfaceContainer)
        .clipShape(Capsule())
    }

    private func addCurrentTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { newTag = ""; return }
        tags.append(trimmed)
        newTag = ""
        Haptics.play(.light)
    }

    /// Calls the dedicated toggle endpoint immediately when the user flips the Active switch.
    /// Reverts the local state on failure.
    private func persistActiveToggle(id: String?) async {
        guard let id, let manager else { return }
        isTogglingActive = true
        do {
            try await manager.togglePrompt(id: id)
            Haptics.play(.light)
        } catch {
            // Revert on failure
            isActive = !isActive
            initialIsActive = isActive
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isTogglingActive = false
    }

    private func populateFromExisting() {
        guard let existing else { return }
        name = existing.name
        command = existing.command
        content = existing.content
        tags = existing.tags
        isActive = existing.isActive
        initialIsActive = existing.isActive   // sync guard value so onChange doesn't fire on load
        // Strip the wildcard entry from the local list — it's represented by isPrivate = false
        let hasWildcard = existing.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = existing.accessGrants.filter { $0.userId != "*" }
        isPrivate = !hasWildcard
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the prompt."
            return
        }
        guard !trimmedCommand.isEmpty else {
            validationError = "Please enter a command (without the leading /)."
            return
        }
        isSaving = true
        Haptics.play(.medium)

        // For create mode, grants are in localAccessGrants.
        // For edit mode, grants are already persisted via dedicated /access/update calls.
        // toUpdatePayload() no longer sends access_grants to avoid creating version history.
        let grants = localAccessGrants
        let detail = PromptDetail(
            id: existing?.id ?? UUID().uuidString,
            command: trimmedCommand,
            name: trimmedName,
            content: content,
            isActive: isActive,
            tags: tags,
            accessGrants: grants,
            meta: existing?.meta ?? [:],
            userId: existing?.userId ?? "",
            createdAt: existing?.createdAt,
            updatedAt: Date()
        )
        let commit = commitMessage.trimmingCharacters(in: .whitespaces)
        onSave(detail, commit.isEmpty ? nil : commit)
        isSaving = false
        dismiss()
    }

    private func loadHistory() async {
        guard let id = existing?.id, let manager else { return }
        loadingHistory = true
        // Fetch history and prompt detail in parallel.
        // The prompt detail contains `version_id` — the ID of the currently live history entry.
        async let versionsTask = manager.getHistory(promptId: id)
        async let detailTask = manager.getPromptDetail(id: id)
        do {
            historyVersions = try await versionsTask
        } catch {
            historyVersions = []
        }
        currentVersionId = (try? await detailTask)?.versionId
        loadingHistory = false
    }
}

// MARK: - Prompt History View

private struct PromptHistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let promptId: String?
    let versions: [PromptVersion]
    let isLoading: Bool
    /// The `version_id` from the prompt detail — tells us which history entry is currently live.
    let currentVersionId: String?
    let manager: PromptManager?

    /// ID of the version currently being set as production (shows spinner on that row).
    @State private var settingProductionId: String?
    /// Local tracking of which version is live. Seeded from currentVersionId on appear,
    /// updated optimistically when "Set as Production" succeeds.
    @State private var liveVersionId: String?
    /// Inline error shown in a banner at the top of the sheet.
    @State private var setProductionError: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: Spacing.md) {
                        Spacer()
                        ProgressView().controlSize(.large).tint(theme.brandPrimary)
                        Text("Loading history…").scaledFont(size: 15).foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                } else if versions.isEmpty {
                    VStack(spacing: Spacing.lg) {
                        Spacer()
                        Image(systemName: "clock.arrow.circlepath")
                            .scaledFont(size: 44).foregroundStyle(theme.textTertiary)
                        Text("No History")
                            .scaledFont(size: 18, weight: .semibold).foregroundStyle(theme.textPrimary)
                        Text("Version history will appear here after you save changes with a version note.")
                            .scaledFont(size: 14).foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center).padding(.horizontal, Spacing.xl)
                        Spacer()
                    }
                } else {
                    List {
                        // Inline error banner
                        if let err = setProductionError {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(err)
                                    .scaledFont(size: 13)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Button { setProductionError = nil } label: {
                                    Image(systemName: "xmark").scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(Spacing.sm)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .listRowBackground(theme.background)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(versions) { version in
                            versionRow(version)
                                .listRowBackground(theme.background)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(theme.background)
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .scaledFont(size: 16).foregroundStyle(theme.brandPrimary)
                }
            }
        }
    }

    /// Returns true if this version is currently the live/production version.
    /// `liveVersionId` is only set as an optimistic override after "Set as Production" succeeds.
    /// Otherwise, we fall back to `currentVersionId` (the authoritative value from the prompt detail),
    /// which SwiftUI updates reactively whenever the parent re-renders with a new value.
    /// This avoids the race condition where `.onAppear` fires before `loadHistory()` completes.
    private func isLive(_ version: PromptVersion) -> Bool {
        if let override = liveVersionId { return version.id == override }
        return version.id == currentVersionId
    }

    @ViewBuilder
    private func versionRow(_ version: PromptVersion) -> some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Top row: LIVE badge + hash + date ────────────────────────────
            HStack(spacing: 6) {
                if isLive(version) {
                    Label("LIVE", systemImage: "checkmark.circle.fill")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(theme.brandPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
                if let hash = version.displayHash {
                    Text(hash)
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(theme.surfaceContainerHighest.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
                if let date = version.createdAt {
                    Text(Self.dateFormatter.string(from: date))
                        .scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                }
            }

            // ── Name / Command ────────────────────────────────────────────────
            if !version.name.isEmpty || !version.command.isEmpty {
                HStack(spacing: 4) {
                    if !version.name.isEmpty {
                        Text(version.name)
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                    }
                    if !version.command.isEmpty {
                        Text("/\(version.command)")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
            }

            // ── Commit message ────────────────────────────────────────────────
            if let msg = version.commitMessage, !msg.isEmpty {
                Text(msg)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }

            // ── Content preview ───────────────────────────────────────────────
            if !version.content.isEmpty {
                Text(version.content)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }

            // ── Set as Production button ──────────────────────────────────────
            if !isLive(version), let pid = promptId {
                let isSettingThis = settingProductionId == version.id
                Button {
                    guard !isSettingThis else { return }
                    Haptics.play(.medium)
                    Task { await setProduction(promptId: pid, version: version) }
                } label: {
                    HStack(spacing: 5) {
                        if isSettingThis {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .scaledFont(size: 13)
                        }
                        Text(isSettingThis ? "Setting…" : "Set as Production")
                            .scaledFont(size: 13, weight: .semibold)
                    }
                    .foregroundStyle(isSettingThis ? theme.textSecondary : theme.brandPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        isSettingThis
                            ? theme.surfaceContainerHighest.opacity(0.5)
                            : theme.brandPrimary.opacity(0.10)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(settingProductionId != nil)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 2)
    }

    private func setProduction(promptId: String, version: PromptVersion) async {
        guard let manager else { return }
        settingProductionId = version.id
        setProductionError = nil
        // Optimistic UI: mark this version as live immediately
        liveVersionId = version.id
        do {
            try await manager.setProductionVersion(promptId: promptId, versionId: version.id)
            Haptics.notify(.success)
        } catch {
            // Revert on failure
            liveVersionId = versions.first(where: { $0.isLive })?.id
            setProductionError = error.localizedDescription
            Haptics.notify(.error)
        }
        settingProductionId = nil
    }
}

// MARK: - Workspace Add Access Sheet
// Generic user picker reused by both PromptEditorView and KnowledgeEditorView.

struct WorkspaceAddAccessSheet: View {
    @Environment(\.theme) private var theme

    let existingUserIds: Set<String>
    let allUsers: [ChannelMember]
    let isLoading: Bool
    var serverBaseURL: String = ""
    var authToken: String?
    let onAdd: ([String]) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var selectedUserIds: Set<String> = []

    private var availableUsers: [ChannelMember] {
        let filtered = allUsers.filter { !existingUserIds.contains($0.id) }
        if searchText.isEmpty { return filtered }
        let q = searchText.lowercased()
        return filtered.filter {
            ($0.name ?? "").lowercased().contains(q) ||
            $0.email.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("Search users…", text: $searchText)
                        .scaledFont(size: 15)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, 8)

                if availableUsers.isEmpty {
                    ContentUnavailableView {
                        Label("No Users", systemImage: "person.slash")
                    } description: {
                        Text(searchText.isEmpty
                            ? "All available users already have access."
                            : "No users match your search.")
                    }
                } else {
                    Text("Users")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    List(availableUsers) { user in
                        Button {
                            if selectedUserIds.contains(user.id) {
                                selectedUserIds.remove(user.id)
                            } else {
                                selectedUserIds.insert(user.id)
                            }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                UserAvatar(
                                    size: 32,
                                    imageURL: user.resolveAvatarURL(serverBaseURL: serverBaseURL),
                                    name: user.displayName,
                                    authToken: authToken
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName)
                                        .scaledFont(size: 15, weight: .medium)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(user.role?.capitalized ?? "User")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: selectedUserIds.contains(user.id)
                                      ? "checkmark.square.fill" : "square")
                                    .scaledFont(size: 20)
                                    .foregroundStyle(selectedUserIds.contains(user.id)
                                                     ? theme.brandPrimary : theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }

                // Add button
                Button {
                    onAdd(Array(selectedUserIds))
                } label: {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(isLoading ? "Adding…" : "Add \(selectedUserIds.isEmpty ? "" : "(\(selectedUserIds.count))")")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedUserIds.isEmpty || isLoading
                                ? theme.textTertiary.opacity(0.3)
                                : theme.brandPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selectedUserIds.isEmpty || isLoading)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.vertical, 12)
            }
            .background(theme.background)
            .navigationTitle("Add Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                    .disabled(isLoading)
                }
            }
        }
    }
}

// MARK: - Flow Layout (wrapping HStack for tags)

struct PromptFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0, currentY: CGFloat = 0, lineHeight: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0; currentY += lineHeight + spacing; lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX, currentY = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX; currentY += lineHeight + spacing; lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
