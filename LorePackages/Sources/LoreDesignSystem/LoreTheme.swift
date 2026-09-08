import SwiftUI

/// Shared visual constants for Lore.
public enum LoreTheme {
    public static let cornerRadius: CGFloat = 16
    public static let smallCornerRadius: CGFloat = 10
    public static let spacing: CGFloat = 12

    /// Brand accent used for the app glyph, send button, active states.
    public static let accent = Color(red: 0.31, green: 0.56, blue: 0.97)

    /// A curated set of project tints (stored as hex on the Project).
    public static let projectTints: [String] = [
        "#4F8EF7", "#34C759", "#FF9F0A", "#FF375F",
        "#AF52DE", "#5AC8FA", "#FFD60A", "#FF6482",
    ]

    public static func color(hex: String) -> Color {
        var hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

/// A soft, theme-aware backdrop that gives the Liquid Glass surfaces something
/// luminous to refract. Sits behind the whole app.
public struct LoreBackground: View {
    public init() {}
    public var body: some View {
        LinearGradient(
            colors: [
                LoreTheme.accent.opacity(0.22),
                Color.purple.opacity(0.12),
                Color.clear,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .background(.background)
    }
}
