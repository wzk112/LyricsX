import SwiftUI
import Observation
import ServiceManagement
import Security
import LyricsXServices

@Observable @MainActor
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored nonisolated let sourceConfigurationReader: SourceConfigurationReader
    var overlayVisible: Bool { didSet { save("overlayVisible", overlayVisible) } }
    var overlayLocked: Bool { didSet { save("overlayLocked", overlayLocked) } }
    var overlayClickThrough: Bool { didSet { save("overlayClickThrough", overlayClickThrough) } }
    var hideOverlayOnHover: Bool { didSet { save("hideOverlayOnHover", hideOverlayOnHover) } }
    var overlayBackgroundStrength: Double { didSet { save("overlayBackgroundStrength", overlayBackgroundStrength) } }
    var overlayWidth: Double { didSet { save("overlayWidth", overlayWidth) } }
    var fontSize: Double { didSet { save("fontSize", fontSize) } }
    var translationFontSize: Double { didSet { save("translationFontSize", translationFontSize) } }
    var nextLineFontSize: Double { didSet { save("nextLineFontSize", nextLineFontSize) } }
    var overlaySecondaryMode: String { didSet { save("overlaySecondaryMode", overlaySecondaryMode) } }
    var mainLyricFontSize: Double { didSet { save("mainLyricFontSize", mainLyricFontSize) } }
    var mainTranslationFontSize: Double { didSet { save("mainTranslationFontSize", mainTranslationFontSize) } }
    var showTranslation: Bool { didSet { save("showTranslation", showTranslation) } }
    var showMenubarLyrics: Bool { didSet { save("showMenubarLyrics", showMenubarLyrics) } }
    var showMenuBarIcon: Bool { didSet { save("showMenuBarIcon", showMenuBarIcon) } }
    var showDockIcon: Bool { didSet { save("showDockIcon", showDockIcon) } }
    var combinedMenubarLyrics: Bool { didSet { save("combinedMenubarLyrics", combinedMenubarLyrics) } }
    var blockedTracks: [String] { didSet { save("blockedTracks", blockedTracks) } }
    var blockedAlbums: [String] { didSet { save("blockedAlbums", blockedAlbums) } }
    var hideWhenPaused: Bool { didSet { save("hideWhenPaused", hideWhenPaused) } }
    var reduceMotion: Bool { didSet { save("reduceMotion", reduceMotion) } }
    var conversion: String { didSet { save("conversion", conversion) } }
    var playerMode: PlayerMode { didSet { save("playerMode", playerMode.rawValue) } }
    var disabledSources: [String] { didSet { save("disabledSources", disabledSources) } }
    var sourceOrder: [String] { didSet { save("sourceOrder", sourceOrder) } }
    var preferBilingual: Bool { didSet { save("preferBilingual", preferBilingual) } }
    var preferWordTiming: Bool { didSet { save("preferWordTiming", preferWordTiming) } }
    var strictLyricsMatching: Bool { didSet { save("strictLyricsMatching", strictLyricsMatching) } }
    var directory: URL
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var overlayPrimarySpacing: Double { max(10, fontSize * 0.44) }
    var overlaySecondarySpacing: Double { max(8, max(translationFontSize, nextLineFontSize) * 0.6) }
    init(defaults d: UserDefaults = .standard) {
        defaults = d
        sourceConfigurationReader = SourceConfigurationReader(defaults: d)
        overlayVisible = d.object(forKey: "overlayVisible") as? Bool ?? true
        overlayLocked = d.bool(forKey: "overlayLocked")
        overlayClickThrough = d.bool(forKey: "overlayClickThrough")
        hideOverlayOnHover = d.bool(forKey: "hideOverlayOnHover")
        overlayBackgroundStrength = d.object(forKey: "overlayBackgroundStrength") as? Double ?? 0
        if d.integer(forKey: "compactOverlayVersion") < 1 {
            if d.object(forKey: "overlayWidth") == nil || d.double(forKey: "overlayWidth") == 640 { d.set(520.0, forKey: "overlayWidth") }
            d.set(1, forKey: "compactOverlayVersion")
        }
        overlayWidth = d.object(forKey: "overlayWidth") as? Double ?? 520
        fontSize = d.object(forKey: "fontSize") as? Double ?? 26
        translationFontSize = d.object(forKey: "translationFontSize") as? Double ?? 13
        nextLineFontSize = d.object(forKey: "nextLineFontSize") as? Double ?? 12
        overlaySecondaryMode = d.string(forKey: "overlaySecondaryMode") ?? "translation"
        mainLyricFontSize = d.object(forKey: "mainLyricFontSize") as? Double ?? 30
        mainTranslationFontSize = d.object(forKey: "mainTranslationFontSize") as? Double ?? 14
        showTranslation = d.object(forKey: "showTranslation") as? Bool ?? true
        showMenubarLyrics = d.bool(forKey: "showMenubarLyrics")
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        showDockIcon = d.object(forKey: "showDockIcon") as? Bool ?? true
        combinedMenubarLyrics = d.object(forKey: "combinedMenubarLyrics") as? Bool ?? true
        blockedTracks = d.stringArray(forKey: "blockedTracks") ?? []
        blockedAlbums = d.stringArray(forKey: "blockedAlbums") ?? []
        hideWhenPaused = d.bool(forKey: "hideWhenPaused")
        reduceMotion = d.bool(forKey: "reduceMotion")
        conversion = d.string(forKey: "conversion") ?? "原文"
        playerMode = PlayerMode(rawValue: d.string(forKey: "playerMode") ?? "automatic") ?? .automatic
        disabledSources = d.stringArray(forKey: "disabledSources") ?? []
        sourceOrder = SourceConfiguration.normalizedOrder(d.stringArray(forKey: "sourceOrder") ?? [])
        preferBilingual = d.object(forKey: "preferBilingual") as? Bool ?? true
        preferWordTiming = d.object(forKey: "preferWordTiming") as? Bool ?? true
        strictLyricsMatching = d.object(forKey: "strictLyricsMatching") as? Bool ?? true
        directory = CacheLocation.resolve()
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    func setSource(_ name: String, enabled: Bool) {
        disabledSources.removeAll { $0 == name }
        if !enabled { disabledSources.append(name) }
    }
    func moveSource(_ source: String, by delta: Int) {
        guard let index = sourceOrder.firstIndex(of: source) else { return }
        let destination = min(sourceOrder.count - 1, max(0, index + delta))
        guard destination != index else { return }
        var order = sourceOrder
        order.remove(at: index)
        order.insert(source, at: destination)
        sourceOrder = order
    }
    func moveSource(_ source: String, before destination: String) -> Bool {
        guard source != destination, sourceOrder.contains(source), sourceOrder.contains(destination) else { return false }
        var order = sourceOrder.filter { $0 != source }
        guard let index = order.firstIndex(of: destination) else { return false }
        order.insert(source, at: index)
        sourceOrder = order
        return true
    }
    func chooseDirectory(_ url: URL) {
        directory = url
        UserDefaults.standard.set(url.path, forKey: "ModernLyricsDirectory")
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) {
            UserDefaults.standard.set(bookmark, forKey: "ModernLyricsDirectoryBookmark")
        }
    }
    func text(_ text: String) -> String {
        switch conversion {
        case "简体": text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        case "繁體": text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text
        default: text
        }
    }
}

/// UserDefaults is thread-safe. Keep the exact settings store used by the UI,
/// including test/profile suites, instead of rereading a separate global store.
final class SourceConfigurationReader: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func read() -> SourceConfiguration {
        var config = SourceConfiguration()
        let disabled = defaults.stringArray(forKey: "disabledSources") ?? []
        config.enabled = Set(SourceConfiguration.defaultOrder).subtracting(disabled)
        config.sourceOrder = SourceConfiguration.normalizedOrder(defaults.stringArray(forKey: "sourceOrder") ?? [])
        config.preferBilingual = defaults.object(forKey: "preferBilingual") as? Bool ?? true
        config.preferWordTiming = defaults.object(forKey: "preferWordTiming") as? Bool ?? true
        config.strictMatching = defaults.object(forKey: "strictLyricsMatching") as? Bool ?? true
        config.musixmatchToken = TokenStore.read()
        return config
    }
}

enum TokenStore {
    private static let service = "com.lyricsx.modern.musixmatch"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "usertoken", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "usertoken"]
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; new[kSecValueData as String] = data
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
