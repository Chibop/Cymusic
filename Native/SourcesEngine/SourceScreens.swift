import SwiftUI
import UniformTypeIdentifiers

struct SourcesScreen: View {
    @EnvironmentObject private var engine: SourceEngine
    @State private var filePicker = false
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section("已安装") {
                if engine.scripts.isEmpty { Text("尚未导入音源").foregroundStyle(.secondary) }
                ForEach(engine.scripts) { item in
                    Button { run { try await engine.select(item) } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).foregroundStyle(.primary)
                                if let author = item.metadata["author"] { Text(author).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if engine.selected == item.id { Image(systemName: "checkmark").accessibilityLabel("已选中") }
                        }
                    }.swipeActions { Button("删除", role: .destructive) { run { try engine.remove(item) } } }
                }
            }
            Section {
                Button { filePicker = true } label: { Label("选择 JavaScript 文件", systemImage: "doc.badge.plus") }
                TextField("粘贴脚本或脚本链接", text: $input, axis: .vertical).lineLimit(1...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("导入音源") {
                    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    run {
                        if let url = ProviderSession.webURL(value) {
                            let (data, response) = try await URLSession.shared.data(from: url)
                            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let script = String(data: data, encoding: .utf8) else { throw SourceFailure("下载脚本失败") }
                            try await engine.importScript(script, name: url.lastPathComponent)
                        } else { try await engine.importScript(value, name: "自定义音源") }
                        input = ""
                    }
                }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("添加音源") } footer: { Text("导入后会运行脚本。请选择你信任的来源。") }
            if busy { ProgressView("正在加载音源") }
            if let error = error ?? engine.notice { Text(error).foregroundStyle(.secondary) }
        }.navigationTitle("音源").disabled(busy)
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.javaScript, .plainText, .data]) { result in
            run {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try await engine.importScript(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}

struct SearchScreen: View {
    @EnvironmentObject private var engine: SourceEngine
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    var onSavePlaylist: ((String, [Song]) -> Void)? = nil
    private enum Mode: String, CaseIterable { case qq = "QQ 音乐", playlist = "QQ 歌单", previews = "Apple 试听" }
    @State private var mode = Mode.qq
    @State private var input = ""
    @State private var term = ""
    @State private var songs: [Song] = []
    @State private var title = ""
    @State private var nextPage: Int?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            Picker("目录", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if mode == .qq {
                Button { search(page: 1, chart: true) } label: { Label("浏览热歌榜", systemImage: "chart.bar") }
                if engine.selected == nil { Text("播放 QQ 音乐前，请先选择音源。").font(.footnote).foregroundStyle(.secondary) }
            }
            if busy { ProgressView("正在获取目录") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !title.isEmpty {
                Section(title) {
                    if songs.isEmpty && !busy { Text("没有找到歌曲").foregroundStyle(.secondary) }
                    if mode == .playlist, !songs.isEmpty, let save = onSavePlaylist { Button("保存歌单") { save(title, songs) } }
                    ForEach(songs.indices, id: \.self) { index in
                        let song = songs[index]
                        Button { playback.play(songs, index: index) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: song.artwork) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note").foregroundStyle(.secondary) }.frame(width: 44, height: 44).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.title).font(.headline).foregroundStyle(.primary)
                                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                                }.lineLimit(1)
                            }
                        }.swipeActions { Button { library.favorite(song) } label: { Label("收藏", systemImage: "heart") } }
                        .contextMenu { Button { library.favorite(song) } label: { Label("收藏", systemImage: "heart") } }
                    }
                    if let nextPage { Button("更多歌曲") { search(page: nextPage) }.disabled(busy) }
                }
            }
        }.navigationTitle("搜索")
        .searchable(text: $input, prompt: mode == .playlist ? "输入歌单 ID 或链接" : "歌曲或艺人")
        .onSubmit(of: .search) { search(page: 1) }
        .onChange(of: mode) { _ in
            task?.cancel(); songs = []; title = ""; nextPage = nil; busy = false; error = nil
            if !input.isEmpty && mode != .playlist { search(page: 1) }
        }
    }

    private func search(page: Int, chart: Bool = false) {
        let query = (page == 1 ? input : term).trimmingCharacters(in: .whitespacesAndNewlines)
        guard chart || !query.isEmpty else { return }
        task?.cancel(); busy = true; error = nil
        if page == 1 { songs = []; nextPage = nil; title = ""; term = query }
        task = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                let result: (String, [Song])
                switch mode {
                case .qq where chart: result = try await SourceCatalog.chart()
                case .qq: result = (query, try await SourceCatalog.search(query, page: page))
                case .playlist: result = try await SourceCatalog.playlist(query)
                case .previews: result = (query, try await SourceCatalog.previews(query))
                }
                try Task.checkCancellation()
                title = result.0
                var ids = Set(songs.map(\.id))
                songs += result.1.filter { ids.insert($0.id).inserted }
                nextPage = !chart && mode == .qq && result.1.count == 20 ? page + 1 : nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
