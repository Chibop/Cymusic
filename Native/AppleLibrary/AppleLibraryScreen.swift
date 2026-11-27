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
    @EnvironmentObject private var library: Library
    @State private var downloaded = false
    @State private var query = ""
    @State private var settings = false
    @State private var files: [String: URL] = [:]
    @State private var batch: [Song] = []

    private func enqueue(_ songs: [Song]) {
        batch = batch.filter { downloads.pending.contains(.init($0)) }
        let existing = Set(batch.map(DownloadCenter.Key.init))
        batch += songs.filter { !existing.contains(.init($0)) }
        downloads.enqueueApple(songs)
    }

    var body: some View {
        let rows = tracks.filter { track in
            (files[track.id] != nil) == downloaded && (query.isEmpty || track.title.localizedCaseInsensitiveContains(query) || track.artist.localizedCaseInsensitiveContains(query))
        }
        let eligible = rows.filter { $0.canMatch && !downloads.pending.contains(.init($0.song)) }
        let routesEnabled = downloads.appleDownloadRoutes?.values.contains(where: { !$0.isEmpty }) ?? true
        List {
            Picker(zh ? "下载状态" : "Download status", selection: $downloaded) {
                Text(zh ? "未下载" : "Not downloaded").tag(false)
                Text(zh ? "已下载" : "Downloaded").tag(true)
            }.pickerStyle(.segmented)
            if !downloaded {
                Button { enqueue(eligible.map(\.song)) } label: {
                    Label(query.isEmpty ? (zh ? "下载全部 · 最高音质" : "Download all · Best quality") : (zh ? "下载搜索结果" : "Download search results"), systemImage: "arrow.down.circle")
                }.disabled(eligible.isEmpty || !routesEnabled)
            }
            batchProgress
            if rows.isEmpty { Text(zh ? "没有符合条件的歌曲" : "No matching songs").foregroundStyle(.secondary) }
            ForEach(rows) { track in
                let song = track.song, key = DownloadCenter.Key(song)
                let file = files[track.id], pending = downloads.pending.contains(key)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: track.title.isEmpty ? (zh ? "未知歌曲" : "Untitled track") : track.title).font(.headline)
                        if !track.artist.isEmpty { Text(verbatim: track.artist).font(.subheadline) }
                        Text(track.cloudOnly ? (zh ? "Apple 音乐 · 云端" : "Apple Music · Cloud") : (zh ? "Apple 音乐 · 设备上" : "Apple Music · On device"))
                        if let file { AppleLocalFileDetails(file: file, zh: zh) }
                        else if pending { progress(downloads.progress(for: song), label: downloads.isPaused ? (zh ? "已暂停" : "Paused") : (zh ? "下载队列中" : "In download queue")) }
                        else if downloads.failures[key] != nil { Text(zh ? "下载失败，可重试" : "Download failed. Retry available.") }
                        else if !track.canMatch { Text(zh ? "缺少匹配所需的歌曲名或艺人" : "Missing title or artist for provider search") }
                    }.font(.caption)
                    Spacer()
                    if file == nil && !pending && track.canMatch {
                        Button { enqueue([song]) } label: { Image(systemName: "arrow.down.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).disabled(!routesEnabled).accessibilityLabel((zh ? "下载 " : "Download ") + track.title)
                    }
                }
            }
        }.searchable(text: $query).navigationTitle(title)
            .toolbar {
                Button { settings = true } label: { Label(zh ? "下载设置" : "Download settings", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("apple.songs.settings")
            }
            .sheet(isPresented: $settings) { AppleRouteSettings(zh: zh) }
            .task(id: library.shelfRevision) {
                var next = [String: URL]()
                for (index, track) in tracks.enumerated() {
                    if index.isMultiple(of: 32) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                    }
                    next[track.id] = downloads.localFile(track.song)
                }
                files = next
            }
            .onAppear {
                if batch.isEmpty { batch = tracks.map(\.song).filter { downloads.pending.contains(.init($0)) } }
            }
    }

    @ViewBuilder private var batchProgress: some View {
        let remaining = batch.filter { downloads.pending.contains(.init($0)) }
        if !remaining.isEmpty {
            let finished = batch.count - remaining.count
            let fractions = remaining.compactMap { downloads.progress(for: $0) }
            let fraction = fractions.isEmpty ? nil : (Double(finished) + fractions.reduce(0, +)) / Double(batch.count)
            progress(fraction, label: (zh ? "批量进度" : "Batch progress") + " · \(finished)/\(batch.count)")
        }
    }

    @ViewBuilder private func progress(_ fraction: Double?, label: String) -> some View {
        if let fraction {
            ProgressView(value: fraction) { Text(label) } currentValueLabel: { Text(fraction, format: .percent) }
        } else {
            HStack { ProgressView(); Text(label) }
                .accessibilityElement(children: .combine)
        }
    }
}

private struct AppleLocalFileDetails: View {
    let file: URL
    let zh: Bool
    @State private var details: String?

    var body: some View {
        Text(details ?? (zh ? "正在读取文件信息…" : "Reading file details…"))
            .foregroundStyle(.secondary)
            .task(id: file) {
                details = nil
                let info = await AppleLocalAudio.read(file)
                guard !Task.isCancelled else { return }
                details = [info.quality ?? (zh ? "音质未知" : "Unknown quality"), info.duration ?? (zh ? "时长未知" : "Unknown duration")].joined(separator: " · ")
            }
    }
}

@MainActor private struct AppleRouteSettings: View {
    let zh: Bool
    @EnvironmentObject private var downloads: DownloadCenter
    @EnvironmentObject private var engine: SourceEngine
    @Environment(\.dismiss) private var dismiss
    @State private var platforms: [String: [String]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loading = true
    @State private var retry = 0
    private var all: [String: Set<String>] { platforms.mapValues(Set.init) }
    private var selection: [String: Set<String>] { downloads.appleDownloadRoutes ?? all }

    var body: some View {
        NavigationStack {
            List {
                Button(zh ? "允许所有音源和平台" : "Allow all sources and platforms") { downloads.setAppleDownloadRoutes(nil) }
                    .accessibilityValue(downloads.appleDownloadRoutes == nil ? (zh ? "已选" : "Selected") : "")
                if loading { ProgressView() }
                if engine.scripts.isEmpty { Text(zh ? "尚未导入音源" : "No imported sources") }
                ForEach(engine.scripts) { script in
                    Section {
                        if let message = errors[script.id] {
                            Text(verbatim: message)
                            Button(zh ? "重试" : "Retry") { retry += 1 }
                        } else if let list = platforms[script.id] {
                            if list.isEmpty { Text(zh ? "无可用平台" : "No download platforms") }
                            else {
                                Toggle(zh ? "启用音源" : "Allow source", isOn: Binding(get: { selection[script.id]?.isEmpty == false }, set: { enabled in
                                    var next = selection
                                    next[script.id] = enabled ? Set(list) : nil
                                    downloads.setAppleDownloadRoutes(next)
                                }))
                                ForEach(list, id: \.self) { platform in
                                    let enabled = selection[script.id]?.contains(platform) == true
                                    Button {
                                        var next = selection
                                        if enabled { next[script.id]?.remove(platform) }
                                        else { next[script.id, default: []].insert(platform) }
                                        if next[script.id]?.isEmpty == true { next[script.id] = nil }
                                        downloads.setAppleDownloadRoutes(next)
                                    } label: {
                                        HStack {
                                            Text(verbatim: ScopedSearchPlatform.name(platform)).foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                        }.contentShape(Rectangle())
                                    }.accessibilityIdentifier("apple.route.\(script.id).\(platform)")
                                        .accessibilityAddTraits(enabled ? .isSelected : [])
                                }
                            }
                        }
                    } header: { Text(verbatim: script.name) }.disabled(loading)
                }
            }.navigationTitle(zh ? "下载设置" : "Download settings")
                .toolbar { Button(zh ? "完成" : "Done") { dismiss() } }
                .task(id: [String(retry)] + engine.scripts.map(\.id)) {
                    loading = true
                    var found = [String: [String]](), failed = [String: String]()
                    for script in engine.scripts {
                        do { found[script.id] = try await engine.declaredDownloadPlatforms(for: script) }
                        catch { failed[script.id] = error.localizedDescription }
                        if Task.isCancelled { return }
                    }
                    platforms = found; errors = failed; loading = false
                }
        }
    }
}
