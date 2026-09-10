import Foundation

extension Lyrics.Metadata.Key {
    public static var attachmentTags = Lyrics.Metadata.Key("attachmentTags")
}

extension Lyrics.Metadata {
    public var attachmentTags: Set<LyricsLine.Attachments.Tag> {
        get { return data[.attachmentTags] as? Set<LyricsLine.Attachments.Tag> ?? [] }
        set { data[.attachmentTags] = newValue }
    }

    public var hasTranslation: Bool {
        return attachmentTags.contains(where: \.isTranslation)
    }
}
