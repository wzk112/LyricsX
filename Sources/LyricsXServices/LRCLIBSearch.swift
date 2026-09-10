import Foundation
import LyricsXCore

enum LRCLIBSearch {
    struct Record: Decodable {
        var id: Int?
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    static func documents(track: Track, keyword: String?, client: SecureLyricsHTTPClient) async throws -> [LyricsDocument] {
        var url = URLComponents(string: "https://lrclib.net/api/search")!
        url.queryItems = keyword.map { [.init(name: "q", value: $0)] } ?? [
            .init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist)
        ]
        let (data, _) = try await client.data(for: URLRequest(url: url.url!))
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [LyricsDocument] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        // One malformed or nullable record must not erase all other versions.
        return rows.compactMap { row in
            guard let encoded = try? JSONSerialization.data(withJSONObject: row),
                  let item = try? JSONDecoder().decode(Record.self, from: encoded),
                  let title = item.trackName, !title.isEmpty else { return nil }
            var doc: LyricsDocument
            if let lrc = item.syncedLyrics, !lrc.isEmpty, let parsed = try? LyricsCodec.parse(lrc, source: "LRCLIB") {
                doc = parsed
            } else if item.instrumental == true || item.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                doc = .init(source: "LRCLIB", plainText: item.plainLyrics, isInstrumental: item.instrumental == true)
            } else { return nil }
            doc.title = title; doc.artist = item.artistName ?? ""; doc.album = item.albumName ?? ""
            doc.duration = item.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
            doc.providerID = item.id.map(String.init)
            return doc
        }
    }
}
