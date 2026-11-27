import SwiftUI

struct PlaylistSongPicker: View {
  @EnvironmentObject private var library: Library
  @Environment(\.dismiss) private var dismiss
  let playlistID: UUID
  @State private var byArtist = true
  @State private var selection = Set<String>()
  @State private var saveFailed = false

  var body: some View {
    let tracks = library.localSongs
    let existing = Set(library.playlists.first { $0.id == playlistID }?.songIDs ?? [])
    let additions = tracks.filter { selection.contains($0.id) && !existing.contains($0.id) }
    NavigationStack {
      List {
        Picker("选择方式", selection: $byArtist) {
          Text("艺人").tag(true)
          Text("全部歌曲").tag(false)
        }.pickerStyle(.segmented)
        if byArtist {
          let groups = Dictionary(grouping: tracks, by: \.artist)
          ForEach(groups.keys.sorted(), id: \.self) { artist in
            choice(artist, ids: Set((groups[artist] ?? []).map(\.id)), existing: existing)
          }
        } else {
          ForEach(tracks) { song in
            choice(song.title, ids: [song.id], existing: existing, subtitle: song.artist)
              .accessibilityIdentifier("library.track." + song.id)
          }
        }
      }.navigationTitle("添加歌曲").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("添加（\(additions.count)）") {
              if library.add(additions, to: playlistID) { dismiss() } else { saveFailed = true }
            }.disabled(additions.isEmpty).accessibilityIdentifier("playlist.confirm")
          }
        }.alert("无法保存歌单", isPresented: $saveFailed) { Button("好") {} }
    }
  }

  private func choice(_ title: String, ids: Set<String>, existing: Set<String>, subtitle: String? = nil) -> some View {
    let available = ids.subtracting(existing)
    let checked = available.isSubset(of: selection)
    let partial = !ids.isDisjoint(with: existing) || !available.isDisjoint(with: selection)
    return Button {
      if checked { selection.subtract(available) } else { selection.formUnion(available) }
    } label: {
      HStack {
        Image(systemName: checked ? "checkmark.square.fill" : partial ? "minus.square" : "square")
          .foregroundStyle(Color.accentColor).accessibilityHidden(true)
        VStack(alignment: .leading) {
          Text(verbatim: title)
          if let subtitle { Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(available.isEmpty)
      .accessibilityValue(checked ? "已选择" : partial ? "部分选择" : "未选择")
  }
}
