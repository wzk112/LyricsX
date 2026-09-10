import Foundation
import CryptoKit
import LyricsXCore

public enum CacheLocation {
    public static func resolve(modern: UserDefaults = .standard, legacy: UserDefaults? = UserDefaults(suiteName: "com.JH.LyricsX")) -> URL {
        if let bookmark = modern.data(forKey: "ModernLyricsDirectoryBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) { return url }
        }
        if let path = modern.string(forKey: "ModernLyricsDirectory") { return URL(fileURLWithPath: path, isDirectory: true) }
        for defaults in [legacy, UserDefaults(suiteName: "com.ddddxxx.LyricsX"), UserDefaults(suiteName: "dev.JH.LyricsX")].compactMap({ $0 }) {
            if defaults.integer(forKey: "LyricsSavingPathPopUpIndex") != 0,
               let bookmark = defaults.data(forKey: "LyricsCustomSavingPathBookmark") {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) {
                    // Stale bookmarks still yield a valid URL; do not silently switch cache directories.
                    return url
                }
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/LyricsX", isDirectory: true)
    }
}

/// Reads and writes the original LyricsX directory, using its existing filenames.
/// No second lyrics database or JSON copy is created.
public actor LyricsCache {
    public struct Entry: Sendable, Identifiable {
        public var url: URL
        public var track: Track
        public var document: LyricsDocument
        public var savedAt: Date
        public var id: String { url.path }
    }
    public private(set) var directory: URL
    private var loadedPaths: [String: URL] = [:]
    public init(directory: URL = CacheLocation.resolve()) { self.directory = directory }
    public func setDirectory(_ url: URL) { directory = url; loadedPaths = [:] }
    public func existingURL(for track: Track) -> URL? {
        if let loaded = loadedPaths[track.cacheIdentity], FileManager.default.fileExists(atPath: loaded.path) { return loaded }
        _ = load(for: track)
        return loadedPaths[track.cacheIdentity]
    }
    public nonisolated static func filename(for track: Track) -> String {
        let name = "\(track.title) - \(track.artist)".replacingOccurrences(of: "/", with: ":")
            .replacingOccurrences(of: "\u{0000}", with: "").replacingOccurrences(of: "\n", with: " ")
        if name.utf8.count <= 220 { return name }
        let hash = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return String(name.prefix(45)) + "-" + hash
    }
    public func load(for track: Track) -> LyricsDocument? {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        for ext in ["lrcx", "lrc", "txt"] {
            let url = directory.appendingPathComponent(Self.filename(for: track)).appendingPathExtension(ext)
            if var doc = try? LyricsCodec.read(url) {
                loadedPaths[track.cacheIdentity] = url
                if doc.title.isEmpty { doc.title = track.title }; if doc.artist.isEmpty { doc.artist = track.artist }
                return doc
            }
        }
        return nil
    }
    public func save(_ document: LyricsDocument, for track: Track) throws {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // LRCX remains the default so word-level timing and provider attachments
        // survive every cache write. Existing LRC files remain interoperable and
        // are updated in place when explicitly loaded.
        let ext = document.isSynced || document.isInstrumental ? "lrcx" : "txt"
        // A manual/forced search may save before this process has loaded the old
        // file. Resolve it on disk too, so a user-managed cache is not duplicated.
        let existing = loadedPaths[track.cacheIdentity] ?? existingURL(for: track)
        let url = existing ?? directory.appendingPathComponent(Self.filename(for: track)).appendingPathExtension(ext)
        var doc = document
        doc.title = track.title; doc.artist = track.artist
        let value = LyricsCodec.export(doc)
        if let old = try? String(contentsOf: url, encoding: .utf8), old == value { return }
        try value.write(to: url, atomically: true, encoding: .utf8)
        loadedPaths[track.cacheIdentity] = url
    }
    public func entries() throws -> [Entry] {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { ["lrcx", "lrc", "txt"].contains($0.pathExtension.lowercased()) }.compactMap { url in
                guard let doc = try? LyricsCodec.read(url) else { return nil }
                let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " - ")
                let title = doc.title.isEmpty ? parts.first ?? "未命名" : doc.title
                let artist = doc.artist.isEmpty ? parts.dropFirst().joined(separator: " - ") : doc.artist
                return Entry(url: url, track: Track(playerID: "library", playerName: "资料库", title: title, artist: artist), document: doc,
                             savedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.sorted { $0.savedAt > $1.savedAt }
    }
}
