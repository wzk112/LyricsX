import Foundation
import Testing
import LyricsXCore
@testable import LyricsXApp

@Test func auxiliaryModesDistinguishOnlyFallbackAndBoth() {
    let translation = "翻译", next = "Next line"
    #expect(OverlaySecondaryMode.translation.content(translation: translation, next: next) == .init(translation: translation))
    #expect(OverlaySecondaryMode.translation.content(translation: nil, next: next) == .init())
    #expect(OverlaySecondaryMode.next.content(translation: translation, next: next) == .init(next: next))
    #expect(OverlaySecondaryMode.either.content(translation: translation, next: next) == .init(translation: translation))
    #expect(OverlaySecondaryMode.either.content(translation: " \n ", next: next) == .init(next: next))
    #expect(OverlaySecondaryMode.either.content(translation: nil, next: nil) == .init())
    #expect(OverlaySecondaryMode.both.content(translation: translation, next: next) == .init(translation: translation, next: next))
    #expect(OverlaySecondaryMode.both.content(translation: translation, next: "") == .init(translation: translation))
    #expect(OverlaySecondaryMode.none.content(translation: translation, next: next) == .init())
}

@Test @MainActor func auxiliaryModePersistsAndKeepsLegacyChoices() throws {
    let suite = "LyricsXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for mode in OverlaySecondaryMode.allCases {
        let prefs = Preferences(defaults: defaults)
        prefs.overlaySecondaryMode = mode
        #expect(Preferences(defaults: defaults).overlaySecondaryMode == mode)
        #expect(defaults.string(forKey: "overlaySecondaryMode") == mode.rawValue)
    }
    defaults.set("unknown", forKey: "overlaySecondaryMode")
    #expect(Preferences(defaults: defaults).overlaySecondaryMode == .translation)
    #expect(OverlaySecondaryMode.either.reservedHeight(translationSize: 13, nextSize: 24, primarySpacing: 12, secondarySpacing: 8) == 24 * 1.4 + 12)
}

private struct AuxiliaryFixtureRepository: LyricsRepository {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { $0.finish() } }
    func save(_ document: LyricsDocument, for track: Track) async throws { }
}

@Test @MainActor func cachedDocumentTraitsFollowReplacementAndClearing() {
    let session = LyricsSession(repository: AuxiliaryFixtureRepository())
    let track = Track(playerID: "test", playerName: "", title: "Song")
    session.accept(.init(track: track, position: 0, isPlaying: false), shouldSearch: false)
    var document = LyricsDocument(lines: [.init(id: 0, time: 0, text: "Hello", words: [.init(text: "Hello", start: 0, end: 1)])])
    session.use(document, persist: false)
    #expect(session.documentHasWordTiming && !session.documentIsPlaceholder)
    // The same UUID can acquire new contents; update flags on assignment, not ID.
    document.lines = [.init(id: 0, time: 0, text: "纯音乐，请欣赏")]
    session.use(document, persist: false)
    #expect(!session.documentHasWordTiming && session.documentIsPlaceholder)
    session.suppressLyrics()
    #expect(!session.documentHasWordTiming && !session.documentIsPlaceholder)
    session.stop()
}
