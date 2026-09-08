import SwiftUI
import LoreCore
import LoreDesignSystem

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false
    @State private var renamingProject: Project?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.selectedProjectID },
            set: { id in if let id { Task { await model.select(project: id) } } }
        )) {
            Section("Projects") {
                ForEach(model.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button("Rename…") {
                                renameText = project.name
                                renamingProject = project
                            }
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteProject(project.id) }
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .alert("Rename project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                if let project = renamingProject { Task { await model.renameProject(project.id, to: renameText) } }
                renamingProject = nil
            }
            Button("Cancel", role: .cancel) { renamingProject = nil }
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Lore")
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet().environment(model)
        }
    }

    private var statusBar: some View {
        HStack {
            Button {
                model.showSetup = true
            } label: {
                healthPill
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(10)
    }

    private var healthPill: some View {
        Group {
            switch model.health {
            case .ready where model.modelsReady:
                StatusPill(.good, "Ollama ready")
            case .ready:
                StatusPill(.warning, "Models needed")
            case .installedNotRunning:
                StatusPill(.warning, "Ollama not running")
            case .notInstalled:
                StatusPill(.bad, "Ollama not installed")
            case .error:
                StatusPill(.bad, "Ollama error")
            }
        }
    }
}

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: project.icon)
                .foregroundStyle(LoreTheme.color(hex: project.colorTint))
                .frame(width: 22)
            Text(project.name)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
