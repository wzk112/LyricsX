import AppKit
import QuartzCore

/// A single native material with a contrast gradient in its supported content
/// view. No synthetic rim or per-frame decoration competes with the lyrics.
@MainActor
final class OverlayGlassBackground: NSView {
    private let glass = NSGlassEffectView()
    private let scrim = OverlayGradientView()
    private var configuration: Configuration?

    private struct Configuration: Equatable {
        let appearance: OverlayAppearance
        let transparency: Double
        let reduceTransparency: Bool
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        glass.cornerRadius = 24
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        // The foreground stays white regardless of the desktop appearance.
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.tintColor = nil
        scrim.wantsLayer = true
        glass.contentView = scrim
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(appearance: OverlayAppearance, transparency: Double, reduceTransparency: Bool, reduceMotion: Bool) {
        let next = Configuration(appearance: appearance,
                                 transparency: OverlayAppearance.clampedTransparency(transparency),
                                 reduceTransparency: reduceTransparency)
        guard configuration != next, let gradient = scrim.layer as? CAGradientLayer else { return }
        let animate = configuration != nil && configuration?.appearance != appearance
            && !reduceMotion && !reduceTransparency
        let previousColors = gradient.presentation()?.colors ?? gradient.colors
        configuration = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // .regular softens the backdrop more for reading; .clear keeps its
        // texture and refraction. Tint color is not an opacity control.
        glass.style = appearance == .glass ? .clear : .regular
        // Mix the native optical surface with the actual desktop. Changing
        // only the scrim leaves the full backdrop blur in place at every value.
        glass.alphaValue = appearance == .glass ? 1 - next.transparency : 1
        glass.isHidden = reduceTransparency
        layer?.backgroundColor = reduceTransparency ? NSColor(white: 0.12, alpha: 1).cgColor : nil
        gradient.colors = appearance.shadeOpacities(transparency: next.transparency)
            .map { NSColor.black.withAlphaComponent($0).cgColor }
        CATransaction.commit()
        gradient.removeAnimation(forKey: "appearance")
        if animate, let previousColors {
            let transition = CABasicAnimation(keyPath: "colors")
            transition.fromValue = previousColors
            transition.toValue = gradient.colors
            transition.duration = 0.24
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0, 0.2, 1)
            gradient.add(transition, forKey: "appearance")
        }
    }

}

/// AppKit resizes this backing gradient with the material's content view.
@MainActor private final class OverlayGradientView: NSView {
    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.locations = [0, 0.38, 0.76, 1]
        gradient.cornerRadius = 24
        gradient.cornerCurve = .continuous
        gradient.masksToBounds = true
        return gradient
    }
}
