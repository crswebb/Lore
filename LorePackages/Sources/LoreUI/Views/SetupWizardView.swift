import SwiftUI
import LoreCore
import LoreProviders
import LoreDesignSystem

/// First-run (and on-demand) wizard that gets the local model ready without a
/// terminal: detect Ollama, pull the needed models with progress, verify.
struct SetupWizardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selectedChatModel: String = OllamaModelCatalog.chatModels[0].name
    @State private var pull: PullState?

    struct PullState: Equatable {
        var model: String
        var fraction: Double
        var status: String
    }

    private var availableModels: [String] {
        if case let .ready(models) = model.health { return models }
        return []
    }

    private var embeddingReady: Bool {
        AppModel.modelPresent(model.settings.embeddingModel, in: availableModels)
    }
    private var chatReady: Bool {
        AppModel.modelPresent(selectedChatModel, in: availableModels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            switch model.health {
            case .notInstalled:
                installStep
            case .installedNotRunning:
                notRunningStep
            case .error(let message):
                errorStep(message)
            case .ready:
                modelsStep
            }

            Spacer()
            footer
        }
        .padding(28)
        .task {
            selectedChatModel = OllamaModelCatalog
                .recommendedChatModel(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory).name
            await model.refreshHealth()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up your local AI").font(.largeTitle.bold())
            Text("Lore runs entirely on your Mac using Ollama. Explore your lore — privately.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Steps

    private var installStep: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Ollama isn't installed", systemImage: "xmark.circle.fill")
                    .font(.headline).foregroundStyle(.red)
                Text("Ollama is a free app that runs AI models locally. Install it, then come back and check again.")
                Button("Download Ollama") {
                    openURL(URL(string: "https://ollama.com/download")!)
                }
                .buttonStyle(.glassProminent)
                Text("Or with Homebrew: `brew install ollama`")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(18)
        }
    }

    private var notRunningStep: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Ollama is installed but not running", systemImage: "pause.circle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Start Ollama, then check again. From Terminal you can run:")
                Text("ollama serve")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .loreGlass(cornerRadius: 8)
            }
            .padding(18)
        }
    }

    private func errorStep(_ message: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't reach Ollama", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red)
                Text(message).foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            modelCard(
                title: "Embedding model",
                subtitle: "\(model.settings.embeddingModel) · needed to search your documents",
                ready: embeddingReady,
                modelName: model.settings.embeddingModel
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Chat model").font(.headline)
                Picker("Chat model", selection: $selectedChatModel) {
                    ForEach(OllamaModelCatalog.chatModels, id: \.name) { m in
                        Text("\(m.label) · ~\(String(format: "%.1f", m.approxDownloadGB)) GB").tag(m.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: selectedChatModel) { model.settings.chatModel = selectedChatModel }

                modelCard(
                    title: "",
                    subtitle: chatBlurb,
                    ready: chatReady,
                    modelName: selectedChatModel
                )
            }
        }
    }

    private var chatBlurb: String {
        OllamaModelCatalog.chatModels.first { $0.name == selectedChatModel }?.blurb ?? ""
    }

    private func modelCard(title: String, subtitle: String, ready: Bool, modelName: String) -> some View {
        GlassCard(cornerRadius: LoreTheme.smallCornerRadius) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty { Text(title).font(.headline) }
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    if let pull, pull.model == modelName {
                        ProgressView(value: pull.fraction) {
                            Text(pull.status).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 260)
                    }
                }
                Spacer()
                if ready {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).labelStyle(.iconOnly).font(.title2)
                } else if pull?.model == modelName {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download") { startPull(modelName) }
                        .buttonStyle(.glass)
                }
            }
            .padding(14)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Check again") { Task { await model.refreshHealth() } }
            Spacer()
            if allReady {
                Button("Finish") { model.completeSetup() }
                    .buttonStyle(.glassProminent)
            } else {
                Button("Skip for now") { model.showSetup = false }
                    .buttonStyle(.plain)
            }
        }
    }

    private var allReady: Bool {
        if case .ready = model.health { return embeddingReady && chatReady }
        return false
    }

    // MARK: Pull

    private func startPull(_ name: String) {
        pull = PullState(model: name, fraction: 0, status: "Starting…")
        Task {
            do {
                for try await progress in model.setupService.pull(model: name) {
                    pull = PullState(model: name, fraction: progress.fraction, status: progress.status)
                }
                await model.refreshHealth()
                pull = nil
            } catch {
                model.report(error)
                pull = nil
            }
        }
    }
}
