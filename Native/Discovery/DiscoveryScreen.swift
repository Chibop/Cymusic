import SwiftUI

@MainActor private struct PublishedList<Item: Codable, Rows: View>: View {
    @StateObject private var cache: DiscoveryCache<Item>
    @Environment(\.scenePhase) private var phase
    @Environment(\.locale) private var locale
    private let load: () async throws -> [Item]
    private let rows: ([Item], DiscoveryStatus) -> Rows

    init(key: String, load: @escaping () async throws -> [Item], @ViewBuilder rows: @escaping ([Item], DiscoveryStatus) -> Rows) {
        _cache = StateObject(wrappedValue: DiscoveryCache(key: key))
        self.load = load; self.rows = rows
    }
    var body: some View {
        List { rows(cache.items, DiscoveryStatus(loading: cache.loading, problem: cache.problem, zh: locale.identifier.hasPrefix("zh")) { Task { await cache.refresh(force: true, load: load) } }) }
            .refreshable { await cache.refresh(force: true, load: load) }
            .task { await cache.refresh(load: load) }
            .onChange(of: phase) { if $0 == .active { Task { await cache.refresh(load: load) } } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                if phase == .active { Task { await cache.refresh(load: load) } }
            }
    }
}

private struct DiscoveryStatus: View {
    let loading: Bool, problem: String?, zh: Bool
    let retry: () -> Void
    var body: some View {
        if loading { ProgressView(zh ? "正在加载…" : "Loading…") }
        if let problem {
            VStack(alignment: .leading, spacing: 6) {
                Text(zh ? "未能更新" : "Couldn’t refresh").font(.headline)
                Text(verbatim: problem).font(.caption).foregroundStyle(.secondary)
                Button(zh ? "重试" : "Retry", action: retry)
            }
        }
    }
}

private struct DiscoveryCover: View {
    let url: URL?
    let side: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { ZStack { Color.secondary.opacity(0.12); Image(systemName: "music.note.list").foregroundStyle(.secondary) } }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
    }
}

struct DiscoveryScreen: View {
    @State private var platform = DiscoveryPlatform.qq
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.identifier.hasPrefix("zh") }
    var body: some View {
        PublishedList(key: "\(platform.rawValue):playlists", load: { [platform] in try await DiscoveryCatalog.playlists(platform) }) { items, status in
            Picker(zh ? "平台" : "Platform", selection: $platform) {
                ForEach(DiscoveryPlatform.allCases, id: \.self) { p in Text(verbatim: p.name).tag(p) }
            }.pickerStyle(.segmented)
            Section {
                status
                ForEach(items) { item in
                    NavigationLink { PublishedPlaylistScreen(playlist: item) } label: {
                        HStack(spacing: 12) {
                            DiscoveryCover(url: item.artwork, side: 64)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: item.title).font(.headline).lineLimit(2)
                                if !item.curator.isEmpty { Text(verbatim: item.curator).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }.padding(.vertical, 3)
                    }
                }
            } footer: { Text(zh ? "平台公开发布的精选歌单，非个人推荐。" : "Published selections, not personalized recommendations.") }
        }.id(platform).navigationTitle(zh ? "发现" : "Discover")
    }
}

private struct PublishedPlaylistScreen: View {
    let playlist: DiscoveryPlaylist
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.identifier.hasPrefix("zh") }
    private func playable(_ songs: [Song]) -> [Song] {
        songs.map { song in
            guard let file = downloads.localFile(song) else { return song }
            var local = library.localSongs.first { $0.id == song.id && $0.platform == song.platform } ?? song
            local.url = file; return local
        }
    }
    var body: some View {
        PublishedList(key: "\(playlist.platform.rawValue):tracks:\(playlist.id)", load: { try await DiscoveryCatalog.tracks(playlist) }) { songs, status in
            Section {
                HStack(spacing: 14) {
                    DiscoveryCover(url: playlist.artwork, side: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: playlist.title).font(.headline)
                        if !playlist.curator.isEmpty { Text(verbatim: playlist.curator).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                status
                HStack(spacing: 20) {
                    Button { playback.play(playable(songs), index: 0) } label: { Label(zh ? "播放全部" : "Play all", systemImage: "play.fill") }
                    Button { downloads.enqueue(songs) } label: { Label(zh ? "下载全部" : "Download all", systemImage: "arrow.down.circle") }
                }.buttonStyle(.borderless).disabled(songs.isEmpty)
                if !downloads.pending.isEmpty {
                    let done = downloads.total - downloads.pending.count
                    ProgressView(value: Double(done), total: Double(downloads.total)) {
                        Text(zh ? "下载队列 · \(done)/\(downloads.total)" : "Download queue · \(done)/\(downloads.total)").font(.caption)
                    }
                }
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    HStack(spacing: 12) {
                        Button { playback.play(playable(songs), index: index) } label: {
                            HStack(spacing: 12) {
                                DiscoveryCover(url: song.artwork, side: 44)
                                VStack(alignment: .leading) {
                                    Text(verbatim: song.title).lineLimit(2)
                                    Text(verbatim: song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if let error = downloads.failures[DownloadCenter.Key(song)] { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button { library.favorite(song) } label: { Label(library.isFavorite(song) ? (zh ? "取消收藏" : "Remove from favorites") : (zh ? "收藏" : "Add to favorites"), systemImage: "heart") }
                        }
                        if downloads.pending.contains(DownloadCenter.Key(song)) { ProgressView() }
                        else if downloads.localFile(song) == nil {
                            Button { downloads.enqueue([song]) } label: { Image(systemName: "arrow.down.circle").frame(width: 44, height: 44) }
                                .buttonStyle(.borderless).accessibilityLabel(zh ? "下载 \(song.title)" : "Download \(song.title)")
                        }
                    }
                }
            } header: { Text(zh ? "公开曲目 · \(songs.count)" : "Published tracks · \(songs.count)") } footer: {
                Text(zh ? "仅列出平台公开返回的曲目。播放需有可用音源。" : "Only tracks returned publicly are listed. Playback requires an available source.")
            }
        }.navigationTitle(zh ? "歌单" : "Playlist").navigationBarTitleDisplayMode(.inline)
    }
}
