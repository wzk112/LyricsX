import Foundation
import LyricsCore

extension Lyrics {
    func merge(translation: Lyrics) {
        // Match nearby timestamps one-to-one. Bound tolerance by neighboring
        // lines so a close translation cannot jump to a fast adjacent lyric.
        var used = Set<Int>()
        var cursor = 0
        for translated in translation.lines {
            while cursor + 1 < lines.count, lines[cursor + 1].position <= translated.position { cursor += 1 }
            let candidates = [cursor - 1, cursor, cursor + 1].filter { lines.indices.contains($0) && !used.contains($0) }
            guard let index = candidates.min(by: { abs(lines[$0].position - translated.position) < abs(lines[$1].position - translated.position) }) else { continue }
            var tolerance = 0.65
            if index > 0 { tolerance = min(tolerance, max(0.02, (lines[index].position - lines[index - 1].position) * 0.45)) }
            if index + 1 < lines.count { tolerance = min(tolerance, max(0.02, (lines[index + 1].position - lines[index].position) * 0.45)) }
            guard abs(lines[index].position - translated.position) <= tolerance else { continue }
            let value = translated.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "//", value != lines[index].content else { continue }
            lines[index].attachments[.translation()] = translated.content
            used.insert(index)
        }
        if !used.isEmpty { metadata.attachmentTags.insert(.translation()) }
    }

    /// merge without maching timetag
    func forceMerge(translation: Lyrics) {
        guard lines.count == translation.lines.count else {
            return
        }
        for idx in lines.indices {
            let transStr = translation.lines[idx].content
            if !transStr.isEmpty, transStr != "//" {
                lines[idx].attachments[.translation()] = transStr
            }
        }
        metadata.attachmentTags.insert(.translation())
    }
}
