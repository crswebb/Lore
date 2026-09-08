import SwiftUI
import LoreDesignSystem

/// Top-level three-column layout: Projects · Documents · Chat.
public struct RootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } content: {
            if model.selectedProject != nil {
                ProjectDetailView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
            } else {
                EmptyProjectsPlaceholder()
            }
        } detail: {
            if model.selectedProject != nil {
                ChatView()
            } else {
                ContentUnavailableView(
                    "Explore your lore",
                    systemImage: "sparkles",
                    description: Text("Create a project to start collecting knowledge and asking questions.")
                )
            }
        }
        .background(LoreBackground())
        .environment(model)
        .task { await model.bootstrap() }
        .sheet(isPresented: $model.showSetup) {
            SetupWizardView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 540)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EmptyProjectsPlaceholder: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false

    var body: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("A project groups documents, links, and chats around one topic — like your home, a car, or a research area.")
        } actions: {
            Button("Create your first project") { showNewProject = true }
                .buttonStyle(.glassProminent)
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet().environment(model)
        }
    }
}
