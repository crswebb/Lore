import SwiftUI
import LoreCore
import LoreDesignSystem

// MARK: - Display helpers

func iconName(for kind: DocumentKind) -> String {
    switch kind {
    case .pdf: return "doc.richtext"
    case .webLink: return "link"
    case .text: return "doc.plaintext"
    case .markdown: return "text.alignleft"
    }
}

func statusLabel(for status: DocumentStatus) -> String {
    switch status {
    case .pending: return "Pending"
    case .extracting: return "Reading…"
    case .chunking: return "Chunking…"
    case .embedding: return "Embedding…"
    case .ready: return "Ready"
    case .failed: return "Failed"
    }
}

// MARK: - Project editor (create + edit)

/// Convenience for the "New Shelf" call sites.
struct NewProjectSheet: View {
    var body: some View { ProjectEditorSheet() }
}

/// Create a new project (when `existing` is nil) or edit name/icon/color of an
/// existing one.
struct ProjectEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var existing: Project?

    @State private var name = ""
    @State private var icon = "house.fill"
    @State private var tint = LoreTheme.projectTints[0]

    private let icons = ["house.fill", "car.fill", "briefcase.fill", "book.fill",
                         "wrench.and.screwdriver.fill", "heart.fill", "airplane", "leaf.fill"]

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isEditing ? "Edit Shelf" : "New Shelf").font(.title2.bold())

            TextField("Shelf name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                    ForEach(icons, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.title3)
                            .frame(width: 34, height: 34)
                            .background(icon == symbol ? LoreTheme.color(hex: tint).opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
                            .onTapGesture { icon = symbol }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.headline)
                HStack(spacing: 10) {
                    ForEach(LoreTheme.projectTints, id: \.self) { hex in
                        Circle()
                            .fill(LoreTheme.color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(.primary, lineWidth: tint == hex ? 2 : 0))
                            .onTapGesture { tint = hex }
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isEditing ? "Save" : "Create") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
        .onAppear {
            if let existing {
                name = existing.name
                icon = existing.icon
                tint = existing.colorTint
            }
        }
    }

    private func save() {
        if var project = existing {
            project.name = name
            project.icon = icon
            project.colorTint = tint
            Task { await model.updateProject(project); dismiss() }
        } else {
            Task { await model.createProject(name: name, icon: icon, tint: tint); dismiss() }
        }
    }
}

// MARK: - Add link

struct AddLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a web link").font(.title2.bold())
            Text("Lore will fetch the page and index its text so you can ask about it.")
                .foregroundStyle(.secondary)
            TextField("https://example.com/manual", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let url = normalizedURL(urlString) {
                        Task { await model.addWebLink(url); dismiss() }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(normalizedURL(urlString) == nil)
            }
        }
        .padding(24)
        .frame(width: 460, height: 220)
    }

    private func normalizedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }
}

// MARK: - Metadata editor

struct MetadataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let document: Document

    @State private var pairs: [Pair] = []

    struct Pair: Identifiable { let id = UUID(); var key: String; var value: String }

    private let suggestedKeys = ["vendor", "purchaseDate", "warrantyUntil", "model", "serialNumber", "products"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Facts about “\(document.title)”").font(.title2.bold())
            Text("Structured facts help Lore answer precisely — e.g. whether a warranty is still valid.")
                .foregroundStyle(.secondary)
                .font(.callout)

            List {
                ForEach($pairs) { $pair in
                    HStack {
                        TextField("key", text: $pair.key).frame(width: 140)
                        TextField("value", text: $pair.value)
                        Button(role: .destructive) {
                            pairs.removeAll { $0.id == pair.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Menu("Add fact") {
                    ForEach(suggestedKeys, id: \.self) { key in
                        Button(key) { pairs.append(Pair(key: key, value: "")) }
                    }
                    Divider()
                    Button("Custom…") { pairs.append(Pair(key: "", value: "")) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var dict: [String: String] = [:]
                    for pair in pairs where !pair.key.trimmingCharacters(in: .whitespaces).isEmpty {
                        dict[pair.key] = pair.value
                    }
                    Task { await model.setMetadata(dict, for: document); dismiss() }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
        .onAppear {
            pairs = document.metadata.map { Pair(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
        }
    }
}
