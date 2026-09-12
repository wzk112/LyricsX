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
    private(set) var requestedFrameRate = 0

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
        NotificationCenter.default.addObserver(self, selector: #selector(updateFrameRate),
            name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFrameRate),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
            self.link = link
            updateFrameRate()
            link.add(to: .main, forMode: .common)
        }
        link?.isPaused = !deliveringFrames
    }
    @objc private func updateFrameRate() {
        guard let link else { return }
        let maximum = max(1, window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        guard requestedFrameRate != maximum else { return }
        requestedFrameRate = maximum
        // Request the current display's full cadence. AppKit moves this link
        // across screens; macOS still applies power and thermal constraints.
        let rate = Float(maximum)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }
    func stop() {
        attachment &+= 1
        link?.invalidate(); link = nil
        deliveringFrames = false
        requestedFrameRate = 0
        NotificationCenter.default.removeObserver(self)
    }
}
