import Foundation

public struct Track: Codable, Hashable, Sendable, Identifiable {
    public var playerID: String
    public var playerName: String
    public var persistentID: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var artworkData: Data?
    public var artworkURL: URL?
    public var localFileURL: URL?
    public var embeddedLyrics: String?

    public init(playerID: String, playerName: String, persistentID: String = "", title: String,
                artist: String = "", album: String = "", duration: Double = 0,
                artworkData: Data? = nil, artworkURL: URL? = nil, localFileURL: URL? = nil, embeddedLyrics: String? = nil) {
        self.playerID = playerID; self.playerName = playerName; self.persistentID = persistentID
        self.title = title; self.artist = artist; self.album = album
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.artworkData = artworkData; self.artworkURL = artworkURL
        self.localFileURL = localFileURL; self.embeddedLyrics = embeddedLyrics
    }

    // Length prefixes prevent ambiguous identities when metadata contains separators.
    public var id: String { [playerID, persistentID, title, artist, album].map { "\($0.utf8.count):\($0)" }.joined() }
    public var cacheIdentity: String { [title, artist, album, String(Int(duration.rounded()))].map { "\($0.utf8.count):\($0)" }.joined() }
}

public struct PlaybackSnapshot: Sendable {
    public var track: Track?
    public var position: Double
    public var isPlaying: Bool
    public var sampledAt: Double
    public var positionIsReliable: Bool
    public var playbackStateIsReliable: Bool
    public init(
        track: Track?,
        position: Double,
        isPlaying: Bool,
        sampledAt: Double = ProcessInfo.processInfo.systemUptime,
        positionIsReliable: Bool = true,
        playbackStateIsReliable: Bool = true
    ) {
        self.track = track; self.position = position; self.isPlaying = isPlaying; self.sampledAt = sampledAt
        self.positionIsReliable = positionIsReliable
        self.playbackStateIsReliable = playbackStateIsReliable
    }
}

public struct WordCue: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    public func progress(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(1, max(0, (time - start) / max(0.001, end - start)))
    }
}

public struct LyricLine: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var time: Double
    public var text: String
    public var translation: String?
    public var words: [WordCue]
    public var attachments: [String: String]
    public init(id: Int, time: Double, text: String, translation: String? = nil,
                words: [WordCue] = [], attachments: [String: String] = [:]) {
        self.id = id; self.time = time; self.text = text; self.translation = translation
        self.words = words; self.attachments = attachments
    }
}

public struct LyricsDocument: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var album: String
    public var source: String
    public var duration: Double
    public var lines: [LyricLine]
    public var plainText: String?
    public var offsetMilliseconds: Int
    public var isInstrumental: Bool
    public var originalLRC: String
    public var artworkURL: URL?
    public init(id: UUID = UUID(), title: String = "", artist: String = "", album: String = "", source: String = "本地",
                duration: Double = 0, lines: [LyricLine] = [], plainText: String? = nil,
                offsetMilliseconds: Int = 0, isInstrumental: Bool = false, originalLRC: String = "", artworkURL: URL? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.source = source
        self.duration = duration; self.lines = lines.filter { $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }
        for index in self.lines.indices { self.lines[index].id = index }
        self.plainText = plainText; self.offsetMilliseconds = offsetMilliseconds
        self.isInstrumental = isInstrumental; self.originalLRC = originalLRC; self.artworkURL = artworkURL
    }
    public var hasWordTiming: Bool { lines.contains { !$0.words.isEmpty } }
    public var hasTranslation: Bool {
        lines.contains {
            guard let translation = $0.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !translation.isEmpty else { return false }
            return translation != $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    public var isSynced: Bool { !lines.isEmpty }
    /// Some providers return a short status sentence as a timed lyric instead
    /// of setting their instrumental flag. Only classify it as non-lyrical
    /// when there are at most three non-empty lines, so normal songs cannot be
    /// hidden merely because one lyric happens to contain a matching word.
    public var isLikelyInstrumentalPlaceholder: Bool {
        guard !isInstrumental else { return true }
        let textLines = lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard textLines.count <= 3 else { return false }
        guard !textLines.isEmpty else { return true }
        let normalized = Self.normalizedPlaceholderText(textLines.joined(separator: " "))
        if Self.instrumentalPlaceholderPhrases.contains(where: { normalized.contains($0) }) { return true }
        return textLines.allSatisfy(Self.isOnlyMusicNotation)
    }

    // The list covers wording returned by the providers we support and common
    // variants in Simplified/Traditional Chinese, English, Japanese and Korean.
    // Punctuation and whitespace are discarded before matching, so forms such
    // as "♪ 纯音乐，请欣赏 ♪" and "No lyrics available" are equivalent.
    private static let instrumentalPlaceholderPhrases: Set<String> = [
        "纯音乐", "纯音樂", "无歌词", "無歌詞", "没有歌词", "沒有歌詞", "暂无歌词", "暫無歌詞",
        "未填词", "未填詞", "无填词", "無填詞", "没有填词", "沒有填詞", "间奏", "間奏",
        "instrumental", "instrumentalmusic", "instrumentalonly", "instrumentalversion", "interlude",
        "nolyric", "nolyrics", "lyricsunavailable", "lyricsnotavailable", "musiconly",
        "インスト", "インストゥルメンタル", "歌詞なし", "歌詞無し", "歌詞はありません", "歌詞がありません", "間奏",
        "연주곡", "가사없음", "가사가없습니다", "가사가없어요",
        "musiqueinstrumentale", "sansparoles", "sinletra", "sinletras", "keintext", "ohnegesang"
    ]

    private static func normalizedPlaceholderText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func isOnlyMusicNotation(_ text: String) -> Bool {
        let allowed = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return !text.unicodeScalars.isEmpty && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    public func lyricTime(for position: Double) -> Double { position + Double(offsetMilliseconds) / 1000 }
    public func index(at position: Double) -> Int? {
        let time = lyricTime(for: position)
        guard time.isFinite, let first = lines.first, time >= first.time else { return nil }
        var low = 0; var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
    public func seekPosition(for line: LyricLine) -> Double { max(0, line.time - Double(offsetMilliseconds) / 1000) }
}

public struct LyricCandidate: Sendable, Identifiable {
    public var document: LyricsDocument
    public var score: Double
    public var id: UUID { document.id }
    public init(document: LyricsDocument, score: Double) { self.document = document; self.score = score }
}

public enum LyricsPhase: Equatable, Sendable {
    case idle, loading, ready, notFound, failed(String)
}

public protocol LyricsRepository: Sendable {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error>
    func save(_ document: LyricsDocument, for track: Track) async throws
}
