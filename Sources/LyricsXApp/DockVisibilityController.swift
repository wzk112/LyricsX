import AppKit

/// The saved preference owns Dock visibility, including after Launch Services
/// reopens or activates the app. Reconcile at events, never by polling.
@MainActor
final class DockVisibilityController {
    private let shouldShow: () -> Bool
    private let currentPolicy: () -> NSApplication.ActivationPolicy
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private var deferred: Task<Void, Never>?
    private var stopped = false

    init(shouldShow: @escaping () -> Bool,
         currentPolicy: @escaping () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() },
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }) {
        self.shouldShow = shouldShow; self.currentPolicy = currentPolicy; self.setPolicy = setPolicy
    }
    func start() { stopped = false; reconcile() }
    func reconcile() {
        guard !stopped else { return }
        let desired: NSApplication.ActivationPolicy = shouldShow() ? .regular : .accessory
        if currentPolicy() != desired { setPolicy(desired) }
    }
    @discardableResult func applicationActivated() -> Task<Void, Never>? {
        guard !stopped else { return nil }
        reconcile()
        deferred?.cancel()
        // Window opening and activation can finish after the delegate callback.
        // Re-read the preference on the next turn; never replay a stale value.
        deferred = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.reconcile(); self.deferred = nil
        }
        return deferred
    }
    func stop() { stopped = true; deferred?.cancel(); deferred = nil }
}
