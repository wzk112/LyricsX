import AppKit
import QuartzCore

/// A single glass silhouette with a dark crown that opens into clear glass.
/// Decoration stays on native layers, independently of the lyric render clock.
@MainActor
final class OverlayGlassBackground: NSView {
    private let glass = NSGlassEffectView()
    private let shade = CAGradientLayer()
    private let glassMask = CALayer()
    private let rim = CAShapeLayer()
    private var configuration: Configuration?

    private struct Configuration: Equatable {
        let strength: Double
        let reduceTransparency: Bool
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        shade.locations = [0, 0.38, 0.76, 1]
        shade.cornerRadius = 23.5
        shade.cornerCurve = .continuous
        shade.masksToBounds = true
        layer?.addSublayer(shade)

        glass.style = .clear
        glass.tintColor = nil
        glass.cornerRadius = 24
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        // Keep the full native refraction at the rim, but mix only a small
        // amount of its blur into the centre. Lowering the entire glass's alpha
        // would also erase the very edge that makes it look like glass.
        glassMask.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        rim.fillColor = nil
        rim.strokeColor = NSColor.white.cgColor
        rim.lineWidth = 2
        rim.shadowColor = NSColor.white.cgColor
        rim.shadowOpacity = 1
        rim.shadowRadius = 3
        rim.shadowOffset = .zero
        glassMask.addSublayer(rim)
        glass.layer?.mask = glassMask
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(strength: Double, reduceTransparency: Bool) {
        let next = Configuration(strength: strength.isFinite ? min(0.28, max(0, strength)) : 0,
                                 reduceTransparency: reduceTransparency)
        guard configuration != next else { return }
        configuration = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = next.strength
        shade.colors = reduceTransparency
            ? Array(repeating: NSColor(white: 0.12, alpha: 1).cgColor, count: 4)
            : [0.72 + s * 0.5, 0.38 + s * 0.7, 0.06 + s * 0.4, s * 0.12]
                .map { NSColor.black.withAlphaComponent($0).cgColor }
        // Accessibility remains opaque; it must not be bypassed by our gradient.
        glass.isHidden = reduceTransparency
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // Resize only these layers with the panel, without rebuilding its content
        // or starting a second animation that trails behind the native frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The dimming layer sits behind the native glass and slightly inside its
        // continuous corners, so it cannot paint over the refractive top rim.
        shade.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        glassMask.frame = bounds
        rim.frame = bounds
        let edge = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                          cornerWidth: 23, cornerHeight: 23, transform: nil)
        rim.path = edge
        rim.shadowPath = edge.copy(strokingWithWidth: rim.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 0)
        CATransaction.commit()
    }
}
