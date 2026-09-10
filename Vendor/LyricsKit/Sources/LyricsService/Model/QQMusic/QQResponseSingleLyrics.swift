import Foundation

struct QQResponseSingleLyrics: Decodable {
    let retcode: Int
    let code: Int
    let subcode: Int
    let lyric: Data
    let trans: Data?
}

extension QQResponseSingleLyrics {
    var lyricString: String? {
        return String(data: lyric, encoding: .utf8)?.decodingXMLEntities()
    }

    var transString: String? {
        guard let data = trans,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string.decodingXMLEntities()
    }
}
