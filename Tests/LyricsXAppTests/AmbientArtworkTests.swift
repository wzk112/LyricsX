import AppKit
import Testing
@testable import LyricsXApp

@Suite(.serialized) @MainActor
struct AmbientArtworkTests {
    @Test func backdropIsBoundedReusedAndReplacedWhenArtworkChanges() async throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = try #require(CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.systemBlue.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        let source = try #require(bitmap.makeImage())
        let artwork = NSImage(cgImage: source, size: .init(width: 640, height: 640))
        let key = AmbientArtworkKey(artwork: artwork, size: .init(width: 2048, height: 1440))
        let renderer = AmbientArtworkRenderer()
        let start = ProcessInfo.processInfo.systemUptime
        let first = try #require(await renderer.render(source, key: key))
        let cold = ProcessInfo.processInfo.systemUptime - start
        #expect(max(first.width, first.height) <= 384)
        for _ in 0..<100 {
            let reused = try #require(await renderer.render(source, key: key))
            #expect(first === reused)
        }
        bitmap.setFillColor(NSColor.systemRed.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        let changed = try #require(bitmap.makeImage())
        let replacement = try #require(await renderer.render(changed, key: key))
        #expect(first !== replacement)
        #expect(AmbientArtworkKey(artwork: artwork, size: .init(width: 1001, height: 701)) ==
                AmbientArtworkKey(artwork: artwork, size: .init(width: 1002, height: 702)))
        print("Ambient CPU raster: first=\(cold * 1000) ms; cached reuse=100; output=\(first.width)x\(first.height)")
    }
}
