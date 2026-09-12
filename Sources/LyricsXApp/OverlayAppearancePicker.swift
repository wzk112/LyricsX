import SwiftUI

struct OverlayAppearancePicker: View {
    @Binding var selection: OverlayAppearance
    let transparency: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("悬浮窗样式").font(.body.weight(.medium))
            HStack(alignment: .top, spacing: 12) {
                ForEach(OverlayAppearance.allCases) { appearance in
                    Button { selection = appearance } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack {
                                LinearGradient(colors: [.blue.opacity(0.65), .cyan.opacity(0.6), .orange.opacity(0.55)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                HStack(spacing: 14) {
                                    ForEach(0..<5) { _ in Rectangle().fill(.white.opacity(0.22)).frame(width: 12) }
                                }.rotationEffect(.degrees(25))
                                OverlayMaterialPreview(appearance: appearance, transparency: transparency)
                                VStack(spacing: 9) {
                                    Text("当前歌词").font(.system(size: 20, weight: .semibold))
                                    Text("翻译 / 下一句").font(.system(size: 12, weight: .medium))
                                }.foregroundStyle(.white).shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                            }.frame(height: 108).clipShape(.rect(cornerRadius: 24)).accessibilityHidden(true)
                            HStack {
                                Text(appearance.title).font(.body.weight(.medium))
                                Spacer(minLength: 0)
                                Image(systemName: selection == appearance ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection == appearance ? Color.accentColor : .secondary)
                            }
                            Text(appearance.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(selection == appearance ? Color.accentColor.opacity(0.07) : .clear, in: .rect(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selection == appearance ? Color.accentColor : .secondary.opacity(0.2), lineWidth: 1) }
                            .contentShape(.rect(cornerRadius: 16))
                    }.buttonStyle(.plain).accessibilityLabel(appearance.title)
                        .accessibilityValue(selection == appearance ? "已选择" : "未选择")
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Text("点击图例切换。预览使用相同背景；实际效果会随悬浮窗后方内容变化。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}

private struct OverlayMaterialPreview: NSViewRepresentable {
    let appearance: OverlayAppearance
    let transparency: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context: Context) -> OverlayGlassBackground { OverlayGlassBackground() }
    func updateNSView(_ view: OverlayGlassBackground, context: Context) {
        view.configure(appearance: appearance, transparency: transparency,
                       reduceTransparency: reduceTransparency, reduceMotion: true)
    }
}
