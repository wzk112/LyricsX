import SwiftUI
import LyricsXCore

enum OverlayLayoutMetrics {
    static let chromeHeight = 78.0
    @MainActor static func height(preferences: Preferences) -> Double {
        chromeHeight + ceil(preferences.fontSize * 1.4) * 2 + preferences.overlaySecondaryMode.reservedHeight(
            translationSize: preferences.translationFontSize, nextSize: preferences.nextLineFontSize,
            primarySpacing: preferences.overlayPrimarySpacing, secondarySpacing: preferences.overlaySecondarySpacing)
    }
}

/// No outgoing row: the one primary surface starts at the previous next-row
/// geometry and moves on the cue clock. Nothing waits for a removal completion.
struct OverlayMotionFrame: Equatable {
    var offset = 0.0
    var scale = 1.0
    var blur = 0.0
    var opacity = 1.0

    static func make(time: Double, plan: LyricLinePresentation?, distance: Double?, nextScale: Double, reduced: Bool) -> Self {
        guard !reduced, let plan, let distance, plan.stablePrefixCount == 0 else { return .init() }
        let duration = min(0.58, plan.duration)
        let progress = min(1, max(0, (time - plan.start) / duration))
        guard progress < 1 else { return .init() }
        let settle = 0.007 * sin(.pi * max(0, (progress - 0.7) / 0.3))
        let eased = LyricMotion.arrivalCurve.value(at: progress) + settle
        return .init(offset: distance * (1 - eased), scale: nextScale + (1 - nextScale) * eased,
                     blur: 0.45 * (1 - min(1, eased)), opacity: 0.85 + 0.15 * min(1, eased))
    }

    func auxiliaryOpacity(top: Double, primaryHeight: Double, reduced: Bool) -> Double {
        guard !reduced else { return 1 }
        let primaryBottom = primaryHeight / 2 + offset + primaryHeight * scale / 2
        return LyricEmphasisFrame.smooth((top - primaryBottom) / 8)
    }
}

struct OverlayLyricsContent: View {
    let preferences: Preferences
    let document: LyricsDocument
    let index: Int
    let lyricTime: () -> Double
    var renderTime: (() -> Double)?
    var playing = false
    var secondaryMode: OverlaySecondaryMode?
    var adaptiveCanvasWidth: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prefs: Preferences { preferences }
    private func secondary(at index: Int) -> OverlaySecondaryMode.Content {
        guard document.lines.indices.contains(index) else { return .init() }
        let line = document.lines[index]
        let translation = prefs.showTranslation && line.hasTranslation ? line.translation.map(prefs.text) : nil
        let next = document.lines.indices.contains(index + 1) ? prefs.text(document.lines[index + 1].text) : nil
        return (secondaryMode ?? prefs.overlaySecondaryMode).content(translation: translation, next: next)
    }
    private func nextCenter(translation: Bool, primaryHeight: Double, nextHeight: Double) -> Double {
        primaryHeight + prefs.overlayPrimarySpacing + (translation ? prefs.translationFontSize * 1.4 + prefs.overlaySecondarySpacing : 0) + nextHeight / 2
    }

    private func primaryHeight(at index: Int) -> Double {
        guard let width = adaptiveCanvasWidth else { return ceil(prefs.fontSize * 1.4) * 2 }
        return OverlayTextMeasure.primaryHeight(document: document, index: index, preferences: prefs, canvasWidth: width)
    }

    var body: some View {
        let line = document.lines[index]
        let text = line.text.isEmpty ? "•••" : prefs.text(line.text)
        let content = secondary(at: index)
        let nextLine = document.lines.indices.contains(index + 1) ? document.lines[index + 1] : nil
        let nextPlan = nextLine.flatMap { _ in LyricLinePresentation.make(lines: document.lines, index: index + 1, transform: prefs.text) }?.withoutEntry(text: content.next ?? "")
        let previous = secondary(at: index - 1)
        let plan = LyricLinePresentation.make(lines: document.lines, index: index, transform: prefs.text)
        let reduced = reduceMotion || prefs.reduceMotion
        let primaryHeight = primaryHeight(at: index)
        let nextPrimaryHeight = self.primaryHeight(at: index + 1)
        let previousPrimaryHeight = self.primaryHeight(at: index - 1)
        let nextScale = prefs.nextLineFontSize / prefs.fontSize
        let nextHeight = nextPrimaryHeight * nextScale
        let translationHeight = prefs.translationFontSize * 1.4
        let translationTop = primaryHeight + prefs.overlayPrimarySpacing
        let nextY = nextCenter(translation: content.translation != nil, primaryHeight: primaryHeight, nextHeight: nextHeight)
        let promoted = previous.next != nil && plan?.stablePrefixCount == 0
        let distance = promoted ? nextCenter(translation: previous.translation != nil, primaryHeight: previousPrimaryHeight, nextHeight: primaryHeight * nextScale) - primaryHeight / 2 : nil
        let arrival = promoted ? plan?.withoutEntry(text: text) : plan
        let height = primaryHeight + (secondaryMode ?? prefs.overlaySecondaryMode).reservedHeight(
            translationSize: prefs.translationFontSize, nextSize: prefs.nextLineFontSize,
            primarySpacing: prefs.overlayPrimarySpacing, secondarySpacing: prefs.overlaySecondarySpacing)
        let sampledTime = lyricTime()
        let moving = !reduced && plan.map { sampledTime < $0.start + $0.duration } == true
        let wordFrames = LyricRenderTimelineActivity.needsFrames(line: line, time: sampledTime, arrival: arrival)
        GeometryReader { geometry in
            LyricRenderTimeline(running: playing && (moving || wordFrames), sampledTime: sampledTime, preciseTime: renderTime ?? lyricTime) { time in
                let motion = OverlayMotionFrame.make(time: time, plan: plan, distance: distance, nextScale: nextScale, reduced: reduced)
                ZStack {
                    lyricSurface(line: line, text: text, time: time, arrival: arrival, effects: prefs.lyricEmphasis)
                        .frame(width: geometry.size.width, height: primaryHeight, alignment: .bottom)
                        .scaleEffect(motion.scale).blur(radius: motion.blur)
                        .opacity(motion.opacity)
                        .position(x: geometry.size.width / 2, y: primaryHeight / 2 + motion.offset)
                    if let translation = content.translation {
                        Text(translation).font(.system(size: prefs.translationFontSize, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95)).lineLimit(1).minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: geometry.size.width, height: translationHeight)
                            .opacity(motion.auxiliaryOpacity(top: translationTop, primaryHeight: primaryHeight, reduced: reduced))
                            .position(x: geometry.size.width / 2, y: translationTop + translationHeight / 2)
                    }
                    if let next = content.next, let nextLine {
                        // Preview and primary use identical wrapping. Transform
                        // the cached layout rather than re-typesetting each size.
                        lyricSurface(line: nextLine, text: next, time: nextLine.time, arrival: nextPlan,
                                     effects: .init(lift: prefs.lyricWordLift, glow: false, reduced: reduced))
                            .frame(width: geometry.size.width, height: nextPrimaryHeight, alignment: .bottom)
                            .scaleEffect(nextScale).blur(radius: reduced ? 0 : 0.45)
                            .opacity(0.85 * motion.auxiliaryOpacity(top: nextY - nextHeight / 2, primaryHeight: primaryHeight, reduced: reduced))
                            .position(x: geometry.size.width / 2, y: nextY)
                    }
                }
            }
        }.frame(height: height)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private func lyricSurface(line: LyricLine, text: String, time: Double, arrival: LyricLinePresentation?, effects: LyricEmphasisOptions) -> some View {
        WordHighlight(line: line, time: time, active: true, text: text, effects: effects, arrival: arrival)
            .font(.system(size: prefs.fontSize, weight: .semibold))
            .tracking(-0.4).multilineTextAlignment(.center).foregroundStyle(.white)
            .lineLimit(2).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
    }
}
