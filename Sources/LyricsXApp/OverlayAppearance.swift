import Foundation

enum OverlayAppearance: String, CaseIterable, Identifiable {
    case glass, frosted

    static let transparencyRange = 0.2...0.8
    static let defaultTransparency = 0.6
    static let frostRange = 0.0...1.0
    var defaultFrost: Double { self == .glass ? 0.35 : 0.82 }
    private var frostCapacity: Double { self == .glass ? 0.7 : 0.9 }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .frosted: "磨砂阅读"
        }
    }
    var detail: String {
        switch self {
        case .glass: "通透的原生折射边缘，中央磨砂程度可调。"
        case .frosted: "柔化后方细节，配合较浅底色，让歌词更容易阅读。"
        }
    }

    init(savedValue: String?) {
        switch savedValue {
        case "frosted", "dark": self = .frosted
        default: self = .glass
        }
    }

    static func clampedTransparency(_ value: Double) -> Double {
        value.isFinite ? min(transparencyRange.upperBound, max(transparencyRange.lowerBound, value)) : defaultTransparency
    }

    func clampedFrost(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : defaultFrost
    }

    func materialOpacity(transparency: Double, frost: Double) -> Double {
        let transparency = Self.clampedTransparency(transparency)
        // Continuous across both sliders; even maximum frost retains some
        // unfiltered backdrop. The foreground is outside this optical layer.
        return 1 - transparency + transparency * frostCapacity * clampedFrost(frost)
    }

    func migratedFrost(transparency: Double) -> Double {
        let transparency = Self.clampedTransparency(transparency)
        let previousOpacity = self == .glass ? min(0.9, 1 - transparency + 0.14) : 0.96 - transparency * 0.18
        return clampedFrost((previousOpacity - (1 - transparency)) / (transparency * frostCapacity))
    }

    func shadeOpacities(transparency: Double) -> [Double] {
        let opacity = 1 - Self.clampedTransparency(transparency)
        switch self {
        case .glass:
            return [opacity * 1.25, opacity * 0.88, opacity * 0.46, opacity * 0.18]
        case .frosted:
            return [0.14 + opacity * 0.6, 0.12 + opacity * 0.58,
                    0.11 + opacity * 0.56, 0.10 + opacity * 0.55]
        }
    }
}
