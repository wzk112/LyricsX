import SwiftUI
import LyricsXCore
import LyricsXServices

struct SearchView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LyricCandidate] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var deadline: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var trackID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("找到对的那一句").font(.title2.bold()); Text("搜索多个歌词源，选择最适合当前歌曲的版本。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("歌曲名和歌手", text: $query).textFieldStyle(.plain).onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
                Button("搜索", action: search).buttonStyle(.glassProminent).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(12).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if results.isEmpty {
                ContentUnavailableView(searching ? "正在搜索歌词" : "暂无结果", systemImage: "text.magnifyingglass", description: Text("也可以将本地 LRC 或 LRCX 文件拖入主窗口。"))
            } else {
                List(results) { candidate in
                    HStack(spacing: 14) {
                        Image(systemName: candidate.document.hasWordTiming ? "waveform" : "text.quote").font(.title3).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.document.title.isEmpty ? "未命名歌词" : candidate.document.title).font(.headline)
                            Text("\(candidate.document.artist) · \(candidate.document.source) · \(candidate.document.lines.count) 行").font(.caption).foregroundStyle(.secondary)
                            if let first = candidate.document.lines.first(where: { !$0.text.isEmpty }) { Text(first.text).font(.caption).lineLimit(1).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        if candidate.document.hasTranslation { Text("双语").font(.caption2).foregroundStyle(.secondary) }
                        Button("使用") {
                            guard model.session.track?.id == trackID else { error = "歌曲已切换，请重新搜索。"; return }
                            model.session.use(candidate.document); dismiss()
                        }.buttonStyle(.glass).disabled(model.session.track == nil)
                    }.padding(.vertical, 8)
                }.listStyle(.plain)
            }
            HStack { Text("\(results.count) 个版本").font(.caption).foregroundStyle(.secondary); Spacer(); Button("导入本地歌词") { model.importLyrics() } }
        }.padding(26).frame(width: 680, height: 490)
            .onAppear { query = [model.session.track?.title, model.session.track?.artist].compactMap { $0 }.joined(separator: " "); trackID = model.session.track?.id; results = model.session.candidates }
            .onDisappear { searchTask?.cancel(); deadline?.cancel() }
            .onChange(of: model.session.track?.id) { _, _ in searchTask?.cancel(); deadline?.cancel(); searching = false; results = []; error = "歌曲已切换，请重新搜索。" }
    }
    private func search() {
        searchTask?.cancel(); deadline?.cancel()
        let id = UUID(); requestID = id; searching = true; results = []; error = nil
        let track = model.session.track ?? Track(playerID: "search", playerName: "搜索", title: query)
        trackID = model.session.track?.id
        searchTask = Task {
            do {
                for try await result in model.store.search(track: track, keyword: query) {
                    guard !Task.isCancelled, requestID == id else { return }
                    if !results.contains(where: { $0.document.source == result.document.source && $0.document.originalLRC == result.document.originalLRC }) {
                        results.append(result); results.sort { $0.score > $1.score }
                    }
                }
            } catch { if !Task.isCancelled, requestID == id { self.error = error.localizedDescription } }
            if requestID == id { searching = false; deadline?.cancel() }
        }
        deadline = Task {
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            guard requestID == id else { return }; searchTask?.cancel(); searching = false
            if results.isEmpty { error = "歌词源响应超时，请重试。" }
        }
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: LyricsCache.Entry?
    private var filtered: [LyricsCache.Entry] { model.library.filter { query.isEmpty || ($0.track.title + $0.track.artist).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("歌词资料库").font(.title2.bold()); Text("\(model.library.count) 首").foregroundStyle(.secondary); if model.libraryLoading { ProgressView().controlSize(.small) }; Spacer(); Button("完成") { dismiss() } }
            TextField("搜索已保存的歌曲", text: $query).textFieldStyle(.roundedBorder)
            HSplitView {
                List(filtered) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.track.title).font(.headline)
                            Text(entry.track.artist + " · " + entry.url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }.frame(minWidth: 240).listStyle(.plain)
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(selected.track.title).font(.title2.bold())
                            Text(LyricsCodec.export(selected.document, plain: true)).font(.system(size: 15)).lineSpacing(8).textSelection(.enabled)
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) }
                            if model.session.track != nil { Button("用于当前歌曲") { model.session.use(selected.document); dismiss() }.buttonStyle(.glass) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else { ContentUnavailableView("选择一首歌曲", systemImage: "text.book.closed", description: Text("这里直接显示现有缓存文件夹中的歌词。")) }
                }.frame(minWidth: 310)
            }
            HStack { Image(systemName: "folder"); Text(model.preferences.directory.path).lineLimit(1).truncationMode(.middle); Spacer(); Button("更改…") { model.chooseCacheDirectory() } }.font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 740, height: 510).task { model.loadLibrary() }
    }
}
