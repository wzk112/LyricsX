import Foundation
import Testing
import LyricsXCore
@testable import LyricsXServices

@Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_DIAG_TITLE"] != nil))
func diagnoseSearchCandidates() async throws {
    let env = ProcessInfo.processInfo.environment
    let track = Track(playerID: "diagnostic", playerName: "", title: try #require(env["LYRICSX_DIAG_TITLE"]),
                      artist: env["LYRICSX_DIAG_ARTIST"] ?? "", album: env["LYRICSX_DIAG_ALBUM"] ?? "",
                      duration: Double(env["LYRICSX_DIAG_DURATION"] ?? "0") ?? 0)
    let cache = LyricsCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let store = LyricsStore(cache: cache)
    var documents: [LyricsDocument] = []
    for try await value in store.search(track: track, keyword: env["LYRICSX_DIAG_KEYWORD"]) {
        let doc = value.document
        documents.append(doc)
        print("SEARCH_CANDIDATE score=\(value.score) source=\(doc.source) title=\(doc.title) artist=\(doc.artist) duration=\(doc.duration) word=\(doc.hasWordTiming) bilingual=\(doc.hasTranslation) lines=\(doc.lines.count)")
    }
    if let output = env["LYRICSX_DIAG_OUTPUT"] {
        try JSONEncoder().encode(documents).write(to: URL(fileURLWithPath: output))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_CACHE_AUDIT_PATH"] != nil))
func existingCacheAuditIsReadOnly() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["LYRICSX_CACHE_AUDIT_PATH"])
    let directory = URL(fileURLWithPath: path)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "lrcx" }
    let before = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    let entries = try await LyricsCache(directory: directory).entries()
    let after = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    #expect(before == after)
    #expect(entries.count == files.count)
    print("CACHE_AUDIT files=\(files.count) parsed=\(entries.count) wordTimed=\(entries.filter { $0.document.hasWordTiming }.count) translated=\(entries.filter { $0.document.hasTranslation }.count) modified=0")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LYRICSX_LIVE_SOURCES"] == "1"))
func liveSourceSmoke() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LyricsStore(cache: LyricsCache(directory: directory))
    let track = Track(playerID: "test", playerName: "", title: "Hello", artist: "Adele", duration: 295)
    var sources: Set<String> = []
    for try await result in store.search(track: track) { sources.insert(result.document.source) }
    print("LIVE_SOURCE_SMOKE responding=\(sources.sorted().joined(separator: ","))")
    #expect(!sources.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func embeddedPlainLyricsAreUsedBeforeNetworkSearch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LyricsStore(cache: LyricsCache(directory: directory))
    let track = Track(playerID: "com.apple.Music", playerName: "Apple Music", title: "Song", embeddedLyrics: "first line\nsecond line")
    var results: [LyricCandidate] = []
    for try await result in store.lyrics(for: track, forceRefresh: false) { results.append(result) }
    #expect(results.count == 1)
    #expect(results.first?.document.plainText == "first line\nsecond line")
    #expect(results.first?.score == 999)
}
