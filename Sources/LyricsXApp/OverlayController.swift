import AppKit
import SwiftUI
import Observation
import LyricsXCore

final class DraggableOverlayPanel: NSPanel {
    var contentDragEnabled = true
    var onDragActivity: ((Bool) -> Void)?
    func shouldDrag(at point: NSPoint) -> Bool {
        let controls = NSRect(x: frame.width - 154, y: frame.height - 48, width: 154, height: 48)
        return contentDragEnabled && !controls.contains(point)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, shouldDrag(at: event.locationInWindow) {
            // The fixed header controls own clicks; all other content can drag.
            onDragActivity?(true)
            performDrag(with: event)
            onDragActivity?(false)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    let panel: DraggableOverlayPanel
    let controlPanel: NSPanel
    private let backdrop = NSVisualEffectView()
    private let glass = NSGlassEffectView()
    private let content: NSHostingView<OverlayView>
    private let root = NSView()
    private let controls: NSHostingView<OverlayControlStrip>
    private unowned let model: AppModel
    private let frameAutosaveName: String?
    private var lastVisible = false
    private var controlsVisible = false
    private var controlsDetached = false
    private var hoverHidden = false
    private var lastSize = NSSize.zero
    private var explicitShowWhilePaused = false
    private var wasPlaying = false
    private var stopped = false
    private var dragging = false
    private var resizing = false
    private var restoring = true
    private var anchorCenter: NSPoint?
    private var hoverTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    var isRenderingLyrics: Bool { lastVisible && !hoverHidden && !model.overlayUsesCompactPresentation }
    var controlsView: NSView { controls }
    private var positionDefaultsKey: String? { frameAutosaveName.map { "LyricsX.OverlayPosition.\($0)" } }
    private var centerDefaultsKey: String? { frameAutosaveName.map { "LyricsX.OverlayCenter.\($0)" } }

    init(model: AppModel, frameAutosaveName: String? = "LyricsXModernOverlay") {
        self.model = model
        self.frameAutosaveName = frameAutosaveName
        panel = DraggableOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: model.preferences.overlayWidth, height: 174),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controlPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 134, height: 34),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        content = NSHostingView(rootView: OverlayView(model: model))
        controls = NSHostingView(rootView: OverlayControlStrip(model: model))
        super.init()
        for window in [panel as NSPanel, controlPanel] {
            window.isFloatingPanel = true
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
        }
        panel.delegate = self
        panel.onDragActivity = { [weak self] dragging in
            guard let self else { return }
            self.dragging = dragging
            self.refreshAppearance()
            if !dragging { self.saveFrame() }
        }
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
        // Blur the desktop itself, not the lyric foreground. Both materials share
        // one silhouette; only the native glass draws the refractive edge.
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.alphaValue = 0.55
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 24
        backdrop.layer?.masksToBounds = true
        backdrop.frame = root.bounds.insetBy(dx: 6, dy: 6)
        backdrop.autoresizingMask = [.width, .height]
        glass.style = .clear
        glass.tintColor = nil
        glass.cornerRadius = 24
        glass.alphaValue = 1
        glass.frame = root.bounds.insetBy(dx: 6, dy: 6)
        glass.autoresizingMask = [.width, .height]
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(backdrop)
        root.addSubview(glass)
        root.addSubview(content)
        panel.contentView = root
        // Draggable lyrics and controls share a single window/render surface.
        // Only click-through mode needs a second window that can receive clicks.
        root.addSubview(controls)
        controls.frame = inlineControlFrame
        controls.autoresizingMask = [.minXMargin, .minYMargin]
        controls.isHidden = true
        panel.addChildWindow(controlPanel, ordered: .above)
        panel.setAccessibilityLabel("悬浮歌词")
        controlPanel.setAccessibilityLabel("悬浮歌词控制")
        controlPanel.setAccessibilityParent(panel)
        panel.setAccessibilityChildren([content])
        let restoredPosition: Bool
        // Restore the previous dimensions before migrating an old origin. The
        // compact and lyric layouts now share one persistent center anchor.
        let restoredLegacyFrame = frameAutosaveName.map { panel.setFrameUsingName($0) } ?? false
        if let key = centerDefaultsKey, let value = UserDefaults.standard.string(forKey: key) {
            anchorCenter = NSPointFromString(value)
            restoredPosition = true
        } else if let key = positionDefaultsKey,
           let value = UserDefaults.standard.string(forKey: key) {
            panel.setFrameOrigin(NSPointFromString(value))
            restoredPosition = true
        } else {
            restoredPosition = restoredLegacyFrame
        }
        if !restoredPosition, let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.minY + 90))
        }
        if anchorCenter == nil { anchorCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restoreOnScreen() }
        }
        restoreOnScreen()
        observeConfiguration()
        restoring = false
    }

    private func observeConfiguration() {
        guard !stopped else { return }
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConfiguration() }
        }
    }

    func stop() {
        stopped = true
        hoverTimer?.invalidate(); hoverTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        controlPanel.orderOut(nil); panel.orderOut(nil)
    }

    func setUserVisible(_ visible: Bool) {
        explicitShowWhilePaused = visible && model.preferences.hideWhenPaused && !model.session.isPlaying
        sync()
    }

    private func sync() {
        let prefs = model.preferences
        if model.session.isPlaying && !wasPlaying { explicitShowWhilePaused = false }
        wasPlaying = model.session.isPlaying
        let autoHidden = prefs.hideWhenPaused && !model.session.isPlaying && !explicitShowWhilePaused
        let visible = prefs.overlayVisible && !autoHidden && model.session.track != nil
        if visible != lastVisible {
            lastVisible = visible
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        panel.contentDragEnabled = !prefs.overlayLocked && !prefs.overlayClickThrough
        if panel.ignoresMouseEvents != prefs.overlayClickThrough { panel.ignoresMouseEvents = prefs.overlayClickThrough }
        setControlsDetached(prefs.overlayClickThrough)
        let width = min(1000, max(320, prefs.overlayWidth))
        let secondaryHeight: Double
        switch prefs.overlaySecondaryMode {
        case "none": secondaryHeight = 0
        case "next": secondaryHeight = prefs.nextLineFontSize * 1.4 + prefs.overlayPrimarySpacing
        case "both": secondaryHeight = (prefs.translationFontSize + prefs.nextLineFontSize) * 1.4 + prefs.overlayPrimarySpacing + prefs.overlaySecondarySpacing
        default: secondaryHeight = prefs.translationFontSize * 1.4 + prefs.overlayPrimarySpacing
        }
        let size = model.overlayUsesCompactPresentation
            ? NSSize(width: min(width, 400), height: 108)
            : NSSize(width: width, height: max(110, prefs.fontSize * 2.3 + 46 + secondaryHeight))
        if lastSize != size {
            lastSize = size
            resizing = true
            let center = anchorCenter ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            panel.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                 width: size.width, height: size.height), display: true)
            restoreOnScreen()
            resizing = false
        }
        let needsHoverTracking = visible
        if needsHoverTracking && hoverTimer == nil {
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAppearance() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else if !needsHoverTracking {
            hoverTimer?.invalidate(); hoverTimer = nil
        }
        refreshAppearance()
    }

    func refreshAppearance(at point: NSPoint = NSEvent.mouseLocation) {
        let prefs = model.preferences
        let inside = panel.frame.contains(point) || (controlsDetached && controlsVisible && controlPanel.frame.contains(point))
        let hidden = lastVisible && prefs.hideOverlayOnHover && prefs.overlayLocked && inside
        if hoverHidden != hidden {
            hoverHidden = hidden
            NSAnimationContext.runAnimationGroup { context in
                context.duration = prefs.reduceMotion ? 0 : 0.16
                content.animator().alphaValue = hidden ? 0 : 1
                backdrop.animator().alphaValue = hidden ? 0 : 0.55
                glass.animator().alphaValue = hidden ? 0 : 1
            }
        }
        let showControls = lastVisible && (inside || dragging)
        if showControls != controlsVisible {
            controlsVisible = showControls
            if showControls {
                controls.isHidden = false
                controls.alphaValue = 0
                if controlsDetached {
                    positionControlPanel()
                    controlPanel.orderFrontRegardless()
                }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = prefs.reduceMotion || dragging || !lastVisible ? 0 : 0.16
                controls.animator().alphaValue = showControls ? 1 : 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.controlsVisible else { return }
                    self.controls.isHidden = true
                    self.controlPanel.orderOut(nil)
                }
            }
            if prefs.reduceMotion || !lastVisible, !showControls {
                controls.isHidden = true
                controlPanel.orderOut(nil)
            }
            panel.setAccessibilityChildren(showControls ? [content, controls] : [content])
        }
    }

    private var inlineControlFrame: NSRect {
        NSRect(x: root.bounds.width - 148, y: root.bounds.height - 42, width: 134, height: 34)
    }

    private func setControlsDetached(_ detached: Bool) {
        guard detached != controlsDetached else { return }
        controlsDetached = detached
        controls.removeFromSuperview()
        if detached {
            controls.frame = NSRect(origin: .zero, size: NSSize(width: 134, height: 34))
            controls.autoresizingMask = [.width, .height]
            controlPanel.contentView = controls
            positionControlPanel()
            if controlsVisible && lastVisible { controlPanel.orderFrontRegardless() }
        } else {
            controlPanel.contentView = nil
            controlPanel.orderOut(nil)
            controls.frame = inlineControlFrame
            controls.autoresizingMask = [.minXMargin, .minYMargin]
            root.addSubview(controls)
        }
    }

    func restoreOnScreen() {
        let center = anchorCenter ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let anchoredScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) })
        guard let screen = anchoredScreen ?? NSScreen.main else { return }
        var frame = panel.frame
        frame.size.width = min(frame.width, screen.visibleFrame.width)
        frame.origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
        frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - frame.height))
        let wasResizing = resizing; resizing = true
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        resizing = wasResizing
        // A disconnected monitor needs a new usable anchor. Merely clamping a
        // larger lyric layout at the edge must not overwrite the compact anchor.
        if anchoredScreen == nil {
            anchorCenter = NSPoint(x: frame.midX, y: frame.midY)
            if !restoring { saveFrame() }
        }
        positionControlPanel()
    }

    private func positionControlPanel() {
        let origin = NSPoint(x: panel.frame.maxX - 148, y: panel.frame.maxY - 42)
        if controlPanel.frame.origin != origin { controlPanel.setFrameOrigin(origin) }
    }

    func windowDidMove(_ notification: Notification) {
        // Inline controls are part of this window, so dragging needs no second
        // window update, timer, animation, or end-of-drag position correction.
        if !dragging && !resizing && !restoring { saveFrame() }
    }

    private func saveFrame() {
        guard !restoring else { return }
        anchorCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        if let key = centerDefaultsKey, let center = anchorCenter { UserDefaults.standard.set(NSStringFromPoint(center), forKey: key) }
        if let frameAutosaveName { panel.saveFrame(usingName: frameAutosaveName) }
        if let key = positionDefaultsKey { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: key) }
    }

}

struct OverlayView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var line: LyricLine? {
        guard let doc = model.session.document, let index = model.session.currentLineIndex, doc.lines.indices.contains(index) else { return nil }
        return doc.lines[index]
    }
    private var translation: String? {
        guard model.preferences.showTranslation, let value = line?.translation else { return nil }
        return model.preferences.text(value)
    }
    private var nextLine: String? {
        guard let doc = model.session.document, let index = model.session.currentLineIndex, doc.lines.indices.contains(index + 1) else { return nil }
        return model.preferences.text(doc.lines[index + 1].text)
    }
    private var lyricIdentity: String {
        "\(model.session.track?.id ?? "idle")-\(model.session.document?.id.description ?? placeholder)-\(line?.id ?? -1)"
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.overlayUsesCompactPresentation {
                // Reserve the same top strip for controls in both layouts.
                Spacer(minLength: 22)
                HStack(spacing: 12) {
                    Group {
                        if let artwork = model.artwork {
                            Image(nsImage: artwork).resizable().scaledToFill()
                        } else {
                            ZStack { Color.white.opacity(0.08); Image(systemName: "music.note").font(.system(size: 18)) }
                        }
                    }.frame(width: 42, height: 42).clipShape(.rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.session.track?.title ?? "LyricsX")
                            .font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        if model.session.isSearching {
                            Text("正在加载歌词…").font(.system(size: 12, weight: .medium)).opacity(0.8)
                        } else if let artist = model.session.track?.artist, !artist.isEmpty {
                            Text(artist).font(.system(size: 12, weight: .medium)).lineLimit(1).opacity(0.8)
                        }
                    }.shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 2)
            } else {
                HStack(spacing: 6) {
                    Text(model.session.track?.title ?? "LyricsX").lineLimit(1)
                    if let artist = model.session.track?.artist, !artist.isEmpty { Text("· " + artist).lineLimit(1).opacity(0.85) }
                    Spacer(minLength: 4)
                    Color.clear.frame(width: 126, height: 30)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.92)).frame(height: 30)
                Spacer(minLength: 4)
                ZStack {
                  VStack(spacing: 0) {
                    if let line, let doc = model.session.document {
                        LiveLyricText(session: model.session, line: line, document: doc, active: true,
                            text: line.text.isEmpty ? "•••" : model.preferences.text(line.text))
                            .font(.system(size: model.preferences.fontSize, weight: .semibold)).tracking(-0.4)
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    } else { Text(placeholder) }
                if ["translation", "both"].contains(model.preferences.overlaySecondaryMode), let translation {
                    Text(translation).font(.system(size: model.preferences.translationFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95)).lineLimit(1).minimumScaleFactor(0.75)
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 1).padding(.top, model.preferences.overlayPrimarySpacing)
                }
                if ["next", "both"].contains(model.preferences.overlaySecondaryMode), let nextLine {
                    Text(nextLine).font(.system(size: model.preferences.nextLineFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.75)
                        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
                        .padding(.top, model.preferences.overlaySecondaryMode == "both" && translation != nil ? model.preferences.overlaySecondarySpacing : model.preferences.overlayPrimarySpacing)
                }
                  }.frame(maxWidth: .infinity)
                    .id(lyricIdentity)
                    .transition(reduceMotion || model.preferences.reduceMotion ? .opacity : .lyricDissolve)
                }.font(.system(size: model.preferences.fontSize, weight: .semibold))
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
                    .animation(reduceMotion || model.preferences.reduceMotion ? nil : .smooth(duration: 0.48), value: lyricIdentity)
                Spacer(minLength: 8)
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(reduceTransparency ? Color(white: 0.12) : .black.opacity(model.preferences.overlayBackgroundStrength), in: .rect(cornerRadius: 24))
            .padding(6)
    }
    private var placeholder: String {
        if model.lyricsBlocked { return "已停用此歌曲歌词" }
        if model.session.document?.isInstrumental == true { return "纯音乐" }
        if model.session.document?.isSynced == false { return "此歌词暂无时间轴" }
        if model.session.phase == .loading { return "正在寻找歌词…" }
        if model.session.document != nil { return "•••" }
        return model.session.track == nil ? "未在播放" : "还没有找到歌词"
    }
}

private struct OverlayControlStrip: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        HStack(spacing: 2) {
            SymbolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "打开主窗口", inactiveOpacity: 0.92) { model.showMainWindow?() }
            SymbolButton(symbol: model.preferences.overlayLocked ? "lock.fill" : "lock.open", help: model.preferences.overlayLocked ? "解锁并恢复拖动" : "锁定位置", active: model.preferences.overlayLocked, inactiveOpacity: 0.92) {
                model.setOverlayLocked(!model.preferences.overlayLocked)
            }
            SymbolButton(symbol: model.preferences.overlayClickThrough ? "cursorarrow.slash" : "cursorarrow.rays", help: model.preferences.overlayClickThrough ? "关闭点击穿透" : "开启点击穿透", active: model.preferences.overlayClickThrough, inactiveOpacity: 0.92) {
                model.setOverlayClickThrough(!model.preferences.overlayClickThrough)
            }
            SymbolButton(symbol: "xmark", help: "隐藏悬浮歌词", inactiveOpacity: 0.92) { model.setOverlayVisible(false) }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.65), radius: 1, y: 1)
        .padding(2)
        // A minimum local scrim keeps white controls legible over white pages.
        // Keep this independent from the user's much lighter lyric glass tint.
        .background(reduceTransparency ? Color(white: 0.16) : .black.opacity(max(0.52, model.preferences.overlayBackgroundStrength)), in: .capsule)
        .glassEffect(.clear, in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5).allowsHitTesting(false) }
    }
}
