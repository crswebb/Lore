import SwiftUI
import LoreDesignSystem

/// Top-level layout: Projects · Chat history · Chat, with Documents in a
/// right-hand inspector that's hidden by default (chatting > admin).
public struct RootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } content: {
            if model.selectedProject != nil {
                ChatListView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } else {
                EmptyProjectsPlaceholder()
            }
        } detail: {
            if model.selectedProject != nil {
                ChatView()
                    .inspector(isPresented: $model.showDocuments) {
                        DocumentsView()
                            .environment(model)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
                    }
            } else {
                ContentUnavailableView(
                    "Explore your lore",
                    systemImage: "sparkles",
                    description: Text("Create a shelf to start collecting knowledge and asking questions.")
                )
            }
        }
        .background(AdaptiveBackground(translucency: model.settings.windowTranslucency))
        .background(WindowConfigurator())
        .environment(model)
        .task { await model.bootstrap() }
        .sheet(isPresented: $model.showSetup) {
            SetupWizardView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 540)
        }
        .sheet(isPresented: $model.showManualResults) {
            ManualResultsSheet().environment(model)
        }
        .alert(
            "Look for the user manual?",
            isPresented: Binding(get: { model.manualPrompt != nil }, set: { if !$0 { model.manualPrompt = nil } }),
            presenting: model.manualPrompt
        ) { _ in
            Button("Search online") { model.confirmManualSearch() }
            Button("Not now", role: .cancel) { model.manualPrompt = nil }
        } message: { prompt in
            Text("Lore found “\(prompt.productLabel)”. Want me to search the web for its user manual and add it to this shelf?")
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
            Label("No shelves yet", systemImage: "folder.badge.plus")
        } description: {
            Text("A shelf holds a topic's documents, links, and chats — like a shelf for your home or car.")
        } actions: {
            Button("Create your first shelf") { showNewProject = true }
                .buttonStyle(.glassProminent)
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet().environment(model)
        }
    }
}
