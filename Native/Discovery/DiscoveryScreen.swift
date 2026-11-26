import SwiftUI
import CryptoKit

private struct DiscoverySnapshot<T: Codable>: Codable {
    let fetched: Date
    let items: [T]
}

/// One state identity per platform + resource. Never display another feed's rows
/// while switching tabs, even if a previous URLSession request finishes late.
private struct PublishedRows<T: Codable, Rows: View>: View {
    let key: String
    let load: () async throws -> [T]
    @ViewBuilder var rows: ([T]) -> Rows
    @State private var snapshot: DiscoverySnapshot<T>?
    @State private var problem: String?
    @State private var loading = true
    @State private var generation = UUID()
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.identifier.hasPrefix("zh") }
    private var cacheFile: URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Discovery-v1", isDirectory: true).appendingPathComponent(digest)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if loading { ProgressView(zh ? "正在加载…" : "Loading…") }
            if let problem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(zh ? "未能更新" : "Couldn’t refresh").font(.headline)
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                    Button(zh ? "重试" : "Retry") { Task { await refresh(force: true) } }
                }
            }
            if let snapshot {
                HStack { Text(zh ? "上次获取" : "Last fetched"); Text(snapshot.fetched, style: .relative) }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await refresh(force: false) }
        if let snapshot { rows(snapshot.items) }
    }
    private func refresh(force: Bool) async {
        let ticket = UUID(); generation = ticket
        if !force, let data = try? Data(contentsOf: cacheFile), let saved = try? JSONDecoder().decode(DiscoverySnapshot<T>.self, from: data) {
            snapshot = saved
            if Date().timeIntervalSince(saved.fetched) < 900 { loading = false; return }
        }
        loading = true; problem = nil
        do {
            let items = try await load(); try Task.checkCancellation()
            guard generation == ticket else { return }
            let saved = DiscoverySnapshot(fetched: Date(), items: items); snapshot = saved
            if let bytes = try? JSONEncoder().encode(saved) {
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: cacheFile, options: .atomic)
            }
        } catch { if generation == ticket && !Task.isCancelled { problem = error.localizedDescription } }
        if generation == ticket { loading = false }
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
        List {
            Picker(zh ? "平台" : "Platform", selection: $platform) {
                ForEach(DiscoveryPlatform.allCases, id: \.self) { p in Text(verbatim: p.name).tag(p) }
            }.pickerStyle(.segmented)
            Section {
                PublishedRows(key: "\(platform.rawValue):playlists", load: { [platform] in try await DiscoveryCatalog.playlists(platform) }) { items in
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
                }.id(platform)
            } header: {
                Text(verbatim: platform == .apple ? (zh ? "Apple Music · 中国大陆新发现" : "Apple Music · China mainland New") : platform == .qq ? (zh ? "QQ 音乐 · 编辑推荐" : "QQ Music · Editor picks") : (zh ? "网易云音乐 · 精品歌单" : "NetEase · Featured playlists"))
            } footer: { Text(zh ? "平台公开发布的精选歌单，非个人推荐。" : "Published selections, not personalized recommendations.") }
        }.navigationTitle(zh ? "发现" : "Discover")
    }
}

private struct PublishedPlaylistScreen: View {
    let playlist: DiscoveryPlaylist
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.identifier.hasPrefix("zh") }
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    DiscoveryCover(url: playlist.artwork, side: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: playlist.title).font(.headline)
                        if !playlist.curator.isEmpty { Text(verbatim: playlist.curator).font(.subheadline).foregroundStyle(.secondary) }
                        Link(destination: playlist.source) { Label(playlist.platform.name, systemImage: "arrow.up.right.square") }.font(.caption)
                    }
                }
            }
            PublishedRows(key: "\(playlist.platform.rawValue):tracks:\(playlist.id)", load: { try await DiscoveryCatalog.tracks(playlist) }) { songs in
                Section {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        Button { playback.play(songs, index: index) } label: {
                            HStack(spacing: 12) {
                                DiscoveryCover(url: song.artwork, side: 44)
                                VStack(alignment: .leading) { Text(verbatim: song.title).lineLimit(2); Text(verbatim: song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button { library.favorite(song) } label: { Label(library.isFavorite(song) ? (zh ? "取消收藏" : "Remove from favorites") : (zh ? "收藏" : "Add to favorites"), systemImage: "heart") }
                        }
                    }
                } header: { Text(zh ? "公开曲目 · \(songs.count)" : "Published tracks · \(songs.count)") } footer: {
                    Text(zh ? "仅列出平台公开返回的曲目。播放需有可用音源。" : "Only tracks returned publicly are listed. Playback requires an available source.")
                }
            }
        }.navigationTitle(zh ? "歌单" : "Playlist").navigationBarTitleDisplayMode(.inline)
    }
}
