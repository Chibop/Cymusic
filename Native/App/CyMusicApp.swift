import SwiftUI

@main
@MainActor struct CyMusicApp: App {
    @StateObject private var playback: Playback
    @StateObject private var engine: SourceEngine
    @StateObject private var library: Library
    init() {
        let engine = SourceEngine(), library = Library(), playback = Playback()
        playback.resolve = { try await engine.resolve($0) }
        playback.cached = { library.registerCache($0, $1) }
        _engine = StateObject(wrappedValue: engine)
        _library = StateObject(wrappedValue: library)
        _playback = StateObject(wrappedValue: playback)
    }
    var body: some Scene {
        WindowGroup { RootScreen().environmentObject(playback).environmentObject(engine).environmentObject(library) }
    }
}

struct RootScreen: View {
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: SourceEngine
    @AppStorage("appearance") private var appearance = 0
    @State private var playerShown = false
    var body: some View {
        shell
            .sheet(isPresented: $playerShown) { PlayerScreen().presentationDragIndicator(.visible) }
            .preferredColorScheme(appearance == 0 ? nil : appearance == 1 ? .light : .dark)
            .receiveSharedSource { text, name in try await engine.importScript(text, name: name) }
    }
    @ViewBuilder private var shell: some View {
        if #available(iOS 26.0, *), playback.current != nil {
            tabs.tabViewBottomAccessory { miniPlayer }
        } else if playback.current != nil {
            tabs.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer.background(.regularMaterial) }
        } else { tabs }
    }
    private var tabs: some View {
        TabView {
            NavigationStack { LibraryScreen() }.tabItem { Label("资料库", systemImage: "music.note.list") }
            NavigationStack { SearchScreen(onSavePlaylist: { library.importPlaylist($0, songs: $1) }) }.tabItem { Label("发现", systemImage: "magnifyingglass") }
            NavigationStack {
                Form {
                    Section("播放来源") { NavigationLink { SourcesScreen() } label: { Label("自定义音源", systemImage: "dot.radiowaves.left.and.right") } }
                    Section("外观") { Picker("主题", selection: $appearance) { Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2) } }
                }.navigationTitle("设置")
            }.tabItem { Label("设置", systemImage: "gearshape") }
        }.tint(.pink)
    }
    @ViewBuilder private var miniPlayer: some View {
        if let song = playback.current {
            HStack(spacing: 12) {
                Button { playerShown = true } label: {
                    HStack { Image(systemName: "waveform").foregroundStyle(.pink); VStack(alignment: .leading) { Text(verbatim: song.title).font(.subheadline.weight(.semibold)); Text(verbatim: song.artist).font(.caption).foregroundStyle(.secondary) }.lineLimit(1); Spacer(minLength: 0) }.contentShape(Rectangle())
                }.accessibilityHint("展开播放器")
                Button { library.favorite(song) } label: { Image(systemName: library.isFavorite(song) ? "heart.fill" : "heart").frame(minWidth: 36, minHeight: 44) }.accessibilityLabel("收藏")
                Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 36, minHeight: 44) }.accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
            }.buttonStyle(.plain).padding(.horizontal, 16)
        }
    }
}
