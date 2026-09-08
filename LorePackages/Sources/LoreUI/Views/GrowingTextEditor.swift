import SwiftUI
import AppKit

/// A multiline text input that word-wraps and grows with its content, up to a
/// max height (then scrolls). Uses TextEditor (native NSTextView) for correct
/// wrapping, and drives its height from a mirror Text that re-measures whenever
/// the width changes — avoiding the stale-height bug of TextField(axis:.vertical).
struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 22
    var maxHeight: CGFloat = 140
    var onSubmit: () -> Void = {}

    @State private var measuredHeight: CGFloat = 22

    private let font: Font = .body
    // Horizontal inset TextEditor applies to its text; match it in the mirror so
    // the two wrap at the same width.
    private let hInset: CGFloat = 5
    private let vInset: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible mirror that measures the wrapped height at the real width.
            Text(text.isEmpty ? " " : text)
                .font(font)
                .padding(.horizontal, hInset)
                .padding(.vertical, vInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: EditorHeightKey.self, value: proxy.size.height)
                    }
                )
                .hidden()

            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, hInset)
                    .padding(.vertical, vInset)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(ScrollerHider())
                .frame(height: min(max(measuredHeight, minHeight), maxHeight))
                .onKeyPress { keyPress in
                    // Enter sends; Shift+Enter inserts a newline; other keys pass through.
                    guard keyPress.key == .return, !keyPress.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    onSubmit()
                    return .handled
                }
        }
        .onPreferenceChange(EditorHeightKey.self) { measuredHeight = $0 }
    }
}

private struct EditorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 22
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Hides the scroller on the composer's TextEditor by disabling it on the
/// underlying NSScrollView. Scoped to scroll views whose document is an
/// NSTextView, so it never touches the sidebar/list scrollers.
private struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { hideScrollers(around: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { hideScrollers(around: nsView) }
    }

    private func hideScrollers(around view: NSView) {
        guard let root = view.window?.contentView else { return }
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.documentView is NSTextView {
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
                scroll.verticalScroller?.alphaValue = 0
            }
            v.subviews.forEach(walk)
        }
        walk(root)
    }
}
