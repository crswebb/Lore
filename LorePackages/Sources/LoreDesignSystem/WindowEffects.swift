import SwiftUI
import AppKit

/// A behind-window vibrancy layer (NSVisualEffectView). With a non-opaque
/// window this lets the desktop/wallpaper blur through — the foundation of the
/// Liquid Glass feel.
public struct VisualEffectView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material = .hudWindow,
                blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Makes the hosting window non-opaque so behind-window vibrancy can show. The
/// visible translucency is then controlled by the scrim in `AdaptiveBackground`.
public struct WindowConfigurator: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The app backdrop. `translucency` in 0...1 fades an opaque scrim out, so at 0
/// the window looks solid and at 1 the desktop shows through the vibrancy. A
/// subtle brand tint stays on top at all levels.
public struct AdaptiveBackground: View {
    public var translucency: Double

    public init(translucency: Double) {
        self.translucency = translucency
    }

    public var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .opacity(1 - max(0, min(1, translucency)))
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    LoreTheme.accent.opacity(0.20),
                    Color.purple.opacity(0.10),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
