import AppKit
import Observation
import LyricsXCore

/// Window hysteresis is independent of playback frames and lyric rendering.
struct OverlaySizingPolicy {
    private(set) var size = NSSize.zero
    private var smallerSince: Double?
    private var pending = NSSize.zero
    private var lastGrowth = -Double.infinity

    mutating func resolve(_ desired: NSSize, at now: Double, immediate: Bool = false) -> NSSize {
        if immediate || size == .zero {
            size = desired; pending = .zero; smallerSince = nil; lastGrowth = now
            return size
        }
        let grown = NSSize(width: max(size.width, desired.width), height: max(size.height, desired.height))
        if grown != size {
            size = grown; lastGrowth = now; smallerSince = nil
        }
        // One width bucket is a dead band. Height changes require the same hold
        // as width, so a brief short line never collapses the two-line slot.
        let smaller = desired.width <= size.width - 80 || desired.height <= size.height - 12
        guard smaller else { smallerSince = nil; pending = .zero; return size }
        if smallerSince == nil { smallerSince = now; pending = desired }
        else {
            // Reserve the largest request during the quiet interval. Rapid
            // small variations cannot oscillate between width buckets.
            pending.width = max(pending.width, desired.width)
            pending.height = max(pending.height, desired.height)
        }
        if now - (smallerSince ?? now) >= 1.25, now - lastGrowth >= 1.6 {
            size = pending; smallerSince = nil; pending = .zero
        }
        return size
    }
}

@Observable @MainActor
final class OverlayViewport {
    var width: Double
    init(width: Double) { self.width = width }
}

/// Measure full lines once, never individual reveal frames. The rendering canvas
/// remains at maximum width while only the native glass/window bounds animate.
@MainActor enum OverlayTextMeasure {
    private struct Key: Hashable { let text: String; let font: Double; let tracking: Double }
    private static var cache: [Key: Double] = [:]
    private struct LineKey: Hashable { let document: UUID; let index: Int; let conversion: String; let text: String }
    private static var lineCache: [LineKey: String] = [:]
    static func width(_ text: String, font: Double, tracking: Double = -0.4) -> Double {
        let key = Key(text: text, font: font, tracking: tracking)
        if let value = cache[key] { return value }
        let value = ceil((text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: font, weight: .semibold), .kern: tracking
        ]).width)
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }
    static func layoutText(document: LyricsDocument, index: Int, preferences: Preferences) -> String {
        guard document.lines.indices.contains(index) else { return "" }
        let key = LineKey(document: document.id, index: index, conversion: preferences.conversion, text: document.lines[index].text)
        if let value = lineCache[key] { return value }
        let text = preferences.text(document.lines[index].text)
        let value = text + (LyricLinePresentation.make(lines: document.lines, index: index, transform: preferences.text)?.layoutTail ?? "")
        if lineCache.count >= 256 { lineCache.removeAll(keepingCapacity: true) }
        lineCache[key] = value
        return value
    }
    static func primaryHeight(document: LyricsDocument, index: Int, preferences: Preferences, canvasWidth: Double) -> Double {
        let text = layoutText(document: document, index: index, preferences: preferences)
        let rows = text.contains("\n") || width(text, font: preferences.fontSize) > canvasWidth - 8 ? 2.0 : 1.0
        return ceil(preferences.fontSize * 1.4) * rows
    }
    static func desiredSize(document: LyricsDocument, index: Int, preferences p: Preferences, maximumWidth: Double) -> NSSize {
        let minimum = min(maximumWidth, max(320, p.overlayMinimumWidth))
        guard document.lines.indices.contains(index) else {
            return .init(width: maximumWidth, height: OverlayLayoutMetrics.height(preferences: p))
        }
        let text = layoutText(document: document, index: index, preferences: p)
        var needed = width(text, font: p.fontSize) * 1.08 + 84
        let line = document.lines[index]
        let nextText = document.lines.indices.contains(index + 1)
            ? layoutText(document: document, index: index + 1, preferences: p) : nil
        let auxiliary = p.overlaySecondaryMode.content(
            translation: p.showTranslation && line.hasTranslation ? line.translation.map(p.text) : nil,
            next: nextText)
        if let translation = auxiliary.translation {
            needed = max(needed, width(translation, font: p.translationFontSize, tracking: 0) + 72)
        }
        if let next = auxiliary.next {
            // The next row shares the future primary's wrapping, scaled down.
            needed = max(needed, min(width(next, font: p.fontSize), maximumWidth - 60) * p.nextLineFontSize / p.fontSize + 84)
        }
        let width = min(maximumWidth, max(minimum, ceil(needed / 40) * 40))
        let primary = primaryHeight(document: document, index: index, preferences: p, canvasWidth: maximumWidth - 60)
        return .init(width: width, height: OverlayLayoutMetrics.chromeHeight + primary + p.overlaySecondaryMode.reservedHeight(
            translationSize: p.translationFontSize, nextSize: p.nextLineFontSize,
            primarySpacing: p.overlayPrimarySpacing, secondarySpacing: p.overlaySecondarySpacing))
    }
}

struct OverlayAnchor {
    var topCenter: NSPoint
    func frame(size: NSSize, in screen: NSRect) -> NSRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        return .init(x: max(screen.minX, min(topCenter.x - width / 2, screen.maxX - width)),
                     y: max(screen.minY, min(topCenter.y - height, screen.maxY - height)),
                     width: width, height: height)
    }
}
