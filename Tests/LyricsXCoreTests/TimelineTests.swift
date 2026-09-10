import Foundation
import Testing
@testable import LyricsXCore

private let song = Track(playerID: "test", playerName: "Test", title: "Song", duration: 100)
@Test func pausedClockNeverAdvances() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 42, isPlaying: false, sampledAt: 100))
    #expect(clock.position(at: 500) == 42)
}
@Test func missedResumeIsRecoveredBySnapshot() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 42, isPlaying: false, sampledAt: 100))
    clock.accept(.init(track: song, position: 42, isPlaying: true, sampledAt: 200))
    #expect(clock.position(at: 201) == 43)
}
@Test func droppedSourceCannotRunForever() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 10, isPlaying: true, sampledAt: 100))
    #expect(clock.position(at: 1000) == 13)
}
@Test func seekingBackwardReanchorsImmediately() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 70, isPlaying: true, sampledAt: 100))
    clock.seek(to: 12, at: 101)
    #expect(clock.position(at: 102) == 13)
}
@Test func resumeAfterSleepUsesFreshPlayerPosition() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 10, isPlaying: true, sampledAt: 100))
    clock.freeze(at: 101)
    #expect(clock.position(at: 5000) == 11)
    clock.accept(.init(track: song, position: 26, isPlaying: true, sampledAt: 5000))
    #expect(clock.position(at: 5001) == 27)
}
@Test func invalidPositionsAreIgnoredAndDurationClamped() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 99, isPlaying: true, sampledAt: 100))
    clock.accept(.init(track: song, position: .nan, isPlaying: true, sampledAt: 101))
    #expect(clock.position(at: 102) == 100)
    clock.seek(to: -.infinity, at: 100)
    #expect(clock.position(at: 102) == 100)
}
@Test func futureSampleDoesNotReverseTime() {
    var clock = PlaybackTimeline()
    clock.accept(.init(track: song, position: 20, isPlaying: true, sampledAt: 100))
    #expect(clock.position(at: 99) == 20)
}
@Test func titleArtistAndPlayerArePartOfIdentityButArtworkIsNot() {
    var another = song; another.artist = "Other"
    #expect(another.id != song.id)
    another = song; another.playerID = "other"
    #expect(another.id != song.id)
    another = song; another.artworkData = Data([1, 2, 3])
    #expect(another.id == song.id)
}
@Test func identityCannotCollideThroughDelimiters() {
    let one = Track(playerID: "a", playerName: "", title: "b:c", artist: "d")
    let two = Track(playerID: "a", playerName: "", title: "b", artist: "c:d")
    #expect(one.id != two.id)
}
@Test func lyricBoundariesAndOffsetAreConsistent() {
    let lines = [LyricLine(id: 0, time: 5, text: "A"), LyricLine(id: 1, time: 10, text: "B"), LyricLine(id: 2, time: 15, text: "")]
    var doc = LyricsDocument(lines: lines)
    #expect(doc.index(at: 4.999) == nil)
    #expect(doc.index(at: 5) == 0)
    #expect(doc.index(at: 10) == 1)
    #expect(doc.index(at: 20) == 2) // A blank line clears the preceding lyric.
    #expect(doc.index(at: .nan) == nil)
    doc.offsetMilliseconds = 500
    #expect(doc.index(at: 9.5) == 1)
    #expect(doc.seekPosition(for: lines[1]) == 9.5)
}
@Test func duplicateTimestampsUseLastDeterministicLine() {
    let doc = LyricsDocument(lines: [.init(id: 5, time: 10, text: "A"), .init(id: 6, time: 10, text: "B")])
    #expect(doc.index(at: 10) == 1)
}
@Test func invalidTimestampsAreFiltered() {
    let doc = LyricsDocument(lines: [.init(id: 1, time: .nan, text: "A"), .init(id: 2, time: -1, text: "B"), .init(id: 3, time: 4, text: "C")])
    #expect(doc.lines.count == 1); #expect(doc.lines.first?.id == 0)
}
@Test func wordCueProgressClamps() {
    let word = WordCue(text: "hello", start: 10, end: 12)
    #expect(word.progress(at: 9) == 0); #expect(word.progress(at: 11) == 0.5); #expect(word.progress(at: 20) == 1)
}
@Test func differentArtistsAndLiveDurationsAreRejected() {
    let track = Track(playerID: "test", playerName: "", title: "Song", artist: "Singer", duration: 180)
    #expect(CandidateRanker.score(.init(title: "Song", artist: "Another", duration: 180), for: track) == 0)
    #expect(CandidateRanker.score(.init(title: "Song", artist: "Singer", duration: 230), for: track) == 0)
    #expect(CandidateRanker.score(.init(title: "ＳＯＮＧ", artist: "singer", duration: 180), for: track) >= 90)
}
