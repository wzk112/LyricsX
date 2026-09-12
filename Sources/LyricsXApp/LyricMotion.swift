import SwiftUI

enum LyricMotion {
    static let response = 0.68
    static let damping = 0.78
    static var animation: Animation { .spring(response: response, dampingFraction: damping, blendDuration: 0.12) }

    struct Frame: Equatable, Sendable {
        var offset = 0.0
        var blur = 0.0
        var opacity = 1.0
        var isSettled: Bool { abs(offset) < 0.06 && blur < 0.01 && opacity > 0.99 }
        func arrival(distance: Double) -> Frame {
            // Rapid lyrics continue from their current presentation. Resetting
            // the offset on every syllable would create a visible downward jump.
            isSettled ? Frame(offset: distance, blur: 2.2, opacity: 0.5) : self
        }
    }
}

private struct LyricArrival<Trigger: Equatable & Sendable>: ViewModifier {
    let trigger: Trigger
    let reduced: Bool
    let distance: Double

    func body(content: Content) -> some View {
        if reduced { content }
        else {
            // Animate a single live view. There is no departing lyric layer to
            // linger behind the new text, even when keyframes are interrupted.
            content.keyframeAnimator(initialValue: LyricMotion.Frame(), trigger: trigger) { view, frame in
                view.offset(y: frame.offset).blur(radius: max(0, frame.blur)).opacity(min(1, max(0, frame.opacity)))
            } keyframes: { current in
                KeyframeTrack(\.offset) {
                    MoveKeyframe(current.arrival(distance: distance).offset)
                    SpringKeyframe(0, duration: 0.72, spring: Spring(response: LyricMotion.response, dampingRatio: LyricMotion.damping))
                }
                KeyframeTrack(\.blur) {
                    MoveKeyframe(current.arrival(distance: distance).blur)
                    CubicKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(current.arrival(distance: distance).opacity)
                    CubicKeyframe(1, duration: 0.2)
                }
            }
        }
    }
}

extension View {
    func lyricArrival(trigger: some Equatable & Sendable, reduced: Bool, distance: Double = 14) -> some View {
        modifier(LyricArrival(trigger: trigger, reduced: reduced, distance: distance))
    }
}
