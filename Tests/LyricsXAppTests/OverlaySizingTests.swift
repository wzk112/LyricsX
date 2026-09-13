import AppKit
import Testing
import LyricsXCore
@testable import LyricsXApp

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
    p.overlayWidth = 620; p.overlaySecondaryMode = .none
    let doc = LyricsDocument(lines: [
        .init(id: 0, time: 0, text: "C"), .init(id: 1, time: 0.1, text: "Cor"),
        .init(id: 2, time: 0.2, text: "Corporation"),
        .init(id: 3, time: 3, text: String(repeating: "A long sentence with words ", count: 8))])
    let sizes = (0..<3).map { OverlayTextMeasure.desiredSize(document: doc, index: $0, preferences: p, maximumWidth: 620) }
    #expect(sizes.allSatisfy { $0 == sizes[0] })
    #expect(sizes[0].width == 620)
    let long = OverlayTextMeasure.desiredSize(document: doc, index: 3, preferences: p, maximumWidth: 620)
    #expect(long.width == 620 && long.height > sizes[0].height)
    let singleTranslation = OverlayTextMeasure.translationHeight("MMMM", font: 20, canvasWidth: 260)
    #expect(OverlayTextMeasure.translationHeight("MMMM\nMMMM", font: 20, canvasWidth: 260) == singleTranslation * 2)
    #expect(OverlayTextMeasure.translationHeight(String(repeating: "MMMM ", count: 6), font: 20, canvasWidth: 260) == singleTranslation * 2)
    p.overlayWidth = 320
    #expect(p.overlayLayoutWidth == 320)
    p.overlayAdaptiveSize = false
    let restored = Preferences(defaults: defaults)
    #expect(!restored.overlayAdaptiveSize && restored.overlayLayoutWidth == 320)
}

private struct SizingRepository: LyricsRepository {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { $0.finish() } }
    func save(_ document: LyricsDocument, for track: Track) async throws {}
}

@MainActor @Test func overlayFrameRatePreferencePreservesTheUsersChoice() throws {
    let suite = "LyricsXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    #expect(prefs.overlayFrameRate == .display)
    prefs.overlayFrameRate = .sixty
    #expect(Preferences(defaults: defaults).overlayFrameRate.limit == 60)
    defaults.set("invalid", forKey: "overlayFrameRate")
    #expect(Preferences(defaults: defaults).overlayFrameRate == .display)
}

@MainActor @Test func nativeWaitingHandoverKeepsTheDepartingLyricsInsideTheWindow() async throws {
    _ = NSApplication.shared
    let suite = "LyricsXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    prefs.overlayWidth = 620; prefs.hideWhenPaused = false; prefs.hideOverlayOnHover = false
    prefs.overlaySecondaryMode = .translation
    let model = AppModel(repository: SizingRepository(), preferences: prefs)
    let track = Track(playerID: "test", playerName: "Test", title: "Window sizing fixture")
    model.session.accept(.init(track: track, position: 1, isPlaying: false), shouldSearch: false)
    let doc = LyricsDocument(lines: [
        .init(id: 0, time: 0, text: "A long line\nWith a second row", translation: "A translation"),
        .init(id: 1, time: 5, text: ""), .init(id: 2, time: 8, text: "Short lyric")])
    model.session.use(doc, persist: false)
    let overlay = OverlayController(model: model, frameAutosaveName: nil)
    defer { overlay.stop(); model.stop() }
    try await Task.sleep(for: .milliseconds(120))
    let height = overlay.panel.frame.height
    let top = overlay.panel.frame.maxY
    model.session.seek(to: 5)
    try await Task.sleep(for: .milliseconds(90))
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        #expect(abs(overlay.panel.frame.height - height) < 1, "The old lyric is still fading out; a waiting-size window clips it")
    }
    try await Task.sleep(for: .milliseconds(700))
    #expect(abs(overlay.panel.frame.height - OverlayPresentationMode.waitingHeight) < 1)
    #expect(abs(overlay.panel.frame.maxY - top) < 1)
    model.session.seek(to: 8)
    try await Task.sleep(for: .milliseconds(500))
    let lyricHeight = OverlayTextMeasure.height(document: doc, index: 2, preferences: prefs, maximumWidth: 620)
    #expect(abs(overlay.panel.frame.height - lyricHeight) < 1)
    #expect(abs(overlay.panel.frame.maxY - top) < 1)
}

@MainActor @Test func nativeHeightResizeKeepsWidthHostingBoundsAndTopEdge() async throws {
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
    let originalHeight = overlay.panel.frame.height
    let targetHeight = OverlayTextMeasure.height(document: doc, index: 1, preferences: prefs, maximumWidth: prefs.overlayLayoutWidth)
    let maximum = prefs.overlayLayoutWidth
    model.session.seek(to: 3)
    var intermediate = false
    for _ in 0..<28 {
        try await Task.sleep(for: .milliseconds(20))
        let frame = overlay.panel.frame
        #expect(abs(frame.maxY - top) <= 1 && abs(frame.midX - center) <= 1)
        #expect(overlay.lyricHostingView === host && host.bounds == bounds)
        #expect(abs(host.frame.maxY - (overlay.panel.contentView?.bounds.maxY ?? 0)) <= 1)
        #expect(abs(frame.width - originalWidth) <= 1)
        if frame.height > originalHeight && frame.height < targetHeight { intermediate = true }
    }
    #expect(abs(overlay.panel.frame.width - maximum) <= 1)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(intermediate) }
    #expect(abs(overlay.panel.frame.height - targetHeight) <= 1)
    model.session.seek(to: 6)
    try await Task.sleep(for: .milliseconds(250))
    #expect(overlay.panel.frame.height < targetHeight - 1)
    // Shrink starts immediately; wait only for the native animation to finish.
    for _ in 0..<115 where overlay.panel.frame.height > originalHeight + 1 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(overlay.panel.frame.height <= originalHeight + 1)
    #expect(abs(overlay.panel.frame.width - originalWidth) <= 1)
    #expect(abs(overlay.panel.frame.maxY - top) <= 1)
    #expect(host.bounds == bounds)
    // Drag during a new expansion, then let sizing resume at the new anchor.
    model.session.seek(to: 3)
    try await Task.sleep(for: .milliseconds(50))
    overlay.panel.onDragActivity?(true)
    let heldHeight = overlay.panel.frame.height
    overlay.panel.setFrameOrigin(.init(x: overlay.panel.frame.minX + 10, y: overlay.panel.frame.minY + 10))
    let movedTop = overlay.panel.frame.maxY
    try await Task.sleep(for: .milliseconds(420))
    #expect(abs(overlay.panel.frame.height - heldHeight) <= 1)
    overlay.panel.onDragActivity?(false)
    try await Task.sleep(for: .milliseconds(500))
    #expect(abs(overlay.panel.frame.maxY - movedTop) <= 1)
    #expect(abs(overlay.panel.frame.height - targetHeight) <= 1)
}
