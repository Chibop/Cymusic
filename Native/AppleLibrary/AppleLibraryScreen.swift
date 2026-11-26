import SwiftUI
import MediaPlayer

@MainActor struct AppleLibraryScreen: View {
    @EnvironmentObject private var downloads: DownloadCenter
    @StateObject private var sync = AppleLibrarySync()
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    private var zh: Bool { locale.identifier.hasPrefix("zh") }

    var body: some View {
        List {
            Section {
                if sync.busy { ProgressView(zh ? "正在同步…" : "Syncing…") }
                if sync.failed { Text(zh ? "同步失败。请重试。" : "Sync failed. Try again.") }
                switch sync.permission {
                case .denied:
                    Text(zh ? "音乐资料库访问已关闭。" : "Music library access is off.")
                    Button(zh ? "打开设置" : "Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                case .restricted: Text(zh ? "此设备限制了音乐资料库访问。" : "Music library access is restricted on this device.")
                default:
                    Button(sync.permission == .authorized ? (zh ? "重新同步" : "Sync now") : (zh ? "连接音乐资料库" : "Connect music library")) {
                        Task { await sync.refresh(prompt: true) }
                    }.disabled(sync.busy)
                }
                if let date = sync.snapshot?.syncedAt {
                    LabeledContent(zh ? "上次同步" : "Last synced", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: { Text(zh ? "同步只在此设备保存资料库信息。下载时会向音源搜索所选曲目，以可用的最高音质保存，并尝试获取歌词。" : "Sync keeps library metadata on this device. Downloads search providers for the selected tracks, request their best available quality, and look for lyrics.") }
            if !downloads.pending.isEmpty {
                Section("下载队列") {
                    if let until = downloads.retryAfter { Text("限流等待至 \(until.formatted(date: .omitted, time: .standard))") }
                    Button(downloads.isPaused ? "继续下载" : "暂停下载") { if downloads.isPaused { downloads.resume() } else { downloads.pause() } }
                    Button("停止剩余下载", role: .destructive) { downloads.stop() }
                }
            }
            if let snapshot = sync.snapshot {
                if snapshot.tracks.isEmpty { Text(zh ? "音乐资料库中没有歌曲。" : "Your music library has no songs.") }
                else {
                    NavigationLink {
                        AppleLibrarySongs(tracks: snapshot.tracks, title: zh ? "歌曲" : "Songs", zh: zh)
                    } label: { LabeledContent(zh ? "歌曲" : "Songs", value: String(snapshot.tracks.count)) }
                    NavigationLink {
                        List(sync.albums) { album in
                            let title = album.title.isEmpty ? (zh ? "未知专辑" : "Unknown album") : album.title
                            NavigationLink { AppleLibrarySongs(tracks: album.tracks, title: title, zh: zh) } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: title)
                                    if !album.artist.isEmpty { Text(verbatim: album.artist).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.navigationTitle(zh ? "专辑" : "Albums")
                    } label: { LabeledContent(zh ? "专辑" : "Albums", value: String(sync.albums.count)) }
                }
            }
        }.navigationTitle(zh ? "Apple 音乐资料库" : "Apple Music Library")
            .task { await sync.refresh() }
            .onChange(of: phase) { if $0 == .active { Task { await sync.refresh() } } }
    }
}

@MainActor private struct AppleLibrarySongs: View {
    let tracks: [AppleLibraryTrack]
    let title: String
    let zh: Bool
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var query = ""
    private var visible: [AppleLibraryTrack] {
        query.isEmpty ? tracks : tracks.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        let rows = visible
        List {
            Button {
                downloads.enqueueBest(rows.filter(\.canMatch).map(\.song))
            } label: { Label(query.isEmpty ? (zh ? "下载全部 · 最高音质" : "Download all · Best quality") : (zh ? "下载搜索结果" : "Download search results"), systemImage: "arrow.down.circle") }
                .disabled(!rows.contains(where: \.canMatch))
            ForEach(rows) { track in
                let song = track.song, key = DownloadCenter.Key(song)
                let local = downloads.localFile(song) != nil
                let pending = downloads.pending.contains(key)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: track.title.isEmpty ? (zh ? "未知歌曲" : "Untitled track") : track.title).font(.headline)
                        if !track.artist.isEmpty { Text(verbatim: track.artist).font(.subheadline) }
                        Text(track.cloudOnly ? (zh ? "Apple 音乐 · 云端" : "Apple Music · Cloud") : (zh ? "Apple 音乐 · 设备上" : "Apple Music · On device"))
                        if local { Text(zh ? "CyMusic · 已下载" : "CyMusic · Downloaded") }
                        else if pending { Text(zh ? "CyMusic · 下载队列中" : "CyMusic · In download queue") }
                        else if downloads.failures[key] != nil { Text(zh ? "CyMusic · 下载失败，可重试" : "CyMusic · Download failed. Retry available.") }
                        else if !track.canMatch { Text(zh ? "缺少匹配所需的歌曲名或艺人" : "Missing title or artist for provider search") }
                        else { Text(zh ? "CyMusic · 未下载" : "CyMusic · Not downloaded") }
                    }.font(.caption).foregroundStyle(.primary)
                    Spacer()
                    if !local && !pending && track.canMatch {
                        Button { downloads.enqueueBest([song]) } label: { Image(systemName: "arrow.down.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel((zh ? "下载 " : "Download ") + track.title)
                    }
                }
            }
        }.searchable(text: $query).navigationTitle(title)
    }
}
