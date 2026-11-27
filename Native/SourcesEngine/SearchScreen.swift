import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var engine: SourceEngine
    @EnvironmentObject private var playback: Playback
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var input = ""
    @State private var scriptID: String?
    @State private var platforms = [String]()
    @State private var selected = Set<String>()
    @State private var loadingPlatforms = false
    @State private var platformError: String?
    @State private var result: ScopedSearchResults?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var editing: Bool

    private var script: SourceScript? { engine.scripts.first { $0.id == scriptID } }
    private var canSearch: Bool {
        script != nil && !selected.isEmpty && !loadingPlatforms && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("输入关键词", text: $input).focused($editing).submitLabel(.search).onSubmit { search() }
                }
                Picker("音源脚本", selection: $scriptID) {
                    Text("请选择").tag(String?.none)
                    ForEach(engine.scripts) { Text($0.name).tag(Optional($0.id)) }
                }
                if engine.scripts.isEmpty { Text("请先在设置中导入音源脚本。").foregroundStyle(.secondary) }
            }
            if let script {
                Section("搜索平台") {
                    if loadingPlatforms { ProgressView("正在读取平台") }
                    else if let platformError { Text(platformError).foregroundStyle(.secondary) }
                    else if platforms.isEmpty { Text("此脚本未声明搜索能力，无法用于关键词搜索。").foregroundStyle(.secondary) }
                    ForEach(platforms, id: \.self) { platform in
                        Button {
                            if selected.contains(platform) { selected.remove(platform) } else { selected.insert(platform) }
                        } label: {
                            HStack {
                                Text(ScopedSearchPlatform.name(platform)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(platform) ? "checkmark.circle.fill" : "circle")
                            }.contentShape(Rectangle())
                        }.accessibilityAddTraits(selected.contains(platform) ? .isSelected : [])
                    }
                }
                if !platforms.isEmpty {
                    Button { search() } label: { Label("搜索", systemImage: "magnifyingglass") }.disabled(!canSearch || busy)
                }
                if busy { ProgressView("正在搜索") }
                if let error { Text(error).foregroundStyle(.secondary) }
                if let result {
                    Section(script.name) {
                        ForEach(result.failures, id: \.self) { Text($0).foregroundStyle(.secondary) }
                        if result.songs.isEmpty && result.failures.isEmpty { Text("没有找到歌曲").foregroundStyle(.secondary) }
                        ForEach(result.songs.indices, id: \.self) { index in
                            let song = result.songs[index]
                            Button { playback.play(result.songs, index: index) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title).font(.headline)
                                    Text([song.artist, song.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text(ScopedSearchPlatform.name(song.platform ?? "")).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .swipeActions {
                                Button("下载") { downloads.enqueue([song]) }.tint(.blue)
                                Button("收藏") { library.favorite(song) }.tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .task(id: [script?.id, script?.text]) { await loadPlatforms() }
        .onChange(of: input) { _ in resetSearch() }
        .onChange(of: selected) { _ in resetSearch() }
        .onDisappear { resetSearch() }
    }

    @MainActor private func loadPlatforms() async {
        resetSearch()
        selected.removeAll(); platforms = []; platformError = nil; loadingPlatforms = false
        guard let script else { scriptID = nil; return }
        loadingPlatforms = true
        defer { if !Task.isCancelled { loadingPlatforms = false } }
        do {
            let values = try await engine.declaredSearchPlatforms(for: script)
            try Task.checkCancellation()
            platforms = values
        } catch { if !Task.isCancelled { platformError = error.localizedDescription } }
    }

    private func resetSearch() {
        task?.cancel(); busy = false; result = nil; error = nil
    }

    private func search() {
        guard canSearch, let script else { return }
        resetSearch(); editing = false; busy = true
        let query = input, scope = selected
        task = Task { @MainActor in
            defer { if !Task.isCancelled { busy = false } }
            do {
                let response = try await engine.scopedSearch(query, script: script, platforms: scope)
                try Task.checkCancellation()
                result = response
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
