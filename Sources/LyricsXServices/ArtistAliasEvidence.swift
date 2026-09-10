import Foundation
import LyricsXCore

/// Some providers explicitly co-list a localized artist name and its Latin
/// credit, e.g. "雨良 Amala". Use that evidence from an otherwise matching
/// recording; never assume arbitrary artists of the same song are equivalent.
enum ArtistAliasEvidence {
    static func searchTitles(in document: LyricsDocument, for track: Track, aliases: [Track]) -> [Track] {
        let originals = TrackSearchText.titles(track.title)
        let existing = Set(originals.map(CandidateRanker.normalized))
        guard let identity = ([track] + aliases).first(where: {
            CandidateRanker.equivalentTitle(document.title, $0.title) && CandidateRanker.compatibleArtists(document.artist, for: $0)
        }) else { return [] }
        return TrackSearchText.titles(document.title).compactMap { name in
            guard !existing.contains(CandidateRanker.normalized(name)), originals.contains(where: { CandidateRanker.equivalent(name, $0) }) else { return nil }
            var alias = identity; alias.title = name
            return alias
        }
    }
    static func aliases(in document: LyricsDocument, for track: Track) -> [Track] {
        guard CandidateRanker.equivalentTitle(document.title, track.title), !track.artist.isEmpty else { return [] }
        if document.duration > 0, track.duration > 0,
           abs(document.duration - track.duration) > max(15, track.duration * 0.08) { return [] }
        let credit = document.artist
        guard credit.range(of: #"[/&+,、×]|\b(feat\.?|featuring|with|vs\.?)\b"#,
                           options: [.regularExpression, .caseInsensitive]) == nil else { return [] }
        let words = credit.replacingOccurrences(of: #"[()（）]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return [] }
        for split in 1..<words.count {
            let left = words[..<split].joined(separator: " "), right = words[split...].joined(separator: " ")
            for (known, alternative) in [(left, right), (right, left)] {
                guard CandidateRanker.equivalent(known, track.artist), distinctScripts(known, alternative) else { continue }
                var alias = track; alias.artist = alternative
                return [alias]
            }
        }
        return []
    }
    private static func distinctScripts(_ lhs: String, _ rhs: String) -> Bool {
        func latin(_ value: String) -> Bool {
            value.range(of: #"\p{Latin}"#, options: .regularExpression) != nil
                && value.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Cyrillic}\p{Greek}]"#, options: .regularExpression) == nil
        }
        func native(_ value: String) -> Bool {
            value.range(of: #"\p{Latin}"#, options: .regularExpression) == nil
                && value.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Cyrillic}\p{Greek}]"#, options: .regularExpression) != nil
        }
        return (latin(lhs) && native(rhs)) || (native(lhs) && latin(rhs))
    }
}
