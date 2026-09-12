import AppKit
import Observation
import SwiftUI

struct HDRDisplayCapability: Equatable, Identifiable {
    let id: UInt32
    let name: String
    let potential: Double
    let current: Double
    // Current headroom can be 1 before the first EDR surface is shown. Hardware
    // eligibility must use potential headroom, never the current brightness.
    var supported: Bool { potential.isFinite && potential > 1 }

    @MainActor init(screen: NSScreen) {
        id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        name = screen.localizedName
        potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        current = screen.maximumExtendedDynamicRangeColorComponentValue
    }
    init(id: UInt32 = 0, name: String = "Display", potential: Double, current: Double) {
        self.id = id; self.name = name; self.potential = potential; self.current = current
    }
}

@Observable @MainActor final class HDRDisplayMonitor: NSObject {
    private(set) var displays: [HDRDisplayCapability] = []
    @ObservationIgnored private var observing = false
    var supported: Bool { displays.contains(where: \.supported) }
    override init() { super.init(); refresh() }
    func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refresh()
    }
    @objc func refresh() {
        let updated = NSScreen.screens.map(HDRDisplayCapability.init(screen:))
        if displays != updated { displays = updated }
    }
    func stop() { NotificationCenter.default.removeObserver(self); observing = false }
}

private struct LyricHDRSupportKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var lyricHDRSupported: Bool {
        get { self[LyricHDRSupportKey.self] }
        set { self[LyricHDRSupportKey.self] = newValue }
    }
}

/// One reader per window, not per lyric or frame. Moving onto SDR immediately
/// selects ordinary glow, even when another connected display supports HDR.
private struct WindowHDRReader: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.stop(); view.changed = nil }

    @MainActor final class Reader: NSView {
        var changed: ((Bool) -> Void)?
        private var supported: Bool?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            refresh()
        }
        @objc private func refresh() {
            let value = window?.screen.map { HDRDisplayCapability(screen: $0).supported } ?? false
            guard supported != value else { return }
            supported = value
            // Avoid publishing SwiftUI state during native view attachment.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.supported == value else { return }
                self.changed?(value)
            }
        }
        func stop() { NotificationCenter.default.removeObserver(self); supported = nil }
    }
}

private struct HDRDisplayScope: ViewModifier {
    let requested: Bool
    @State private var supported = false
    func body(content: Content) -> some View {
        content.environment(\.lyricHDRSupported, supported)
            .allowedDynamicRange(requested && supported ? .high : .standard)
            .background(WindowHDRReader { supported = $0 }.frame(width: 0, height: 0))
    }
}
extension View {
    func hdrDisplayScope(requested: Bool) -> some View { modifier(HDRDisplayScope(requested: requested)) }
}
