import Foundation
import Testing
import LyricsXCore
@testable import LyricsXServices

private let romanTrack = Track(playerID: "test", playerName: "", title: "Sekai-Chan and Kafu-Chan's Otsukai Gassoukyoku", artist: "Minami no Minami", duration: 205)
private let nativeTitle = "星界ちゃんと可不ちゃんのおつかい合騒曲"
private let nativeArtist = "南ノ南"
private let seedJSON = #"{"results":[{"trackId":123,"artistId":456,"trackName":"Sekai-Chan and Kafu-Chan's Otsukai Gassoukyoku","artistName":"Minami no Minami","trackTimeMillis":205000}]}"#
private let aliasJSON = #"{"results":[{"trackId":123,"artistId":456,"trackName":"星界ちゃんと可不ちゃんのおつかい合騒曲","artistName":"南ノ南","trackTimeMillis":205000}]}"#

private func fixtureResolver() -> TrackAliasResolver {
    TrackAliasResolver { request in Data((request.url?.path == "/search" ? seedJSON : aliasJSON).utf8) }
}
private func emptyResolver() -> TrackAliasResolver { TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) } }
private func temporaryCache() -> LyricsCache { LyricsCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
private func nativeDocument(translation: String? = nil, words: Bool = false, artist: String = nativeArtist) -> LyricsDocument {
    .init(title: nativeTitle, artist: artist, source: "NetEase", duration: 160,
          lines: [.init(id: 0, time: 0, text: "届けよう", translation: translation,
                        words: words ? [.init(text: "届け", start: 0, end: 1), .init(text: "よう", start: 1, end: 2)] : [])])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_LIVE_SOURCES"] == "1"))
func liveRomanizedSongResolvesAndSearchesNativeTitle() async throws {
    let store = LyricsStore(cache: temporaryCache())
    let started = ContinuousClock.now
    var results: [LyricCandidate] = []
    for try await result in store.lyrics(for: romanTrack, forceRefresh: true) { results.append(result) }
    print("LIVE_ALIAS_SEARCH results=\(results.count) elapsed=\(started.duration(to: .now)) sources=\(Set(results.map { $0.document.source }).sorted())")
    #expect(!results.isEmpty)
    #expect(results.contains { $0.document.title.contains("星界") })
}

@Test func automaticSearchFindsNativeAliasAndKeepsWordAndBilingualPriorities() async throws {
    let store = LyricsStore(cache: temporaryCache(), aliasResolver: fixtureResolver()) { track, _, _, _ in
        .init { stream in
            if track.title == nativeTitle {
                stream.yield(nativeDocument())
                stream.yield(nativeDocument(translation: "送达吧"))
                stream.yield(nativeDocument(translation: "送达吧", words: true))
            }
            stream.finish()
        }
    }
    var results: [LyricCandidate] = []
    for try await result in store.lyrics(for: romanTrack, forceRefresh: true) { results.append(result) }
    #expect(results.count == 3) // repeated title-only queries are deduplicated
    let best = try #require(results.first)
    #expect(best.document.hasTranslation && best.document.hasWordTiming && best.score >= 60)
    #expect(best.document.duration == 160) // an early lyric ending is accepted
}

@Test func aliasesRescoreResultsThatArrivedBeforeCatalogLookup() async throws {
    let store = LyricsStore(cache: temporaryCache(), aliasResolver: fixtureResolver()) { _, _, _, _ in
        .init { $0.yield(nativeDocument()); $0.finish() }
    }
    var results: [LyricCandidate] = []
    for try await result in store.lyrics(for: romanTrack, forceRefresh: true) { results.append(result) }
    #expect(results.count == 1 && results.first?.score ?? 0 >= 60)
}

@Test func titleOnlyAutomaticQueryReachesResultsAvailableInManualSearch() async throws {
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer", duration: 200)
    let store = LyricsStore(cache: temporaryCache(), aliasResolver: emptyResolver()) { _, keyword, _, _ in
        .init { stream in
            if keyword == "Song" { stream.yield(.init(title: "Song", artist: "Singer", duration: 120, lines: [.init(id: 0, time: 0, text: "Hello")])) }
            stream.finish()
        }
    }
    var automatic: [LyricCandidate] = [], manual: [LyricCandidate] = []
    for try await value in store.lyrics(for: track, forceRefresh: true) { automatic.append(value) }
    for try await value in store.search(track: track, keyword: "Song") { manual.append(value) }
    #expect(automatic.count == 1 && manual.count == 1)
}

@Test func sharedDeadlineReturnsBufferedLyricsFromAStreamThatNeverFinishes() async throws {
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let store = LyricsStore(cache: temporaryCache(), aliasResolver: emptyResolver(), searchBudget: .milliseconds(80)) { _, _, _, _ in
        .init { $0.yield(.init(title: "Song", artist: "Singer", lines: [.init(id: 0, time: 0, text: "Hello")])) }
    }
    var results: [LyricCandidate] = []
    for try await value in store.lyrics(for: track, forceRefresh: true) { results.append(value) }
    #expect(results.count == 1)
}

@Test func failingProviderDoesNotDiscardLyricsItAlreadyYielded() async throws {
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let store = LyricsStore(cache: temporaryCache(), aliasResolver: emptyResolver()) { _, _, _, _ in
        .init { stream in
            stream.yield(.init(title: "Song", artist: "Singer", lines: [.init(id: 0, time: 0, text: "Hello")]))
            stream.finish(throwing: URLError(.networkConnectionLost))
        }
    }
    var count = 0
    for try await _ in store.lyrics(for: track, forceRefresh: true) { count += 1 }
    #expect(count == 1)
}

@Test func aliasMustReferToSameCatalogSongAndArtist() throws {
    let seed = TrackAliasResolver.Record(trackId: 1, artistId: 2, trackName: "Song", artistName: "Singer", trackTimeMillis: 180000)
    var alias = seed; alias.trackName = "歌曲"; alias.artistName = "歌手"
    #expect(TrackAliasResolver.isSameRecording(alias, seed: seed))
    alias.trackId = 3; #expect(!TrackAliasResolver.isSameRecording(alias, seed: seed))
    alias.trackId = 1; alias.artistId = 4; #expect(!TrackAliasResolver.isSameRecording(alias, seed: seed))
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer", duration: 172)
    #expect(TrackAliasResolver.isSeed(seed, for: track)) // near full-song durations
}

@Test func scriptAndDiacriticEquivalenceIsNotLimitedToJapanese() {
    #expect(CandidateRanker.equivalent("Привет", "Privet"))
    #expect(CandidateRanker.equivalent("안녕", "annyeong"))
    #expect(CandidateRanker.equivalent("Été", "Ete"))
    #expect(!CandidateRanker.equivalent("One Song", "Another Song"))
    let config = SourceConfiguration()
    #expect(config.bestScore(nativeDocument(artist: "別の歌手"), for: romanTrack) == 0)
}

@Test func relaxedMatchingStillHonorsBothPreferences() {
    var config = SourceConfiguration(); config.strictMatching = false
    let track = Track(playerID: "test", playerName: "", title: nativeTitle, artist: "Unknown Singer")
    let plain = nativeDocument(artist: "")
    let bilingual = nativeDocument(translation: "送达吧", artist: "")
    let word = nativeDocument(words: true, artist: "")
    #expect(config.bestScore(word, for: track) > config.bestScore(bilingual, for: track))
    #expect(config.bestScore(bilingual, for: track) > config.bestScore(plain, for: track))
    config.preferWordTiming = false
    #expect(config.bestScore(bilingual, for: track) > config.bestScore(word, for: track))
    config.preferBilingual = false
    #expect(config.bestScore(bilingual, for: track) == config.bestScore(plain, for: track))
}

@Test func bilingualAndWordTagsRejectDuplicateTextAndMalformedTimings() {
    func document(_ line: LyricLine) -> LyricsDocument { .init(lines: [line]) }
    for text in [" HELLO！", "hello\nHello.", "♪", "  "] {
        #expect(!document(.init(id: 0, time: 0, text: "Hello", translation: text)).hasTranslation)
    }
    #expect(document(.init(id: 0, time: 0, text: "Hello", translation: "Hello\n你好")).hasTranslation)
    var line = LyricLine(id: 0, time: 0, text: "Hello", words: [.init(text: "Hello", start: 0, end: 2)])
    #expect(!document(line).hasWordTiming)
    line.words = [.init(text: "Hel", start: 0, end: 1), .init(text: "lo", start: 1, end: 2)]
    #expect(document(line).hasWordTiming)
    line.words[1].end = 1; #expect(!document(line).hasWordTiming)
    line.words[1].end = .infinity; #expect(!document(line).hasWordTiming)
    line.words[1].end = 2; line.words[1].start = 0; #expect(!document(line).hasWordTiming)
    line.words[1].start = 1; line.words[1].text = "Wrong"; #expect(!document(line).hasWordTiming)
}

@Test func romanizationAttachmentIsNotMistakenForBilingualTranslation() throws {
    let romanization = try LyricsCodec.parse("[00:01]こんにちは\n[00:01][ro]konnichiwa")
    #expect(!romanization.hasTranslation && !romanization.hasWordTiming)
    let bilingual = try LyricsCodec.parse("[00:01]こんにちは\n[00:01][tr:zh-Hans]你好")
    #expect(bilingual.hasTranslation)
}

@Test func decoratedTitlesAndCollaboratingArtistsMatchWithoutMixingRemixes() {
    let track = Track(playerID: "test", playerName: "", title: "雪降り ~ 雪が降っている ~ (feat. 結月ゆかり) [Full Ver.]",
                      artist: "AiSS & NE1516Hz", duration: 222)
    let document = LyricsDocument(title: "雪降り ~雪が降っている~", artist: "NE1516Hz/结月缘", duration: 0,
                                  lines: [.init(id: 0, time: 20, text: "Original", translation: "译文")])
    #expect(SourceConfiguration().selectionScore(document, for: track) >= 60)
    #expect(TrackSearchText.titles(track.title).contains("雪降り"))
    #expect(TrackSearchText.titles(track.title).contains("雪が降っている"))
    #expect(!CandidateRanker.equivalentTitle("Song (Remix)", "Song"))
    #expect(!CandidateRanker.equivalentTitle("Song (English Cover)", "Song"))
}

@Test func coListedArtistAliasesRescueWordAndBilingualVersionsAndRejectCovers() async throws {
    let track = Track(playerID: "test", playerName: "", title: "DaiDaiDaiDaiDaikirai", artist: "amala", duration: 157)
    let evidence = LyricsDocument(title: track.title, artist: "雨良 Amala", source: "LRCLIB", duration: 157,
                                  lines: [.init(id: 0, time: 0, text: "歌詞")])
    let native = LyricsDocument(title: "ダイダイダイダイダイキライ", artist: "雨良", source: "QQMusic",
                               lines: [.init(id: 0, time: 0, text: "歌詞", translation: "歌词", words: [.init(text: "歌", start: 0, end: 1), .init(text: "詞", start: 1, end: 2)])])
    let store = LyricsStore(cache: temporaryCache(), aliasResolver: emptyResolver()) { query, _, _, _ in
        .init { stream in
            stream.yield(native) // the better lyric can arrive before the name evidence
            if query.artist == "amala" { stream.yield(evidence) }
            stream.finish()
        }
    }
    var results: [LyricCandidate] = []
    for try await value in store.lyrics(for: track, forceRefresh: true) { results.append(value) }
    #expect(results.first?.document.source == "QQMusic")
    #expect(results.first?.document.hasTranslation == true && results.first?.document.hasWordTiming == true)
    var collaboration = evidence; collaboration.artist = "雨良 & Amala"
    #expect(ArtistAliasEvidence.aliases(in: collaboration, for: track).isEmpty)
    collaboration.artist = "雨良 feat. Amala"
    #expect(ArtistAliasEvidence.aliases(in: collaboration, for: track).isEmpty)
    var cover = native; cover.artist = "JubyPhonic/Rachie"
    #expect(SourceConfiguration().bestScore(cover, for: track, aliases: ArtistAliasEvidence.aliases(in: evidence, for: track)) == 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_LIVE_REPORTED_SONGS"] == "1"))
func liveReportedSongsAutomaticallyChooseBilingualWordLyricsWithoutCache() async throws {
    let tracks = [
        Track(playerID: "test", playerName: "", title: "DaiDaiDaiDaiDaikirai", artist: "amala", duration: 157),
        Track(playerID: "test", playerName: "", title: "雪降り ~ 雪が降っている ~ (feat. 結月ゆかり) [Full Ver.]", artist: "AiSS & NE1516Hz", duration: 222)
    ]
    for track in tracks {
        let store = LyricsStore(cache: temporaryCache(), configuration: {
            var config = SourceConfiguration()
            config.sourceOrder = ["Kugou", "NetEase", "QQMusic", "LRCLIB", "Musixmatch"]
            config.strictMatching = false
            return config
        })
        var results: [LyricCandidate] = []
        for try await result in store.lyrics(for: track, forceRefresh: true) { results.append(result) }
        let best = try #require(results.first)
        print("LIVE_AUTOMATIC_WINNER query=\(track.title) title=\(best.document.title) source=\(best.document.source) bilingual=\(best.document.hasTranslation) word=\(best.document.hasWordTiming) candidates=\(results.count)")
        #expect(best.document.hasTranslation && best.document.hasWordTiming)
        #expect(best.document.source != "LRCLIB")
    }
}

@Test func shortPlaceholderMatchingProtectsRealLyricsAndPlainText() {
    for phrase in ["纯音乐，请欣赏", "纯音乐\n请欣赏", "此歌曲为没有填词的纯音乐，请您欣赏", "此歌曲為沒有填詞的純音樂，請您欣賞", "No lyrics available", "歌詞なし", "가사 없음", "Без слов"] {
        #expect(LyricsDocument(plainText: phrase).isLikelyInstrumentalPlaceholder)
        #expect(LyricsDocument(lines: [.init(id: 0, time: 0, text: phrase)]).isLikelyInstrumentalPlaceholder)
    }
    for text in ["I have no lyrics left to sing", "纯音乐陪我度过每一天", "Hello\nGoodbye", "纯音乐，请欣赏\nThis is a real lyric", "纯音乐\n纯音乐\n纯音乐\n纯音乐"] {
        #expect(!LyricsDocument(plainText: text).isLikelyInstrumentalPlaceholder)
    }
}
