import SwiftUI

/// A rounded glass surface used for cards, panels, and the chat composer.
public struct GlassCard<Content: View>: View {
    private let cornerRadius: CGFloat
    private let content: Content

    public init(cornerRadius: CGFloat = LoreTheme.cornerRadius, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Small status indicator (used for the Ollama health pill and document status).
public struct StatusPill: View {
    public enum Level {
        case good, warning, bad, neutral

        var color: Color {
            switch self {
            case .good: return .green
            case .warning: return .orange
            case .bad: return .red
            case .neutral: return .secondary
            }
        }
    }

    let level: Level
    let text: String

    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

public extension View {
    /// Apply a glass surface with Lore's default corner radius.
    func loreGlass(cornerRadius: CGFloat = LoreTheme.cornerRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
