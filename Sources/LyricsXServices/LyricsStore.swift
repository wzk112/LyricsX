import Foundation
@preconcurrency import LyricsKit
import LyricsXCore

public struct SourceConfiguration: Sendable {
    public static let defaultOrder = ["LRCLIB", "NetEase", "QQMusic", "Kugou", "Musixmatch"]
    public var enabled: Set<String> = ["LRCLIB", "NetEase", "QQMusic", "Kugou"]
    public var sourceOrder: [String] = defaultOrder
    public var preferBilingual = true
    public var preferWordTiming = true
    /// Keep the automatic result conservative by default. When disabled, a
    /// synchronized result with an exact title can still be used when a player
    /// or provider omits or formats artist and duration metadata differently.
    public var strictMatching = true
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
        let exactTitle = CandidateRanker.equivalentTitle(document.title, track.title)
        let order = Self.normalizedOrder(sourceOrder)
        let sourceBonus = order.firstIndex(of: document.source).map { Double(order.count - $0) * 10 } ?? 0
        // Lexicographic priorities: title match > timing > bilingual > source >
        // small quality differences. Keep network scores below local cache 999.
        return 60 + (exactTitle ? 400 : 0) + (document.isSynced ? 200 : 0)
            + (preferWordTiming && document.hasWordTiming ? 150 : 0)
            + (preferBilingual && document.hasTranslation ? 100 : 0) + sourceBonus + match / 100
    }

    /// Providers occasionally publish a stale duration for an otherwise exact
    /// title/artist match. This is only a fallback after every strict candidate
    /// has failed; it prevents automatic search from showing an empty state while
    /// preserving strict candidates as the normal path.
    public func fallbackSelectionScore(_ document: LyricsDocument, for track: Track) -> Double? {
        guard document.isSynced else { return nil }
        let title = CandidateRanker.normalized(track.title)
        let candidateTitle = CandidateRanker.normalized(document.title)
        let artist = CandidateRanker.normalized(track.artist)
        let candidateArtist = CandidateRanker.normalized(document.artist)
        guard !title.isEmpty, title == candidateTitle,
              artist.isEmpty || (!candidateArtist.isEmpty && (artist == candidateArtist || artist.contains(candidateArtist) || candidateArtist.contains(artist)))
        else { return nil }
        let order = Self.normalizedOrder(sourceOrder)
        let sourceBonus = order.firstIndex(of: document.source).map { Double(order.count - $0) } ?? 0
        return 50 + preferenceBonus(document) + sourceBonus / 100
    }

    /// A deliberately lower-priority fallback for sources with incomplete
    /// metadata. Strict candidates and exact title/artist candidates above
    /// always win; this path is only used after they have all failed.
    public func relaxedSelectionScore(_ document: LyricsDocument, for track: Track) -> Double? {
        guard !strictMatching, document.isSynced else { return nil }
        let title = CandidateRanker.normalized(track.title)
        let candidateTitle = CandidateRanker.normalized(document.title)
        guard title.count >= 3, candidateTitle.count >= 3 else { return nil }
        let exactTitle = CandidateRanker.equivalentTitle(document.title, track.title)
        let compatibleTitle = exactTitle || title.contains(candidateTitle) || candidateTitle.contains(title)
        guard compatibleTitle else { return nil }

        let compatibleArtist = CandidateRanker.compatibleArtists(document.artist, for: track)
        // A partial title must retain an artist match; an exact title is useful
        // even when a provider has omitted the artist or reports a variant.
        guard exactTitle || compatibleArtist else { return nil }
        let order = Self.normalizedOrder(sourceOrder)
        let sourceBonus = order.firstIndex(of: document.source).map { Double(order.count - $0) } ?? 0
        return (exactTitle ? 40 : 30) + preferenceBonus(document) + (compatibleArtist ? 0.1 : 0) + sourceBonus / 100
    }

    private func preferenceBonus(_ document: LyricsDocument) -> Double {
        (preferWordTiming && document.hasWordTiming ? 4 : 0) + (preferBilingual && document.hasTranslation ? 2 : 0)
    }

    func bestScore(_ document: LyricsDocument, for track: Track, aliases: [Track] = []) -> Double {
        ([track] + aliases).map { query in
            let strict = selectionScore(document, for: query)
            if strict >= 60 { return strict }
            return max(fallbackSelectionScore(document, for: query) ?? 0, relaxedSelectionScore(document, for: query) ?? 0)
        }.max() ?? 0
    }
}

public final class LyricsStore: LyricsRepository, Sendable {
    /// Automatic search inspects the top ten candidates from each enabled
    /// source before choosing. This reaches the versions manual search often
    /// exposes without unbounded provider requests.
    static let automaticCandidateLimit = 10
    static let manualCandidateLimit = 10
    public let cache: LyricsCache
    private let configuration: @Sendable () -> SourceConfiguration
    private let aliasResolver: TrackAliasResolver
    typealias SearchBackend = @Sendable (Track, String?, SourceConfiguration, SecureLyricsHTTPClient) -> AsyncThrowingStream<LyricsDocument, Error>
    private let searchBackend: SearchBackend
    private let searchBudget: Duration
    public init(cache: LyricsCache = LyricsCache(), configuration: @escaping @Sendable () -> SourceConfiguration = { .init() }) {
        self.cache = cache; self.configuration = configuration
        self.aliasResolver = TrackAliasResolver(); self.searchBackend = Self.providerSearch; self.searchBudget = .seconds(12)
    }
    init(cache: LyricsCache, configuration: @escaping @Sendable () -> SourceConfiguration = { .init() },
         aliasResolver: TrackAliasResolver, searchBudget: Duration = .seconds(12), searchBackend: @escaping SearchBackend) {
        self.cache = cache; self.configuration = configuration; self.aliasResolver = aliasResolver
        self.searchBackend = searchBackend; self.searchBudget = searchBudget
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
                    if let embedded = track.embeddedLyrics, let doc = try? LyricsCodec.parse(embedded), doc.isSynced || doc.plainText?.isEmpty == false {
                        continuation.yield(LyricCandidate(document: doc, score: 999)); continuation.finish(); return
                    }
                    if let local = Self.localLyrics(track: track, directory: configuration().legacyDirectory) {
                        continuation.yield(LyricCandidate(document: local, score: 999)); continuation.finish(); return
                    }
                }
                var candidates: [LyricCandidate] = []
                var failure: Error?
                do {
                    let results = search(track: track)
                    for try await candidate in results {
                        try Task.checkCancellation()
                        if candidate.score > 0 {
                            candidates.removeAll { $0.id == candidate.id }
                            candidates.append(candidate)
                        }
                    }
                    // Do not let the first provider response become visible and
                    // get cached before the deeper concurrent search completes.
                    // The session receives the best candidate first, then keeps
                    // the remaining versions for manual inspection.
                } catch { failure = error }
                guard !Task.isCancelled else { continuation.finish(); return }
                // A slow or failing source must not throw away another source's
                // usable results collected before the shared search deadline.
                for candidate in candidates.sorted(by: { $0.score > $1.score }) { continuation.yield(candidate) }
                if candidates.isEmpty, let failure { continuation.finish(throwing: failure) }
                else { continuation.finish() }
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
                let deadline = Task {
                    do { try await Task.sleep(for: searchBudget) } catch { return }
                    continuation.finish(throwing: StoreError.timeout)
                    session.invalidateAndCancel()
                }
                defer { deadline.cancel() }
                let collector = SearchCollector(track: track, configuration: config, continuation: continuation)
                await withTaskGroup(of: Void.self) { group in
                    for query in Self.queryKeywords(track: track, keyword: keyword) {
                        group.addTask { await self.collect(track: track, keyword: query, client: client, config: config, collector: collector) }
                    }
                    if keyword == nil {
                        group.addTask {
                            let aliases = await self.aliasResolver.aliases(for: track, client: client)
                            guard !Task.isCancelled else { return }
                            await collector.addAliases(aliases)
                            await withTaskGroup(of: Void.self) { aliasGroup in
                                for alias in aliases {
                                    for query in Self.queryKeywords(track: alias, keyword: nil) {
                                        aliasGroup.addTask { await self.collect(track: alias, keyword: query, client: client, config: config, collector: collector) }
                                    }
                                }
                            }
                        }
                    }
                }
                if await collector.allFailed { continuation.finish(throwing: StoreError.unavailable) }
                else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Manual and automatic search share the keyword path. Title-only queries
    /// recover songs where a provider cannot match a localized artist spelling.
    static func queryKeywords(track: Track, keyword: String?) -> [String?] {
        if let keyword { return [keyword] }
        return [nil] + TrackSearchText.titles(track.title).map { Optional($0) }
    }

    private func collect(track: Track, keyword: String?, client: SecureLyricsHTTPClient,
                         config: SourceConfiguration, collector: SearchCollector) async {
        do {
            for try await document in searchBackend(track, keyword, config, client) {
                guard !Task.isCancelled else { return }
                let discovered = await collector.add(document)
                for alias in discovered {
                    guard !Task.isCancelled else { return }
                    await collect(track: alias, keyword: nil, client: client, config: config, collector: collector)
                }
            }
            await collector.completed(failed: false)
        } catch { await collector.completed(failed: true) }
    }

    private static func providerSearch(track: Track, keyword: String?, config: SourceConfiguration,
                                       client: SecureLyricsHTTPClient) -> AsyncThrowingStream<LyricsDocument, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let services: [LyricsProviders.Service<LyricsProviders.EmptyOptions>] = [.lrclib, .netease, .qq, .kugou]
                var providers: [any LyricsProvider] = services.filter { config.enabled.contains($0.displayName) }.map { $0.create(httpClient: client) }
                if let token = config.musixmatchToken, !token.isEmpty, config.enabled.contains("Musixmatch") {
                    providers.append(LyricsProviders.Service.musixmatch.create(.init(usertoken: token), httpClient: client))
                }
                let limit = keyword == nil ? Self.automaticCandidateLimit : Self.manualCandidateLimit
                let request = LyricsSearchRequest(searchTerm: keyword.map { .keyword($0) } ?? .info(title: track.title, artist: track.artist), duration: track.duration, limit: limit)
                let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                    for provider in providers {
                        group.addTask {
                            do {
                                for try await lyrics in provider.lyrics(for: request) {
                                    try Task.checkCancellation()
                                    let doc = LyricsCodec.convert(lyrics)
                                    continuation.yield(doc)
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
                                    continuation.yield(doc)
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
    enum StoreError: LocalizedError {
        case unavailable, timeout
        var errorDescription: String? {
            switch self {
            case .unavailable: "暂时无法连接歌词源，请检查网络后重试。"
            case .timeout: "部分歌词源响应超时，已保留可用结果；可以重新搜索。"
            }
        }
    }
}

struct SecureLyricsHTTPClient: HTTPClient {
    let session: URLSession
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        guard let original = request.url,
              let scheme = original.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = original.host, !host.isEmpty else { throw URLError(.badURL) }
        // QQ Music makes this optional request only to decorate a lyric result
        // with its own album art. Playback artwork is owned by the active player
        // (for example Apple Music), so avoid an unrelated request on macOS 27.
        if host == "u.y.qq.com", let body = request.httpBody,
           String(decoding: body, as: UTF8.self).contains("music.pf_song_detail_svr") {
            throw URLError(.resourceUnavailable)
        }
        if scheme == "http", var components = URLComponents(url: original, resolvingAgainstBaseURL: false) {
            components.scheme = "https"; request.url = components.url
        }
        request.setValue("LyricsX/2.0 (https://github.com/MxIris-LyricsX-Project/LyricsX)", forHTTPHeaderField: "X-Client")
        // macOS 27.0 can abort the process from URLSession.data(for:) while QQ
        // Music performs its optional cover request. The data-task API keeps the
        // same timeout and cancellation behavior without that async bridge.
        let cancellation = HTTPTaskCancellation()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data, data.count < 8_000_000, let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                continuation.resume(returning: (data, response))
            }
            cancellation.install(task)
            task.resume()
          }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class HTTPTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func install(_ value: URLSessionDataTask) {
        lock.withLock { task = value; if cancelled { value.cancel() } }
    }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

private actor SearchCollector {
    struct Key: Hashable {
        var title: String; var artist: String; var source: String
        var lines: [LyricLine]; var plain: String?; var instrumental: Bool
        init(_ document: LyricsDocument) {
            title = document.title; artist = document.artist; source = document.source
            lines = document.lines; plain = document.plainText; instrumental = document.isInstrumental
        }
    }
    let track: Track
    let configuration: SourceConfiguration
    let continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation
    var aliases: [Track] = []
    var candidates: [Key: LyricCandidate] = [:]
    var successes = 0
    var failures = 0
    var allFailed: Bool { candidates.isEmpty && successes == 0 && failures > 0 }
    init(track: Track, configuration: SourceConfiguration, continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation) {
        self.track = track; self.configuration = configuration; self.continuation = continuation
    }
    func add(_ document: LyricsDocument) -> [Track] {
        guard document.isSynced || document.isInstrumental || document.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return [] }
        var discovered = addAliases(ArtistAliasEvidence.aliases(in: document, for: track))
        discovered += addAliases(ArtistAliasEvidence.searchTitles(in: document, for: track, aliases: aliases))
        let key = Key(document)
        guard candidates[key] == nil else { return discovered }
        let candidate = LyricCandidate(document: document, score: configuration.bestScore(document, for: track, aliases: aliases))
        candidates[key] = candidate
        continuation.yield(candidate)
        return discovered
    }
    @discardableResult func addAliases(_ values: [Track]) -> [Track] {
        var added: [Track] = []
        for value in values where aliases.count < 4 {
            guard !aliases.contains(where: { CandidateRanker.normalized($0.title) == CandidateRanker.normalized(value.title)
                && CandidateRanker.normalized($0.artist) == CandidateRanker.normalized(value.artist) }) else { continue }
            aliases.append(value); added.append(value)
        }
        guard !added.isEmpty else { return [] }
        for (key, var candidate) in candidates {
            let score = configuration.bestScore(candidate.document, for: track, aliases: aliases)
            if score > candidate.score {
                candidate.score = score; candidates[key] = candidate; continuation.yield(candidate)
            }
        }
        return added
    }
    func completed(failed: Bool) { if failed { failures += 1 } else { successes += 1 } }
}
