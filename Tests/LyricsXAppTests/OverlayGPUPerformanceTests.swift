import AppKit
import Darwin
import Testing
import LyricsXCore
@testable import LyricsXApp

/// Run alone; owns a native window and event pump, never the real music player.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LYRICSX_GPU_QA"] != nil))
@MainActor struct OverlayGPUPerformanceTests {
    @Test func compareNativeOverlayFrameRates() async throws {
        struct Repository: LyricsRepository {
            func lyrics(for track: Track, forceRefresh: Bool) -> AsyncThrowingStream<LyricCandidate, Error> { .init { $0.finish() } }
            func save(_ document: LyricsDocument, for track: Track) async throws {}
        }
        _ = NSApplication.shared; NSApp.finishLaunching()
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LYRICSX_GPU_QA"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LyricsXTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.hideWhenPaused = false; prefs.hideOverlayOnHover = false; prefs.overlaySecondaryMode = .both
        let model = AppModel(repository: Repository(), preferences: prefs)
        let track = Track(playerID: "test", playerName: "Test", title: "GPU measurement")
        let document = LyricsDocument(lines: (0..<100).map { index in
            let start = Double(index) * 3
            let text = index.isMultiple(of: 2) ? "Light moves through the glass" : "保持光线与文字流畅清晰"
            return LyricLine(id: index, time: start, text: text, translation: "Independent render fixture",
                words: [.init(text: text, start: start, end: start + 3)])
        })
        model.session.accept(.init(track: track, position: 0, isPlaying: true), shouldSearch: false)
        model.session.use(document, persist: false)
        let overlay = OverlayController(model: model, frameAutosaveName: nil,
            pointerLocation: { .init(x: -10_000, y: -10_000) })
        let screen = try #require(NSScreen.main)
        overlay.panel.setFrameOrigin(.init(x: screen.visibleFrame.midX - 310, y: screen.visibleFrame.midY))
        let ticker = PlaybackTicker {
            model.session.tick()
            return LyricTickCadence.milliseconds(playing: true, visible: true, document: document, position: model.session.position)
        }
        ticker.start()
        defer { ticker.stop(); overlay.stop(); model.stop() }
        func render(_ seconds: Double) async throws {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.006), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        func cpuTime() -> Double {
            var value = rusage(); getrusage(RUSAGE_SELF, &value)
            return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        func phase(_ name: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["phase": name, "pid": ProcessInfo.processInfo.processIdentifier,
                "time": Date().timeIntervalSince1970])
            try data.write(to: directory.appendingPathComponent("phase.json"), options: .atomic)
        }
        try phase("warmup"); try await render(10)
        var measurements: [[String: Any]] = []
        for (index, cap) in [0, 120, 60, 60, 120, 0].enumerated() {
            prefs.overlayVisible = cap != 0
            prefs.overlayFrameRate = cap == 60 ? .sixty : .display
            model.session.seek(to: 0)
            try phase("settle"); try await render(1)
            let name = cap == 0 ? "hidden" : "\(cap)fps"
            try phase(name)
            let epoch = Date().timeIntervalSince1970
            let wall = ProcessInfo.processInfo.systemUptime, cpu = cpuTime()
            try await render(6)
            let elapsed = ProcessInfo.processInfo.systemUptime - wall
            let value = (cpuTime() - cpu) / elapsed * 100
            measurements.append(["phase": name, "order": index, "cpuPercent": value, "seconds": elapsed, "startedAt": epoch])
            print("GPU QA phase \(name): CPU \(value)%")
        }
        try phase("finished")
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("cpu.json"))
    }
}
