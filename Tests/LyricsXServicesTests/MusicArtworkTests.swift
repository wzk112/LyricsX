import Foundation
import Testing
@testable import LyricsXServices

@Test func musicArtworkFallbackRequiresSamePlayerAndSong() throws {
    let json = #"{"title":"Song","artist":"Artist","album":"Album","bundleIdentifier":"com.apple.Music","artworkDataBase64":"AQID"}"#
    var payload = try JSONDecoder().decode(SystemMediaPayload.self, from: Data(json.utf8))
    #expect(payload.matchingMusicArtwork(title: "Song", artist: "Artist", album: "Album") == Data([1,2,3]))
    #expect(payload.matchingMusicArtwork(title: "Other", artist: "Artist", album: "Album") == nil)
    #expect(payload.matchingMusicArtwork(title: "Song", artist: "Other", album: "Album") == nil)
    #expect(payload.matchingMusicArtwork(title: "Song", artist: "Artist", album: "Live") == nil)
    payload.bundleIdentifier = "com.spotify.client"
    #expect(payload.matchingMusicArtwork(title: "Song", artist: "Artist", album: "Album") == nil)
}

@Test func musicArtworkFallbackAcceptsParentAndDataURIWithoutCrossPlayerBorrowing() throws {
    let json = #"{"title":"Song","artist":"Artist","album":"Album","bundleIdentifier":"helper","parentApplicationBundleIdentifier":"com.apple.Music","artworkDataBase64":"data:image/png;base64,AQID"}"#
    var payload = try JSONDecoder().decode(SystemMediaPayload.self, from: Data(json.utf8))
    #expect(payload.matchingMusicArtwork(title: "Song", artist: "Artist", album: "") == Data([1, 2, 3]))
    payload.parentApplicationBundleIdentifier = "com.apple.Safari"
    payload.bundleIdentifier = "com.apple.Music"
    #expect(payload.matchingMusicArtwork(title: "Song", artist: "Artist", album: "Album") == nil)
}

@Test func musicArtworkFallbackRejectsMissingInvalidAndOversizedData() throws {
    let json = #"{"title":"Song","artist":"Artist","album":"Album","bundleIdentifier":"com.apple.Music"}"#
    var payload = try JSONDecoder().decode(SystemMediaPayload.self, from: Data(json.utf8))
    for encoded in [nil, "", "not-base64", Data(repeating: 1, count: 8_000_000).base64EncodedString()] as [String?] {
        payload.artworkDataBase64 = encoded
        #expect(payload.matchingMusicArtwork(title: "Song", artist: "Artist", album: "Album") == nil)
    }
}
