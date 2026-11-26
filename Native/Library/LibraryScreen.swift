import SwiftUI
import UniformTypeIdentifiers

struct LibraryScreen: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    @State private var favoritesOnly = false
    @State private var pickingFiles = false
    @State private var namingPlaylist = false
    @State private var name = ""

    var body: some View {
        List {
            Section {
                Button { pickingFiles = true } label: {
                    Label(library.importing ? "Importing audio…" : "Import audio files", systemImage: "square.and.arrow.down")
                }.disabled(library.importing)
            }
            Section("Playlists") {
                ForEach(library.playlists) { item in
                    NavigationLink {
                        PlaylistContents(id: item.id)
                    } label: {
                        Label(item.name, systemImage: "music.note.list")
                    }.swipeActions {
                        Button("Delete", role: .destructive) { library.deletePlaylist(item.id) }
                    }
                }
                Button { name = ""; namingPlaylist = true } label: { Label("New playlist", systemImage: "plus") }
            }
            Section {
                Picker("Show songs", selection: $favoritesOnly) {
                    Text("All songs").tag(false)
                    Text("Favorites").tag(true)
                }.pickerStyle(.segmented)
                LibraryTracks(queue: favoritesOnly ? library.favorites : library.songs, playlist: nil, playback: playback)
            }
        }
        .navigationTitle("Library")
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await library.importFiles(urls) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { library.message = error.localizedDescription }
            }
        }
        .alert("New playlist", isPresented: $namingPlaylist) {
            TextField("Playlist name", text: $name)
            Button("Create") { library.createPlaylist(name) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Library", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK") { library.message = nil }
        } message: { Text(library.message ?? "") }
    }
}

private struct PlaylistContents: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var playback: Playback
    let id: UUID

    var body: some View {
        let playlist = library.playlists.first { $0.id == id }
        List {
            LibraryTracks(queue: library.songs(for: playlist?.songIDs ?? []), playlist: id, playback: playback)
        }.navigationTitle(playlist?.name ?? "Playlist")
    }
}

private struct LibraryTracks: View {
    @EnvironmentObject var library: Library
    let queue: [Song]
    let playlist: UUID?
    let playback: Playback

    var body: some View {
        if queue.isEmpty { Text("No songs yet").foregroundStyle(.secondary) }
        ForEach(Array(queue.enumerated()), id: \.element.id) { index, song in
            HStack {
                Button { playback.play(queue, index: index) } label: {
                    VStack(alignment: .leading) {
                        Text(song.title).lineLimit(1)
                        Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    Button(library.isFavorite(song) ? "Remove from favorites" : "Add to favorites") { library.favorite(song) }
                    if !library.playlists.isEmpty {
                        Menu("Add to playlist") {
                            ForEach(library.playlists) { item in
                                Button(item.name) { library.add(song, to: item.id) }.disabled(item.songIDs.contains(song.id))
                            }
                        }
                    }
                    if let playlist {
                        Button("Remove from playlist", role: .destructive) { library.remove(song, from: playlist) }
                    }
                } label: { Image(systemName: "ellipsis.circle").padding(6) }
                .accessibilityLabel("Actions for \(song.title)")
            }
        }
    }
}
