import AppKit
import SwiftUI
import Testing
import LyricsXCore
@testable import LyricsXApp

private struct PendingOverlayRepository: LyricsRepository {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { _ in } }
    func save(_ document: LyricsDocument, for track: Track) async throws {}
}

@Suite @MainActor struct OverlayPresentationTests {
    private func fixture(_ run: (AppModel) throws -> Void) throws {
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: PendingOverlayRepository(), preferences: Preferences(defaults: defaults))
        defer { model.stop() }
        model.session.accept(.init(track: .init(playerID: "test", playerName: "Test", title: "First"), position: 2, isPlaying: false), shouldSearch: false)
        model.session.use(.init(lines: [.init(id: 0, time: 0, text: "First lyric")]), persist: false)
        try run(model)
    }

    @Test func cachedSongHandoverKeepsOneCoherentFrameAndSkipsLoadingCard() throws {
        try fixture { model in
            let presentation = OverlayPresentation(); defer { presentation.stop() }
            presentation.update(model: model, at: 10)
            model.session.accept(.init(track: .init(playerID: "test", playerName: "Test", title: "Second"), position: 0, isPlaying: true))
            presentation.update(model: model, at: 10.01)
            let held = try #require(presentation.held)
            #expect(held.track?.title == "First" && held.document?.lines.first?.text == "First lyric")
            #expect(!held.compact && !held.playing && held.position == 2)
            let newDocument = LyricsDocument(lines: [.init(id: 0, time: 0, text: "Second lyric")])
            model.session.use(newDocument, persist: false)
            presentation.update(model: model, at: 10.06)
            #expect(presentation.held == nil && presentation.preparingSince == nil)
            #expect(model.session.document?.id == newDocument.id && model.session.track?.title == "Second")
            presentation.finishIfDue(model: model, at: 20)
            #expect(presentation.held == nil && model.session.document?.id == newDocument.id)
        }
    }

    @Test func rapidSkipsKeepTheOriginalShortDeadlineAndSlowSearchReleasesIt() throws {
        try fixture { model in
            let presentation = OverlayPresentation(); defer { presentation.stop() }
            presentation.update(model: model, at: 10)
            for index in 0..<3 {
                model.session.accept(.init(track: .init(playerID: "test", playerName: "Test", title: "Skip \(index)"), position: 0, isPlaying: true))
                presentation.update(model: model, at: 10.01 + Double(index) * 0.05)
                #expect(presentation.preparingSince == 10.01)
            }
            presentation.finishIfDue(model: model, at: 10.16)
            #expect(presentation.held != nil)
            presentation.finishIfDue(model: model, at: 10.18)
            #expect(presentation.held == nil && model.session.track?.title == "Skip 2")
            presentation.update(model: model, at: 10.19)
            #expect(presentation.held == nil) // No repeated old-frame hold during a slow search.
        }
    }

    @Test func introEmptyLinesAndDotPlaceholdersUseTheCompactCard() throws {
        try fixture { model in
            let document = LyricsDocument(lines: [.init(id: 0, time: 5, text: "A real lyric"),
                .init(id: 1, time: 10, text: ""), .init(id: 2, time: 15, text: " ••• "),
                .init(id: 3, time: 20, text: "… …"), .init(id: 4, time: 25, text: "Wait...")])
            model.session.use(document, persist: false)
            for time in [0.0, 10, 15, 20] {
                model.session.seek(to: time)
                #expect(model.overlayUsesCompactPresentation)
            }
            for time in [5.0, 25] {
                model.session.seek(to: time)
                #expect(!model.overlayUsesCompactPresentation)
            }
        }
    }

    @Test func hiddenMainSelectionFreezesWhilePlaybackAndOverlayContinue() throws {
        try fixture { model in
            model.session.use(.init(lines: (0..<10).map { .init(id: $0, time: Double($0), text: "Line \($0)") }), persist: false)
            model.mainWindowVisible = true
            model.session.seek(to: 0); model.updateMainLyricSelection()
            #expect(model.mainLyricIndex == 0)
            model.mainWindowVisible = false
            for index in 1...8 {
                model.session.seek(to: Double(index)); model.updateMainLyricSelection()
                #expect(model.mainLyricIndex == 0 && model.session.currentLineIndex == index)
                #expect(!model.overlayUsesCompactPresentation)
            }
            model.mainWindowVisible = true
            #expect(model.mainLyricIndex == 8)
        }
    }

    @Test func compactArtworkAndTitleGroupAreCenteredInBothDirections() throws {
        try fixture { model in
            model.preferences.reduceMotion = true
            model.session.use(.init(plainText: "Instrumental"), persist: false)
            model.artwork = NSImage(size: .init(width: 64, height: 64), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill(); return true
            }
            for width in [320.0, 400.0, 620.0] {
                model.preferences.overlayWidth = width
                let cardWidth = min(400, width)
                let view = OverlayView(model: model, viewport: .init(width: cardWidth))
                    .frame(width: cardWidth, height: 108).background(.black)
                let renderer = ImageRenderer(content: view); renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                var left = bitmap.pixelsWide, right = 0, top = bitmap.pixelsHigh, bottom = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.5 {
                        left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    }
                }
                print("Compact ink: \(left)...\(right), \(top)...\(bottom), card=\(cardWidth)")
                #expect(abs(Double(left + right) / 2 - cardWidth / 2) <= 2)
                #expect(abs(Double(top + bottom) / 2 - 54) <= 2)
            }
        }
    }
}

@Test func windowRenderingStopsBeforeMinimizingAndRestartsWhenShown() {
    var main = WindowRenderActivity(), overlay = WindowRenderActivity()
    #expect(main.update(event: nil, visible: true, miniaturized: false, exposed: true) == true)
    #expect(main.update(event: NSWindow.willMiniaturizeNotification, visible: true, miniaturized: false, exposed: true) == false)
    #expect(main.update(event: NSWindow.didChangeOcclusionStateNotification, visible: true, miniaturized: false, exposed: true) == false)
    #expect(overlay.update(event: nil, visible: true, miniaturized: false, exposed: true) == true)
    #expect(main.update(event: NSWindow.didMiniaturizeNotification, visible: true, miniaturized: true, exposed: false) == false)
    #expect(main.update(event: NSWindow.didDeminiaturizeNotification, visible: true, miniaturized: false, exposed: true) == true)
    #expect(main.update(event: NSWindow.willCloseNotification, visible: true, miniaturized: false, exposed: true) == false)
    #expect(main.update(event: nil, visible: false, miniaturized: false, exposed: false) == false)
    #expect(main.update(event: NSWindow.didBecomeKeyNotification, visible: true, miniaturized: false, exposed: true) == true)
}
