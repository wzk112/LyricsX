import AppKit
import Testing
import LyricsXCore
@testable import LyricsXApp

@Test func adaptiveSizingGrowsImmediatelyAndShrinksOnlyAfterStableInterval() {
    var policy = OverlaySizingPolicy()
    let large = NSSize(width: 640, height: 210), small = NSSize(width: 320, height: 170)
    #expect(policy.resolve(large, at: 0) == large)
    for step in 1...15 { #expect(policy.resolve(small, at: Double(step) / 10) == large) }
    #expect(policy.resolve(small, at: 1.7) == small)
    #expect(policy.resolve(large, at: 1.8) == large)
    #expect(policy.resolve(small, at: 1.9) == large)
    // A slightly narrower line lives in the dead band.
    #expect(policy.resolve(.init(width: 600, height: 210), at: 4) == large)
    #expect(policy.resolve(small, at: 4.1) == large)
    #expect(policy.resolve(small, at: 5.5) == small)
}

@Test func rapidAlternatingLyricsDoNotPumpTheWindow() {
    var policy = OverlaySizingPolicy()
    let large = NSSize(width: 620, height: 220), small = NSSize(width: 320, height: 180)
    _ = policy.resolve(large, at: 0)
    for step in 1...250 {
        #expect(policy.resolve(step % 5 == 0 ? large : small, at: Double(step) * 0.08) == large)
    }
    #expect(policy.resolve(small, at: 21) == large)
    #expect(policy.resolve(small, at: 22.3) == small)
}

@Test func resizingKeepsTopAndHorizontalCenterAcrossSizesAndScreenClamps() {
    let screen = NSRect(x: -1440, y: -200, width: 1440, height: 1000)
    let anchor = OverlayAnchor(topCenter: .init(x: -700, y: 680))
    for width in stride(from: 320.0, through: 920, by: 40) {
        let frame = anchor.frame(size: .init(width: width, height: width / 4), in: screen)
        #expect(frame.midX == -700 && frame.maxY == 680)
    }
    let edge = OverlayAnchor(topCenter: .init(x: -210, y: 680))
    #expect(edge.frame(size: .init(width: 800, height: 220), in: screen).maxX == 0)
    #expect(edge.frame(size: .init(width: 320, height: 160), in: screen).midX == -210)
}

@MainActor @Test func adaptiveGeometryReservesIncrementalChainsAndHonorsSizeBounds() throws {
    let suite = "LyricsXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let p = Preferences(defaults: defaults)
    p.overlayWidth = 620; p.overlayMinimumWidth = 360; p.overlaySecondaryMode = .none
    let doc = LyricsDocument(lines: [
        .init(id: 0, time: 0, text: "C"), .init(id: 1, time: 0.1, text: "Cor"),
        .init(id: 2, time: 0.2, text: "Corporation"),
        .init(id: 3, time: 3, text: String(repeating: "A long sentence with words ", count: 8))])
    let sizes = (0..<3).map { OverlayTextMeasure.desiredSize(document: doc, index: $0, preferences: p, maximumWidth: 620) }
    #expect(sizes.allSatisfy { $0 == sizes[0] })
    #expect(sizes[0].width >= 360 && sizes[0].width < 620)
    let long = OverlayTextMeasure.desiredSize(document: doc, index: 3, preferences: p, maximumWidth: 620)
    #expect(long.width == 620 && long.height > sizes[0].height)
    p.overlayMinimumWidth = 900
    #expect(OverlayTextMeasure.desiredSize(document: doc, index: 0, preferences: p, maximumWidth: 620).width == 620)
    p.overlayAdaptiveSize = false
    let restored = Preferences(defaults: defaults)
    #expect(!restored.overlayAdaptiveSize && restored.overlayMinimumWidth == 900)
}

private struct SizingRepository: LyricsRepository {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { $0.finish() } }
    func save(_ document: LyricsDocument, for track: Track) async throws {}
}

@MainActor @Test func nativeResizeKeepsHostingBoundsAndTopEdgeWhileAnimating() async throws {
    _ = NSApplication.shared
    let suite = "LyricsXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    prefs.overlayWidth = 620; prefs.hideWhenPaused = false; prefs.overlaySecondaryMode = .both
    let model = AppModel(repository: SizingRepository(), preferences: prefs)
    model.session.accept(.init(track: .init(playerID: "test", playerName: "Test", title: "Sizing fixture"), position: 0, isPlaying: false), shouldSearch: false)
    let doc = LyricsDocument(lines: [
        .init(id: 0, time: 0, text: "Corpora", translation: "公司"),
        .init(id: 1, time: 3, text: "A longer current sentence needs enough room to stay readable", translation: "较长的一句"),
        .init(id: 2, time: 6, text: "Light", translation: "光")])
    model.session.use(doc, persist: false)
    let overlay = OverlayController(model: model, frameAutosaveName: nil)
    defer { overlay.stop(); model.stop() }
    let screen = try #require(NSScreen.main)
    overlay.panel.setFrameOrigin(.init(x: screen.visibleFrame.midX - overlay.panel.frame.width / 2, y: screen.visibleFrame.midY))
    overlay.windowDidMove(.init(name: NSWindow.didMoveNotification, object: overlay.panel))
    // Let native window setup and concurrent offscreen render tests drain;
    // otherwise a blocked MainActor can consume the entire animation duration.
    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(50)) }
    let top = overlay.panel.frame.maxY, center = overlay.panel.frame.midX
    let host = overlay.lyricHostingView, bounds = overlay.lyricHostingView.bounds
    let originalWidth = overlay.panel.frame.width
    model.session.seek(to: 3)
    var intermediate = false
    for _ in 0..<28 {
        try await Task.sleep(for: .milliseconds(20))
        let frame = overlay.panel.frame
        #expect(abs(frame.maxY - top) <= 1 && abs(frame.midX - center) <= 1)
        #expect(overlay.lyricHostingView === host && host.bounds == bounds)
        #expect(abs(host.frame.maxY - (overlay.panel.contentView?.bounds.maxY ?? 0)) <= 1)
        if frame.width > originalWidth && frame.width < 620 { intermediate = true }
    }
    #expect(overlay.panel.frame.width == 620)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(intermediate) }
    model.session.seek(to: 6)
    try await Task.sleep(for: .milliseconds(250))
    #expect(overlay.panel.frame.width == 620)
    // Poll for the actual shrink deadline, tolerating a busy rendering executor.
    for _ in 0..<60 where overlay.panel.frame.width > originalWidth {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(overlay.panel.frame.width <= originalWidth)
    #expect(abs(overlay.panel.frame.maxY - top) <= 1)
    #expect(host.bounds == bounds)
}
