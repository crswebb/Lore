import SwiftUI
import LoreProviders
import LoreDesignSystem

/// Settings window (⌘,). Keeps model choice out of the main UI but easy to reach.
public struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var apiKeyDraft = ""

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Local AI") {
                Picker("Chat model", selection: $settings.chatModel) {
                    ForEach(chatModelOptions, id: \.self) { name in
                        Text(label(for: name)).tag(name)
                    }
                }

                LabeledContent("Embedding model") {
                    Text(settings.embeddingModel).foregroundStyle(.secondary)
                }

                TextField("Ollama server", text: $settings.ollamaBaseURLString)

                LabeledContent("Status") {
                    HStack {
                        healthText
                        Button("Check") { Task { await model.refreshHealth() } }
                    }
                }
            }

            Section("Appearance") {
                VStack(alignment: .leading, spacing: 4) {
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

            Section("Advanced — External chat API") {
                Toggle("Use an external API for chat", isOn: $settings.useExternalAPI)
                if settings.useExternalAPI {
                    TextField("Base URL", text: $settings.externalBaseURLString, prompt: Text("https://api.openai.com/v1"))
                    SecureField("API key", text: $apiKeyDraft)
                    TextField("Chat model", text: $settings.externalChatModel, prompt: Text("gpt-4o-mini"))
                    Button("Apply & reconnect") {
                        settings.externalAPIKey = apiKeyDraft
                        model.reconfigureProviders()
                        Task { await model.refreshHealth() }
                    }
                    Text("Any OpenAI-compatible endpoint (OpenAI, OpenRouter, a remote Ollama’s /v1, …). Embeddings still run locally via Ollama, so your documents stay private and the search index stays consistent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Manage local models…") { model.showSetup = true }
                Text("Download or switch models, and verify the local runtime.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text(settings.useExternalAPI
                     ? "Chat uses your external API; embeddings run locally. Explore your lore."
                     : "Everything runs locally on your Mac. Explore your lore.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear { apiKeyDraft = model.settings.externalAPIKey }
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
