import Foundation
import LyricsCore

extension Lyrics {
    convenience init?(qqmusicQrcContent content: String) {
        var idTags: [IDTagKey: String] = [:]
        for match in id3TagRegex.matches(in: content) {
            guard let key = match[1]?.content.trimmingCharacters(in: .whitespaces),
                  let value = match[2]?.content.trimmingCharacters(in: .whitespaces),
                  !key.isEmpty,
                  !value.isEmpty else {
                continue
            }
            idTags[.init(key)] = value
        }

        let lines: [LyricsLine] = qrcLineRegex.matches(in: content).map { match in
            let timeTagStr = match[1]!.content
            let timeTag = TimeInterval(timeTagStr)! / 1000

            let durationStr = match[2]!.content
            let duration = TimeInterval(durationStr)! / 1000

            var lineContent = ""
            var attachment = LyricsLine.Attachments.InlineTimeTag(tags: [.init(index: 0, time: 0)], duration: duration)
            for m in qqmusicInlineTagRegex.matches(in: content, range: match[3]!.range) {
                let t1 = Int(m[2]!.content)! - Int(timeTagStr)!
                let t2 = Int(m[3]!.content)!
                let t = TimeInterval(t1 + t2) / 1000
                let fragment = m[1]!.content
                let prevCount = lineContent.count
                lineContent += fragment
                if lineContent.count > prevCount {
                    attachment.tags.append(.init(index: lineContent.count, time: t))
                }
            }

            let att = LyricsLine.Attachments(attachments: [.timetag: attachment])
            return LyricsLine(content: lineContent, position: timeTag, attachments: att)
        }
        guard !lines.isEmpty else {
            return nil
        }
        self.init(lines: lines, idTags: idTags)
    }
}
