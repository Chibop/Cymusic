import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var engine: SourceEngine
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    @State private var input = ""
    @State private var result: PoolCatalog.Results?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            if busy { ProgressView("正在获取目录") }
            if let error { Text(error).foregroundStyle(.secondary) }
            if let result {
                if result.songs.isEmpty { Text("没有找到歌曲").foregroundStyle(.secondary) }
                else {
                    if engine.scripts.isEmpty { Text("音源池为空。可以搜索，播放或下载前请在设置里导入音源。").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(result.songs.indices, id: \.self) { index in
                        let song = result.songs[index]
                        Button { playback.play(result.songs, index: index) } label: {
                            HStack {
                                AsyncImage(url: song.artwork) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note") }
                                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(song.title).font(.headline)
                                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                                }.lineLimit(2)
                                Spacer()
                                Text(song.platform == "tx" ? "QQ 音乐" : song.platform == "wy" ? "网易云音乐" : result.origin)
                                    .font(.caption2).padding(5).background(.thinMaterial, in: Capsule())
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .swipeActions { Button("收藏") { library.favorite(song) } }
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $input, prompt: "歌曲或艺人")
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
