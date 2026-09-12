import Foundation

enum OverlayAppearance: String, CaseIterable, Identifiable {
    case glass, frosted

    static let transparencyRange = 0.2...0.8
    static let defaultTransparency = 0.6
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .frosted: "磨砂阅读"
        }
    }
    var detail: String {
        switch self {
        case .glass: "清透玻璃与深浅渐变，保留背景纹理和原生折射。"
        case .frosted: "柔化后方细节并加深底色，让歌词更容易阅读。"
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

    func shadeOpacities(transparency: Double) -> [Double] {
        let opacity = 1 - Self.clampedTransparency(transparency)
        switch self {
        case .glass:
            return [opacity * 1.1, opacity * 0.92, opacity * 0.68, opacity * 0.46]
        case .frosted:
            return [0.24 + opacity * 0.8, 0.2 + opacity * 0.8,
                    0.18 + opacity * 0.78, 0.16 + opacity * 0.78]
        }
    }
}
