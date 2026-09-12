import Foundation
import SwiftUI
import Testing
import LyricsXCore
import LyricsXServices
@testable import LyricsXApp

@Test func exactPrefixGrowthPreservesOldCharactersAndReservesOnlyItsOwnChain() throws {
    let strings = ["G", "Go", "Go slowly", "Go slowly now", "A new line", "A new line"]
    let lines = strings.enumerated().map { LyricLine(id: $0, time: Double($0) * 0.08, text: $1) }
    let first = try #require(LyricLinePresentation.make(lines: lines, index: 0))
    #expect(first.stablePrefixCount == 0 && "G" + first.layoutTail == "Go slowly now")
    for index in 1...3 {
        let value = try #require(LyricLinePresentation.make(lines: lines, index: index))
        #expect(value.stablePrefixCount == strings[index - 1].count)
        #expect(strings[index] + value.layoutTail == "Go slowly now")
    }
    #expect(LyricLinePresentation.make(lines: lines, index: 4)?.stablePrefixCount == 0)
    #expect(LyricLinePresentation.make(lines: lines, index: 5)?.stablePrefixCount == 0)
}

@Test func incrementalComparisonUsesWholeGraphemesAndDoesNotCrossPauses() throws {
    let lines = [LyricLine(id: 0, time: 0, text: "👩🏽‍🚀光"), .init(id: 1, time: 0.1, text: "👩🏽‍🚀光e\u{301}"),
                 .init(id: 2, time: 4, text: "👩🏽‍🚀光e\u{301}再见"), .init(id: 3, time: 5, text: "")]
    let second = try #require(LyricLinePresentation.make(lines: lines, index: 1))
    #expect(second.stablePrefixCount == 2 && second.layoutTail.isEmpty)
    #expect(LyricLinePresentation.make(lines: lines, index: 2)?.stablePrefixCount == 0)
    #expect(LyricLinePresentation.make(lines: lines, index: 3) == nil)
}

@Test func everyFastLineGetsItsOwnImmediateClockDrivenArrival() throws {
    let lines = (0..<80).map { LyricLine(id: $0, time: Double($0) * 0.08, text: "line \($0)") }
    for index in lines.indices.dropLast() {
        let plan = try #require(LyricLinePresentation.make(lines: lines, index: index))
        let initial = plan.frame(at: lines[index].time + 0.002)
        #expect(initial.offset > 0 && initial.opacity > 0.8 && initial.opacity < 1)
        #expect(initial.blur < 1)
        if index < lines.count - 1 { #expect(plan.frame(at: lines[index + 1].time) == .init()) }
        #expect(plan.frame(at: lines[index].time + 2) == .init())
        // Seeking back re-evaluates the same curve, without another task.
        #expect(plan.frame(at: lines[index].time + 0.002) == initial)
    }
}

@Test func nextRowMovesFromItsOldPositionWithoutAnOutgoingLayer() throws {
    let lines = [LyricLine(id: 0, time: 0, text: "First"), .init(id: 1, time: 3, text: "Next"),
                 .init(id: 2, time: 3.1, text: "Next grows"), .init(id: 3, time: 6, text: "Last")]
    let plan = try #require(LyricLinePresentation.make(lines: lines, index: 1))
    let initial = OverlayMotionFrame.make(time: 3, plan: plan, distance: 90, nextScale: 0.5, reduced: false)
    #expect(initial.offset == 90 && initial.scale == 0.5 && initial.opacity == 0.85)
    let intermediate = OverlayMotionFrame.make(time: 3.04, plan: plan, distance: 90, nextScale: 0.5, reduced: false)
    #expect(intermediate.offset < initial.offset && intermediate.scale > initial.scale)
    #expect(OverlayMotionFrame.make(time: 3.1, plan: plan, distance: 90, nextScale: 0.5, reduced: false) == .init())
    let growth = LyricLinePresentation.make(lines: lines, index: 2)
    #expect(OverlayMotionFrame.make(time: 3.11, plan: growth, distance: 90, nextScale: 0.5, reduced: false) == .init())
    #expect(initial.auxiliaryOpacity(top: 84, primaryHeight: 72, reduced: false) == 0)
    #expect(OverlayMotionFrame().auxiliaryOpacity(top: 84, primaryHeight: 72, reduced: false) == 1)
}

@Test func drawingFramesReuseTextMeasurementUntilTheProposalChanges() {
    var cache = LyricSizeCache(), measurements = 0
    for _ in 0..<600 {
        let size = cache.size(proposal: .init(width: 500, height: nil)) {
            measurements += 1
            return CGSize(width: 500, height: 72)
        }
        #expect(size.height == 72)
    }
    #expect(measurements == 1)
    _ = cache.size(proposal: .init(width: 300, height: nil)) { measurements += 1; return .init(width: 300, height: 108) }
    #expect(measurements == 2)
}

/// Optional local verification: never copies lyric contents or private paths
/// into fixtures, logs, build products or the release.
@Test func localRapidLyricsUseTheProductionParserAndCadence() throws {
    guard let paths = ProcessInfo.processInfo.environment["LYRICSX_LOCAL_TIMELINE_FIXTURES"] else { return }
    for path in paths.components(separatedBy: ":") {
        let document = try LyricsCodec.read(URL(fileURLWithPath: path))
        #expect(document.lines.count > 1)
        let first = document.seekPosition(for: document.lines[0])
        let end = document.seekPosition(for: document.lines.last!) + 1
        func countSeen(adaptive: Bool) -> Int {
            var seen = Set<Int>(), time = first
            while time < end {
                if let index = document.index(at: time) { seen.insert(index) }
                time += adaptive ? LyricTickCadence.milliseconds(playing: true, visible: true, document: document, position: time) / 1_000 : 0.1
            }
            return seen.count
        }
        let old = countSeen(adaptive: false), improved = countSeen(adaptive: true)
        let growing = document.lines.indices.filter {
            (LyricLinePresentation.make(lines: document.lines, index: $0)?.stablePrefixCount ?? 0) > 0
        }.count
        #expect(improved >= old)
        print("Local timing diagnostic: lines=\(document.lines.count), prefix-growth=\(growing), old-visible=\(old), adaptive-visible=\(improved)")
    }
}

@Test func refreshCadenceCatchesFastLineBoundariesAndStillThrottlesHiddenPlayback() {
    let fast = LyricsDocument(title: "Fast", lines: (0..<20).map { .init(id: $0, time: Double($0) * 0.08, text: "\($0)") })
    #expect(LyricTickCadence.milliseconds(playing: true, visible: true, document: fast, position: 0) <= 16)
    #expect(LyricMotion.followResponse(lines: fast.lines, index: 0) < fast.lines[1].time - fast.lines[0].time)
    #expect(LyricTickCadence.milliseconds(playing: true, visible: true, document: fast, position: 0.075) == 8)
    #expect(LyricTickCadence.milliseconds(playing: true, visible: false, document: fast, position: 0) == 250)
    #expect(LyricTickCadence.milliseconds(playing: false, visible: true, document: fast, position: 0) == 500)
    let slow = LyricsDocument(title: "Slow", lines: [.init(id: 0, time: 0, text: "one"), .init(id: 1, time: 5, text: "two")])
    #expect(LyricTickCadence.milliseconds(playing: true, visible: true, document: slow, position: 4.99) < 12)
    #expect(LyricTickCadence.milliseconds(playing: true, visible: true, document: slow, position: 7) == 100)
    #expect(LyricMotion.followResponse(lines: slow.lines, index: 0) == LyricMotion.response)
}

@Test func displayFramesStopDuringLongGapsButWakeBeforeTheNextCue() {
    let line = LyricLine(id: 0, time: 0, text: "Stay here", words: [
        .init(text: "Stay", start: 0, end: 2), .init(text: "here", start: 4, end: 5)
    ])
    #expect(LyricRenderTimelineActivity.needsFrames(line: line, time: 1, arrival: nil))
    #expect(!LyricRenderTimelineActivity.needsFrames(line: line, time: 3, arrival: nil))
    #expect(LyricRenderTimelineActivity.needsFrames(line: line, time: 3.95, arrival: nil))
    #expect(!LyricRenderTimelineActivity.needsFrames(line: line, time: 6, arrival: nil))
}
