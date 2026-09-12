import SwiftUI

/// A drawing timestamp cannot change text geometry. Stop those invalidations
/// here instead of remeasuring the entire window for every display frame.
struct LyricLayoutBoundary<Content: View>: View {
    let text: String
    @ViewBuilder let content: () -> Content
    @Environment(\.font) private var font
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.minimumScaleFactor) private var minimumScaleFactor
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.lineSpacing) private var spacing
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.legibilityWeight) private var legibility
    @Environment(\.layoutDirection) private var direction
    @Environment(\.locale) private var locale

    var body: some View {
        StableLyricLayout(inputs: .init(text: text, font: font, lineLimit: lineLimit, minimumScaleFactor: minimumScaleFactor,
            alignment: alignment, spacing: spacing, dynamicType: dynamicType, legibility: legibility,
            direction: direction, locale: locale.identifier)) { content() }
    }
}

private struct LyricLayoutInputs: Equatable {
    let text: String
    let font: Font?
    let lineLimit: Int?
    let minimumScaleFactor: CGFloat
    let alignment: TextAlignment
    let spacing: CGFloat
    let dynamicType: DynamicTypeSize
    let legibility: LegibilityWeight?
    let direction: LayoutDirection
    let locale: String
}

struct LyricSizeCache {
    private struct Key: Hashable { let width: CGFloat?; let height: CGFloat? }
    private var values: [Key: CGSize] = [:]
    mutating func size(proposal: ProposedViewSize, measure: () -> CGSize) -> CGSize {
        let key = Key(width: proposal.width, height: proposal.height)
        if let value = values[key] { return value }
        let value = measure()
        if values.count >= 8 { values.removeAll(keepingCapacity: true) }
        values[key] = value
        return value
    }
}

private struct StableLyricLayout: Layout {
    let inputs: LyricLayoutInputs
    struct Cache {
        var inputs: LyricLayoutInputs
        var sizes = LyricSizeCache()
    }
    func makeCache(subviews: Subviews) -> Cache { Cache(inputs: inputs) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if cache.inputs != inputs { cache = Cache(inputs: inputs) }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache.sizes.size(proposal: proposal) { subviews.first?.sizeThatFits(proposal) ?? .zero }
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .init(bounds.size))
    }
}
