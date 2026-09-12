import Foundation

/// A short information row uses the same user-selected width as timed lyrics.
/// Text and artwork grow gently, with room for a two-line title at every width.
struct OverlaySongCardLayout {
    let width: Double
    private var scale: Double { min(1, max(0, (width - 320) / 400)) }
    var artwork: Double { 42 + 18 * scale }
    var title: Double { 17 + 4 * scale }
    var artist: Double { 12 + 2 * scale }
    var spacing: Double { 12 + 4 * scale }
    var height: Double { ceil(108 + 12 * scale) }
    var contentWidth: Double { max(260, width - 60) }
}
