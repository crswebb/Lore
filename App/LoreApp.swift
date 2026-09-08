import SwiftUI
import LoreUI

@main
struct LoreApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    RootView(model: model)
                } else if let startupError {
                    ContentUnavailableView(
                        "Couldn't start Lore",
                        systemImage: "exclamationmark.triangle",
                        description: Text(startupError)
                    )
                } else {
                    ProgressView("Starting Lore…")
                        .task { start() }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if let model {
                SettingsView(model: model)
            } else {
                Text("Starting Lore…").padding(40)
            }
        }
    }

    private func start() {
        do {
            model = try AppModel()
        } catch {
            startupError = error.localizedDescription
        }
    }
}
