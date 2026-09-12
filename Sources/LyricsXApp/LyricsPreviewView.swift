import SwiftUI

/// Preview owns no player bridge, cache or production lyrics session.
struct LyricsPreviewView: View {
    @State private var anchor = Date()
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 36) {
            CoverArtwork(artwork: nil, demo: true).frame(width: 250)
            TimelineView(.animation(minimumInterval: 0.05, paused: !visible || reduceMotion)) { context in
                let time = context.date.timeIntervalSince(anchor).truncatingRemainder(dividingBy: 96)
                let doc = DemoContent.document
                let index = doc.index(at: time) ?? 0
                VStack(alignment: .leading, spacing: 20) {
                    Text("动效预览").font(.headline).foregroundStyle(.secondary)
                    Text("演示内容仅在此窗口显示").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        WordHighlight(line: doc.lines[index], time: time, active: true, text: doc.lines[index].text)
                            .font(.system(size: 30, weight: .semibold))
                        Text(doc.lines[index].translation ?? "").font(.callout).foregroundStyle(.secondary)
                    }.lyricArrival(trigger: index, reduced: reduceMotion)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(40).frame(minWidth: 680, minHeight: 380)
            .background(Color(white: 0.08)).preferredColorScheme(.dark)
            .background(WindowVisibilityReader { visible = $0 })
    }
}

struct WindowVisibilityReader: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { let view = VisibilityView(); view.changed = changed; return view }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility(_:)), name: name, object: window)
                }
            }
            DispatchQueue.main.async { [weak self] in self?.updateVisibility(nil) }
        }
        @objc private func updateVisibility(_ notification: Notification?) {
            let visible = notification?.name != NSWindow.willCloseNotification && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            changed?(visible)
        }
    }
}
