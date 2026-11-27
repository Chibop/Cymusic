import SwiftUI

struct ArtworkPickerSheet: View {
  let seed: Song, albumMode: Bool
  @EnvironmentObject private var library: Library
  @Environment(\.dismiss) private var dismiss
  @State private var query: String
  @State private var page: ArtworkCatalog.ResultPage?
  @State private var error: String?
  @State private var searching = false
  @State private var applying: Int64?
  @State private var request = UUID()
  @State private var applyTask: Task<Void, Never>?
  @FocusState private var focused: Bool

  init(seed: Song, albumMode: Bool) {
    self.seed = seed; self.albumMode = albumMode
    _query = State(initialValue: [albumMode ? seed.album ?? "" : seed.title, albumMode ? seed.albumArtist ?? seed.artist : seed.artist].filter { !$0.isEmpty }.joined(separator: " "))
  }
  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Apple Music", text: $query).focused($focused).submitLabel(.search)
              .onSubmit { submit() }
            Button { submit() } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }
              .buttonStyle(.borderless).accessibilityLabel("Search")
              .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } footer: { Text(verbatim: albumMode ? (seed.album ?? seed.title) : seed.title) }
        if let error { Section { Text(verbatim: error).foregroundStyle(.secondary) } }
        if searching { ProgressView("Searching Apple Music…") }
        if let page {
          Section {
            if page.candidates.isEmpty { Text("No covers found. Try another title or artist.").foregroundStyle(.secondary) }
            ForEach(page.candidates) { item in
              Button { apply(item) } label: {
                HStack(spacing: 12) {
                  AsyncImage(url: item.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.title).font(.headline)
                    Text(verbatim: item.detail).font(.subheadline).foregroundStyle(.secondary)
                  }
                  Spacer()
                  if applying == item.id { ProgressView() }
                }.contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityHint("Use this artwork")
            }
          } header: { Text(verbatim: "Apple Music · " + page.country) }
        }
      }
      .disabled(applying != nil)
      .navigationTitle(albumMode ? Text("Album artwork") : Text("Song artwork"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { applyTask?.cancel(); dismiss() } } }
      .task(id: request) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        page = nil; error = nil
        guard !term.isEmpty else { searching = false; return }; searching = true
        do { let result = try await ArtworkCatalog.search(term, albumMode: albumMode); try Task.checkCancellation(); page = result }
        catch { guard !Task.isCancelled else { return }; self.error = L10n.message(for: error) }
        searching = false
      }
      .onDisappear { applyTask?.cancel() }
    }
  }
  private func submit() { focused = false; request = UUID() }
  private func apply(_ item: ArtworkCatalog.Candidate) {
    guard applying == nil else { return }; focused = false; applying = item.id; error = nil
    applyTask = Task {
      do {
        let data = try await ArtworkCatalog.download(item); try Task.checkCancellation()
        try await library.replaceArtwork(for: seed, albumMode: albumMode, data: data)
        dismiss()
      } catch { if !Task.isCancelled { self.error = L10n.message(for: error) } }
      applying = nil
    }
  }
}
