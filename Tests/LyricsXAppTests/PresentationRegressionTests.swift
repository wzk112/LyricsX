import AppKit
import Foundation
import Testing
import LyricsXCore
@testable import LyricsXApp

private struct EmptyRepository: LyricsRepository {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { $0.finish() } }
    func save(_ document: LyricsDocument, for track: Track) async throws { }
}

private let overlayTrack = Track(playerID: "test", playerName: "Test", title: "Overlay Song", artist: "Artist", duration: 180)
private let overlayLyrics = LyricsDocument(title: "Overlay Song", artist: "Artist", duration: 180,
    lines: [.init(id: 0, time: 0, text: "Visible lyric")])

@Suite @MainActor struct PresentationRegressionTests {
    @Test func nativeOverlayKeepsControlsClickableDuringPassThroughAndHoverHide() async throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.hideWhenPaused = false
        prefs.hideOverlayOnHover = true
        prefs.reduceMotion = true
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        model.session.accept(.init(track: overlayTrack, position: 1, isPlaying: true), shouldSearch: false)
        model.session.use(overlayLyrics, persist: false)
        let overlay = OverlayController(model: model, frameAutosaveName: nil)
        defer { overlay.stop(); model.stop() }
        let center = NSPoint(x: overlay.panel.frame.midX, y: overlay.panel.frame.midY)
        let outside = NSPoint(x: -10_000, y: -10_000)
        let dragPoint = NSPoint(x: 100, y: 50)
        model.setOverlayClickThrough(true)
        try await Task.sleep(for: .milliseconds(25))
        overlay.refreshAppearance(at: center)
        #expect(overlay.panel.ignoresMouseEvents)
        #expect(!overlay.controlPanel.ignoresMouseEvents && overlay.controlPanel.isVisible)
        #expect(!overlay.isRenderingLyrics)
        #expect(!overlay.panel.shouldDrag(at: dragPoint))
        overlay.refreshAppearance(at: outside)
        #expect(overlay.isRenderingLyrics && !overlay.controlPanel.isVisible)
        overlay.refreshAppearance(at: center)
        #expect(overlay.controlPanel.isVisible)
        model.setOverlayLocked(false)
        try await Task.sleep(for: .milliseconds(25))
        overlay.refreshAppearance(at: center)
        #expect(!overlay.panel.ignoresMouseEvents && overlay.panel.shouldDrag(at: dragPoint))
        #expect(overlay.isRenderingLyrics)
        #expect(overlay.controlsView.window === overlay.panel)
        #expect(!overlay.controlsView.isHidden && !overlay.controlPanel.isVisible)
        #expect(!overlay.panel.shouldDrag(at: NSPoint(x: overlay.panel.frame.width - 40, y: overlay.panel.frame.height - 20)))
        let originalFrame = overlay.panel.frame
        let originalControlRect = overlay.controlsView.convert(overlay.controlsView.bounds, to: nil)
        overlay.panel.onDragActivity?(true)
        // Assert visibility and fixed screen-relative geometry DURING every move,
        // including when the pointer sample falls outside during a fast drag.
        for step in 1...12 {
            let delta = NSPoint(x: Double(step) * 9, y: Double(step) * 4)
            overlay.panel.setFrameOrigin(NSPoint(x: originalFrame.minX + delta.x, y: originalFrame.minY + delta.y))
            overlay.refreshAppearance(at: outside)
            #expect(overlay.controlsView.window === overlay.panel)
            #expect(!overlay.controlsView.isHidden && overlay.controlsView.alphaValue == 1)
            #expect(!overlay.controlPanel.isVisible)
            let rect = overlay.panel.convertToScreen(overlay.controlsView.convert(overlay.controlsView.bounds, to: nil))
            #expect(rect.origin == NSPoint(x: originalFrame.minX + originalControlRect.minX + delta.x, y: originalFrame.minY + originalControlRect.minY + delta.y))
        }
        overlay.panel.onDragActivity?(false)
        overlay.refreshAppearance(at: NSPoint(x: overlay.panel.frame.midX, y: overlay.panel.frame.midY))
        #expect(!overlay.controlsView.isHidden && overlay.controlsView.window === overlay.panel)
        model.setOverlayClickThrough(true)
        try await Task.sleep(for: .milliseconds(25))
        overlay.refreshAppearance(at: NSPoint(x: overlay.panel.frame.midX, y: overlay.panel.frame.midY))
        #expect(overlay.controlsView.window === overlay.controlPanel)
        #expect(overlay.controlPanel.isVisible && !overlay.controlPanel.ignoresMouseEvents)
        #expect(overlay.panel.ignoresMouseEvents)
        prefs.overlayVisible = false
        try await Task.sleep(for: .milliseconds(25))
        #expect(!overlay.panel.isVisible && !overlay.controlPanel.isVisible)
    }

    @Test func overlayShowsSongTitleWhenLyricsAreUnavailable() async throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.hideWhenPaused = false
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        defer { model.stop() }
        let overlay = OverlayController(model: model, frameAutosaveName: nil)
        defer { overlay.stop() }
        #expect(!overlay.panel.isVisible)

        model.session.accept(.init(track: overlayTrack, position: 1, isPlaying: true), shouldSearch: false)
        model.session.use(overlayLyrics, persist: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(overlay.panel.isVisible)

        model.session.use(.init(title: "Overlay Song",
            lines: [.init(id: 0, time: 0, text: "Instrumental")], isInstrumental: true), persist: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(overlay.panel.isVisible)

        model.session.use(.init(title: "Overlay Song",
            lines: [.init(id: 0, time: 0, text: "   ")]), persist: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(overlay.panel.isVisible)
    }

    @Test func overlayPositionSurvivesControllerRecreation() throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        let autosaveName = "LyricsXTestOverlay-\(UUID().uuidString)"
        let first = OverlayController(model: model, frameAutosaveName: autosaveName)
        defer { first.stop(); model.stop() }
        let target = NSPoint(x: first.panel.frame.minX + 83, y: first.panel.frame.minY + 47)
        first.panel.setFrameOrigin(target)
        first.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: first.panel))
        let second = OverlayController(model: model, frameAutosaveName: autosaveName)
        defer { second.stop() }
        #expect(abs(second.panel.frame.minX - target.x) < 1)
        #expect(abs(second.panel.frame.minY - target.y) < 1)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")
        UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayPosition.\(autosaveName)")
        UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayCenter.\(autosaveName)")
    }

    @Test func compactCardAndTimedLyricsKeepCenterAndRestoreAfterEdgeClamping() async throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.fontSize = 42; prefs.overlayWidth = 600
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        model.session.accept(.init(track: overlayTrack, position: 10, isPlaying: true), shouldSearch: false)
        let name = "LyricsXTestOverlay-" + UUID().uuidString
        let overlay = OverlayController(model: model, frameAutosaveName: name)
        defer {
            overlay.stop(); model.stop()
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
            UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayPosition.\(name)")
        }
        let screen = try #require(NSScreen.main)
        let target = NSPoint(x: screen.visibleFrame.maxX - 404, y: screen.visibleFrame.minY + 100)
        overlay.panel.setFrameOrigin(target)
        let center = NSPoint(x: overlay.panel.frame.midX, y: overlay.panel.frame.midY)
        overlay.windowDidMove(.init(name: NSWindow.didMoveNotification, object: overlay.panel))
        for _ in 0..<3 {
            model.session.use(overlayLyrics, persist: false)
            try await Task.sleep(for: .milliseconds(25))
            #expect(!model.overlayUsesCompactPresentation && overlay.panel.frame.width == 600)
            #expect(overlay.panel.frame.maxX <= screen.visibleFrame.maxX)
            model.session.use(.init(plainText: "纯音乐，请欣赏"), persist: false)
            try await Task.sleep(for: .milliseconds(25))
            #expect(model.overlayUsesCompactPresentation && overlay.panel.frame.size == NSSize(width: 400, height: 108))
            #expect(overlay.panel.frame.origin == target)
            #expect(UserDefaults.standard.string(forKey: "LyricsX.OverlayPosition.\(name)") == NSStringFromPoint(target))
            #expect(UserDefaults.standard.string(forKey: "LyricsX.OverlayCenter.\(name)") == NSStringFromPoint(center))
        }
        UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayCenter.\(name)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_RENDER_QA"] != nil))
    func renderCompactCardForVisualInspection() async throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults); prefs.overlayVisible = true; prefs.hideWhenPaused = false
        prefs.overlayWidth = 400; prefs.hideOverlayOnHover = false
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        let track = Track(playerID: "test", playerName: "Test", title: "ATLAS RUSH", artist: "kanone")
        model.session.accept(.init(track: track, position: 0, isPlaying: false), shouldSearch: false)
        model.session.use(.init(plainText: "纯音乐，请欣赏"), persist: false)
        let overlay = OverlayController(model: model, frameAutosaveName: nil)
        defer { overlay.stop(); model.stop() }
        overlay.panel.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(350))
        let directory = try #require(ProcessInfo.processInfo.environment["LYRICSX_RENDER_QA"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(overlay.panel.windowNumber), directory + "/compact-overlay.png"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func overlayControlsKeepARecoverableDragState() throws {
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        prefs.hideOverlayOnHover = true
        model.setOverlayClickThrough(true)
        #expect(prefs.overlayClickThrough && prefs.overlayLocked)
        model.setOverlayClickThrough(false)
        #expect(!prefs.overlayClickThrough && prefs.overlayLocked)
        #expect(prefs.hideOverlayOnHover)
        model.setOverlayClickThrough(true)
        model.setOverlayLocked(false)
        #expect(!prefs.overlayClickThrough && !prefs.overlayLocked)
        model.setOverlayLocked(true)
        #expect(prefs.overlayLocked && !prefs.overlayClickThrough)
        model.setOverlayVisible(false)
        #expect(!prefs.overlayVisible && prefs.overlayLocked)
        model.setOverlayVisible(true)
        #expect(prefs.overlayVisible && prefs.overlayLocked)
        model.stop()
    }

    @Test func repeatedArtworkSamplesKeepTheDecodedImageAndTrackChangeClearsIt() throws {
        let model = AppModel(repository: EmptyRepository())
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let track = Track(playerID: "test", playerName: "Test", title: "A", artworkData: data)
        let snapshot = PlaybackSnapshot(track: track, position: 2, isPlaying: true)
        model.bridge.onSnapshot?(snapshot)
        let image = try #require(model.artwork)
        for _ in 0..<6 { model.bridge.onSnapshot?(snapshot); #expect(model.artwork === image) }
        model.bridge.onSnapshot?(.init(track: .init(playerID: "test", playerName: "Test", title: "B"), position: 0, isPlaying: true))
        #expect(model.artwork == nil)
        #expect(model.session.track?.title == "B")
        model.stop()
    }

    @Test func rejectedTransportGapDoesNotClearAcceptedTrackOrArtwork() throws {
        let model = AppModel(repository: EmptyRepository())
        defer { model.stop() }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let track = Track(playerID: "test", playerName: "Test", title: "A", artworkData: data)
        model.bridge.onSnapshot?(.init(track: track, position: 40, isPlaying: true))
        let image = try #require(model.artwork)
        let generation = model.session.searchGeneration
        model.bridge.onSnapshot?(.init(track: nil, position: 0, isPlaying: false, positionIsReliable: false, playbackStateIsReliable: false))
        #expect(model.artwork === image)
        #expect(model.session.track == track && model.session.searchGeneration == generation)
    }

    @Test func previewDataCannotReplaceTheProductionSession() {
        let model = AppModel(repository: EmptyRepository())
        model.bridge.onSnapshot?(.init(track: .init(playerID: "test", playerName: "Test", title: "Real song"), position: 10, isPlaying: true))
        let preview = LyricsPreviewView()
        _ = preview
        _ = DemoContent.document
        #expect(model.session.track?.title == "Real song")
        #expect(model.session.track?.playerID != "lyricsx.demo")
        model.stop()
    }

    @Test func menuAndOverlayPreferencesSurviveRelaunch() throws {
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.showMenuBarIcon = false
        prefs.showDockIcon = false
        prefs.showMenubarLyrics = true
        prefs.combinedMenubarLyrics = false
        prefs.translationFontSize = 19
        prefs.nextLineFontSize = 15
        prefs.overlaySecondaryMode = "both"
        prefs.setSource("Kugou", enabled: false)
        prefs.moveSource("NetEase", by: -1)
        #expect(prefs.moveSource("QQMusic", before: "LRCLIB"))
        #expect(!prefs.moveSource("Unknown", before: "LRCLIB"))
        prefs.preferBilingual = false
        prefs.preferWordTiming = false
        prefs.strictLyricsMatching = false
        let restored = Preferences(defaults: defaults)
        let liveConfiguration = prefs.sourceConfigurationReader.read()
        #expect(liveConfiguration.sourceOrder == prefs.sourceOrder)
        #expect(!liveConfiguration.preferBilingual && !liveConfiguration.preferWordTiming && !liveConfiguration.strictMatching)
        #expect(!liveConfiguration.enabled.contains("Kugou"))
        #expect(!restored.showDockIcon)
        #expect(!restored.showMenuBarIcon && restored.showMenubarLyrics && !restored.combinedMenubarLyrics)
        #expect(restored.translationFontSize == 19 && restored.nextLineFontSize == 15)
        #expect(restored.overlaySecondaryMode == "both")
        #expect(restored.sourceOrder == ["NetEase", "QQMusic", "LRCLIB", "Kugou", "Musixmatch"])
        #expect(!restored.preferBilingual && !restored.preferWordTiming && !restored.strictLyricsMatching && restored.disabledSources.contains("Kugou"))
    }
}
