import Foundation

struct QQResponseSongDetail: Decodable {
    let songinfo: Songinfo

    struct Songinfo: Decodable {
        let data: SongData

        struct SongData: Decodable {
            let trackInfo: TrackInfo

            struct TrackInfo: Decodable {
                let album: Album

                struct Album: Decodable {
                    let mid: String
                }

                private enum CodingKeys: String, CodingKey {
                    case album
                }
            }

            private enum CodingKeys: String, CodingKey {
                case trackInfo = "track_info"
            }
        }
    }
}
