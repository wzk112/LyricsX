import AppKit
import Observation
import LyricsXCore

/// Window hysteresis is independent of playback frames and lyric rendering.
struct OverlaySizingPolicy {
    private(set) var size = NSSize.zero
    private var shorterSince: Double?

    mutating func resolve(_ desired: NSSize, at now: Double, immediate: Bool = false) -> NSSize {
        // Width is a user setting, never inferred from the current lyric.
        if immediate || size == .zero {
            size = desired; shorterSince = nil
            return size
        }
        size.width = desired.width
        if desired.height >= size.height {
            size.height = desired.height; shorterSince = nil
            return size
        }
        guard desired.height <= size.height - 12 else { shorterSince = nil; return size }
        if shorterSince == nil { shorterSince = now }
        // Let the incoming row settle, then use its current measured height.
        // Keeping the largest old request made shrinking happen in slow steps.
        // Full incremental chains already share one measurement, while brief
        // short interjections are filtered by this small stability interval.
        if now - (shorterSince ?? now) >= 0.65 {
            size.height = desired.height; shorterSince = nil
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
/// keeps its fixed width while only the native glass/window height animates.
@MainActor enum OverlayTextMeasure {
    private struct Key: Hashable { let text: String; let font: Double; let tracking: Double; let weight: Double }
    private static var cache: [Key: Double] = [:]
    private struct LineKey: Hashable { let document: UUID; let index: Int; let conversion: String; let text: String }
    private static var lineCache: [LineKey: String] = [:]
    static func width(_ text: String, font: Double, tracking: Double = -0.4, weight: NSFont.Weight = .semibold) -> Double {
        let key = Key(text: text, font: font, tracking: tracking, weight: weight.rawValue)
        if let value = cache[key] { return value }
        let value = ceil((text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: font, weight: weight), .kern: tracking
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
    static func translationHeight(_ text: String?, font: Double, canvasWidth: Double) -> Double {
        guard let text else { return 0 }
        let rows = text.contains("\n") || width(text, font: font, tracking: 0, weight: .medium) > canvasWidth - 8 ? 2.0 : 1.0
        return ceil(font * 1.4) * rows
    }
    static func desiredSize(document: LyricsDocument, index: Int, preferences p: Preferences, maximumWidth: Double) -> NSSize {
        .init(width: maximumWidth, height: height(document: document, index: index, preferences: p, maximumWidth: maximumWidth))
    }
    static func secondary(document: LyricsDocument, index: Int, preferences p: Preferences) -> OverlaySecondaryMode.Content {
        guard document.lines.indices.contains(index) else { return .init() }
        let line = document.lines[index]
        return p.overlaySecondaryMode.content(
            translation: p.showTranslation && line.hasTranslation ? line.translation.map(p.text) : nil,
            next: document.lines.indices.contains(index + 1) ? p.text(document.lines[index + 1].text) : nil)
    }
    static func height(document: LyricsDocument, index: Int, preferences p: Preferences, maximumWidth: Double) -> Double {
        let primary = primaryHeight(document: document, index: index, preferences: p, canvasWidth: maximumWidth - 60)
        let next = primaryHeight(document: document, index: index + 1, preferences: p, canvasWidth: maximumWidth - 60) * p.nextLineFontSize / p.fontSize
        let auxiliary = secondary(document: document, index: index, preferences: p)
        return OverlayLayoutMetrics.chromeHeight + primary + auxiliary.height(
            translationHeight: translationHeight(auxiliary.translation, font: p.translationFontSize, canvasWidth: maximumWidth - 60), nextHeight: next,
            primarySpacing: p.overlayPrimarySpacing, secondarySpacing: p.overlaySecondarySpacing)
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
