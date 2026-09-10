import Foundation
import Testing
import LyricsXCore
@testable import LyricsXServices

private let rankingTrack = Track(playerID: "test", playerName: "", title: "Song", artist: "Artist", duration: 180)
private func version(_ source: String, translation: String? = nil) -> LyricsDocument {
    .init(title: "Song", artist: "Artist", source: source, duration: 180,
          lines: [.init(id: 0, time: 1, text: "Hello", translation: translation)])
}

@Test func sourceOrderIsNormalizedWithoutLosingDisabledOrNewSources() {
    #expect(SourceConfiguration.normalizedOrder(["QQMusic", "Unknown", "QQMusic", "NetEase"]) == ["QQMusic", "NetEase", "LRCLIB", "Kugou", "Musixmatch"])
}

@Test func sourcePriorityAndBilingualPreferenceChangeTheWinner() {
    var config = SourceConfiguration()
    let plain = version("LRCLIB")
    let bilingual = version("NetEase", translation: "你好")
    #expect(config.selectionScore(bilingual, for: rankingTrack) > config.selectionScore(plain, for: rankingTrack))
    config.preferBilingual = false
    #expect(config.selectionScore(plain, for: rankingTrack) > config.selectionScore(bilingual, for: rankingTrack))
    config.sourceOrder = ["NetEase", "LRCLIB"]
    #expect(config.selectionScore(bilingual, for: rankingTrack) > config.selectionScore(plain, for: rankingTrack))
}

@Test func sourcePreferencesDoNotPromoteWrongSongsOrLoseSynchronization() {
    let config = SourceConfiguration()
    var wrong = version("LRCLIB", translation: "你好")
    wrong.artist = "Someone Else"; wrong.title = "Unrelated"
    #expect(config.selectionScore(wrong, for: rankingTrack) == 0)
    wrong = version("LRCLIB", translation: "你好"); wrong.duration = 250
    #expect(config.selectionScore(wrong, for: rankingTrack) == 0)
    let plain = LyricsDocument(title: "Song", artist: "Artist", source: "LRCLIB", duration: 180, plainText: "Hello")
    let timed = version("Musixmatch")
    #expect(config.selectionScore(timed, for: rankingTrack) > config.selectionScore(plain, for: rankingTrack))
    var partial = version("LRCLIB", translation: "你好"); partial.title = "Song Live"
    #expect(config.selectionScore(timed, for: rankingTrack) > config.selectionScore(partial, for: rankingTrack))
    #expect(config.selectionScore(version("LRCLIB", translation: "你好"), for: rankingTrack) < 999)
}

@Test func exactMetadataCanFallbackWhenProviderDurationIsStale() {
    let config = SourceConfiguration()
    var staleDuration = version("NetEase", translation: "你好")
    staleDuration.duration = 999
    #expect(config.selectionScore(staleDuration, for: rankingTrack) == 0)
    #expect(config.fallbackSelectionScore(staleDuration, for: rankingTrack) != nil)
    staleDuration.artist = "Someone Else"
    #expect(config.fallbackSelectionScore(staleDuration, for: rankingTrack) == nil)
}

@Test func relaxedMatchingCanRecoverSynchronizedLyricsWithIncompleteProviderMetadata() {
    var config = SourceConfiguration()
    var incomplete = version("NetEase", translation: "你好")
    incomplete.artist = ""
    incomplete.duration = 999
    #expect(config.selectionScore(incomplete, for: rankingTrack) == 0)
    #expect(config.fallbackSelectionScore(incomplete, for: rankingTrack) == nil)
    #expect(config.relaxedSelectionScore(incomplete, for: rankingTrack) == nil)

    config.strictMatching = false
    #expect(config.relaxedSelectionScore(incomplete, for: rankingTrack) != nil)
    incomplete.title = "Song Live"
    #expect(config.relaxedSelectionScore(incomplete, for: rankingTrack) == nil)
    incomplete.artist = "Artist"
    #expect(config.relaxedSelectionScore(incomplete, for: rankingTrack) != nil)
}

@Test func blankAndDuplicateTranslationsDoNotCountAsBilingual() {
    #expect(!version("NetEase", translation: " \n ").hasTranslation)
    #expect(!version("NetEase", translation: "Hello").hasTranslation)
    #expect(version("NetEase", translation: "你好").hasTranslation)
}

private struct RankedFixtureRepository: LyricsRepository {
    let values: [LyricCandidate]
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> {
        .init { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }
    func save(_ document: LyricsDocument, for track: Track) async throws { }
}

@Test @MainActor func bestSourceWinsRegardlessOfResponseOrder() async throws {
    let config = SourceConfiguration()
    let docs = [version("LRCLIB"), version("NetEase", translation: "你好"), version("QQMusic")]
    let values = docs.map { LyricCandidate(document: $0, score: config.selectionScore($0, for: rankingTrack)) }
    for order in [values, Array(values.reversed())] {
        let session = LyricsSession(repository: RankedFixtureRepository(values: order))
        session.accept(.init(track: rankingTrack, position: 0, isPlaying: false))
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while session.candidates.count < order.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.document?.source == "NetEase")
        #expect(session.candidates.first?.document.source == "NetEase")
        session.stop()
    }
}

@Test @MainActor func applyingAnotherVersionAutomaticallyReplacesTheOriginalCacheFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("Song - Artist.lrc")
    try "[00:01]Old version".write(to: path, atomically: true, encoding: .utf8)
    let store = LyricsStore(cache: LyricsCache(directory: directory))
    let session = LyricsSession(repository: store)
    // Skip the initial cache read/search, then exercise the same use() action
    // invoked by the search result button. The save must find the old .lrc itself.
    session.accept(.init(track: rankingTrack, position: 0, isPlaying: false), shouldSearch: false)
    session.use(version("NetEase", translation: "你好"))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while (try LyricsCodec.read(path)).lines.first?.text != "Hello", ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let freshCache = LyricsCache(directory: directory)
    let restored = try #require(await freshCache.load(for: rankingTrack))
    #expect(restored.lines.first?.text == "Hello" && restored.hasTranslation)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Song - Artist.lrc"])
    #expect(session.persistenceError == nil)
    session.stop()
}
