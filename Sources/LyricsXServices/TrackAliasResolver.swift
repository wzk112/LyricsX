import Foundation
import LyricsXCore

/// Catalog names are search hints only. Playback metadata and artwork continue
/// to belong to the selected player. An alias must refer to the verified ID.
actor TrackAliasResolver {
    struct Record: Decodable, Sendable {
        var trackId: Int64?
        var artistId: Int64?
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var trackTimeMillis: Double?
    }
    private struct Envelope: Decodable { var results: [Record] }
    private var cache: [String: (Date, [Track])] = [:]
    private var requests: [Date] = []
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    private let fetch: Fetch?
    init(fetch: Fetch? = nil) { self.fetch = fetch }

    func aliases(for track: Track, client: SecureLyricsHTTPClient) async -> [Track] {
        if let (date, value) = cache[track.cacheIdentity], Date().timeIntervalSince(date) < (value.isEmpty ? 300 : 86_400) { return value }
        guard !track.title.isEmpty, !track.artist.isEmpty else { return [] }
        var seeds: [Record] = []
        // The English catalog lets a romanized/localized title locate the
        // recording. The returned numeric ID then locates its native names.
        for country in ["us", "jp"] {
            let values = await records(endpoint: "search", query: [
                "term": track.title + " " + track.artist, "entity": "song", "limit": "12", "country": country, "lang": "en_us"
            ], client: client)
            seeds = values.filter { Self.isSeed($0, for: track) }
            if !seeds.isEmpty || Task.isCancelled { break }
        }
        guard !Task.isCancelled else { return [] }
        let seed = seeds.sorted {
            func quality(_ item: Record) -> Double {
                let album = !track.album.isEmpty && CandidateRanker.equivalent(item.collectionName ?? "", track.album)
                return (album ? 100 : 0) - abs((item.trackTimeMillis ?? 0) / 1000 - track.duration)
            }
            return quality($0) > quality($1)
        }.first
        guard let seed, let id = seed.trackId else {
            remember([], for: track); return []
        }
        var aliases: [Track] = []
        for country in ["jp", "tw"] {
            guard !Task.isCancelled else { return [] }
            let values = await records(endpoint: "lookup", query: ["id": String(id), "country": country, "lang": "ja_jp"], client: client)
            for item in values where Self.isSameRecording(item, seed: seed) {
                guard let title = item.trackName, let artist = item.artistName else { continue }
                var alias = track
                alias.title = title; alias.artist = artist; alias.album = item.collectionName ?? track.album
                if alias.title != track.title || alias.artist != track.artist,
                   !aliases.contains(where: { $0.title == title && $0.artist == artist }) { aliases.append(alias) }
            }
            // Regional catalogs usually share the native name. One verified
            // alternative is sufficient; avoid redundant requests per song.
            if !aliases.isEmpty { break }
        }
        remember(aliases, for: track)
        return aliases
    }

    static func isSeed(_ record: Record, for track: Track) -> Bool {
        guard record.trackId != nil, record.artistId != nil,
              CandidateRanker.equivalentTitle(record.trackName ?? "", track.title),
              CandidateRanker.equivalent(record.artistName ?? "", track.artist),
              let duration = record.trackTimeMillis, duration > 0, track.duration > 0 else { return false }
        return abs(duration / 1000 - track.duration) <= max(15, track.duration * 0.08)
    }
    static func isSameRecording(_ record: Record, seed: Record) -> Bool {
        guard let id = seed.trackId, record.trackId == id,
              let artist = seed.artistId, record.artistId == artist,
              let duration = seed.trackTimeMillis, let other = record.trackTimeMillis else { return false }
        return abs(duration - other) < 1000 && record.trackName?.isEmpty == false && record.artistName?.isEmpty == false
    }
    private func remember(_ value: [Track], for track: Track) {
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[oldest] = nil }
        cache[track.cacheIdentity] = (Date(), value)
    }
    private func records(endpoint: String, query: [String: String], client: SecureLyricsHTTPClient) async -> [Record] {
        requests.removeAll { Date().timeIntervalSince($0) >= 60 }
        guard requests.count < 18, !Task.isCancelled else { return [] }
        requests.append(Date())
        var url = URLComponents(string: "https://itunes.apple.com/" + endpoint)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 2.5
        do {
            let data: Data
            if let fetch { data = try await fetch(request) }
            else {
                let result = try await client.data(for: request)
                guard result.1.statusCode == 200 else { return [] }
                data = result.0
            }
            return try JSONDecoder().decode(Envelope.self, from: data).results
        } catch { return [] }
    }
}
