import Foundation
import Testing
import LyricsXCore
@testable import LyricsXServices

private func checkpointFixture(word: Bool = false) throws -> LyricsDocument {
    try LyricsCodec.parse("[ti:Song]\n[ar:Singer]\n[00:01]Hello world\n[00:01][tr]你好世界" +
        (word ? "\n[00:01][tt]<0,0><500,6><1000,11><1000>" : ""), source: "Kugou")
}
private func checkpointConfig() -> SourceConfiguration {
    var value = SourceConfiguration(); value.enabled = ["Kugou"]; value.sourceOrder = ["Kugou"]
    return value
}
private actor CheckpointGate {
    var opened = false
    func release() { opened = true }
    func wait() async throws {
        while !opened { try await Task.sleep(for: .milliseconds(2)) }
    }
}

@Test @MainActor func switchingAwayAndBackRestoresUnfinishedLyricsThenUpgrades() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = LyricsCache(directory: directory), gate = CheckpointGate()
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let first = try checkpointFixture(), better = try checkpointFixture(word: true)
    let store = LyricsStore(cache: cache, configuration: checkpointConfig,
                            aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }, firstResultDelay: .milliseconds(5)) { track, _, _, _ in
        .init { stream in
            let task = Task {
                guard track.title == "Song" else { stream.finish(); return }
                stream.yield(first)
                do { try await gate.wait(); stream.yield(better); stream.finish() }
                catch { stream.finish(throwing: error) }
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
    let session = LyricsSession(repository: store)
    defer { session.stop() }
    session.accept(.init(track: track, position: 2, isPlaying: false))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while session.document == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(session.isSearching && session.document?.hasWordTiming == false)
    session.accept(.init(track: .init(playerID: "test", playerName: "", title: "Other"), position: 0, isPlaying: false))
    #expect(session.document == nil)
    session.accept(.init(track: track, position: 2, isPlaying: false))
    while session.document == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(session.document?.lines.first?.text == "Hello world")
    #expect(session.isSearching)
    #expect(await cache.automaticCandidate(for: track, configuration: checkpointConfig().selectionKey)?.isProvisional == true)
    await gate.release()
    while session.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(session.document?.hasWordTiming == true)
    while await cache.automaticCandidate(for: track, configuration: "")?.isProvisional != false, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await cache.load(for: track)?.hasWordTiming == true)
    #expect(await cache.automaticCandidate(for: track, configuration: "")?.score == 1000)
}

@Test func checkpointSurvivesRestartAndManualChoiceRejectsLateWrites() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = LyricsCache(directory: directory)
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let doc = try checkpointFixture(word: true), config = checkpointConfig()
    let candidate = LyricCandidate(document: doc, score: config.selectionScore(doc, for: track))
    let token = await cache.beginSearch(for: track)
    try await cache.saveCheckpoint(candidate, for: track, searchID: token, configuration: config.selectionKey)
    let restarted = LyricsCache(directory: directory)
    let restored = try #require(await restarted.automaticCandidate(for: track, configuration: config.selectionKey))
    #expect(restored.isProvisional && restored.score == candidate.score)
    #expect(restored.document.lines == doc.lines && restored.document.source == "Kugou")
    #expect(await restarted.automaticCandidate(for: track, configuration: "changed preferences")?.score == 1)
    var manual = try checkpointFixture(); manual.offsetMilliseconds = -300
    try await cache.save(manual, for: track)
    try await cache.saveCheckpoint(candidate, for: track, searchID: token, configuration: config.selectionKey)
    #expect(await cache.load(for: track)?.offsetMilliseconds == -300)
    #expect(await cache.automaticCandidate(for: track, configuration: "")?.isProvisional == false)
    let refresh = await cache.beginSearch(for: track)
    try await cache.saveCheckpoint(candidate, for: track, searchID: refresh, configuration: config.selectionKey)
    #expect(await cache.load(for: track)?.hasWordTiming == false)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 1 && files.first?.pathExtension == "lrcx")
    #expect(try String(contentsOf: files[0], encoding: .utf8).contains("lxcheckpoint") == false)
}

@Test func supersededSearchCannotReplaceNewerCheckpoint() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = LyricsCache(directory: directory), track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let old = await cache.beginSearch(for: track), fresh = await cache.beginSearch(for: track)
    let better = try checkpointFixture(word: true)
    try await cache.saveCheckpoint(.init(document: better, score: 900), for: track, searchID: fresh, configuration: "key")
    await cache.endSearch(for: track, id: old)
    try await cache.saveCheckpoint(.init(document: try checkpointFixture(), score: 800), for: track, searchID: old, configuration: "key")
    #expect(await cache.load(for: track)?.hasWordTiming == true)
}

@Test func automaticStopsAfterPreferredSourceHasAllFeaturesButManualKeepsAllVersions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let doc = try checkpointFixture(word: true)
    let store = LyricsStore(cache: .init(directory: directory), configuration: checkpointConfig,
                            aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }) { _, _, _, _ in
        .init { stream in
            let task = Task {
                for id in 0..<30 {
                    var version = doc; version.id = UUID(); version.providerID = String(id)
                    stream.yield(version)
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { stream.finish(); return }
                }
                stream.finish()
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
    var automatic: [LyricCandidate] = []
    for try await candidate in store.lyrics(for: track, forceRefresh: true) { automatic.append(candidate) }
    #expect(automatic.count == 1 && automatic.first?.document.hasWordTiming == true)
    var manual: [LyricCandidate] = []
    for try await candidate in store.search(track: track, keyword: "Song Singer", complete: true) { manual.append(candidate) }
    #expect(manual.count == 30)
}

@Test func cancellingBeforeFirstDisplayStillPreservesFoundLyricsForOfflineRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = LyricsCache(directory: directory), gate = CheckpointGate()
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let doc = try checkpointFixture()
    let store = LyricsStore(cache: cache, configuration: checkpointConfig,
                            aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }, firstResultDelay: .seconds(30)) { _, _, _, _ in
        .init { stream in
            let task = Task {
                stream.yield(doc)
                do { try await gate.wait(); stream.finish() } catch { stream.finish(throwing: error) }
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
    let loading = Task {
        var count = 0
        do { for try await _ in store.lyrics(for: track, forceRefresh: false) { count += 1 } } catch { }
        return count
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await cache.load(for: track) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await cache.load(for: track)?.lines.first?.text == "Hello world")
    loading.cancel()
    #expect(await loading.value == 0)
    let restarted = LyricsStore(cache: .init(directory: directory), configuration: checkpointConfig,
                                aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }, firstResultDelay: .seconds(30)) { _, _, _, _ in
        .init { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
    var results: [LyricCandidate] = []
    for try await value in restarted.lyrics(for: track, forceRefresh: false) { results.append(value) }
    #expect(results.first?.document.lines.first?.text == "Hello world")
    #expect(results.allSatisfy { $0.isProvisional })
    #expect(results.allSatisfy { $0.score < 999 })
}

private actor ManualSearchProbe {
    var limits: [Int] = []
    var queries: [String] = []
    func record(track: Track, keyword: String?, limit: Int) {
        limits.append(limit)
        queries.append(keyword ?? "info:" + track.title)
    }
}

@Test func compactManualSearchBoundsEverySourceWhileCompleteSearchRetainsAllVersions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = Track(playerID: "test", playerName: "", title: "Song (Full Version)", artist: "Singer")
    let probe = ManualSearchProbe()
    let store = LyricsStore(cache: .init(directory: directory),
                            aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }) { query, keyword, config, _ in
        .init { stream in
            let source = config.enabled.first ?? "Unknown"
            let task = Task {
                await probe.record(track: query, keyword: keyword, limit: config.candidateLimit)
                let count = keyword == nil ? 4 : 30
                for id in 0..<count {
                    stream.yield(.init(title: query.title, artist: query.artist, source: source,
                                       lines: [.init(id: 0, time: 0, text: "Version \(id)")], providerID: String(id)))
                }
                stream.finish()
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
    var compact: [LyricCandidate] = []
    for try await value in store.search(track: track, keyword: track.title + " " + track.artist) { compact.append(value) }
    #expect(compact.count == 4 * LyricsStore.compactManualResultsPerSource)
    #expect(await probe.limits.allSatisfy { $0 == LyricsStore.compactManualCandidateLimit })
    #expect(await probe.queries.contains("info:" + track.title))
    #expect(await probe.queries.contains(track.title))

    var complete: [LyricCandidate] = []
    for try await value in store.search(track: track, keyword: track.title + " " + track.artist, complete: true) { complete.append(value) }
    #expect(complete.count == 4 * 30)
    #expect(await probe.limits.contains(LyricsStore.completeManualCandidateLimit))
}

@Test func compactSearchCollapsesIdenticalProviderCopiesButCompleteSearchExposesThem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer")
    let config: SourceConfiguration = {
        var value = SourceConfiguration(); value.enabled = ["NetEase"]; value.strictMatching = false; return value
    }()
    let store = LyricsStore(cache: .init(directory: directory), configuration: { config },
                            aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }) { query, _, sourceConfig, _ in
        .init { stream in
            for id in 0..<8 {
                stream.yield(.init(title: query.title, artist: query.artist, source: sourceConfig.enabled.first ?? "NetEase",
                                   lines: [.init(id: 0, time: 1, text: "Same lyric")], providerID: String(id)))
            }
            stream.finish()
        }
    }
    var compact: [LyricCandidate] = [], complete: [LyricCandidate] = []
    for try await value in store.search(track: track, keyword: "Song Singer") { compact.append(value) }
    for try await value in store.search(track: track, keyword: "Song Singer", complete: true) { complete.append(value) }
    #expect(compact.count == 1)
    #expect(complete.count == 8)
}

@Test func compactCurrentTrackSearchHidesUnrelatedSameTitleButCustomKeywordStillShowsIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = Track(playerID: "test", playerName: "", title: "In My Feelings", artist: "Nerissa")
    let config: SourceConfiguration = {
        var value = SourceConfiguration(); value.enabled = ["NetEase"]; value.strictMatching = false; return value
    }()
    let store = LyricsStore(cache: .init(directory: directory), configuration: { config },
                            aliasResolver: TrackAliasResolver { _ in Data(#"{"results":[]}"#.utf8) }) { _, _, sourceConfig, _ in
        .init { stream in
            let source = sourceConfig.enabled.first ?? "NetEase"
            stream.yield(.init(title: "In My Feelings", artist: "Someone Else", source: source,
                               lines: [.init(id: 0, time: 1, text: "Wrong song")], providerID: "wrong"))
            stream.yield(.init(title: "In My Feelings", artist: "Nerissa", source: source,
                               lines: [.init(id: 0, time: 1, text: "Right song")], providerID: "right"))
            stream.finish()
        }
    }
    var currentTrack: [LyricCandidate] = [], custom: [LyricCandidate] = []
    for try await value in store.search(track: track, keyword: "In My Feelings Nerissa") { currentTrack.append(value) }
    for try await value in store.search(track: track, keyword: "unrelated custom words") { custom.append(value) }
    #expect(currentTrack.map(\.document.providerID) == ["right"])
    #expect(Set(custom.compactMap(\.document.providerID)) == ["wrong", "right"])
}
