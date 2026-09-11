import Foundation
@preconcurrency import LyricsKit
import LyricsXCore

public struct SourceConfiguration: Sendable {
    public static let defaultOrder = ["LRCLIB", "NetEase", "QQMusic", "Kugou", "Musixmatch"]
    var candidateLimit = 40
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

    var selectionKey: String {
        (Self.normalizedOrder(sourceOrder) + enabled.sorted() + [String(preferBilingual), String(preferWordTiming), String(strictMatching)]).joined(separator: "|")
    }

    func satisfiesAutomaticPreferences(_ document: LyricsDocument, for track: Track, aliases: [Track]) -> Bool {
        guard document.isSynced, !document.isLikelyInstrumentalPlaceholder,
              !preferWordTiming || document.hasWordTiming,
              !preferBilingual || document.hasTranslation else { return false }
        return ([track] + aliases).contains {
            CandidateRanker.equivalentTitle(document.title, $0.title) && CandidateRanker.score(document, for: $0) >= 60
        }
    }

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

    /// Even a free-text query unrelated to the playing track must honor source
    /// and feature preferences, rather than using network arrival order.
    public func manualPrecedes(_ lhs: LyricCandidate, _ rhs: LyricCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let left = preferenceBonus(lhs.document), right = preferenceBonus(rhs.document)
        if left != right { return left > right }
        let order = Self.normalizedOrder(sourceOrder)
        let leftSource = order.firstIndex(of: lhs.document.source) ?? order.count
        let rightSource = order.firstIndex(of: rhs.document.source) ?? order.count
        if leftSource != rightSource { return leftSource < rightSource }
        func key(_ doc: LyricsDocument) -> String { doc.title + "|" + doc.artist + "|" + doc.album + "|" + (doc.providerID ?? "") }
        return key(lhs.document) < key(rhs.document)
    }
}

public final class LyricsStore: LyricsRepository, Sendable {
    /// Download budgets per source/query. Manual search retains more versions;
    /// both paths use the same matching, aliases, and completion-order delivery.
    static let automaticCandidateLimit = 40
    static let compactManualCandidateLimit = 12
    static let completeManualCandidateLimit = 80
    static let compactManualResultsPerSource = 12
    public let cache: LyricsCache
    private let configuration: @Sendable () -> SourceConfiguration
    private let aliasResolver: TrackAliasResolver
    typealias SearchBackend = @Sendable (Track, String?, SourceConfiguration, SecureLyricsHTTPClient) -> AsyncThrowingStream<LyricsDocument, Error>
    private let searchBackend: SearchBackend
    private let searchBudget: Duration
    private let firstResultDelay: Duration
    public init(cache: LyricsCache = LyricsCache(), configuration: @escaping @Sendable () -> SourceConfiguration = { .init() }) {
        self.cache = cache; self.configuration = configuration
        self.aliasResolver = TrackAliasResolver(); self.searchBackend = Self.providerSearch; self.searchBudget = .seconds(24); self.firstResultDelay = .seconds(1)
    }
    init(cache: LyricsCache, configuration: @escaping @Sendable () -> SourceConfiguration = { .init() },
         aliasResolver: TrackAliasResolver, searchBudget: Duration = .seconds(24), firstResultDelay: Duration = .seconds(1), searchBackend: @escaping SearchBackend) {
        self.cache = cache; self.configuration = configuration; self.aliasResolver = aliasResolver
        self.searchBackend = searchBackend; self.searchBudget = searchBudget; self.firstResultDelay = firstResultDelay
    }
    public func save(_ document: LyricsDocument, for track: Track) async throws { if track.playerID != "lyricsx.demo" { try await cache.save(document, for: track) } }
    public func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if track.playerID == "lyricsx.demo" { continuation.finish(); return }
                let selectionKey = configuration().selectionKey
                var checkpoint: LyricCandidate?
                if !forceRefresh {
                    if let cached = await cache.automaticCandidate(for: track, configuration: selectionKey) {
                        if !cached.isProvisional { continuation.yield(cached); continuation.finish(); return }
                        checkpoint = cached
                    }
                    if checkpoint == nil, let embedded = track.embeddedLyrics, let doc = try? LyricsCodec.parse(embedded), doc.isSynced || doc.plainText?.isEmpty == false {
                        continuation.yield(LyricCandidate(document: doc, score: 999)); continuation.finish(); return
                    }
                    if checkpoint == nil, let local = Self.localLyrics(track: track, directory: configuration().legacyDirectory) {
                        continuation.yield(LyricCandidate(document: local, score: 999)); continuation.finish(); return
                    }
                }
                guard !Task.isCancelled else { continuation.finish(); return }
                let searchID = await cache.beginSearch(for: track)
                defer { Task { await cache.endSearch(for: track, id: searchID) } }
                let results = AutomaticSearchResults(continuation) { [cache] candidate in
                    try? await cache.saveCheckpoint(candidate, for: track, searchID: searchID, configuration: selectionKey)
                }
                if let checkpoint { await results.restore(checkpoint) }
                let firstDisplay = Task {
                    do { try await Task.sleep(for: firstResultDelay) } catch { return }
                    await results.allowEarlyDisplay()
                }
                defer { firstDisplay.cancel() }
                var failure: Error?
                do {
                    for try await candidate in search(track: track) {
                        try Task.checkCancellation()
                        await results.add(candidate)
                    }
                } catch { failure = error }
                guard !Task.isCancelled else { continuation.finish(); return }
                await results.finish(error: failure)

            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func search(track: Track, keyword: String? = nil, complete: Bool = false,
                       onSourceUpdate: @escaping @Sendable (SourceSearchStatus) -> Void = { _ in }) -> AsyncThrowingStream<LyricCandidate, Error> {
        var config = configuration()
        config.candidateLimit = keyword == nil ? Self.automaticCandidateLimit
            : (complete ? Self.completeManualCandidateLimit : Self.compactManualCandidateLimit)
        let configuration = config
        return AsyncThrowingStream { continuation in
            let collector = SearchCollector(track: track, keyword: keyword, complete: complete, configuration: configuration,
                                            continuation: continuation, onSourceUpdate: onSourceUpdate)
            let task = Task {
                let sessionConfig = URLSessionConfiguration.ephemeral
                sessionConfig.timeoutIntervalForRequest = 6
                sessionConfig.timeoutIntervalForResource = 9
                sessionConfig.httpMaximumConnectionsPerHost = 4
                let session = URLSession(configuration: sessionConfig)
                defer { session.invalidateAndCancel() }
                let client = SecureLyricsHTTPClient(session: session)
                await collector.begin()
                let budget = keyword == nil ? searchBudget
                    : (complete ? max(searchBudget, .seconds(40)) : min(searchBudget, .seconds(18)))
                let deadline = Task {
                    do { try await Task.sleep(for: budget) } catch { return }
                    await collector.finish(timedOut: true)
                    continuation.finish(throwing: StoreError.timeout)
                    session.invalidateAndCancel()
                }
                defer { deadline.cancel() }
                // One worker per source. Newly discovered native names enter
                // each source's queue immediately, ahead of broad title-only
                // queries; no slow source can block alias expansion elsewhere.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        if Self.usesTrackHints(track: track, keyword: keyword) {
                            let aliases = await self.aliasResolver.aliases(for: track, client: client)
                            if !Task.isCancelled { await collector.addAliases(aliases) }
                        }
                        await collector.catalogFinished()
                    }
                    for source in configuration.availableSources {
                        var single = configuration; single.enabled = [source]
                        let sourceConfig = single
                        group.addTask {
                            while let query = await collector.nextQuery(source: source) {
                                guard !Task.isCancelled else { return }
                                do {
                                    for try await document in self.searchBackend(query.track, query.keyword, sourceConfig, client) {
                                        guard !Task.isCancelled else { return }
                                        _ = await collector.add(document)
                                        if await collector.sourceShouldStop(source) { break }
                                    }
                                    await collector.completed(source: source, error: nil)
                                } catch {
                                    if Task.isCancelled { return }
                                    await collector.completed(source: source, error: SourceSearchStatus.describe(error))
                                }
                            }
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                await collector.finish(timedOut: false)
                if await collector.allFailed { continuation.finish(throwing: StoreError.unavailable) }
                else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel(); Task { await collector.cancel() } }
        }
    }

    static func usesTrackHints(track: Track, keyword: String?) -> Bool {
        guard let keyword else { return true }
        let value = CandidateRanker.normalized(keyword)
        return value == CandidateRanker.normalized(track.title)
            || value == CandidateRanker.normalized(track.title + " " + track.artist)
    }

    static func queryKeywords(track: Track, keyword: String?, complete: Bool = true) -> [String?] {
        if let keyword, !usesTrackHints(track: track, keyword: keyword) { return [keyword] }
        let titles = TrackSearchText.titles(track.title)
        if complete { return [nil] + titles.map { Optional($0) } }
        // The info query already carries the original title and artist. Compact
        // search adds only the first useful cleaned title instead of multiplying
        // every source by every subtitle and alias spelling.
        return [nil] + titles.prefix(2).map { Optional($0) }
    }

    private static func providerSearch(track: Track, keyword: String?, config: SourceConfiguration,
                                       client: SecureLyricsHTTPClient) -> AsyncThrowingStream<LyricsDocument, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let services: [LyricsProviders.Service<LyricsProviders.EmptyOptions>] = [.netease, .qq, .kugou]
                var providers: [any LyricsProvider] = services.filter { config.enabled.contains($0.displayName) }.map { $0.create(httpClient: client) }
                if let token = config.musixmatchToken, !token.isEmpty, config.enabled.contains("Musixmatch") {
                    providers.append(LyricsProviders.Service.musixmatch.create(.init(usertoken: token), httpClient: client))
                }
                let limit = config.candidateLimit
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
                            catch {
                                if ProcessInfo.processInfo.environment["LYRICSX_SEARCH_DIAGNOSTICS"] == "1" { print("PROVIDER_ERROR \(SourceSearchStatus.describe(error))") }
                                return SourceSearchStatus.describe(error)
                            }
                        }
                    }
                    if config.enabled.contains("LRCLIB") {
                        group.addTask {
                            do {
                                for doc in try await LRCLIBSearch.documents(track: track, keyword: keyword, client: client) {
                                    try Task.checkCancellation()
                                    continuation.yield(doc)
                                }
                                return nil
                            } catch { return SourceSearchStatus.describe(error) }
                        }
                    }
                    var errors: [String] = []
                    for await failure in group { if let failure { errors.append(failure) } }
                    return errors
                }
                if Task.isCancelled { continuation.finish(throwing: CancellationError()) }
                else if !failures.isEmpty { continuation.finish(throwing: StoreError.sourceFailure(failures.joined(separator: "；"))) }
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
    enum StoreError: LocalizedError {
        case unavailable, timeout
        case sourceFailure(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "歌词源未能完成搜索，请查看各来源状态后重试。"
            case .sourceFailure(let message): message
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
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                let result = try await perform(request, host: host, path: original.path)
                guard (200..<300).contains(result.1.statusCode) else { throw HTTPResponseError(status: result.1.statusCode) }
                return result
            } catch {
                let retryable: Bool
                if let status = error as? HTTPResponseError { retryable = [408, 500, 502, 503, 504].contains(status.status) }
                else {
                    let value = error as NSError
                    retryable = value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(value.code)
                }
                guard attempt == 0, retryable, !Task.isCancelled else { throw error }
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw URLError(.unknown)
    }
    private func perform(_ request: URLRequest, host: String, path: String) async throws -> (Data, HTTPURLResponse) {
        // macOS 27.0 can abort the process from URLSession.data(for:) while QQ
        // Music performs its optional cover request. The data-task API keeps the
        // same timeout and cancellation behavior without that async bridge.
        let cancellation = HTTPTaskCancellation()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if ProcessInfo.processInfo.environment["LYRICSX_SEARCH_DIAGNOSTICS"] == "1" {
                    print("HTTP_RESULT host=\(host) path=\(path) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data?.count ?? 0) error=\((error as NSError?)?.code ?? 0)")
                }
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
        var providerID: String?; var album: String
        init(_ document: LyricsDocument, preserveProviderID: Bool) {
            title = document.title; artist = document.artist; source = document.source
            providerID = preserveProviderID ? document.providerID : nil; album = document.album
            lines = document.lines; plain = document.plainText; instrumental = document.isInstrumental
        }
    }
    let track: Track
    let configuration: SourceConfiguration
    let continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation
    var aliases: [Track] = []
    var candidates: [Key: LyricCandidate] = [:]
    var visibleKeys: Set<Key> = []
    let onSourceUpdate: @Sendable (SourceSearchStatus) -> Void
    var sourceErrors: [String: String] = [:]
    var activeSources: Set<String> = []
    struct Query: Sendable {
        let track: Track
        let keyword: String?
        var key: String {
            keyword.map { "q:" + CandidateRanker.normalized($0) }
                ?? "i:" + CandidateRanker.normalized(track.title) + "|" + CandidateRanker.normalized(track.artist)
        }
    }
    var queues: [String: [Query]] = [:]
    var queryKeys: [String: Set<String>] = [:]
    var waiters: [String: CheckedContinuation<Query?, Never>] = [:]
    var catalogDone = false
    let useTrackHints: Bool
    let isAutomatic: Bool
    let completeManualSearch: Bool
    var satisfiedSources: Set<String> = []
    var completedQueries: [String: Int] = [:]
    var finished = false
    var successes = 0
    var failures = 0
    var allFailed: Bool { candidates.isEmpty && successes == 0 && failures > 0 }
    init(track: Track, keyword: String?, complete: Bool, configuration: SourceConfiguration, continuation: AsyncThrowingStream<LyricCandidate, Error>.Continuation, onSourceUpdate: @escaping @Sendable (SourceSearchStatus) -> Void) {
        self.onSourceUpdate = onSourceUpdate
        self.useTrackHints = LyricsStore.usesTrackHints(track: track, keyword: keyword)
        self.isAutomatic = keyword == nil
        self.completeManualSearch = complete
        self.track = track; self.configuration = configuration; self.continuation = continuation
        let queries = LyricsStore.queryKeywords(track: track, keyword: keyword, complete: complete || keyword == nil).map { Query(track: track, keyword: $0) }
        for source in configuration.availableSources {
            queues[source] = queries
            queryKeys[source] = Set(queries.map(\.key))
        }
    }
    func add(_ document: LyricsDocument) -> [Track] {
        guard !finished else { return [] }
        guard document.isSynced || document.isInstrumental || document.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return [] }
        var discovered: [Track] = []
        if useTrackHints {
            discovered = addAliases(ArtistAliasEvidence.aliases(in: document, for: track))
            discovered += addAliases(ArtistAliasEvidence.searchTitles(in: document, for: track, aliases: aliases))
        }
        guard !finished else { return discovered }
        let key = Key(document, preserveProviderID: isAutomatic || completeManualSearch)
        guard candidates[key] == nil else { return discovered }
        let candidate = LyricCandidate(document: document, score: configuration.bestScore(document, for: track, aliases: aliases))
        candidates[key] = candidate
        publish(candidate, key: key)
        updateSatisfiedSources()
        updateCompactLimit(for: document.source)
        if !finished { report(document.source) }
        return discovered
    }
    @discardableResult func addAliases(_ values: [Track]) -> [Track] {
        guard !finished else { return [] }
        var added: [Track] = []
        let aliasLimit = isAutomatic || completeManualSearch ? 4 : 2
        for value in values where aliases.count < aliasLimit {
            guard !aliases.contains(where: { CandidateRanker.normalized($0.title) == CandidateRanker.normalized(value.title)
                && CandidateRanker.normalized($0.artist) == CandidateRanker.normalized(value.artist) }) else { continue }
            aliases.append(value); added.append(value)
            for source in configuration.availableSources {
                if satisfiedSources.contains(source) { continue }
                let queries = LyricsStore.queryKeywords(track: value, keyword: nil, complete: isAutomatic || completeManualSearch).map { Query(track: value, keyword: $0) }
                    .filter { queryKeys[source, default: []].insert($0.key).inserted }
                queues[source, default: []].insert(contentsOf: queries, at: 0)
                if !queries.isEmpty, let waiter = waiters.removeValue(forKey: source) {
                    activeSources.insert(source)
                    waiter.resume(returning: queues[source]!.removeFirst())
                }
            }
        }
        guard !added.isEmpty else { return [] }
        for (key, var candidate) in candidates {
            let score = configuration.bestScore(candidate.document, for: track, aliases: aliases)
            if score > candidate.score {
                candidate.score = score; candidates[key] = candidate; publish(candidate, key: key)
            }
        }
        updateSatisfiedSources()
        for source in configuration.availableSources { updateCompactLimit(for: source) }
        return added
    }
    private func updateSatisfiedSources() {
        guard isAutomatic else { return }
        for candidate in candidates.values where !satisfiedSources.contains(candidate.document.source) {
            if configuration.satisfiesAutomaticPreferences(candidate.document, for: track, aliases: aliases) {
                satisfiedSources.insert(candidate.document.source)
                queues[candidate.document.source] = []
            }
        }
        // No other enabled source can outrank an exact, fully preferred result
        // from the first source. Do not spend the rest of the budget on it.
        if let first = configuration.availableSources.first, satisfiedSources.contains(first) {
            finish(timedOut: false)
            continuation.finish()
        }
    }
    private func updateCompactLimit(for source: String) {
        guard !isAutomatic, !completeManualSearch else { return }
        let visibleCount = visibleKeys.lazy.filter({ self.candidates[$0]?.document.source == source }).count
        if visibleCount >= LyricsStore.compactManualResultsPerSource || (catalogDone && completedQueries[source, default: 0] >= 2) {
            satisfiedSources.insert(source)
            queues[source] = []
        }
    }
    private func publish(_ candidate: LyricCandidate, key: Key) {
        // For the current track, compact search keeps off-target same-name songs
        // available for later alias rescoring without flooding the visible list.
        let visible = isAutomatic || completeManualSearch || !useTrackHints || candidate.score >= 60
        guard visible else { return }
        visibleKeys.insert(key)
        continuation.yield(candidate)
    }
    func sourceShouldStop(_ source: String) -> Bool { satisfiedSources.contains(source) }
    func begin() { for source in configuration.availableSources { report(source) } }
    func completed(source: String, error: String?) {
        guard !finished else { return }
        activeSources.remove(source)
        completedQueries[source, default: 0] += 1
        if let error { failures += 1; sourceErrors[source] = error }
        else { successes += 1 }
        updateCompactLimit(for: source)
        report(source)
    }
    func catalogFinished() {
        catalogDone = true
        for source in configuration.availableSources { updateCompactLimit(for: source) }
        finishWaitingIfDrained()
    }
    func nextQuery(source: String) async -> Query? {
        guard !finished, !Task.isCancelled else { return nil }
        if satisfiedSources.contains(source) { finishWaitingIfDrained(); return nil }
        if queues[source]?.isEmpty == false {
            activeSources.insert(source)
            return queues[source]!.removeFirst()
        }
        return await withCheckedContinuation { waiter in
            waiters[source] = waiter
            finishWaitingIfDrained()
        }
    }
    private func finishWaitingIfDrained() {
        guard catalogDone, activeSources.isEmpty, queues.values.allSatisfy(\.isEmpty) else { return }
        let pending = waiters.values; waiters = [:]
        for waiter in pending { waiter.resume(returning: nil) }
    }
    func cancel() {
        finished = true
        let pending = waiters.values; waiters = [:]
        for waiter in pending { waiter.resume(returning: nil) }
    }
    func finish(timedOut: Bool) {
        guard !finished else { return }
        for source in configuration.availableSources { report(source, finished: true, timedOut: timedOut && activeSources.contains(source)) }
        cancel()
    }
    private func report(_ source: String, finished: Bool = false, timedOut: Bool = false) {
        let count = visibleKeys.lazy.filter { self.candidates[$0]?.document.source == source }.count
        onSourceUpdate(.init(source: source, count: count, isSearching: !finished,
                             issue: sourceErrors[source] ?? (timedOut ? "搜索超时，已保留结果" : nil)))
    }
}
