struct KugouKrcHeaderFieldLanguage: Codable {
    let content: [Content]
    let version: Int

    struct Content: Codable {
        // TODO: resolve language/type code
        let language: Int
        let type: Int
        let lyricContent: [[String]]
    }
}
