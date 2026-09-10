import Foundation

struct KugouResponseSearchResult: Codable {
    struct Data: Codable {
        struct Info: Codable {
            struct TransParam: Codable {
                let unionCover: String?

                private enum CodingKeys: String, CodingKey {
                    case unionCover = "union_cover"
                }
            }

            let hash: String
            let albumID: String
            let albumAudioID: Int
            let transParam: TransParam?

            private enum CodingKeys: String, CodingKey {
                case hash
                case albumID = "album_id"
                case albumAudioID = "album_audio_id"
                case transParam = "trans_param"
            }
        }

//        let timestamp: Date
//        let tab: String
//        let forcecorrection: Int
//        let correctiontype: Int
//        let total: Int
//        let istag: Int
//        let allowerr: Int
        let info: [Info]
//        let correctiontip: String
//        let istagresult: Int
    }

//    let status: Int
//    let errcode: Int
    let data: Data
//    let error: String
}

struct KugouResponseSearchResultCandidates: Decodable {
    let candidates: [Item]

    // let info: String
    // let status: Int
    // let proposal: String
    // let keyword: String
    //

    struct Item: Decodable {
        let id: String
        let accesskey: String
        let song: String
        let singer: String
        let duration: Int // in msec

        // let adjust: Int
        // let hitlayer: Int
        // let krctype: Int
        // let language: String
        // let nickname: String
        // let originame: String
        // let origiuid: String
        // let score: Int
        // let soundname: String
        // let sounduid: String
        // let transname: String
        // let transuid: String
        // let uid: String
        //

        // let parinfo: [Any]
    }
}
