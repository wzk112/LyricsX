import AppKit
import CoreImage

/// A small, already blurred backdrop needs no live full-window blur surface.
/// Keep only the last request; never persist artwork or derived images to disk.
actor AmbientArtworkRenderer {
    static let shared = AmbientArtworkRenderer()
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private var cached: (key: AmbientArtworkKey, source: CGImage, image: CGImage)?

    func render(_ source: CGImage, key: AmbientArtworkKey) -> CGImage? {
        if let cached, cached.key == key, cached.source === source { return cached.image }
        guard !Task.isCancelled else { return nil }
        let size = key.size
        let downsample = min(1, 384 / max(size.width, size.height))
        let width = max(1, (size.width * downsample).rounded())
        let height = max(1, (size.height * downsample).rounded())
        let scale = max(width / CGFloat(source.width), height / CGFloat(source.height))
        let image = CIImage(cgImage: source).transformed(by: .init(scaleX: scale, y: scale))
        let centered = image.transformed(by: .init(translationX: (width - image.extent.width) / 2,
                                                 y: (height - image.extent.height) / 2))
        let result = centered.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 85 * downsample])
        guard let rendered = context.createCGImage(result, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        cached = (key, source, rendered)
        return rendered
    }
}

struct AmbientArtworkKey: Hashable, Sendable {
    let artwork: ObjectIdentifier
    let width: Int
    let height: Int
    init(artwork: NSImage, size: CGSize) {
        self.artwork = ObjectIdentifier(artwork)
        // Quantize live resizing so each pixel of movement is not a new job.
        width = max(64, Int(ceil(size.width / 64)) * 64)
        height = max(64, Int(ceil(size.height / 64)) * 64)
    }
    var size: CGSize { CGSize(width: width, height: height) }
}
