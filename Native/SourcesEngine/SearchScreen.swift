import SwiftUI

struct SearchScreen: View {
    @State private var input = ""
    @State private var kind: PoolCatalog.Kind = .songs
    @State private var result: PoolCatalog.Results?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            Picker("搜索类型", selection: $kind) {
                ForEach(PoolCatalog.Kind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if busy { ProgressView("正在获取目录") }
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("重试") { search() }
            }
            if let result { CatalogSearchResults(result: result, kind: kind) }
        }
        .navigationTitle("搜索")
        .searchable(text: $input, prompt: "歌曲、专辑或艺人")
        .onSubmit(of: .search) { search() }
        .onChange(of: input) { _ in task?.cancel(); busy = false; result = nil; error = nil }
        .onDisappear { task?.cancel(); busy = false }
    }

    private func search() {
        task?.cancel()
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        result = nil
        error = nil
        busy = true
        task = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                let response = try await PoolCatalog.search(term)
                try Task.checkCancellation()
                result = response
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct CatalogSearchResults: View {
    @EnvironmentObject private var engine: SourceEngine
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    let result: PoolCatalog.Results
    let kind: PoolCatalog.Kind

    var body: some View {
        Section {
            switch kind {
            case .songs:
                if result.songs.isEmpty { Text("没有找到歌曲").foregroundStyle(.secondary) }
                else {
                    if engine.scripts.isEmpty {
                        Text("音源池为空。可以浏览目录，播放或下载前请在设置里导入音源。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(result.songs.indices, id: \.self) { index in
                        let song = result.songs[index]
                        Button { playback.play(result.songs, index: index) } label: {
                            HStack {
                                CatalogArtwork(url: song.artwork, symbol: "music.note")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.title).font(.headline)
                                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                                    if let album = song.album { Text(album).font(.caption).foregroundStyle(.secondary) }
                                    if let duration = song.duration {
                                        Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.lineLimit(2)
                                Spacer()
                                Text(song.platform == "tx" ? "QQ 音乐" : song.platform == "wy" ? "网易云音乐" : result.origin)
                                    .font(.caption2).padding(5).background(.thinMaterial, in: Capsule())
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .swipeActions { Button("收藏") { library.favorite(song) } }
                    }
                }
            case .albums, .artists:
                let entries = kind == .albums ? result.albums : result.artists
                if entries.isEmpty { Text(kind == .albums ? "没有找到专辑" : "没有找到艺人").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    NavigationLink {
                        CatalogSearchDetail(entry: entry, kind: kind)
                    } label: {
                        HStack {
                            CatalogArtwork(url: entry.artwork, symbol: kind == .artists ? "person.fill" : "square.stack")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).font(.headline)
                                Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                if !entry.metadata.isEmpty { Text(entry.metadata).font(.caption).foregroundStyle(.secondary) }
                            }.lineLimit(2)
                        }
                    }
                }
            }
        } header: { Text(result.origin) }
    }
}

private struct CatalogArtwork: View {
    let url: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            Image(systemName: symbol).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct CatalogSearchDetail: View {
    let entry: PoolCatalog.Entry
    let kind: PoolCatalog.Kind
    @State private var result: PoolCatalog.Results?
    @State private var error: String?
    @State private var busy = false
    @State private var attempt = 0

    var body: some View {
        List {
            Section {
                Text(entry.subtitle).foregroundStyle(.secondary)
                if !entry.metadata.isEmpty { Text(entry.metadata).font(.subheadline).foregroundStyle(.secondary) }
            } header: { Text(entry.context.origin) }
            if busy { ProgressView(kind == .artists ? "正在获取艺人发行" : "正在获取专辑曲目") }
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("重试") { attempt += 1 }
            }
            if let result { CatalogSearchResults(result: result, kind: kind == .artists ? .albums : .songs) }
        }
        .navigationTitle(entry.title)
        .task(id: attempt) {
            busy = true
            error = nil
            defer { if !Task.isCancelled { busy = false } }
            do {
                let response = try await (kind == .artists ? PoolCatalog.releases(entry) : PoolCatalog.tracks(entry))
                try Task.checkCancellation()
                result = response
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
