import SwiftUI

struct SearchScreen: View {
    @State private var useLanyue = false
    @State private var site = LanyueCatalog.kugou
    @State private var query = ""
    @State private var songs: [Song]?
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var destination = SongDestination()
    @FocusState private var editing: Bool

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section("歌曲目录") {
                Picker("搜索目录", selection: $useLanyue) {
                    Text("Apple Music").tag(false)
                    Text("揽乐 Lanyue").tag(true)
                }.pickerStyle(.segmented).onChange(of: useLanyue) { _ in resetSearch() }
                if useLanyue {
                    Picker("来源站点", selection: $site) {
                        ForEach(LanyueCatalog.allCases, id: \.self) { site in
                            Text(ScopedSearchPlatform.name(site.rawValue)).tag(site)
                        }
                    }.onChange(of: site) { _ in resetSearch() }
                }
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
                let found = try await useLanyue ? site.search(input) : PoolCatalog.searchSongs(input)
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
            if song.metadataProvider == LanyueCatalog.providerID, let platform = song.platform {
                Text("揽乐 · \(ScopedSearchPlatform.name(platform))").font(.caption).foregroundStyle(.secondary)
            } else if song.platform == "apple" {
                Text("Apple Music").font(.caption).foregroundStyle(.secondary)
            }
            Text([song.artist, song.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// Owned by the search tab, not by the pushed view: returning to the same result
// keeps its completed matches. An interrupted lookup restarts on return.
@MainActor private final class SongDestination: ObservableObject {
    @Published var seed: Song?
    @Published var scriptID: String?
    private var scriptText: String?
    @Published var sites = [String]()
    @Published var matches = [String: Song]()
    @Published var failures = [String: String]()
    @Published var levels = [String: [String]]()
    @Published var busy = false
    private var task: Task<Void, Never>?

    func open(_ seed: Song, engine: SourceEngine) {
        let script = engine.scripts.first { $0.id == scriptID } ?? engine.scripts.first
        if self.seed != seed { self.seed = seed; selectScript(script, engine: engine) }
        else if script?.id != scriptID || script?.text != scriptText || (script != nil && !busy && sites.count > matches.count + failures.count) { selectScript(script, engine: engine) }
    }

    func cancel() { task?.cancel(); task = nil; busy = false }

    func selectScript(_ script: SourceScript?, engine: SourceEngine) {
        cancel(); sites = []; matches = [:]; failures = [:]; levels = [:]
        scriptID = script?.id; scriptText = script?.text
        guard let script, let seed else { return }
        busy = true
        task = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let targets = try await engine.declaredDownloadPlatforms(for: script).filter {
                    seed.metadataProvider != LanyueCatalog.providerID || seed.platform == $0
                }
                try Task.checkCancellation(); sites = targets
                guard !targets.isEmpty else { return }
                await withTaskGroup(of: (String, Song?, [String], String?).self) { group in
                    for site in targets {
                        group.addTask {
                            do {
                                let found = try await engine.matchCatalogSong(seed, script: script, platform: site)
                                let qualities = try await engine.availableLevels(for: found, script: script)
                                return (site, found, qualities, qualities.isEmpty ? "站点未声明可用音质" : nil)
                            }
                            catch let error as SourceFailure { return (site, nil, [], L10n.message(for: error)) }
                            catch { return (site, nil, [], "站点暂不可用：\(L10n.message(for: error))") }
                        }
                    }
                    for await (site, song, qualities, error) in group {
                        guard !Task.isCancelled else { return }
                        if let song, error == nil { matches[site] = song; levels[site] = qualities } else { failures[site] = error ?? "未找到匹配曲目" }
                    }
                }
            } catch { if !Task.isCancelled { failures["_"] = L10n.message(for: error) } }
        }
    }
}

private struct SearchSongDestination: View {
    let seed: Song
    @ObservedObject var route: SongDestination
    @EnvironmentObject private var engine: SourceEngine
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var downloads: DownloadCenter

    private var script: SourceScript? { engine.scripts.first { $0.id == route.scriptID } }

    var body: some View {
        List {
            Section("目录歌曲") { SearchSongLabel(song: seed) }
            Section(seed.metadataProvider == LanyueCatalog.providerID ? "选择本站播放脚本" : "按脚本查询全部站点") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(engine.scripts) { item in
                            let selected = route.scriptID == item.id
                            Button(item.name) { route.selectScript(item, engine: engine) }
                                .buttonStyle(.bordered).tint(selected ? .accentColor : .secondary)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("search.script.\(item.id)")
                        }
                    }
                }
                if engine.scripts.isEmpty { Text("请先在设置中导入音源脚本。").foregroundStyle(.secondary) }
                if route.busy { ProgressView("正在查询所有可用站点…") }
                if let failure = route.failures["_"] { Text(failure).foregroundStyle(.secondary) }
                if !route.busy, route.sites.isEmpty, script != nil {
                    Text(seed.metadataProvider == LanyueCatalog.providerID ? "此脚本不支持该来源站点。" : "脚本未声明可用下载站点。") .foregroundStyle(.secondary)
                }
            }
            ForEach(route.sites, id: \.self) { site in
                if let song = route.matches[site] {
                    Section {
                        SearchSongLabel(song: song)
                        Text("\(ScopedSearchPlatform.name(site)) · \(song.duration.map(clock) ?? "时长未知")")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(route.levels[site] ?? [], id: \.self) { level in
                            qualityActions(song: song, site: site, level: level)
                        }
                    } header: { Text("\(ScopedSearchPlatform.name(site)) · 站点原生曲目") }
                } else if let failure = route.failures[site] {
                    Section("\(ScopedSearchPlatform.name(site))") { Text(failure).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("选择音源").navigationBarTitleDisplayMode(.inline)
        .onAppear { route.open(seed, engine: engine) }
        .onChange(of: script?.text) { _ in route.open(seed, engine: engine) }

    }

    private func requested(_ song: Song, _ quality: String) -> Song {
        var copy = song; copy.searchScriptID = route.scriptID; copy.requestedQuality = quality; return copy
    }

    private func qualityActions(song: Song, site: String, level: String) -> some View {
        let item = requested(song, level), key = DownloadCenter.Key(item)
        let current = playback.current.map { DownloadCenter.Key($0) == key } ?? false
        return VStack(alignment: .leading) {
            HStack {
                Text(L10n.quality(level)).font(.subheadline)
                Spacer()
                Button {
                    if current && playback.loading { playback.clear() }
                    else if current && playback.isPlaying { playback.pause() }
                    else if current && playback.errorMessage == nil { playback.resume() }
                    else { playback.play([item], index: 0) }
                } label: {
                    Label(current && playback.loading ? "取消试听" : current && playback.isPlaying ? "暂停" : "播放",
                          systemImage: current && playback.isPlaying ? "pause.fill" : "play.fill")
                }.accessibilityIdentifier("search.play.\(site).\(level)")
                if downloads.pending.contains(key) {
                    if downloads.isPaused { Button("继续队列") { downloads.resume() } }
                    else if let value = downloads.progress(for: item) { ProgressView(value: value).frame(width: 56) }
                    else { ProgressView("等待下载") }
                } else if downloads.localFile(item) != nil {
                    Label("已下载", systemImage: "checkmark.circle").font(.caption)
                } else {
                    Button { downloads.enqueue([item]) } label: { Label("下载", systemImage: "arrow.down.circle") }
                        .accessibilityIdentifier("search.download.\(site).\(level)")
                }
            }.buttonStyle(.borderless)
            if current && playback.loading { ProgressView("正在准备试听…") }
            if current, playback.duration > 0 {
                ProgressView(value: min(max(0, playback.elapsed), playback.duration), total: playback.duration)
                Text("\(clock(playback.elapsed)) / \(clock(playback.duration))").font(.caption.monospacedDigit())
            }
            if current, let message = playback.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("search.playError.\(site).\(level)")
            }
            if let message = downloads.failures[key] { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func clock(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
