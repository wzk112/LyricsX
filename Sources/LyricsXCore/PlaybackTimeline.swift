import Foundation

/// Only the monotonic clock drives animation. Wall-clock changes cannot advance lyrics.
public struct PlaybackTimeline: Sendable {
    private var anchor = 0.0
    private var sampledAt = 0.0
    public private(set) var isPlaying = false
    private var duration = 0.0
    public var maximumExtrapolation = 3.0
    public init() {}
    public mutating func accept(_ snapshot: PlaybackSnapshot) {
        guard snapshot.position.isFinite, snapshot.sampledAt.isFinite else { return }
        anchor = max(0, snapshot.position); sampledAt = snapshot.sampledAt
        isPlaying = snapshot.isPlaying; duration = snapshot.track?.duration ?? 0
    }
    public func position(at now: Double) -> Double {
        guard now.isFinite else { return anchor }
        let elapsed = isPlaying ? min(maximumExtrapolation, max(0, now - sampledAt)) : 0
        let result = anchor + elapsed
        return duration > 0 ? min(duration, result) : result
    }
    public mutating func seek(to position: Double, at now: Double) {
        guard position.isFinite, now.isFinite else { return }
        anchor = max(0, duration > 0 ? min(position, duration) : position); sampledAt = now
    }
    public mutating func freeze(at now: Double) { anchor = position(at: now); sampledAt = now; isPlaying = false }
}

public enum CandidateRanker {
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    public static func score(_ doc: LyricsDocument, for track: Track) -> Double {
        let title = normalized(track.title), candidateTitle = normalized(doc.title)
        guard !title.isEmpty, !candidateTitle.isEmpty,
              candidateTitle == title || candidateTitle.contains(title) || title.contains(candidateTitle) else { return 0 }
        var result = candidateTitle == title ? 60.0 : 38.0
        let artist = normalized(track.artist), candidateArtist = normalized(doc.artist)
        if !artist.isEmpty {
            guard !candidateArtist.isEmpty, artist == candidateArtist || artist.contains(candidateArtist) || candidateArtist.contains(artist) else { return 0 }
            result += artist == candidateArtist ? 25 : 15
        }
        if track.duration > 0, doc.duration > 0 {
            let delta = abs(track.duration - doc.duration)
            guard delta < max(15, track.duration * 0.08) else { return 0 }
            result += max(0, 10 - delta)
        }
        if doc.hasWordTiming { result += 3 }
        if doc.hasTranslation { result += 2 }
        return result
    }
}
