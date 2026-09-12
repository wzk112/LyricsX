import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    var impact: String? = nil
    @ViewBuilder let control: () -> Control
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                control().fixedSize(horizontal: true, vertical: false)
            }
            if let impact {
                Label(impact, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16)
    }
}

struct SettingToggle: View {
    let title: String
    let detail: String
    var impact: String? = nil
    @Binding var value: Bool
    var body: some View {
        SettingRow(title: title, detail: detail, impact: impact) {
            Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title).accessibilityHint(detail)
        }
    }
}

struct SettingSlider: View {
    let title: String
    let detail: String
    var impact: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var suffix = "pt"
    var multiplier = 1.0
    var decimals = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: title, detail: detail, impact: impact) {
                Text(String(format: "%.*f", decimals, value * multiplier) + " " + suffix)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step).accessibilityLabel(title).accessibilityHint(detail)
                .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
}
