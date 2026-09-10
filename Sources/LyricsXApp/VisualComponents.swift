import SwiftUI
import LyricsXCore

private struct LyricDissolveModifier: ViewModifier {
    var blur: Double
    var opacity: Double
    var offset: Double
    func body(content: Content) -> some View {
        content.blur(radius: blur).opacity(opacity).offset(y: offset)
    }
}

extension AnyTransition {
    static var lyricDissolve: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: LyricDissolveModifier(blur: 3, opacity: 0, offset: 3), identity: LyricDissolveModifier(blur: 0, opacity: 1, offset: 0))
                .animation(.smooth(duration: 0.5)),
            removal: .opacity.animation(.linear(duration: 0.09)))
    }
}

struct AmbientBackground: View {
    var artwork: NSImage?
    var moving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.045, green: 0.035, blue: 0.075)
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).blur(radius: 85).opacity(0.32)
                } else {
                    LinearGradient(colors: [Color(white: 0.12), Color(white: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
            }.clipped()
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct CoverArtwork: View {
    let artwork: NSImage?
    var demo = false
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size.width
            ZStack {
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else if demo {
                    LinearGradient(colors: [Color(red: 0.19, green: 0.10, blue: 0.24), Color(red: 0.55, green: 0.20, blue: 0.24), Color(red: 0.1, green: 0.09, blue: 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.74, blue: 0.48), Color(red: 0.97, green: 0.37, blue: 0.42)], startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.44, height: size * 0.44).blur(radius: 0.5).offset(y: -size * 0.07)
                    ForEach(0..<18, id: \.self) { index in
                        Ellipse().stroke(.white.opacity(0.10), lineWidth: 0.5)
                            .frame(width: size * (0.65 + Double(index) * 0.07), height: size * (0.24 + Double(index) * 0.04))
                            .rotationEffect(.degrees(-22)).offset(x: size * 0.12, y: size * 0.12)
                    }
                    Rectangle().fill(LinearGradient(colors: [.clear, Color(red: 0.11, green: 0.09, blue: 0.2)], startPoint: .top, endPoint: .bottom)).frame(height: size * 0.7).offset(y: size * 0.33)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(demo ? "LYRICSX STUDIO" : "LYRICSX").font(.system(size: size * 0.027, weight: .medium, design: .monospaced)).tracking(2.6)
                            Spacer()
                            Image(systemName: "waveform").font(.system(size: size * 0.035))
                        }
                        Spacer()
                        Text(demo ? "夜航" : "声之所至").font(.system(size: size * 0.135, weight: .ultraLight)).tracking(8)
                        Text(demo ? "N I G H T F A L L" : "E V E R Y  W O R D").font(.system(size: size * 0.029, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }.padding(size * 0.085).frame(width: size, height: size)
                } else {
                    Color(white: 0.13)
                    Image(systemName: "music.note").font(.system(size: size * 0.26, weight: .light)).foregroundStyle(.white.opacity(0.35))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
                .clipShape(.rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 0.7))
        }.aspectRatio(1, contentMode: .fit)
    }
}

// Only the active, word-timed row observes the playback position.
struct LiveLyricText: View {
    let session: LyricsSession
    let line: LyricLine
    let document: LyricsDocument
    let active: Bool
    let text: String
    var body: some View {
        if active && line.hasWordTiming {
            WordHighlight(line: line, time: document.lyricTime(for: session.position), active: true, text: text)
        } else { Text(text) }
    }
}

struct SymbolButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30) }
            .buttonStyle(.plain).foregroundStyle(active ? .white : .white.opacity(0.6))
            .background(active ? .white.opacity(0.1) : .clear, in: .circle)
            .contentShape(.circle).help(help).accessibilityLabel(help)
    }
}

struct WordHighlight: View {
    let line: LyricLine
    let time: Double
    let active: Bool
    let text: String
    var body: some View {
        if active, line.hasWordTiming, text == line.text {
            // Character-level opacity follows actual word tags, not a guessed per-line duration.
            Text(attributedText)
        } else { Text(text) }
    }
    private var attributedText: AttributedString {
        var result = AttributedString()
        let covered = line.words.map(\.text).joined()
        guard covered == text else { return AttributedString(text) }
        for word in line.words {
            var fragment = AttributedString(word.text)
            let progress = word.progress(at: time)
            fragment.foregroundColor = .white.opacity(0.40 + 0.60 * progress)
            result.append(fragment)
        }
        return result
    }
}

struct PlayingIndicator: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !playing || reduceMotion)) { context in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4) { index in
                    let value = barHeight(at: context.date, index: index)
                    Capsule().fill(.foreground).frame(width: 2.5, height: value)
                }
            }.frame(width: 20, height: 18)
        }.accessibilityLabel(playing ? "正在播放" : "已暂停")
    }
    private func barHeight(at date: Date, index: Int) -> Double {
        guard playing && !reduceMotion else { return 5.5 }
        let phase = date.timeIntervalSinceReferenceDate * 4 + Double(index) * 1.4
        return 4 + abs(sin(phase)) * 10
    }
}

func timeString(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
