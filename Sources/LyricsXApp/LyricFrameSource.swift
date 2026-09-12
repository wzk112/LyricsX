import AppKit
import QuartzCore
import SwiftUI

/// Each lyric surface follows its own window's display link. Common run-loop
/// modes keep frames eligible while AppKit is tracking a window interaction.
struct LyricFrameSource: NSViewRepresentable {
    var running: Bool
    var frame: () -> Void

    func makeNSView(context: Context) -> LyricFrameView { LyricFrameView() }
    func updateNSView(_ view: LyricFrameView, context: Context) {
        view.frameCallback = frame
        view.running = running
    }
    static func dismantleNSView(_ view: LyricFrameView, coordinator: ()) { view.stop(); view.frameCallback = nil }
}

@MainActor final class LyricFrameView: NSView {
    var frameCallback: (() -> Void)?
    var running = false { didSet { if running != oldValue { updateActivity(nil) } } }
    private var link: CADisplayLink?
    private var activity = WindowRenderActivity()
    private var attachment: UInt64 = 0
    private(set) var deliveringFrames = false

    // CADisplayLink retains its target. The proxy must not retain the view.
    @MainActor private final class Target: NSObject {
        weak var view: LyricFrameView?
        @objc func tick(_ sender: CADisplayLink) {
            guard let view, view.deliveringFrames else { return }
            view.frameCallback?()
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        activity = WindowRenderActivity()
        guard let window else { return }
        for name in WindowRenderActivity.notifications {
            NotificationCenter.default.addObserver(self, selector: #selector(updateActivity(_:)), name: name, object: window)
        }
        updateActivity(nil)
        // Attachment often precedes the window's first orderFront. Read again
        // after that operation even if AppKit coalesces its occlusion event.
        let token = attachment
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attachment == token else { return }
            self.updateActivity(nil)
        }
    }
    @objc private func updateActivity(_ notification: Notification?) {
        let visible = activity.update(event: notification?.name, visible: window?.isVisible == true,
            miniaturized: window?.isMiniaturized == true, exposed: window?.occlusionState.contains(.visible) == true)
        deliveringFrames = visible && running
        if deliveringFrames, link == nil, let window {
            let target = Target(); target.view = self
            let link = window.displayLink(target: target, selector: #selector(Target.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = !deliveringFrames
    }
    func stop() {
        attachment &+= 1
        link?.invalidate(); link = nil
        deliveringFrames = false
        NotificationCenter.default.removeObserver(self)
    }
}
