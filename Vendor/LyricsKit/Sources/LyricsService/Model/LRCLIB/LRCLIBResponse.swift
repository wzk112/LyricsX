import Foundation

struct LRCLIBResponse: Codable {
    let id: Int
    let name: String
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}
