import SwiftUI

struct SearchScreen: View {
    @State private var query = ""
    @State private var songs: [Song]?
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var destination = SongDestination()
    @FocusState private var editing: Bool

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section("Apple Music 歌曲目录") {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("歌曲名或歌手", text: Binding(get: { query }, set: { query = $0; resetSearch() }))
                        .focused($editing).submitLabel(.search).onSubmit { search() }
                        .accessibilityIdentifier("search.query")
                }
                if searchTask != nil {
                    ProgressView("正在搜索歌曲…")
                    Button("取消搜索") { resetSearch(); error = "已取消搜索" }
                } else {
                    Button("搜索歌曲") { search() }.disabled(term.isEmpty)
                        .accessibilityIdentifier("search.submit")
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            if let songs {
                Section("搜索结果（\(songs.count)）") {
                    if songs.isEmpty { Text("没有找到歌曲，请换个关键词。").foregroundStyle(.secondary) }
                    ForEach(songs) { song in
                        NavigationLink(value: song) { SearchSongLabel(song: song) }
                            .accessibilityIdentifier("search.result.\(song.id)")
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationDestination(for: Song.self) { seed in
            SearchSongDestination(seed: seed, route: destination)
        }
    }

    private func resetSearch() {
        searchTask?.cancel(); searchTask = nil; error = nil; songs = nil
    }

    private func search() {
        let input = term
        guard !input.isEmpty else { return }
        resetSearch(); editing = false
        searchTask = Task { @MainActor in
            defer { if !Task.isCancelled { searchTask = nil } }
            do {
                let found = try await PoolCatalog.searchSongs(input)
                try Task.checkCancellation()
                songs = found
            } catch { if !Task.isCancelled { self.error = "搜索失败：\(L10n.message(for: error))" } }
        }
    }
}

private struct SearchSongLabel: View {
    let song: Song
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title).font(.headline)
            Text([song.artist, song.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// Owned by the search tab, not by the pushed view: returning to the same result
// keeps the selected route and both qualities without repeating a successful match.
@MainActor private final class SongDestination: ObservableObject {
    @Published var seed: Song?
    @Published var scriptID: String?
    private var scriptText: String?
    @Published var sites = [String]()
    @Published var site: String?
    @Published var match: Song?
    @Published var levels = [String]()
    @Published var audition = ""
    @Published var download = ""
    @Published var error: String?
    @Published var busy = false
    private var task: Task<Void, Never>?

    func open(_ seed: Song, engine: SourceEngine) {
        let script = engine.scripts.first { $0.id == scriptID }
        if self.seed != seed {
            self.seed = seed
            selectScript(script, engine: engine)
        } else if script?.text != scriptText { selectScript(script, engine: engine) }
    }

    func cancel() {
        task?.cancel(); task = nil; busy = false; error = "已取消，可重新尝试。"
    }

    private func resetMatch() {
        cancel(); error = nil; match = nil; levels = []; audition = ""; download = ""
    }

    func selectScript(_ script: SourceScript?, engine: SourceEngine) {
        resetMatch(); sites = []; site = nil; scriptID = script?.id; scriptText = script?.text
        guard let script else { return }
        busy = true
        task = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let found = try await engine.declaredDownloadPlatforms(for: script)
                try Task.checkCancellation()
                sites = found
                if found.isEmpty { error = "此脚本没有声明可解析音乐地址的站点。" }
            } catch { if !Task.isCancelled { self.error = L10n.message(for: error) } }
        }
    }

    func selectSite(_ site: String?, script: SourceScript, engine: SourceEngine) {
        resetMatch(); self.site = site
        guard let seed, let site, sites.contains(site) else { return }
        busy = true
        task = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let found = try await engine.matchCatalogSong(seed, script: script, platform: site)
                try Task.checkCancellation()
                let declared = try await engine.availableLevels(for: found, script: script)
                try Task.checkCancellation()
                guard let first = declared.first else { error = "此站点未声明可用音质。"; return }
                levels = declared; audition = first; download = first; match = found
            } catch { if !Task.isCancelled { self.error = "匹配失败：\(L10n.message(for: error))" } }
        }
    }
}

private struct SearchSongDestination: View {
    let seed: Song
    @ObservedObject var route: SongDestination
    @EnvironmentObject private var engine: SourceEngine
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var confirmStop = false
    private var script: SourceScript? { engine.scripts.first { $0.id == route.scriptID } }

    var body: some View {
        List {
            Section("目录歌曲") { SearchSongLabel(song: seed) }
            Section("目标音源") {
                Picker("脚本", selection: Binding(get: { route.scriptID }, set: { id in
                    route.selectScript(engine.scripts.first { $0.id == id }, engine: engine)
                })) {
                    Text("请选择").tag(String?.none)
                    ForEach(engine.scripts) { Text($0.name).tag(Optional($0.id)) }
                }.disabled(engine.scripts.isEmpty)
                if engine.scripts.isEmpty { Text("请先在设置中导入音源脚本。").foregroundStyle(.secondary) }
                if let script, !route.sites.isEmpty {
                    Picker("站点", selection: Binding(get: { route.site }, set: { route.selectSite($0, script: script, engine: engine) })) {
                        Text("请选择").tag(String?.none)
                        ForEach(route.sites, id: \.self) { Text(ScopedSearchPlatform.name($0)).tag(Optional($0)) }
                    }
                }
                if route.busy {
                    ProgressView(route.site == nil ? "正在读取站点…" : "正在匹配歌曲与音质…")
                    Button("取消") { route.cancel() }
                } else if let error = route.error, let script {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") {
                        if let site = route.site { route.selectSite(site, script: script, engine: engine) }
                        else { route.selectScript(script, engine: engine) }
                    }
                }
            }
            if let match = route.match, route.seed == seed {
                Section("站点匹配结果") { SearchSongLabel(song: match) }
                auditionSection(match)
                downloadSection(match)
            }
        }
        .navigationTitle("选择音源").navigationBarTitleDisplayMode(.inline)
        .onAppear { route.open(seed, engine: engine) }
        .onChange(of: script?.text) { _ in route.open(seed, engine: engine) }
        .onDisappear { if route.busy { route.cancel() } }
    }

    private func requested(_ song: Song, _ quality: String) -> Song {
        var copy = song; copy.requestedQuality = quality; return copy
    }

    private func isCurrent(_ song: Song) -> Bool {
        guard let current = playback.current else { return false }
        return current.id == song.id && current.platform == song.platform && current.searchScriptID == song.searchScriptID && current.requestedQuality != nil
    }

    private func auditionSection(_ song: Song) -> some View {
        let current = isCurrent(song)
        return Section("试听") {
            qualityPicker("试听音质", selection: Binding(get: { route.audition }, set: { level in
                guard route.audition != level else { return }; route.audition = level
                if isCurrent(song) && (playback.isPlaying || playback.loading) { playback.play([requested(song, level)], index: 0) }
            }))
            if current && playback.loading {
                ProgressView("正在准备试听…")
                Button("取消试听") { playback.clear() }
            } else if current && playback.isPlaying {
                Button("暂停试听") { playback.pause() }
            } else {
                Button("播放试听") { playback.play([requested(song, route.audition)], index: 0) }
            }
            if current {
                if let error = playback.errorMessage { Text("试听失败：\(error)").foregroundStyle(.secondary) }
                if playback.duration > 0 {
                    ProgressView(value: min(max(0, playback.elapsed), playback.duration), total: playback.duration)
                    Text("\(clock(playback.elapsed)) / \(clock(playback.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func clock(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func qualityPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(route.levels, id: \.self) { Text(L10n.quality($0)).tag($0) }
        }.pickerStyle(.menu)
    }

    private func downloadSection(_ match: Song) -> some View {
        let song = requested(match, route.download), key = DownloadCenter.Key(song)
        return Section("下载") {
            qualityPicker("下载音质", selection: $route.download)
            if let message = downloads.failures[key] { Text("下载失败：\(message)").foregroundStyle(.secondary) }
            if downloads.pending.contains(key) {
                if downloads.isPaused { Text("下载队列已暂停"); Button("继续下载队列") { downloads.resume() } }
                else if let value = downloads.progress(for: song) {
                    ProgressView(value: value) { Text("正在下载") } currentValueLabel: { Text(value, format: .percent) }
                } else { ProgressView("等待下载…") }
                Button("取消下载队列", role: .destructive) { confirmStop = true }
                    .confirmationDialog("取消队列中的全部 \(downloads.pending.count) 项下载？", isPresented: $confirmStop, titleVisibility: .visible) {
                        Button("取消全部下载", role: .destructive) { downloads.stop() }
                        Button("保留下载", role: .cancel) {}
                    }
            } else if downloads.localFile(song) != nil {
                Label("已下载", systemImage: "checkmark.circle")
            } else {
                Button("下载歌曲") { downloads.enqueue([song]) }
            }
        }
    }
}
