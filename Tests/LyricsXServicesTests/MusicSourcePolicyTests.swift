import Testing
import LyricsXCore
@testable import LyricsXServices

@Test func automaticSourcePolicyAcceptsMusicAndRejectsBrowserHelpers() {
    for id in ["com.apple.Music", "com.spotify.client", "com.netease.163music", "com.tencent.QQMusicMac", "com.tencent.QQMusic.D5Q73692VW"] {
        #expect(MusicSourcePolicy.accepts(bundleID: id))
    }
    for id in ["com.apple.Safari", "com.apple.Safari.WebApp.example", "com.google.Chrome.helper", "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser", "com.lyricsx.modern"] {
        #expect(!MusicSourcePolicy.accepts(bundleID: id, category: "public.app-category.music"))
    }
    #expect(!MusicSourcePolicy.accepts(bundleID: nil))
    #expect(!MusicSourcePolicy.accepts(bundleID: "unknown.player"))
    #expect(MusicSourcePolicy.accepts(bundleID: "another.musicplayer", category: "public.app-category.music"))
    #expect(!MusicSourcePolicy.accepts(bundleID: "another.browser", category: "public.app-category.productivity"))
}

@Test @MainActor func pausedNotifyingPlayersBackOffButManualRefreshWakesImmediately() async throws {
    var reads = 0
    var playing = false
    let track = Track(playerID: "com.apple.Music", playerName: "Music", title: "Test", artist: "Test", duration: 120)
    let bridge = PlayerBridge(snapshotReader: {
        reads += 1
        return .init(track: track, position: 10, isPlaying: playing)
    })
    defer { bridge.stop() }
    bridge.refresh()
    for _ in 0..<100 where reads == 0 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(bridge.pollInterval == 5)
    playing = true
    bridge.refresh()
    for _ in 0..<100 where reads < 2 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(reads == 2)
    #expect(bridge.pollInterval == 1)
}
