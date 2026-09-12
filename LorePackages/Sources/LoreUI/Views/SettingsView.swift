import SwiftUI
import LoreProviders
import LoreDesignSystem

/// Settings window (⌘,), organized into tabs so each area stays focused.
public struct SettingsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            ModelsSettingsTab(model: model)
                .tabItem { Label("Models", systemImage: "cpu") }
            AppearanceSettingsTab(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AdvancedSettingsTab(model: model)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Models

private struct ModelsSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Chat & embeddings") {
                Picker("Chat model", selection: $settings.chatModel) {
                    ForEach(chatModelOptions, id: \.self) { name in
                        Text(label(for: name)).tag(name)
                    }
                }
                LabeledContent("Embedding model") {
                    Text(settings.embeddingModel).foregroundStyle(.secondary)
                }
            }

            Section("Local runtime (Ollama)") {
                TextField("Server", text: $settings.ollamaBaseURLString)
                LabeledContent("Status") {
                    HStack {
                        healthText
                        Button("Check") { Task { await model.refreshHealth() } }
                    }
                }
                Button("Manage local models…") { model.showSetup = true }
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
        case .ready where model.modelsReady: Text("Ready").foregroundStyle(.green)
        case .ready: Text("Models needed").foregroundStyle(.orange)
        case .installedNotRunning: Text("Not running").foregroundStyle(.orange)
        case .notInstalled: Text("Not installed").foregroundStyle(.red)
        case .error: Text("Error").foregroundStyle(.red)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Window") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.windowTranslucency, in: 0...1) {
                        Text("Background transparency")
                    } minimumValueLabel: {
                        Image(systemName: "square.fill")
                    } maximumValueLabel: {
                        Image(systemName: "square.dashed")
                    }
                    Text("Let the desktop shine through for a glassier feel. Takes effect immediately.")
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
            Section("Chat provider") {
                Picker("Chat runs on", selection: $settings.chatSource) {
                    Text("Ollama").tag(SettingsStore.ChatSource.ollama)
                    Text("Apple").tag(SettingsStore.ChatSource.apple)
                    Text("External").tag(SettingsStore.ChatSource.external)
                }
                .pickerStyle(.segmented)

                if settings.chatSource == .external {
                    TextField("Base URL", text: $settings.externalBaseURLString, prompt: Text("https://api.openai.com/v1"))
                    SecureField("API key", text: $apiKeyDraft)
                    TextField("Chat model", text: $settings.externalChatModel, prompt: Text("gpt-4o-mini"))
                    Button("Apply & reconnect") {
                        settings.externalAPIKey = apiKeyDraft
                        model.reconfigureProviders()
                        Task { await model.refreshHealth() }
                    }
                }
            }

            Section {
                switch settings.chatSource {
                case .ollama:
                    Label("Chat runs on a local Ollama model. Fully private and offline.", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                case .apple:
                    Label("Chat uses Apple's on-device model (Apple Intelligence). No download, fully private — requires a supported Mac with Apple Intelligence enabled.", systemImage: "apple.logo")
                        .font(.caption).foregroundStyle(.secondary)
                case .external:
                    Label("Chat is sent to your external provider. Your documents and search index stay on this Mac (embeddings always run locally via Ollama).", systemImage: "cloud")
                        .font(.caption).foregroundStyle(model.externalActive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKeyDraft = model.settings.externalAPIKey }
        .onChange(of: settings.chatSource) {
            model.reconfigureProviders()
            Task { await model.refreshHealth() }
        }
    }
}
