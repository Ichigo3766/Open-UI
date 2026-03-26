import SwiftUI

// MARK: - Workspace Tab

enum WorkspaceTab: String, CaseIterable {
    case models = "Models"
    case knowledge = "Knowledge"
    case prompts = "Prompts"
    case skills = "Skills"
    case tools = "Tools"
    

    var icon: String {
        switch self {
        case .models: return "sparkles"
        case .knowledge: return "cylinder.split.1x2"
        case .prompts: return "text.quote"
        case .skills: return "brain"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - WorkspaceView

/// The top-level Workspace hub, opened from the sidebar bottom bar.
/// Houses workspace tabs, mirroring the web UI's Workspace section.
struct WorkspaceView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: WorkspaceTab = .models

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                tabBar
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)

                Divider()
                    .background(theme.inputBorder.opacity(0.3))

                // Tab content
                Group {
                    switch selectedTab {
                    case .models:
                        ModelListView()
                    case .knowledge:
                        KnowledgeListView()
                    case .prompts:
                        PromptsListView()
                    case .skills:
                        SkillsListView()
                    case .tools:
                        ToolsListView()
                    
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.background)
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(theme.surfaceContainer.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTab = tab
                        }
                        Haptics.play(.light)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .scaledFont(size: 13, weight: .medium)
                            Text(tab.rawValue)
                                .scaledFont(size: 14, weight: selectedTab == tab ? .semibold : .regular)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(selectedTab == tab ? theme.brandPrimary : theme.textTertiary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .fill(selectedTab == tab
                                      ? theme.brandPrimary.opacity(0.12)
                                      : theme.surfaceContainer.opacity(0.5))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .strokeBorder(
                                    selectedTab == tab ? theme.brandPrimary.opacity(0.3) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
        }
    }
}
