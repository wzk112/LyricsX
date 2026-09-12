import SwiftUI
import LyricsXCore

enum LyricMotion {
    static let response = 0.82
    static let damping = 0.86
    static let arrivalCurve = UnitCurve.bezier(startControlPoint: .init(x: 0.22, y: 0), endControlPoint: .init(x: 0.18, y: 1))
    static var animation: Animation { .spring(response: response, dampingFraction: damping, blendDuration: 0.2) }

    static func followResponse(lines: [LyricLine], index: Int?) -> Double {
        guard let index, lines.indices.contains(index), lines.indices.contains(index + 1) else { return response }
        return min(response, max(0.025, (lines[index + 1].time - lines[index].time) * 0.8))
    }

    static func following(lines: [LyricLine], index: Int?) -> Animation {
        let duration = followResponse(lines: lines, index: index)
        return .spring(response: duration, dampingFraction: damping, blendDuration: min(0.2, duration * 0.25))
    }

    struct Frame: Equatable, Sendable {
        var offset = 0.0
        var blur = 0.0
        var opacity = 1.0

    }
}

private struct LyricArrival<Trigger: Equatable & Sendable>: ViewModifier {
    let trigger: Trigger
    let reduced: Bool
    let distance: Double
    @State private var startedAt = 0.0
    @State private var running = false
    private let duration = 0.84

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !running || reduced)) { _ in
            let elapsed = startedAt == 0 ? duration : ProcessInfo.processInfo.systemUptime - startedAt
            let frame = reduced ? LyricMotion.Frame() : LyricLinePresentation(
                start: 0, duration: duration, stablePrefixCount: 0, layoutTail: "").frame(at: elapsed)
            content.offset(y: frame.offset * distance / 10).blur(radius: frame.blur).opacity(frame.opacity)
                .onChange(of: elapsed >= duration) { _, finished in if finished { running = false } }
        }
        .onChange(of: trigger) { _, _ in startedAt = ProcessInfo.processInfo.systemUptime; running = !reduced }
        .onChange(of: reduced) { _, value in if value { running = false } }
        .onDisappear { running = false }
    }
}

extension View {
    func lyricArrival(trigger: some Equatable & Sendable, reduced: Bool, distance: Double = 12) -> some View {
        modifier(LyricArrival(trigger: trigger, reduced: reduced, distance: distance))
    }
}
