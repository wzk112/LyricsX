import AppKit
import Foundation
import Testing
@testable import LyricsXApp

@Suite @MainActor struct DockVisibilityTests {
    @Test func reopenAndLateActivationHonorHiddenPreference() async throws {
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults); prefs.showDockIcon = false
        var policy = NSApplication.ActivationPolicy.regular
        var writes = 0
        let controller = DockVisibilityController(shouldShow: { prefs.showDockIcon }, currentPolicy: { policy },
                                                  setPolicy: { policy = $0; writes += 1 })
        defer { controller.stop() }
        controller.start()
        #expect(policy == .accessory)
        policy = .regular // A reopen has promoted the running application.
        let reopening = controller.applicationActivated()
        #expect(policy == .accessory)
        policy = .regular // A window finishes opening after the callback.
        await reopening?.value
        #expect(policy == .accessory)
        #expect(!Preferences(defaults: defaults).showDockIcon)
        let previous = writes
        await controller.applicationActivated()?.value
        #expect(writes == previous) // Already-correct activation must not loop.
    }

    @Test func pendingReconciliationReadsLatestPreferenceAndStopsCleanly() async throws {
        var show = false
        var policy = NSApplication.ActivationPolicy.regular
        let controller = DockVisibilityController(shouldShow: { show }, currentPolicy: { policy }, setPolicy: { policy = $0 })
        let pending = controller.applicationActivated()
        #expect(policy == .accessory)
        show = true
        await pending?.value
        #expect(policy == .regular)
        show = false
        let cancelled = controller.applicationActivated()
        controller.stop()
        policy = .regular
        await cancelled?.value
        #expect(policy == .regular)
        controller.start()
        #expect(policy == .accessory)
        controller.stop()
    }
}

@Test func fastLyricChangesContinueFromTheVisibleMotionFrame() {
    let rest = LyricMotion.Frame()
    let first = rest.arrival(distance: 14)
    #expect(first.offset == 14 && first.blur > 0 && first.opacity >= 0.5)
    let moving = LyricMotion.Frame(offset: 4, blur: 0.6, opacity: 0.9)
    #expect(moving.arrival(distance: 14) == moving)
    let overshoot = LyricMotion.Frame(offset: -0.4, blur: 0, opacity: 1)
    #expect(overshoot.arrival(distance: 14) == overshoot)
    #expect(rest.arrival(distance: 8).offset == 8)
}
