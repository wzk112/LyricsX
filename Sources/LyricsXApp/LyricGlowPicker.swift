import SwiftUI
import LyricsXCore

/// Static samples use the production text renderer without a timer or player.
struct LyricGlowPicker: View {
    @Binding var enabled: Bool

    private static let sample = LyricLine(id: 0, time: 0, text: "让光停留", words: [
        .init(text: "让", start: 0, end: 0.3),
        .init(text: "光", start: 0.3, end: 3),
        .init(text: "停留", start: 3, end: 4)
    ])

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ForEach([false, true], id: \.self) { glow in
                    SettingsIllustratedChoice(title: glow ? "开启" : "关闭",
                        detail: glow ? "慢唱和长音渐进发光，短音保持清晰。" : "保留逐字提亮，文字周围不加光晕。",
                        selected: enabled == glow, action: { enabled = glow }) {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.06, green: 0.11, blue: 0.17),
                                Color(red: 0.14, green: 0.10, blue: 0.18)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                            WordHighlight(line: Self.sample, time: 1.6, active: true, text: Self.sample.text,
                                effects: .init(lift: false, glow: glow, hdr: false))
                                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 14)
                        }.frame(height: 108).clipShape(.rect(cornerRadius: 24))
                    }.accessibilityLabel("长音辉光：" + (glow ? "开启" : "关闭"))
                }
            }
            Text("点击图例切换，同时应用于主窗口和悬浮窗。图例为普通亮度下的长音静帧。")
                .font(.caption).foregroundStyle(.secondary)
            Label("需要歌词自带逐字时间；辉光会增加少量图形绘制开销。减少动态效果开启时暂停辉光。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}
