import SwiftUI
import LoreCore
import LoreDesignSystem

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false
    @State private var editingProject: Project?

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.selectedProjectID },
            set: { id in if let id { Task { await model.select(project: id) } } }
        )) {
            Section(L("Shelves")) {
                ForEach(model.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button(L("Edit…")) { editingProject = project }
                            Button(L("Delete"), role: .destructive) {
                                Task { await model.deleteProject(project.id) }
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $editingProject) { project in
            ProjectEditorSheet(existing: project).environment(model)
        }
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showNewProject = true
                } label: {
                    Label(L("New Shelf"), systemImage: "plus")
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
            if model.usesOllama {
                Button {
                    model.showSetup = true
                } label: {
                    healthPill
                }
                .buttonStyle(.plain)
            }
            if model.externalActive {
                StatusPill(.neutral, "☁ " + L("External chat"))
                    .help(L("Chat is sent to %@. Embeddings stay local.", model.externalHost))
            } else if model.settings.chatSource == .apple {
                StatusPill(model.appleAvailable ? .good : .warning, "Apple Intelligence")
                    .help(model.usesOllama
                          ? L("Chat runs on Apple's on-device model. Embeddings run locally via Ollama.")
                          : L("Chat and search both run fully on-device via Apple. No Ollama needed."))
            }
            Spacer()
        }
        .padding(10)
    }

    private var healthPill: some View {
        Group {
            switch model.health {
            case .ready where model.modelsReady:
                StatusPill(.good, L("Ollama ready"))
            case .ready:
                StatusPill(.warning, L("Models needed"))
            case .installedNotRunning:
                StatusPill(.warning, L("Ollama not running"))
            case .notInstalled:
                StatusPill(.bad, L("Ollama not installed"))
            case .error:
                StatusPill(.bad, L("Ollama error"))
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
