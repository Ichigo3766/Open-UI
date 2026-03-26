import SwiftUI

/// Sheet for creating or editing a Skill.
/// Mirrors PromptEditorView/KnowledgeEditorView in structure and access grant UI.
struct SkillEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    // MARK: - Input

    var existingSkill: SkillDetail?
    var onSave: ((SkillDetail) -> Void)?

    // MARK: - Import Prefill Init

    /// Creates a new-skill editor pre-populated from imported data (e.g. Markdown / JSON import).
    /// Sets `slugManuallyEdited = true` so slug isn't overwritten when name is populated.
    init(
        prefillName: String = "",
        prefillSlug: String = "",
        prefillDescription: String = "",
        prefillContent: String = "",
        onSave: ((SkillDetail) -> Void)? = nil
    ) {
        self.existingSkill = nil
        self.onSave = onSave
        _name = State(initialValue: prefillName)
        _slug = State(initialValue: prefillSlug)
        _description = State(initialValue: prefillDescription)
        _content = State(initialValue: prefillContent)
        // Prevent slug from being auto-overwritten after pre-fill
        _slugManuallyEdited = State(initialValue: !prefillSlug.isEmpty)
    }

    /// Default init — used for edit mode and plain new-skill creation.
    init(existingSkill: SkillDetail? = nil, onSave: ((SkillDetail) -> Void)? = nil) {
        self.existingSkill = existingSkill
        self.onSave = onSave
    }

    // MARK: - Form State

    @State private var name = ""
    @State private var slug = ""        // auto-generated from name; editable
    @State private var description = ""
    @State private var content = ""
    @State private var isActive = true

    // Access control — matches PromptEditorView / KnowledgeEditorView pattern exactly
    /// isPrivate: true = Private (restricted to access list), false = Public (everyone)
    @State private var isPrivate: Bool = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var showUserPicker = false
    @State private var isUpdatingAccess = false
    @State private var accessUpdateError: String?

    // UI
    @State private var isSaving = false
    @State private var validationError: String? = nil
    @State private var slugManuallyEdited = false
    @State private var isContentExpanded = false
    @State private var isAutoSettingSlug = false   // guard: prevents slug onChange from firing when programmatically setting slug
    @State private var showDiscardConfirm = false
    @State private var initialIsActive = true
    @State private var isTogglingActive = false

    @FocusState private var focusedField: Field?
    private enum Field { case name, slug, description, content }

    private var manager: SkillsManager? { dependencies.skillsManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }
    private var isEditing: Bool { existingSkill != nil }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    /// Users who currently have access, resolved from allUsers for display names.
    private var accessedUsers: [ChannelMember] {
        let ids = Set(localAccessGrants.compactMap { $0.userId })
        return allUsers.filter { ids.contains($0.id) }
    }

    private var hasChanges: Bool {
        guard let existing = existingSkill else {
            return !name.isEmpty || !slug.isEmpty || !content.isEmpty
        }
        let grantIds = Set(localAccessGrants.compactMap { $0.userId })
        let existingIds = Set(existing.accessGrants.compactMap { $0.userId })
        return name != existing.name
            || slug != existing.slug
            || description != existing.description
            || content != existing.content
            || isActive != existing.isActive
            || grantIds != existingIds
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    basicInfoSection
                    contentSection
                    settingsSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Skill" : "New Skill")
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
            populateIfEditing()
            Task { await manager?.fetchAllUsers() }
        }
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Skill Info")
            fieldCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("e.g. Code Review Expert", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                if !slugManuallyEdited {
                                    isAutoSettingSlug = true
                                    slug = generateSlug(from: newValue)
                                    isAutoSettingSlug = false
                                }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("ID (Slug)")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("e.g. code-review-expert", text: $slug)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .slug)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .onChange(of: slug) { _, _ in
                                if !isAutoSettingSlug { slugManuallyEdited = true }
                            }
                    }
                    .padding(.vertical, 12)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    HStack {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        TextField("Optional short description", text: $description)
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

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Instructions (Markdown)")
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
            Text("Write the instruction set in Markdown. Use headings, lists, and code blocks to structure the skill.")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textTertiary)
            fieldCard {
                TextEditor(text: $content)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 200, maxHeight: 400)
                    .focused($focusedField, equals: .content)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
            }
        }
        .sheet(isPresented: $isContentExpanded) {
            FullscreenContentEditor(
                title: "Instructions",
                placeholder: "Write Markdown instructions here…",
                content: $content
            )
        }
    }

    // MARK: - Settings Section (Active + Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                VStack(spacing: 0) {
                    // Active toggle
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
                                Text("Inactive skills won't appear in the chat picker.")
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
                        guard isEditing, newVal != initialIsActive else { return }
                        initialIsActive = newVal
                        Task { await persistActiveToggle(id: existingSkill?.id) }
                    }

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Access Control
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

            // Access List
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
                          || slug.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Access Control Actions

    /// Called when user switches between Private / Public.
    /// Immediately calls the API to persist the change (edit mode only).
    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existingSkill?.id, let manager else { return }
        let grantsToSend = localAccessGrants
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: grantsToSend, isPublic: !isPrivate)
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
        guard let id = existingSkill?.id, let manager else {
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
            let updated = try await manager.updateAccessGrants(skillId: id, grants: newGrants)
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

        guard let id = existingSkill?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }

        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeUser(_ userId: String) async {
        guard let id = existingSkill?.id, let manager else {
            localAccessGrants.removeAll { $0.userId == userId }
            Haptics.play(.light)
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            localAccessGrants.removeAll { $0.userId == userId }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(skillId: id, grants: localAccessGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            // Restore on failure
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

    private func populateIfEditing() {
        guard let skill = existingSkill else { return }
        name = skill.name
        slug = skill.slug
        description = skill.description
        content = skill.content
        isActive = skill.isActive
        initialIsActive = skill.isActive
        let hasWildcard = skill.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = skill.accessGrants.filter { $0.userId != "*" }
        isPrivate = !hasWildcard
        slugManuallyEdited = true  // Don't auto-generate slug when editing
    }

    private func generateSlug(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    /// Calls the dedicated toggle endpoint immediately when the user flips the Active switch.
    private func persistActiveToggle(id: String?) async {
        guard let id, let manager else { return }
        isTogglingActive = true
        do {
            try await manager.toggleSkill(id: id)
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

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedSlug = slug.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the skill."
            isSaving = false
            return
        }
        guard !trimmedSlug.isEmpty else {
            validationError = "Please enter an ID (slug) for the skill."
            isSaving = false
            return
        }

        // Build full access grants list including wildcard for public
        var allGrants = localAccessGrants.filter { $0.userId != "*" }
        if !isPrivate {
            allGrants.append(AccessGrant(id: UUID().uuidString, userId: "*", groupId: nil, read: true, write: false))
        }

        do {
            if let existing = existingSkill {
                // Update content/metadata first
                let detail = SkillDetail(
                    id: existing.id,
                    name: trimmedName,
                    slug: trimmedSlug,
                    description: description,
                    content: content,
                    isActive: isActive,
                    accessGrants: allGrants,
                    userId: existing.userId,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt
                )
                var updated = try await manager.updateSkill(detail)

                // Update access grants via dedicated endpoint
                let updatedGrants = try await manager.updateAccessGrants(
                    skillId: trimmedSlug,
                    grants: localAccessGrants.filter { $0.userId != "*" },
                    isPublic: !isPrivate
                )
                updated.accessGrants = updatedGrants

                onSave?(updated)
            } else {
                let detail = SkillDetail(
                    name: trimmedName,
                    slug: trimmedSlug,
                    description: description,
                    content: content,
                    isActive: isActive,
                    accessGrants: allGrants
                )
                let created = try await manager.createSkill(from: detail)
                onSave?(created)
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
        isSaving = false
    }
}
