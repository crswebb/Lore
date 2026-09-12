import SwiftUI
import LoreDesignSystem

/// Top-level layout: Projects · Chat history · Chat, with Documents in a
/// right-hand inspector that's hidden by default (chatting > admin).
public struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL
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
                    L("Explore your lore"),
                    systemImage: "sparkles",
                    description: Text(L("Create a shelf to start collecting knowledge and asking questions."))
                )
            }
        }
        .safeAreaInset(edge: .top) {
            if let update = model.availableUpdate {
                updateBanner(update)
            }
        }
        // Rebuild the split-view subtree when the UI language changes so every
        // label re-localizes live. AppModel state (selection, chats) is owned
        // above and survives; only transient view state resets.
        .id(model.settings.appLanguage)
        .environment(\.locale, AppLanguage.locale(for: model.settings.appLanguage))
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
            L("Look for the user manual?"),
            isPresented: Binding(get: { model.manualPrompt != nil }, set: { if !$0 { model.manualPrompt = nil } }),
            presenting: model.manualPrompt
        ) { _ in
            Button(L("Search online")) { model.confirmManualSearch() }
            Button(L("Not now"), role: .cancel) { model.manualPrompt = nil }
        } message: { prompt in
            Text(L("Lore found “%@”. Want me to search the web for its user manual and add it to this shelf?", prompt.productLabel))
        }
        .alert(
            L("Something went wrong"),
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(L("OK"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            L("Software Update"),
            isPresented: Binding(get: { model.infoMessage != nil }, set: { if !$0 { model.infoMessage = nil } })
        ) {
            Button(L("OK"), role: .cancel) { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
    }

    /// Slim, dismissible bar shown when a newer release is on GitHub.
    private func updateBanner(_ update: ReleaseInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(LoreTheme.accent)
            Text(L("Lore %@ is available.", update.version))
                .font(.callout).fontWeight(.medium)
            Spacer()
            Button(L("Download update")) { openURL(update.url) }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            Button {
                model.availableUpdate = nil
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .help(L("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

struct EmptyProjectsPlaceholder: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false

    var body: some View {
        ContentUnavailableView {
            Label(L("No shelves yet"), systemImage: "folder.badge.plus")
        } description: {
            Text(L("A shelf holds a topic's documents, links, and chats — like a shelf for your home or car."))
        } actions: {
            Button(L("Create your first shelf")) { showNewProject = true }
                .buttonStyle(.glassProminent)
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet().environment(model)
        }
    }
}
