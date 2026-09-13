import Testing
import Foundation
import LyricsXCore
@testable import LyricsXApp

private struct IdleRepository: LyricsRepository {
    func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { $0.finish() } }
    func save(_ document: LyricsDocument, for track: Track) async throws {}
}

@Test @MainActor func lyricClockSleepsWhenPausedAndRestartsOnPlaybackObservation() async throws {
    let suite = "LyricsXTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(repository: IdleRepository(), preferences: Preferences(defaults: defaults))
    defer { model.stop() }
    model.startLyricClock()
    #expect(!model.isLyricClockRunning)
    let track = Track(playerID: "test", playerName: "Test", title: "Test", artist: "Test", duration: 100)
    model.session.accept(.init(track: track, position: 1, isPlaying: true), shouldSearch: false)
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.isLyricClockRunning)
    model.session.accept(.init(track: track, position: 2, isPlaying: false), shouldSearch: false)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!model.isLyricClockRunning)
    let position = model.session.position
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.session.position == position)
    model.session.accept(.init(track: track, position: 2, isPlaying: true), shouldSearch: false)
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.isLyricClockRunning)
}
