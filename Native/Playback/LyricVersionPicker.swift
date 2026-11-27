import SwiftUI

struct LyricPickerContext: Identifiable {
  let id: UUID
  let song: Song
}

struct LyricVersionPicker: View {
  let context: LyricPickerContext
  @EnvironmentObject private var playback: Playback
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var artist: String
  @State private var request: UUID?
  @State private var results: [LyricVersion] = []
  @State private var busy = false
  @State private var message: String?

  init(context: LyricPickerContext) {
    self.context = context
    _title = State(initialValue: context.song.title)
    _artist = State(initialValue: context.song.artist)
  }

  var body: some View {
    NavigationStack {
      List {
        Section("当前版本") {
          if let selected = playback.lyricVersion {
            metadata(selected)
            Button("恢复默认歌词") { apply(nil) }
          } else { Text("默认歌词") }
        }
        Section("搜索 LRCLIB") {
          TextField("歌曲名称", text: $title)
          TextField("歌手（可选）", text: $artist)
          Button("搜索歌词") {
            results = []
            message = nil
            busy = true
            request = UUID()
          }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if busy { ProgressView("正在搜索…") }
        if let message { Text(message).foregroundStyle(.secondary) }
        ForEach(results) { version in
          NavigationLink {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                metadata(version)
                Text(verbatim: version.text).textSelection(.enabled)
              }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.navigationTitle("歌词预览").toolbar {
              Button("应用此版本") { apply(version) }
            }
          } label: { metadata(version) }
        }
      }.navigationTitle("歌词版本").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
      }
    }.task(id: request) {
      guard let token = request else { return }
      let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
      do {
        let versions = try await LyricVersion.search(title: title, artist: artist)
        guard !Task.isCancelled, request == token, playback.generation == context.id else { return }
        results = versions
        message = versions.isEmpty ? "没有找到歌词，可修改歌名或歌手后重试。" : nil
      } catch {
        guard !Task.isCancelled, request == token, playback.generation == context.id else { return }
        message = "搜索失败，请检查网络后重试。"
      }
      busy = false
    }.alert("无法保存歌词版本", isPresented: $saveFailed) { Button("好") {} }
  }

  private func metadata(_ version: LyricVersion) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: version.trackName).font(.headline)
      Text(verbatim: [version.artistName, version.albumName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
      Text(verbatim: ["LRCLIB #\(version.id)", version.synced ? "同步歌词" : "纯文本", version.duration.map { String(format: "%.0f 秒", $0) }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }
  }

  @State private var saveFailed = false
  private func apply(_ version: LyricVersion?) {
    do { try playback.chooseLyrics(version, token: context.id); dismiss() }
    catch { saveFailed = true }
  }
}
