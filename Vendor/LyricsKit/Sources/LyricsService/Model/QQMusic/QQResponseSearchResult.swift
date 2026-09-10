import Foundation

protocol QQMusicSongSearchResult {
    var id: String { get }
    var mid: String { get }
    var name: String { get }
    var singers: [String] { get }
}

struct QQResponseSearchResult: Decodable {
    let data: Data
    let code: Int

    struct Data: Decodable {
        let song: Song

        struct Song: Decodable {
            let list: [Item]
            enum CodingKeys: String, CodingKey {
                case list = "itemlist"
            }

            struct Item: Decodable, QQMusicSongSearchResult {
                var singers: [String] { [singer] }
                let mid: String
                let name: String
                let singer: String
                let id: String
            }
        }
    }
}

extension QQResponseSearchResult {
    var songs: [Data.Song.Item] {
        return data.song.list
    }
}

struct QQResponseSearchResult2: Decodable {
    struct Request: Decodable {
        struct Data: Decodable {
            struct Body: Decodable {
                struct Song: Decodable {
                    struct Item: Decodable, QQMusicSongSearchResult {
                        struct Singer: Decodable {
                            let name: String
                        }

                        let mid: String
                        let name: String
                        let _id: Int
                        let singer: [Singer]
                        var singers: [String] { singer.map(\.name) }
                        var id: String { .init(_id) }
                        enum CodingKeys: String, CodingKey {
                            case mid
                            case name
                            case _id = "id"
                            case singer
                        }
                    }

                    let list: [Item]
                }

                let song: Song
            }

            let body: Body
        }

        let data: Data
        let code: Int
    }

    let request: Request

    enum CodingKeys: String, CodingKey {
        case request = "req_1"
    }
}
