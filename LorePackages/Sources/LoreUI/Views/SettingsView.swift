import SwiftUI
import LoreProviders
import LoreDesignSystem

/// Settings window (⌘,), organized into tabs so each area stays focused.
public struct SettingsView: View {
    @Bindable var model: AppModel
    // Persisted so the selected tab survives the language-driven rebuild below
    // (and across launches) — otherwise switching language would jump tabs.
    @AppStorage("settingsSelectedTab") private var selectedTab = 1

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            ModelsSettingsTab(model: model).tag(0)
                .tabItem { Label(L("Models"), systemImage: "cpu") }
            AppearanceSettingsTab(model: model).tag(1)
                .tabItem { Label(L("Appearance"), systemImage: "paintbrush") }
            AdvancedSettingsTab(model: model).tag(2)
                .tabItem { Label(L("Advanced"), systemImage: "gearshape.2") }
        }
        .frame(width: 500, height: 400)
        // Rebuild when the UI language changes so every label re-localizes live.
        .id(model.settings.appLanguage)
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section(L("Chat & embeddings")) {
                Picker(L("Chat model"), selection: $settings.chatModel) {
                    ForEach(chatModelOptions, id: \.self) { name in
                        Text(label(for: name)).tag(name)
                    }
                }
                LabeledContent(L("Embedding model")) {
                    Text(settings.embeddingModel).foregroundStyle(.secondary)
                }
            }

            Section(L("Local runtime (Ollama)")) {
                TextField(L("Server"), text: $settings.ollamaBaseURLString)
                LabeledContent(L("Status")) {
                    HStack {
                        healthText
                        Button(L("Check")) { Task { await model.refreshHealth() } }
                    }
                }
                Button(L("Manage local models…")) { model.showSetup = true }
            }
        }
        .formStyle(.grouped)
    }

    private var chatModelOptions: [String] {
        var names = OllamaModelCatalog.chatModels.map(\.name)
        if !names.contains(model.settings.chatModel) { names.append(model.settings.chatModel) }
        if case let .ready(installed) = model.health {
            for m in installed where !names.contains(m) && !m.contains("embed") { names.append(m) }
        }
        return names
    }

    private func label(for name: String) -> String {
        if let known = OllamaModelCatalog.chatModels.first(where: { $0.name == name }) {
            return "\(known.label) · ~\(String(format: "%.1f", known.approxDownloadGB)) GB"
        }
        return name
    }

    @ViewBuilder private var healthText: some View {
        switch model.health {
        case .ready where model.modelsReady: Text(L("Ready")).foregroundStyle(.green)
        case .ready: Text(L("Models needed")).foregroundStyle(.orange)
        case .installedNotRunning: Text(L("Not running")).foregroundStyle(.orange)
        case .notInstalled: Text(L("Not installed")).foregroundStyle(.red)
        case .error: Text(L("Error")).foregroundStyle(.red)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section(L("Language")) {
                Picker(L("Language"), selection: $settings.appLanguage) {
                    Text(L("System")).tag("")
                    ForEach(AppLanguage.supported, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Text(L("Changes the language of Lore's interface. Your documents and answers are unaffected."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Window")) {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.windowTranslucency, in: 0...1) {
                        Text(L("Background transparency"))
                    } minimumValueLabel: {
                        Image(systemName: "square.fill")
                    } maximumValueLabel: {
                        Image(systemName: "square.dashed")
                    }
                    Text(L("Let the desktop shine through for a glassier feel. Takes effect immediately."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @Bindable var model: AppModel
    @State private var apiKeyDraft = ""

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section(L("Chat provider")) {
                Picker(L("Chat runs on"), selection: $settings.chatSource) {
                    Text("Ollama").tag(SettingsStore.ChatSource.ollama)
                    Text("Apple").tag(SettingsStore.ChatSource.apple)
                    Text(L("External")).tag(SettingsStore.ChatSource.external)
                }
                .pickerStyle(.segmented)

                if settings.chatSource == .external {
                    TextField(L("Base URL"), text: $settings.externalBaseURLString, prompt: Text("https://api.openai.com/v1"))
                    SecureField(L("API key"), text: $apiKeyDraft)
                    TextField(L("Chat model"), text: $settings.externalChatModel, prompt: Text("gpt-4o-mini"))
                    Button(L("Apply & reconnect")) {
                        settings.externalAPIKey = apiKeyDraft
                        model.reconfigureProviders()
                        Task { await model.refreshHealth() }
                    }
                }
            }

            Section {
                switch settings.chatSource {
                case .ollama:
                    Label(L("Chat runs on a local Ollama model. Fully private and offline."), systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                case .apple:
                    Label(L("Chat uses Apple's on-device model (Apple Intelligence). No download, fully private — requires a supported Mac with Apple Intelligence enabled."), systemImage: "apple.logo")
                        .font(.caption).foregroundStyle(.secondary)
                case .external:
                    Label(L("Chat is sent to your external provider. Your documents and search index stay on this Mac (embeddings always run locally via Ollama)."), systemImage: "cloud")
                        .font(.caption).foregroundStyle(model.externalActive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKeyDraft = model.settings.externalAPIKey }
        .onChange(of: settings.chatSource) {
            settings.chatSourceChosen = true
            model.reconfigureProviders()
            Task { await model.refreshHealth() }
        }
    }
}
