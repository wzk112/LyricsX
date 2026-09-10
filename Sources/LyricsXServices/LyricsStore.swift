import Foundation
@preconcurrency import LyricsKit
import LyricsXCore

public struct SourceConfiguration: Sendable {
    public static let defaultOrder = ["LRCLIB", "NetEase", "QQMusic", "Kugou", "Musixmatch"]
    public var enabled: Set<String> = ["LRCLIB", "NetEase", "QQMusic", "Kugou"]
    public var sourceOrder: [String] = defaultOrder
    public var preferBilingual = true
    public var musixmatchToken: String?
    public var legacyDirectory: URL?
    public init() {}

    public static func normalizedOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return (values + defaultOrder).filter { defaultOrder.contains($0) && seen.insert($0).inserted }
    }

    public func selectionScore(_ document: LyricsDocument, for track: Track) -> Double {
        let match = CandidateRanker.score(document, for: track)
        // Preferences cannot promote a rejected title, artist, or duration match.
        guard match >= 60 else { return match }
        let exactTitle = CandidateRanker.normalized(document.title) == CandidateRanker.normalized(track.title)
        let order = Self.normalizedOrder(sourceOrder)
        let sourceBonus = order.firstIndex(of: document.source).map { Double(order.count - $0) * 10 } ?? 0
        // Lexicographic priorities: title match > timing > bilingual > source >
        // small quality differences. Keep network scores below local cache 999.
        return 60 + (exactTitle ? 400 : 0) + (document.isSynced ? 200 : 0)
            + (preferBilingual && document.hasTranslation ? 100 : 0) + sourceBonus + match / 100
    }
}

public final class LyricsStore: LyricsRepository, Sendable {
    public let cache: LyricsCache
    private let configuration: @Sendable () -> SourceConfiguration
    public init(cache: LyricsCache = LyricsCache(), configuration: @escaping @Sendable () -> SourceConfiguration = { .init() }) {
        self.cache = cache; self.configuration = configuration
    }
    public func save(_ document: LyricsDocument, for track: Track) async throws { if track.playerID != "lyricsx.demo" { try await cache.save(document, for: track) } }
    public func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if track.playerID == "lyricsx.demo" { continuation.finish(); return }
                if !forceRefresh {
                    if let cached = await cache.load(for: track) {
                        continuation.yield(LyricCandidate(document: cached, score: 1000)); continuation.finish(); return
                    }
                    if let embedded = track.embeddedLyrics, let doc = try? LyricsCodec.parse(embedded), doc.isSynced {
                        continuation.yield(LyricCandidate(document: doc, score: 999)); continuation.finish(); return
                    }
                    if let local = Self.localLyrics(track: track, directory: configuration().legacyDirectory) {
                        continuation.yield(LyricCandidate(document: local, score: 999)); continuation.finish(); return
                    }
                }
                do {
                    let results = search(track: track)
                    for try await candidate in results {
                        try Task.checkCancellation()
                        if candidate.score >= 60 { continuation.yield(candidate) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func search(track: Track, keyword: String? = nil) -> AsyncThrowingStream<LyricCandidate, Error> {
        let config = configuration()
        return AsyncThrowingStream { continuation in
            let task = Task {
                let sessionConfig = URLSessionConfiguration.ephemeral
                sessionConfig.timeoutIntervalForRequest = 8
                sessionConfig.timeoutIntervalForResource = 14
                let session = URLSession(configuration: sessionConfig)
                defer { session.invalidateAndCancel() }
                let client = SecureLyricsHTTPClient(session: session)
                let services: [LyricsProviders.Service<LyricsProviders.EmptyOptions>] = [.lrclib, .netease, .qq, .kugou]
                var providers: [any LyricsProvider] = services.filter { config.enabled.contains($0.displayName) }.map { $0.create(httpClient: client) }
                if let token = config.musixmatchToken, !token.isEmpty, config.enabled.contains("Musixmatch") {
                    providers.append(LyricsProviders.Service.musixmatch.create(.init(usertoken: token), httpClient: client))
                }
                let request = LyricsSearchRequest(searchTerm: keyword.map { .keyword($0) } ?? .info(title: track.title, artist: track.artist), duration: track.duration, limit: 5)
                let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                    for provider in providers {
                        group.addTask {
                            do {
                                for try await lyrics in provider.lyrics(for: request) {
                                    try Task.checkCancellation()
                                    let doc = LyricsCodec.convert(lyrics)
                                    continuation.yield(LyricCandidate(document: doc, score: config.selectionScore(doc, for: track)))
                                }
                                return nil
                            } catch is CancellationError { return nil }
                            catch { return error.localizedDescription }
                        }
                    }
                    // LRCLIB also returns unsynchronised and instrumental entries.
                    if config.enabled.contains("LRCLIB"), keyword == nil {
                        group.addTask {
                            do {
                                if let doc = try await Self.fetchPlainLRCLIB(track: track, client: client) {
                                    continuation.yield(LyricCandidate(document: doc, score: config.selectionScore(doc, for: track)))
                                }
                            } catch { /* Other LRCLIB search results remain usable. */ }
                            return nil
                        }
                    }
                    var errors: [String] = []
                    for await failure in group { if let failure { errors.append(failure) } }
                    return errors
                }
                if Task.isCancelled { continuation.finish(throwing: CancellationError()) }
                else if !providers.isEmpty, failures.count >= providers.count { continuation.finish(throwing: StoreError.unavailable) }
                else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func localLyrics(track: Track, directory: URL?) -> LyricsDocument? {
        var bases: [URL] = []
        if let file = track.localFileURL { bases.append(file.deletingPathExtension()) }
        if let directory {
            let name = "\(track.title) - \(track.artist)".replacingOccurrences(of: "/", with: ":")
            bases.append(directory.appendingPathComponent(name))
        }
        for base in bases { for ext in ["lrcx", "lrc"] { if let doc = try? LyricsCodec.read(base.appendingPathExtension(ext)) { return doc } } }
        return nil
    }
    private struct LRCLIBRecord: Decodable {
        var trackName: String; var artistName: String; var albumName: String; var duration: Double
        var instrumental: Bool; var plainLyrics: String?; var syncedLyrics: String?
    }
    private static func fetchPlainLRCLIB(track: Track, client: SecureLyricsHTTPClient) async throws -> LyricsDocument? {
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist),
                          URLQueryItem(name: "album_name", value: track.album), URLQueryItem(name: "duration", value: String(track.duration))]
        let (data, response) = try await client.data(for: URLRequest(url: url.url!))
        guard response.statusCode == 200 else { return nil }
        let item = try JSONDecoder().decode(LRCLIBRecord.self, from: data)
        guard item.syncedLyrics?.isEmpty != false, item.instrumental || item.plainLyrics?.isEmpty == false else { return nil }
        return LyricsDocument(title: item.trackName, artist: item.artistName, album: item.albumName, source: "LRCLIB", duration: item.duration,
                              plainText: item.plainLyrics, isInstrumental: item.instrumental)
    }
    enum StoreError: LocalizedError { case unavailable; var errorDescription: String? { "暂时无法连接歌词源，请检查网络后重试。" } }
}

struct SecureLyricsHTTPClient: HTTPClient {
    let session: URLSession
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if let original = request.url, original.scheme == "http", var components = URLComponents(url: original, resolvingAgainstBaseURL: false) {
            components.scheme = "https"; request.url = components.url
        }
        request.setValue("LyricsX/2.0 (https://github.com/MxIris-LyricsX-Project/LyricsX)", forHTTPHeaderField: "X-Client")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count < 8_000_000 else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
