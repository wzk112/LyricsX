import AppKit
import Testing
@testable import LyricsXApp

// This suite owns NSApplication's event pump. Run it in its own process so it
// cannot consume other suites' AppKit events or block their async deadlines.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LYRICSX_WINDOW_QA"] == "1"))
@MainActor struct WindowFrameTests {
    private func runTracking(for seconds: Double, mode: RunLoop.Mode = .eventTracking) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: min(end, Date().addingTimeInterval(0.01)), inMode: mode, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    @Test func playbackTickerAdvancesDuringTrackingAndCancelsWithoutAQueuedRestart() {
        _ = NSApplication.shared
        var ticks = 0
        let ticker = PlaybackTicker { ticks += 1; return 10 }
        ticker.start()
        runTracking(for: 0.12)
        #expect(ticks > 2)
        ticker.stop()
        let stopped = ticks
        runTracking(for: 0.05)
        #expect(!ticker.running && ticks == stopped)
        ticker.start()
        runTracking(for: 0.05)
        #expect(ticks > stopped)
        ticker.stop()
        let finished = PlaybackTicker { nil }
        finished.start()
        #expect(!finished.running)
    }

    @Test func eachWindowKeepsItsOwnFrameDeliveryDuringMainWindowLifecycle() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let screen = try #require(NSScreen.main)
        let main = NSPanel(contentRect: .init(x: screen.visibleFrame.minX + 30, y: screen.visibleFrame.minY + 30, width: 100, height: 60),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let overlay = NSPanel(contentRect: .init(x: screen.visibleFrame.minX + 140, y: screen.visibleFrame.minY + 30, width: 100, height: 60),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false; overlay.isReleasedWhenClosed = false
        main.level = .floating; overlay.level = .floating
        main.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mainFrames = LyricFrameView(), overlayFrames = LyricFrameView()
        var mainCount = 0, overlayCount = 0
        mainFrames.frameCallback = { mainCount += 1 }; overlayFrames.frameCallback = { overlayCount += 1 }
        mainFrames.running = true; overlayFrames.running = true
        main.contentView = mainFrames; overlay.contentView = overlayFrames
        main.orderFrontRegardless(); overlay.orderFrontRegardless()
        defer { mainFrames.stop(); overlayFrames.stop(); main.close(); overlay.close() }
        for _ in 0..<20 where mainCount == 0 || overlayCount == 0 { runTracking(for: 0.04, mode: .default) }
        #expect(mainCount > 0 && overlayCount > 0)
        #expect(mainFrames.requestedFrameRate == main.screen?.maximumFramesPerSecond)
        #expect(overlayFrames.requestedFrameRate == overlay.screen?.maximumFramesPerSecond)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: overlay)
        #expect(overlayFrames.requestedFrameRate == overlay.screen?.maximumFramesPerSecond)
        let before = overlayCount
        let started = ProcessInfo.processInfo.systemUptime
        runTracking(for: 0.5)
        let measured = Double(overlayCount - before) / (ProcessInfo.processInfo.systemUptime - started)
        #expect(overlayCount > before)
        // Notifications are scoped to their actual window, including the
        // interval before AppKit has finished minimizing or taking a snapshot.
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: main)
        let frozen = mainCount, continuing = overlayCount
        runTracking(for: 0.12)
        #expect(!mainFrames.deliveringFrames && overlayFrames.deliveringFrames)
        #expect(mainCount == frozen && overlayCount > continuing)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: main)
        runTracking(for: 0.08)
        #expect(mainCount > frozen)
        main.close()
        let closed = mainCount, overlayBefore = overlayCount
        runTracking(for: 0.08)
        #expect(mainCount == closed && overlayCount > overlayBefore)
        overlayFrames.running = false
        let paused = overlayCount
        runTracking(for: 0.05)
        #expect(overlayCount == paused && !overlayFrames.deliveringFrames)
        print(String(format: "Native frame delivery: requested %d Hz; measured %.1f callbacks/s; tracking and main-window minimize/close preserved overlay callbacks",
                     overlayFrames.requestedFrameRate, measured))
    }
}
