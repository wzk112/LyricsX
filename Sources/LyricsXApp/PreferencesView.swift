import SwiftUI
import ServiceManagement
import LyricsXServices

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case player = "播放器"
    case overlay = "悬浮窗"
    case lyrics = "歌词"
    case sources = "歌词来源"
    case cache = "缓存"
    case about = "关于"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gear"
        case .player: "play.circle"
        case .overlay: "rectangle.on.rectangle"
        case .lyrics: "text.quote"
        case .sources: "network"
        case .cache: "externaldrive"
        case .about: "info.circle"
        }
    }
}

struct PreferencesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SettingsSection? = .general
    @State private var token = ""
    @State private var tokenMessage = ""

    var body: some View {
        @Bindable var prefs = model.preferences
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 165, ideal: 175, max: 190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text(selection?.rawValue ?? "设置").font(.title2.bold())
                        Spacer()
                        Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    settingsContent(prefs)
                }
                .frame(maxWidth: 620, alignment: .topLeading)
                .padding(28)
            }
        }
        .navigationTitle("设置")
        .frame(minWidth: 680, minHeight: 520)
        .task { token = TokenStore.read() ?? "" }
    }

    @ViewBuilder
    private func settingsContent(_ prefs: Preferences) -> some View {
        switch selection ?? .general {
        case .general:
            settingsGroup("Dock") {
                Toggle("在 Dock 中显示", isOn: Bindable(prefs).showDockIcon)
                Text("关闭后隐藏屏幕底部的应用图标。仍可从菜单栏或 ⌥⌘O 打开 LyricsX。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsGroup("菜单栏") {
                Toggle("显示菜单栏图标", isOn: Bindable(prefs).showMenuBarIcon)
                Toggle("显示菜单栏歌词", isOn: Bindable(prefs).showMenubarLyrics)
                Toggle("图标与歌词合并显示", isOn: Bindable(prefs).combinedMenubarLyrics)
                    .disabled(!prefs.showMenuBarIcon || !prefs.showMenubarLyrics)
                Text("关闭菜单栏显示后，仍可通过 Dock 或 ⌥⌘O 打开主窗口，并在设置中恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsGroup("启动") {
                Toggle("登录时启动", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { enabled in
                        Task {
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try await SMAppService.mainApp.unregister() }
                                prefs.launchAtLogin = SMAppService.mainApp.status == .enabled
                            } catch { model.message = error.localizedDescription }
                        }
                    }
                ))
            }
            settingsGroup("快捷键") {
                shortcut("显示 / 隐藏悬浮歌词", keys: "⌥⌘L")
                shortcut("打开主窗口", keys: "⌥⌘O")
                shortcut("搜索歌词", keys: "⌘F")
            }
        case .player:
            settingsGroup("播放状态") {
                Picker("读取来源", selection: Bindable(prefs).playerMode) {
                    ForEach(PlayerMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: prefs.playerMode) { _, value in
                    model.bridge.mode = value
                }
                Text("自动模式读取系统正在播放。读取失败时可选择 Apple Music 或 Spotify。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新连接播放器") { model.bridge.restart() }
                if let error = model.playerError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        case .overlay:
            settingsGroup("显示") {
                Toggle("显示悬浮窗", isOn: Binding(
                    get: { prefs.overlayVisible },
                    set: { model.setOverlayVisible($0) }
                ))
                Toggle("锁定位置", isOn: Binding(get: { prefs.overlayLocked }, set: { model.setOverlayLocked($0) }))
                Toggle("歌词区域点击穿透", isOn: Binding(get: { prefs.overlayClickThrough }, set: { model.setOverlayClickThrough($0) }))
                Toggle("鼠标经过时暂时隐藏歌词", isOn: Bindable(prefs).hideOverlayOnHover)
                Toggle("暂停时隐藏", isOn: Bindable(prefs).hideWhenPaused)
                Text("开启穿透会锁定位置，控制条仍可点击。解锁会关闭穿透并恢复拖动。锁定时可开启鼠标经过隐藏，控制条始终可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsGroup("外观") {
                sliderRow("文字大小", value: Bindable(prefs).fontSize, range: 18...42, step: 1, suffix: "pt")
                sliderRow("窗口宽度", value: Bindable(prefs).overlayWidth, range: 320...920, step: 20, suffix: "pt")
                sliderRow("背景浓度", value: Bindable(prefs).overlayBackgroundStrength, range: 0...0.28, step: 0.02, suffix: "%", multiplier: 100)
            }
            settingsGroup("辅助文字") {
                Picker("显示内容", selection: Bindable(prefs).overlaySecondaryMode) {
                    ForEach(OverlaySecondaryMode.allCases) { Text($0.title).tag($0) }
                }
                Text("“翻译或下一句”优先显示本句翻译，没有可用翻译时显示下一句；“仅翻译”不会回退。")
                    .font(.caption).foregroundStyle(.secondary)
                sliderRow("翻译字号", value: Bindable(prefs).translationFontSize, range: 10...24, step: 1, suffix: "pt")
                sliderRow("下一句字号", value: Bindable(prefs).nextLineFontSize, range: 10...24, step: 1, suffix: "pt")
            }
        case .lyrics:
            settingsGroup("显示") {
                sliderRow("主窗口歌词字号", value: Bindable(prefs).mainLyricFontSize, range: 20...42, step: 1, suffix: "pt")
                sliderRow("主窗口翻译字号", value: Bindable(prefs).mainTranslationFontSize, range: 11...24, step: 1, suffix: "pt")
                Toggle("显示翻译", isOn: Bindable(prefs).showTranslation)
                Toggle("减少动态效果", isOn: Bindable(prefs).reduceMotion)
                Picker("中文显示", selection: Bindable(prefs).conversion) {
                    ForEach(["原文", "简体", "繁體"], id: \.self) { Text($0) }
                }
                Text("同时遵循系统的减少动态效果和降低透明度设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !prefs.blockedTracks.isEmpty || !prefs.blockedAlbums.isEmpty {
                settingsGroup("已停用的歌词搜索") {
                    Text("\(prefs.blockedTracks.count) 首歌曲，\(prefs.blockedAlbums.count) 张专辑")
                    Button("恢复全部搜索") {
                        prefs.blockedTracks = []; prefs.blockedAlbums = []; model.session.reload()
                    }
                }
            }
            settingsGroup("时间偏移") {
                Text("正值让歌词提前，负值让歌词延后。可在主窗口底部调整，结果会保存回当前歌词文件。")
                    .font(.callout)
            }
        case .sources:
            settingsGroup("版本偏好") {
                Toggle("双语优先", isOn: Bindable(prefs).preferBilingual)
                Toggle("逐字优先", isOn: Bindable(prefs).preferWordTiming)
                Toggle("严格匹配", isOn: Bindable(prefs).strictLyricsMatching)
                Text("严格匹配开启时，准确标题优先；关闭后，可信的标题变体按功能偏好、来源顺序排序。两项偏好都开启时逐字优先，其次双语；只开一项时先满足该项，没有时回退到另一项。两项都关闭则按来源排序。歌词提前结束不会排除准确的歌名、歌手匹配。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsGroup("来源优先级") {
                Text("越靠上越优先。可拖动左侧手柄或使用箭头排序；关闭的来源不参与搜索。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(prefs.sourceOrder, id: \.self) { source in
                    sourceRow(source, prefs: prefs)
                }
                Button("恢复默认顺序") { prefs.sourceOrder = SourceConfiguration.defaultOrder }
            }
            settingsGroup("应用到当前歌曲") {
                Text("继续优先复用现有缓存。新顺序和双语偏好从下一次搜索生效；要为当前歌曲更换版本，可以重新搜索。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("按当前优先级重新搜索") { model.refreshLyrics() }
                    .disabled(model.session.track == nil || model.lyricsBlocked)
                Text("来源同时搜索，自动选择与手动搜索结果共用此排序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            settingsGroup("Musixmatch") {
                SecureField("usertoken（可选）", text: $token).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存令牌") {
                        do { try TokenStore.save(token); tokenMessage = "已保存到钥匙串" }
                        catch { tokenMessage = error.localizedDescription }
                    }
                    Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("联网搜索会向启用的歌词源发送歌曲名、歌手和时长。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .cache:
            settingsGroup("歌词文件夹") {
                Text(prefs.directory.path)
                    .font(.callout).textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle)
                HStack {
                    Button("选择文件夹…") { model.chooseCacheDirectory() }
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(prefs.directory) }
                }
                Text("直接复用旧版 LyricsX 的文件夹和“歌名 - 歌手”文件名。命中已有歌词时不会再次下载，偏移保存回原文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .about:
            VStack(spacing: 14) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 48)).foregroundStyle(.pink.gradient)
                Text("LyricsX").font(.largeTitle.bold())
                Text("2.0 · Swift 重构版").foregroundStyle(.secondary)
                Text("MPL-2.0，保留原项目及依赖的许可声明")
                    .font(.caption).foregroundStyle(.secondary)
                Button("预览歌词动效") {
                    openWindow(id: "preview")
                }
                .buttonStyle(.glass)
                Link("查看原项目", destination: URL(string: "https://github.com/MxIris-LyricsX-Project/LyricsX")!)
            }
            .frame(maxWidth: .infinity).padding(.top, 42)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))
        }
    }

    private func sourceRow(_ source: String, prefs: Preferences) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                .frame(width: 24, height: 28).contentShape(.rect).draggable(source)
                .help("拖动调整 " + sourceName(source) + " 的优先级")
            Text("\((prefs.sourceOrder.firstIndex(of: source) ?? 0) + 1)")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
            Toggle(sourceName(source), isOn: Binding(
                get: { !prefs.disabledSources.contains(source) },
                set: { prefs.setSource(source, enabled: $0) }
            ))
            Spacer(minLength: 4)
            Button { prefs.moveSource(source, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 22) }
                .disabled(prefs.sourceOrder.first == source).accessibilityLabel("提高 " + sourceName(source) + " 的优先级")
            Button { prefs.moveSource(source, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 22) }
                .disabled(prefs.sourceOrder.last == source).accessibilityLabel("降低 " + sourceName(source) + " 的优先级")
        }.buttonStyle(.borderless).contentShape(.rect)
            .dropDestination(for: String.self) { items, _ in
                guard let item = items.first else { return false }
                return prefs.moveSource(item, before: source)
            }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        LabeledContent(title) { Text(keys).monospaced().foregroundStyle(.secondary) }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String,
        multiplier: Double = 1
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * multiplier)) \(suffix)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }

    private func sourceName(_ value: String) -> String {
        switch value {
        case "NetEase": "网易云音乐"
        case "QQMusic": "QQ 音乐"
        case "Kugou": "酷狗音乐"
        default: value
        }
    }
}
