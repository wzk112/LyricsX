import AppKit

/// Source identity is based on the owning app, never on a song title or app name.
enum MusicSourcePolicy {
    static let knownPlayers: Set<String> = ["com.apple.music", "com.apple.itunes", "com.spotify.client",
        "com.netease.163music", "com.tencent.qqmusic", "com.tencent.qqmusicmac", "com.kugou.mac"]
    static let browsers = ["com.apple.safari", "com.google.chrome", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.browser", "company.thebrowser.browser", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "com.kagi.kagimacOS", "app.zen-browser.zen"]

    static func accepts(bundleID: String?, category: String? = nil) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        if id == "com.lyricsx.modern" { return false }
        if browsers.contains(where: { id == $0.lowercased() || id.hasPrefix($0.lowercased() + ".") }) { return false }
        if knownPlayers.contains(id) { return true }
        // iOS-on-Mac wrappers can append their signing team identifier.
        if id.hasPrefix("com.tencent.qqmusic.") || id.hasPrefix("com.netease.163music.") { return true }
        return category == "public.app-category.music"
    }

    @MainActor private static var categoryCache: [URL: Bool] = [:]
    @MainActor static func invalidate(_ app: NSRunningApplication) {
        if let url = app.bundleURL { categoryCache.removeValue(forKey: url) }
    }
    @MainActor static func accepts(_ app: NSRunningApplication) -> Bool {
        if accepts(bundleID: app.bundleIdentifier) { return true }
        guard let url = app.bundleURL else { return false }
        if let cached = categoryCache[url] { return cached }
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        let result = accepts(bundleID: app.bundleIdentifier, category: category)
        if categoryCache.count >= 256 { categoryCache.removeAll(keepingCapacity: true) }
        categoryCache[url] = result
        return result
    }
}
