import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor struct CyMusicApp: App {
    @StateObject private var playback: Playback
    @StateObject private var engine: SourceEngine
    @StateObject private var library: Library
    @StateObject private var downloads: DownloadCenter
    init() {
        let reset = Result { try DownloadedAudioCleanup.once(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) }
        let engine = SourceEngine(), library = Library(), playback = Playback()
        if case .failure(let error) = reset { library.message = "下载缓存未能完全清理：\(L10n.message(for: error))" }
        if let old = try? LegacyMigration.sourceSettings(documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
            do { try engine.restoreLegacy(old) } catch { library.message = "旧音源未迁移，原数据未改动：\(L10n.message(for: error))" }
        }
        playback.resolveMedia = { try await engine.resolveMedia($0) }
        playback.downloadFromPool = { song in
            let media = try await engine.downloadMedia(song) { try await PlaybackFiles.save(song, source: $0) }
            return (media.url, media.source)
        }
        playback.cached = { library.registerCache($0, $1) }
        _downloads = StateObject(wrappedValue: DownloadCenter(engine: engine, library: library))
        _engine = StateObject(wrappedValue: engine)
        _library = StateObject(wrappedValue: library)
        _playback = StateObject(wrappedValue: playback)
    }
    var body: some Scene {
        WindowGroup { RootScreen().environmentObject(playback).environmentObject(engine).environmentObject(library).environmentObject(downloads) }
    }
}

struct RootScreen: View {
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: SourceEngine
    @AppStorage("appearance") private var appearance = 0
    private enum Page: Hashable { case library, search, settings }
    @State private var page = Page.library
    @State private var importingSongs = false
    @State private var playerShown = false
    var body: some View {
        shell
            .sheet(isPresented: $playerShown) { PlayerScreen().presentationDragIndicator(.hidden) }
            .preferredColorScheme(appearance == 0 ? nil : appearance == 1 ? .light : .dark)
            .onChange(of: library.artworkRevision) { _ in playback.refreshArtwork { library.artworkOverride(for: $0) } }
            .receiveSharedSource { text, name in try await engine.importScript(text, name: name) }
            .environment(\.locale, L10n.locale)
    }
    @ViewBuilder private var shell: some View {
        if #available(iOS 26.1, *) {
            modernTabs.tabViewBottomAccessory(isEnabled: page != .library && playback.current != nil) { accessory }
        } else if #available(iOS 26.0, *) {
            modernTabs.tabViewBottomAccessory { accessory }
        } else {
            legacyTabs.safeAreaInset(edge: .bottom, spacing: 0) {
                if page != .library, let song = playback.current { player(song, compact: false).background(.regularMaterial) }
            }
        }
    }

    @available(iOS 26.0, *) private var modernTabs: some View {
        TabView(selection: $page) {
            Tab("资料库", systemImage: "music.note.list", value: Page.library) { NavigationStack { LibraryScreen() } }
            Tab("搜索", systemImage: "magnifyingglass", value: Page.search) { NavigationStack { SearchScreen() } }
            Tab("设置", systemImage: "gearshape", value: Page.settings) { settings }
        }.tabBarMinimizeBehavior(.onScrollDown).tint(.blue)
    }

    private var legacyTabs: some View {
        TabView(selection: $page) {
            NavigationStack { LibraryScreen() }.tabItem { Label("资料库", systemImage: "music.note.list") }.tag(Page.library)
            NavigationStack { SearchScreen() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(Page.search)
            settings.tabItem { Label("设置", systemImage: "gearshape") }.tag(Page.settings)
        }.tint(.blue)
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("本地音乐") { Button { importingSongs = true } label: { Label("导入歌曲", systemImage: "square.and.arrow.down") } }
                Section("播放来源") { NavigationLink { SourcesScreen() } label: { Label("自定义音源", systemImage: "dot.radiowaves.left.and.right") } }
                Section("音乐资料库") { NavigationLink { AppleLibraryScreen() } label: { Label("同步 Apple Music 资料库", systemImage: "arrow.triangle.2.circlepath") } }
                Section("专辑封面") { AlbumCoverSyncButton() }
                Section("外观") { Picker("主题", selection: $appearance) { Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2) } }
            }.navigationTitle("设置")
            .fileImporter(isPresented: $importingSongs, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): if (error as? CocoaError)?.code != .userCancelled { library.message = L10n.message(for: error) }
                }
            }
        }
    }

    @available(iOS 26.0, *) @ViewBuilder private var accessory: some View {
        if page != .library, let song = playback.current {
            AccessoryLayout { compact in player(song, compact: compact) }
        }
    }

    private func player(_ song: Song, compact: Bool) -> some View {
        HStack(spacing: compact ? 0 : 4) {
            Button { playerShown = true } label: {
                HStack(spacing: 8) {
                    MiniArtwork(url: song.artwork).id(song.artwork)
                        .frame(width: compact ? 32 : 38, height: compact ? 32 : 38)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: song.title).font(.subheadline.weight(.semibold))
                        Text(verbatim: song.artist.isEmpty ? "未知歌手" : song.artist).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityHint("展开播放器").accessibilityIdentifier("mini.open")
            if !compact {
                Button { library.favorite(song) } label: {
                    Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart").frame(width: 44, height: 44)
                }.accessibilityLabel("收藏")
            }
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
            }.accessibilityLabel(playback.isPlaying ? "暂停" : "播放").accessibilityIdentifier("mini.toggle")
        }.buttonStyle(.plain).padding(.leading, compact ? 4 : 12).padding(.trailing, compact ? 0 : 8)
    }
}

@available(iOS 26.0, *) private struct AccessoryLayout<Content: View>: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let content: (Bool) -> Content
    var body: some View { content(placement == .inline) }
}

private struct MiniArtwork: View {
    let url: URL?
    @State private var local: UIImage?
    private var placeholder: some View {
        ZStack { Color.secondary.opacity(0.14); Image(systemName: "music.note").foregroundStyle(.secondary) }
    }
    var body: some View {
        if let url, url.isFileURL {
            Group {
                if let local { Image(uiImage: local).resizable().scaledToFill() } else { placeholder }
            }.task(id: url) {
                let image = await Task.detached(priority: .utility) {
                    UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 120, height: 120))
                }.value
                if !Task.isCancelled { local = image }
            }
        } else if let url {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else { placeholder }
    }
}
