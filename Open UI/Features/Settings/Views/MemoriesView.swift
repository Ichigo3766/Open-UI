import SwiftUI

/// Displays and manages the user's AI memories.
///
/// Memories are persistent context that the AI uses across conversations.
/// Users can view, add, edit, and delete memories from this screen.
/// Matches the WebUI's Settings → Personalization → Memory section.
struct MemoriesView: View {
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var memories: [[String: Any]] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newMemoryText = ""
    @State private var isAddingMemory = false
    @State private var editingMemoryId: String?
    @State private var editText = ""
    @State private var showClearAllConfirmation = false
    @State private var isClearingAll = false
    @State private var memoryEnabled = false
    @State private var isLoadingMemoryToggle = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: Spacing.lg) {
                    ProgressView()
                    Text("Loading memories…")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                memoryList
            }
        }
        .background(theme.background)
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { isAddingMemory = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadMemories()
            await loadMemoryToggle()
        }
        .destructiveConfirmation(
            isPresented: $showClearAllConfirmation,
            title: "Clear All Memories",
            message: "This will permanently delete all your memories. The AI will no longer have this context.",
            destructiveTitle: "Clear All"
        ) {
            Task { await clearAllMemories() }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Memories", systemImage: "brain")
        } description: {
            Text("Memories help the AI remember important context about you across conversations. Add a memory to get started.")
        } actions: {
            Button {
                withAnimation { isAddingMemory = true }
            } label: {
                Label("Add Memory", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.brandPrimary)
        }
    }

    // MARK: - Memory List

    private var memoryList: some View {
        List {
            // Memory enabled toggle
            Section {
                Toggle(isOn: $memoryEnabled) {
                    Label("Enable Memory", systemImage: "brain")
                }
                .tint(theme.brandPrimary)
                .disabled(isLoadingMemoryToggle)
                .onChange(of: memoryEnabled) { _, newValue in
                    Task { await updateMemoryToggle(newValue) }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("When enabled, the AI remembers context about you across conversations.")
            }

            // Add new memory section
            if isAddingMemory {
                Section {
                    VStack(spacing: Spacing.sm) {
                        TextField("What should the AI remember?", text: $newMemoryText, axis: .vertical)
                            .lineLimit(3...6)
                            .scaledFont(size: 16)

                        HStack {
                            Button("Cancel") {
                                withAnimation {
                                    isAddingMemory = false
                                    newMemoryText = ""
                                }
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button {
                                Task { await addMemory() }
                            } label: {
                                Text("Save")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.brandPrimary)
                            .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } header: {
                    Text("New Memory")
                }
            }

            // Error
            if let error = errorMessage {
                Section {
                    Text(error)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.error)
                }
            }

            // Existing memories or empty message
            Section {
                if memories.isEmpty && !isAddingMemory {
                    // Empty state inside the list
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "brain")
                            .scaledFont(size: 48)
                            .foregroundStyle(theme.textTertiary.opacity(0.5))
                            .padding(.top, Spacing.lg)
                        
                        Text("No Memories")
                            .scaledFont(size: 20, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        
                        Text("Memories help the AI remember important context about you across conversations.")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.lg)
                        
                        Button {
                            withAnimation { isAddingMemory = true }
                        } label: {
                            Label("Add Memory", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.brandPrimary)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.xl)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                ForEach(memories, id: \.memoryId) { memory in
                    let memId = memory["id"] as? String ?? ""
                    let content = memory["content"] as? String ?? ""

                    if editingMemoryId == memId {
                        // Edit mode
                        VStack(spacing: Spacing.sm) {
                            TextField("Memory content", text: $editText, axis: .vertical)
                                .lineLimit(3...6)
                                .scaledFont(size: 16)

                            HStack {
                                Button("Cancel") {
                                    withAnimation { editingMemoryId = nil }
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button {
                                    Task { await updateMemory(id: memId) }
                                } label: {
                                    Text("Save")
                                        .fontWeight(.semibold)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.brandPrimary)
                                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    } else {
                        // Display mode
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(content)
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)

                            if let createdAt = memory["created_at"] as? Double {
                                Text(Date(timeIntervalSince1970: createdAt).formatted(.relative(presentation: .named)))
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .padding(.vertical, Spacing.xxs)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                editText = content
                                withAnimation { editingMemoryId = memId }
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Task { await deleteMemory(id: memId) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteMemory(id: memId) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editText = content
                                withAnimation { editingMemoryId = memId }
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(theme.brandPrimary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("\(memories.count) memor\(memories.count == 1 ? "y" : "ies")")
                    Spacer()
                }
            }

            // Clear all
            if !memories.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text(isClearingAll ? "Clearing…" : "Clear All Memories")
                        }
                    }
                    .disabled(isClearingAll)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func loadMemories() async {
        guard let api = dependencies.apiClient else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            memories = try await api.getMemories()
        } catch {
            errorMessage = "Failed to load memories."
        }

        isLoading = false
    }

    private func addMemory() async {
        guard let api = dependencies.apiClient else { return }
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let newMemory = try await api.addMemory(content: text)
            withAnimation {
                memories.insert(newMemory, at: 0)
                newMemoryText = ""
                isAddingMemory = false
            }
        } catch {
            errorMessage = "Failed to add memory."
        }
    }

    private func updateMemory(id: String) async {
        guard let api = dependencies.apiClient else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let updated = try await api.updateMemory(id: id, content: text)
            if let idx = memories.firstIndex(where: { ($0["id"] as? String) == id }) {
                memories[idx] = updated
            }
            withAnimation { editingMemoryId = nil }
        } catch {
            errorMessage = "Failed to update memory."
        }
    }

    private func deleteMemory(id: String) async {
        guard let api = dependencies.apiClient else { return }

        do {
            try await api.deleteMemory(id: id)
            withAnimation {
                memories.removeAll { ($0["id"] as? String) == id }
            }
        } catch {
            errorMessage = "Failed to delete memory."
        }
    }

    private func clearAllMemories() async {
        guard let api = dependencies.apiClient else { return }
        isClearingAll = true

        do {
            try await api.resetMemories()
            withAnimation { memories.removeAll() }
        } catch {
            errorMessage = "Failed to clear memories."
        }

        isClearingAll = false
    }

    private func loadMemoryToggle() async {
        guard let api = dependencies.apiClient else { return }
        isLoadingMemoryToggle = true
        if let settings = try? await api.getUserSettings(),
           let ui = settings["ui"] as? [String: Any],
           let enabled = ui["memory"] as? Bool {
            memoryEnabled = enabled
        }
        isLoadingMemoryToggle = false
    }

    private func updateMemoryToggle(_ enabled: Bool) async {
        guard let api = dependencies.apiClient else { return }
        isLoadingMemoryToggle = true
        try? await api.updateUserSettings(["ui": ["memory": enabled as Any]])
        isLoadingMemoryToggle = false
        // Notify all active ChatViewModels so they update immediately
        // without waiting for the next server fetch on model switch/reload.
        NotificationCenter.default.post(name: .memorySettingChanged, object: enabled)
    }
}

// MARK: - Helper

private extension Dictionary where Key == String, Value == Any {
    var memoryId: String {
        (self["id"] as? String) ?? UUID().uuidString
    }
}
