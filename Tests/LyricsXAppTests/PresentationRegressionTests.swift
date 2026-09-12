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
        UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayTop.\(autosaveName)")
    }

    @Test func compactCardAndTimedLyricsKeepTopAndRestoreAfterEdgeClamping() async throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.fontSize = 42; prefs.overlayWidth = 600
        prefs.overlayAdaptiveSize = false; prefs.reduceMotion = true
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
        let target = NSPoint(x: screen.visibleFrame.maxX - 604, y: screen.visibleFrame.minY + 100)
        overlay.panel.setFrameOrigin(target)
        let top = NSPoint(x: overlay.panel.frame.midX, y: overlay.panel.frame.maxY)
        overlay.windowDidMove(.init(name: NSWindow.didMoveNotification, object: overlay.panel))
        for _ in 0..<3 {
            model.session.use(overlayLyrics, persist: false)
            try await Task.sleep(for: .milliseconds(25))
            #expect(!model.overlayUsesCompactPresentation && overlay.panel.frame.width == 600)
            #expect(overlay.panel.frame.maxX <= screen.visibleFrame.maxX)
            model.session.use(.init(plainText: "纯音乐，请欣赏"), persist: false)
            try await Task.sleep(for: .milliseconds(25))
            #expect(model.overlayUsesCompactPresentation && overlay.panel.frame.size == NSSize(width: 600, height: OverlaySongCardLayout(width: 600).height))
            #expect(overlay.panel.frame.origin == target)
            #expect(UserDefaults.standard.string(forKey: "LyricsX.OverlayPosition.\(name)") == NSStringFromPoint(target))
            #expect(UserDefaults.standard.string(forKey: "LyricsX.OverlayTop.\(name)") == NSStringFromPoint(top))
        }
        UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayCenter.\(name)")
        UserDefaults.standard.removeObject(forKey: "LyricsX.OverlayTop.\(name)")
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_CONTROL_QA"] != nil))
    func renderControlsOverLightAndDarkBackgrounds() async throws {
        _ = NSApplication.shared
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.overlayVisible = true; prefs.hideWhenPaused = false; prefs.hideOverlayOnHover = false
        prefs.reduceMotion = false; prefs.overlayTransparency = 0.6
        let model = AppModel(repository: EmptyRepository(), preferences: prefs)
        model.session.accept(.init(track: overlayTrack, position: 1, isPlaying: false), shouldSearch: false)
        model.session.use(LyricsDocument(title: overlayTrack.title, artist: overlayTrack.artist,
            lines: [.init(id: 0, time: 0, text: "Light moves through the glass", translation: "光线穿过玻璃",
                          words: [.init(text: "Light", start: 0, end: 3)]),
                    .init(id: 1, time: 20, text: "And the words stay clear")]), persist: false)
        let overlay = OverlayController(model: model, frameAutosaveName: nil)
        defer { overlay.stop(); model.stop() }
        overlay.panel.onDragActivity?(true)
        let directory = try #require(ProcessInfo.processInfo.environment["LYRICSX_CONTROL_QA"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/qa/glass-backdrop.swift")
        let executable = directory + "/glass-backdrop"
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compiler.arguments = [fixture.path, "-o", executable]
        try compiler.run(); compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let examples = OverlayAppearance.allCases.flatMap { appearance in
            ["light", "dark", "color"].map { (appearance, $0, 0.6) }
                + [0.2, 0.8].flatMap { transparency in ["light", "text"].map { (appearance, $0, transparency) } }
        }
        for hdr in [false, true] {
            prefs.lyricHDR = hdr
            for (appearance, surface, transparency) in examples {
                prefs.overlayAppearance = appearance
                prefs.overlayTransparency = transparency
                let dark = surface == "dark"
                overlay.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                overlay.controlPanel.appearance = overlay.panel.appearance
                let frame = overlay.panel.frame.insetBy(dx: -20, dy: -20)
                let ready = directory + "/" + UUID().uuidString + ".ready"
                let backdrop = Process(); backdrop.executableURL = URL(fileURLWithPath: executable)
                backdrop.arguments = [frame.minX, frame.minY, frame.width, frame.height].map { String(Double($0)) }
                    + [surface, ready]
                try backdrop.run()
                defer {
                    if backdrop.isRunning { backdrop.terminate() }
                    backdrop.waitUntilExit()
                    try? FileManager.default.removeItem(atPath: ready)
                }
                // Readiness is bounded and yields the main actor for native drawing.
                for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(FileManager.default.fileExists(atPath: ready))
                overlay.panel.orderFrontRegardless()
                for detached in [false, true] {
                    model.setOverlayClickThrough(detached)
                    try await Task.sleep(for: .milliseconds(100))
                    overlay.refreshAppearance(at: NSPoint(x: overlay.panel.frame.midX, y: overlay.panel.frame.midY))
                    try await Task.sleep(for: .milliseconds(500))
                    let window = detached ? overlay.controlPanel : overlay.panel
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    let name = "controls-\(appearance.rawValue)-\(surface)-\(Int((transparency * 100).rounded()))-\(hdr ? "hdr" : "sdr")-\(detached ? "detached" : "inline").png"
                    // Capture different processes together, including real EDR
                    // compositing. Isolated window captures can replace glass with grey.
                    let frame = window.frame
                    let top = (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY
                    let region = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
                    process.arguments = ["-x", "-R", region, directory + "/" + name]
                    try process.run(); process.waitUntilExit()
                    #expect(process.terminationStatus == 0)
                }
            }
        }
        // Measure fine background detail away from the foreground lyrics. A
        // successful screenshot alone cannot detect an opaque grey fallback.
        func backgroundDetail(_ style: String, _ range: String) throws -> Double {
            let path = directory + "/controls-\(style)-text-80-\(range)-inline.png"
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
            let scale = Double(bitmap.pixelsWide) / overlay.panel.frame.width
            var energy = 0.0, samples = 0.0
            for y in Int(78 * scale)..<Int(120 * scale) {
                for x in Int(32 * scale)..<Int(110 * scale) {
                    let first = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let next = try #require(bitmap.colorAt(x: x + 1, y: y)?.usingColorSpace(.deviceRGB))
                    energy += abs(first.redComponent - next.redComponent)
                    samples += 1
                }
            }
            return energy / samples
        }
        for range in ["sdr", "hdr"] {
            let clear = try backgroundDetail("glass", range)
            let frosted = try backgroundDetail("frosted", range)
            #expect(clear > 0.015)
            #expect(clear > frosted * 3 + 0.005)
        }
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
        let preview = LyricsPreviewView(preferences: model.preferences)
        _ = preview
        _ = DemoContent.document
        #expect(model.session.track?.title == "Real song")
        #expect(model.session.track?.playerID != "lyricsx.demo")
        model.stop()
    }

    @Test func legacyMaterialSettingsMigrateOnceAndRespectNewTransparency() throws {
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (oldStyle, expectedStyle) in [("native", OverlayAppearance.glass), ("glass", .glass), ("dark", .frosted)] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(oldStyle, forKey: "overlayAppearance")
            defaults.set(0.28, forKey: "overlayBackgroundStrength")
            let migrated = Preferences(defaults: defaults)
            #expect(migrated.overlayAppearance == expectedStyle)
            #expect(abs(migrated.overlayTransparency - 0.72) < 0.001)
            migrated.overlayTransparency = 0.42
            let restored = Preferences(defaults: defaults)
            #expect(restored.overlayAppearance == expectedStyle)
            #expect(restored.overlayTransparency == 0.42)
        }
        defaults.set(0.95, forKey: "overlayTransparency")
        #expect(Preferences(defaults: defaults).overlayTransparency == 0.8)
        defaults.set(-0.5, forKey: "overlayTransparency")
        #expect(Preferences(defaults: defaults).overlayTransparency == 0.2)
    }

    @Test func menuAndOverlayPreferencesSurviveRelaunch() throws {
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.showMenuBarIcon = false
        #expect(prefs.overlayAppearance == .glass)
        prefs.overlayAppearance = .frosted
        prefs.overlayTransparency = 0.34
        prefs.showDockIcon = false
        prefs.showMenubarLyrics = true
        prefs.combinedMenubarLyrics = false
        prefs.translationFontSize = 19
        prefs.nextLineFontSize = 15
        prefs.overlaySecondaryMode = .both
        prefs.setSource("Kugou", enabled: false)
        prefs.moveSource("NetEase", by: -1)
        #expect(prefs.moveSource("QQMusic", before: "LRCLIB"))
        #expect(!prefs.moveSource("Unknown", before: "LRCLIB"))
        prefs.preferBilingual = false
        prefs.preferWordTiming = false
        prefs.strictLyricsMatching = false
        let restored = Preferences(defaults: defaults)
        #expect(restored.overlayAppearance == .frosted && restored.overlayTransparency == 0.34)
        let liveConfiguration = prefs.sourceConfigurationReader.read()
        #expect(liveConfiguration.sourceOrder == prefs.sourceOrder)
        #expect(!liveConfiguration.preferBilingual && !liveConfiguration.preferWordTiming && !liveConfiguration.strictMatching)
        #expect(!liveConfiguration.enabled.contains("Kugou"))
        #expect(!restored.showDockIcon)
        #expect(!restored.showMenuBarIcon && restored.showMenubarLyrics && !restored.combinedMenubarLyrics)
        #expect(restored.translationFontSize == 19 && restored.nextLineFontSize == 15)
        #expect(restored.overlaySecondaryMode == .both)
        #expect(restored.sourceOrder == ["NetEase", "QQMusic", "LRCLIB", "Kugou", "Musixmatch"])
        #expect(!restored.preferBilingual && !restored.preferWordTiming && !restored.strictLyricsMatching && restored.disabledSources.contains("Kugou"))
    }
}
