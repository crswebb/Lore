import SwiftUI
import LoreIngestion
import LoreDesignSystem

/// Shows candidate user manuals found online. The user chooses which (if any)
/// to add — nothing is downloaded or indexed without an explicit tap.
struct ManualResultsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(LoreTheme.accent)
                Text(model.webResultsHeading).font(.title2.bold())
                Spacer()
            }
            Text("Pick the ones to add to this shelf. PDFs are downloaded and stored; pages are indexed by their link.")
                .font(.callout).foregroundStyle(.secondary)

            if model.manualSearching {
                ProgressView("Searching the web…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.manualCandidates.isEmpty {
                ContentUnavailableView(
                    "No manuals found",
                    systemImage: "magnifyingglass",
                    description: Text("Try adding the manual link manually with Add Link in the documents panel.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(model.manualCandidates) { candidate in
                    HStack(spacing: 10) {
                        Image(systemName: candidate.isPDF ? "doc.richtext" : "link")
                            .foregroundStyle(LoreTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).lineLimit(2)
                            Text(candidate.url.host ?? candidate.url.absoluteString)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if model.addedManualURLs.contains(candidate.url) {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly).foregroundStyle(.green)
                        } else {
                            Button("Add") { Task { await model.addManual(candidate) } }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 480)
    }
}
