import SwiftUI
import UniformTypeIdentifiers

private struct ShelfAlbum: Identifiable {
  let id: String, title: String, artist: String, tracks: [Song]
  let art: URL?
  @MainActor static func collect(_ library: Library, songs: [Song]) -> [Self] {
    func key(_ s: String) -> String {
      s.trimmingCharacters(in: .whitespacesAndNewlines).folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    return Dictionary(grouping: songs) { song in
      [key(song.album ?? ""), key(song.albumArtist ?? song.artist)].joined(separator: "\u{0}")
    }.map { key, tracks in
      let sorted = tracks.sorted {
        let a = library.trackOrder($0)
        let b = library.trackOrder($1)
        return a != b ? a < b : $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
      let s = sorted[0]
      return Self(
        id: key, title: s.album ?? "Unknown Album", artist: s.albumArtist ?? s.artist,
        tracks: sorted, art: sorted.lazy.compactMap { library.albumArtwork(for: $0) }.first)
    }.sorted {
      $0.title == $1.title
        ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
}

private enum ShelfCollection: Hashable {
  case all, favorites
  case playlist(UUID)

  @MainActor func tracks(in library: Library) -> [Song] {
    switch self {
    case .all: return library.localSongs
    case .favorites: return library.localFavorites
    case .playlist(let id):
      return library.localTracks(library.playlists.first { $0.id == id }?.songIDs ?? [])
    }
  }
  @MainActor func title(in library: Library) -> String {
    switch self {
    case .all: return String(localized: "All Songs")
    case .favorites: return String(localized: "Favorites")
    case .playlist(let id): return library.playlists.first { $0.id == id }?.name ?? ""
    }
  }
}

struct LibraryScreen: View {
  @EnvironmentObject private var library: Library
  @EnvironmentObject private var playback: Playback
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var collection = ShelfCollection.all
  @State private var albums: [ShelfAlbum] = []
  @State private var selected = 0
  @State private var songFlow = false
  @State private var detail: ShelfAlbum?
  @State private var collections = false
  @State private var pickingFiles = false
  private var inQueue: Bool {
    songFlow && !playback.queue.isEmpty && playback.current?.url?.isFileURL == true
  }
  private var album: ShelfAlbum? { albums.indices.contains(selected) ? albums[selected] : nil }
  private var count: Int { inQueue ? playback.queue.count : albums.count }
  private var focus: Int { inQueue ? playback.index : selected }
  private func step(_ n: Int) {
    guard count > 0 else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    let next = (focus + n % count + count) % count
    if inQueue { playback.select(next) } else { selected = next }
  }
  private func center() {
    if inQueue {
      playback.toggle()
    } else if let album {
      detail = album
    } else {
      pickingFiles = true
    }
  }
  private func menu() { if inQueue { songFlow = false } else { collections = true } }
  private func shuffle() {
    let songs = collection.tracks(in: library).shuffled()
    guard !songs.isEmpty else { return }
    playback.play(songs, index: 0)
    songFlow = true
  }
  private func playPause() {
    if inQueue {
      playback.toggle()
    } else if let album {
      playback.play(album.tracks, index: 0)
      songFlow = true
    }
  }
  var body: some View {
    GeometryReader { g in
      let landscape = g.size.width > g.size.height * 1.35
      let side = max(
        1,
        min(
          landscape ? g.size.width * 0.46 : g.size.width - 26,
          landscape ? g.size.height - 20 : g.size.height * 0.56, 560))
      let dial = max(
        1,
        min(
          landscape ? g.size.width * 0.36 : g.size.width * 0.61,
          landscape ? g.size.height * 0.82 : g.size.height - side - 25, 270))
      let layout =
        landscape ? AnyLayout(HStackLayout(spacing: 26)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        display(side).padding(.top, landscape ? 0 : 6)
        if !landscape { Spacer(minLength: 4) }
        ClickWheel(
          size: dial, songMode: inQueue, menu: menu, center: center, step: step, play: playPause)
        if !landscape { Spacer(minLength: 4) }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(
      LinearGradient(
        colors: [Color(white: 0.95), Color(white: 0.82), Color(white: 0.93)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    )
    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button {
          pickingFiles = true
        } label: {
          Image(systemName: "square.and.arrow.down")
        }.accessibilityLabel("Import audio files").accessibilityIdentifier("library.import")
          .disabled(library.importing)
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: shuffle) { Label("随机播放", systemImage: "shuffle") }.disabled(albums.isEmpty)
          .accessibilityIdentifier("library.shuffle")
      }
    }
    .onChange(of: library.artworkRevision) { _ in refreshShelf() }
    .onChange(of: library.localSongs) { _ in refreshShelf() }
    .onChange(of: collection.tracks(in: library)) { _ in refreshShelf() }
    .onChange(of: collection) { _ in
      selected = 0
      refreshShelf()
    }
    .onAppear { refreshShelf() }
    .task { await library.indexLocalFiles() }
    .onChange(of: scenePhase) { if $0 == .active { Task { await library.indexLocalFiles() } } }
    .sheet(item: $detail) { album in
      NavigationStack {
        AlbumDetail(album: album) { tracks, index in
          playback.play(tracks, index: index)
          songFlow = true
          detail = nil
        }
      }.presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $collections) {
      NavigationStack {
        CollectionsView(selection: $collection) { tracks, i in
          playback.play(tracks, index: i)
          songFlow = true
          collections = false
        }
      }.presentationDragIndicator(.visible)
    }
    .fileImporter(
      isPresented: $pickingFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): Task { await library.importFiles(urls) }
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled {
          library.message = error.localizedDescription
        }
      }
    }
    .alert(
      "Library",
      isPresented: Binding(
        get: { library.message != nil }, set: { if !$0 { library.message = nil } })
    ) {
      Button("OK") { library.message = nil }
    } message: {
      Text(library.message ?? "")
    }
  }
  private func refreshShelf() {
    let oldID = album?.id
    albums = ShelfAlbum.collect(library, songs: collection.tracks(in: library))
    selected = albums.firstIndex { $0.id == oldID } ?? min(selected, max(0, albums.count - 1))
  }
  private func display(_ side: CGFloat) -> some View {
    let art = inQueue ? playback.current?.artwork : album?.art
    let title = inQueue ? playback.current?.title : album?.title
    return VStack(spacing: 0) {
      HStack {
        Text(inQueue ? String(localized: "Now Playing") : collection.title(in: library)).fontWeight(
          .bold)
        Spacer()
        if inQueue { Image(systemName: playback.isPlaying ? "play.fill" : "pause.fill") }
        Text(count == 0 ? "—" : "\(focus + 1) / \(count)").monospacedDigit()
      }
      .font(.caption).foregroundStyle(.primary).padding(.horizontal, 12).frame(height: 27)
      .background(.regularMaterial)
      .overlay(alignment: .bottom) { Divider() }
      if count > 0 {
        CoverFlowShelf(count: count, focus: focus, reduceMotion: reduceMotion, step: step, activate: center) { i in
          Jacket(art: inQueue ? playback.queue[i].artwork : albums[i].art,
                 title: inQueue ? playback.queue[i].title : albums[i].title)
        }
          .accessibilityElement(children: .ignore).accessibilityLabel("Cover Flow")
          .accessibilityValue(inQueue ? playback.current?.title ?? "" : album?.title ?? "")
          .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }.accessibilityAction {
            center()
          }.accessibilityIdentifier("library.coverflow")
        ShelfCaption(raw: inQueue ? playback.current?.lyrics : nil, elapsed: playback.elapsed) {
          VStack(spacing: 2) {
            Text(verbatim: inQueue ? playback.current?.title ?? "" : album?.title ?? "").font(
              .headline
            ).accessibilityIdentifier(inQueue ? "library.currentTitle" : "library.albumTitle")
            Text(verbatim: inQueue ? playback.current?.artist ?? "" : album?.artist ?? "").font(
              .subheadline
            ).foregroundStyle(Color(white: 0.76))
            if inQueue, let badge = playback.current?.quality {
              Text(verbatim: badge).font(.caption2.monospaced()).foregroundStyle(Color(white: 0.76))
            }
          }.lineLimit(1).padding(.horizontal, 8).padding(.bottom, 12).foregroundStyle(.white)
        }.frame(minHeight: min(80, side * 0.24)).layoutPriority(1)
      } else {
        Spacer()
        Image(systemName: "music.note.list").font(.largeTitle)
        Text("No songs yet").font(.headline).padding(.top, 5)
        Button("Import audio files") { pickingFiles = true }.font(.subheadline).padding(8)
        Spacer()
      }
    }.foregroundStyle(.white).frame(width: max(1, side - 12), height: max(1, side - 12)).background(
      CoverFlowBackdrop(art: art, title: title ?? "")
    ).clipShape(RoundedRectangle(cornerRadius: 5)).padding(6)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.14))).overlay(
        RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.7), lineWidth: 1))
  }
}

private struct ShelfCaption<Metadata: View>: View {
  let raw: String?, elapsed: Double
  @ViewBuilder var metadata: () -> Metadata
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let lines = ShelfLyrics.lines(raw)
    if let index = ShelfLyrics.index(at: elapsed, in: lines), !lines[index].text.isEmpty {
      let line = lines[index]
      ZStack {
        VStack(spacing: 2) {
          neighbor(index > 0 ? lines[index - 1].text : "", id: "library.lyric.previous")
          Text(attributed(line)).font(.subheadline.weight(.semibold)).lineLimit(1)
            .accessibilityLabel(Text(verbatim: line.text)).accessibilityIdentifier("library.lyric")
          neighbor(index + 1 < lines.count ? lines[index + 1].text : "", id: "library.lyric.next")
        }.id(index).transition(.opacity)
      }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index)
        .padding(.horizontal, 10).padding(.bottom, 6)
    } else {
      metadata()
    }
  }

  @ViewBuilder private func neighbor(_ text: String, id: String) -> some View {
    if text.isEmpty {
      Text(verbatim: " ").font(.caption2).hidden().accessibilityHidden(true)
    } else {
      Text(verbatim: text).font(.caption2).lineLimit(1)
        .foregroundStyle(Color(white: 0.67)).accessibilityIdentifier(id)
    }
  }

  private func attributed(_ line: ShelfLyrics.Line) -> AttributedString {
    guard !line.parts.isEmpty else { return AttributedString(line.text) }
    let active = line.activePart(at: elapsed)
    var result = AttributedString()
    for (i, part) in line.parts.enumerated() {
      var run = AttributedString(part.text)
      run.foregroundColor = i == active ? .white : Color(white: 0.70)
      result.append(run)
    }
    return result
  }
}

// Independent of SwiftUI so timestamp and seek boundaries can be tested numerically.
enum ShelfLyrics {
  struct Part { let time: Double?, text: String }
  struct Line {
    let time: Double, text: String, parts: [Part]
    func activePart(at elapsed: Double) -> Int? {
      guard let i = parts.lastIndex(where: { ($0.time ?? .infinity) <= elapsed }),
        !parts[i].text.isEmpty else { return nil }
      return i
    }
  }
  private static let lineStamp = try! NSRegularExpression(pattern: #"\[(\d+):([0-5]?\d)(?:[.:](\d+))?\]"#)
  private static let wordStamp = try! NSRegularExpression(pattern: #"<(\d+):([0-5]?\d)(?:[.:](\d+))?>"#)
  private static let adjustment = try! NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#)
  @MainActor private static var cache: (String, [Line])?
  @MainActor static func lines(_ raw: String?) -> [Line] {
    guard let raw else { return [] }
    if let cache, cache.0 == raw { return cache.1 }
    let parsed = parse(raw)
    cache = (raw, parsed)
    return parsed
  }

  // Return the latest cue at or before the clock, including on a backward seek.
  static func index(at elapsed: Double, in lines: [Line]) -> Int? {
    var low = 0, high = lines.count
    while low < high {
      let mid = low + (high - low) / 2
      if lines[mid].time <= elapsed { low = mid + 1 } else { high = mid }
    }
    return low > 0 ? low - 1 : nil
  }

  static func parse(_ raw: String) -> [Line] {
    let source = raw as NSString
    let offset = adjustment.firstMatch(in: raw, range: NSRange(location: 0, length: source.length))
      .flatMap { Double(source.substring(with: $0.range(at: 1))) } ?? 0
    // Keep milliseconds until the final conversion to avoid offset subtraction jitter at boundaries.
    func millis(_ match: NSTextCheckingResult, _ s: NSString) -> Double {
      let minute = Double(s.substring(with: match.range(at: 1))) ?? 0
      let second = Double(s.substring(with: match.range(at: 2))) ?? 0
      let fraction = match.range(at: 3)
      let digits = fraction.location == NSNotFound ? "" : s.substring(with: fraction)
      return minute * 60_000 + second * 1_000 + (Double("0." + digits) ?? 0) * 1_000
    }
    var lines: [Line] = []
    for row in raw.components(separatedBy: .newlines) {
      let s = row as NSString, range = NSRange(location: 0, length: (row as NSString).length)
      let stamps = lineStamp.matches(in: row, range: range)
      guard let first = stamps.first, let last = stamps.last else { continue }
      let body = s.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
      let b = body as NSString
      let tags = wordStamp.matches(in: body, range: NSRange(location: 0, length: b.length))
      var runs: [(Double?, String)] = []
      if let tag = tags.first, tag.range.location > 0 { runs.append((nil, b.substring(to: tag.range.location))) }
      for (i, tag) in tags.enumerated() {
        let start = NSMaxRange(tag.range), end = i + 1 < tags.count ? tags[i + 1].range.location : b.length
        runs.append((millis(tag, b), b.substring(with: NSRange(location: start, length: end - start))))
      }
      let text = tags.isEmpty ? body : runs.map { $0.1 }.joined()
      let times = runs.compactMap { $0.0 }
      let ordered = zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
      for stamp in stamps {
        let start = millis(stamp, s), shift = start - millis(first, s) - offset
        let parts = ordered ? runs.map { Part(time: $0.0.map { ($0 + shift) / 1000 }, text: $0.1) } : []
        lines.append(Line(time: max(0, (start - offset) / 1000), text: text, parts: parts))
      }
    }
    return lines.sorted { $0.time < $1.time }
  }
}

private struct Jacket: View {
  let art: URL?, title: String
  @State private var loaded: UIImage?
  var body: some View {
    GeometryReader { g in
      if let loaded {
        Image(uiImage: loaded).resizable().scaledToFill().frame(
          width: g.size.width, height: g.size.height
        ).clipped()
      } else {
        let hue = CoverFlowArtwork.fallbackHue(title)
        ZStack {
          Color(hue: hue, saturation: 0.43, brightness: 0.74)
          Canvas { context, size in
            let edge = size.width
            let c = CGPoint(x: edge * 0.84, y: edge * 0.32)
            for i in 0..<13 {
              let radius = edge * (0.12 + Double(i) * 0.037)
              context.stroke(
                Path(
                  ellipseIn: CGRect(
                    x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.black.opacity(i == 0 ? 0.8 : 0.40)),
                lineWidth: edge * (i == 0 ? 0.11 : 0.014))
            }
          }
          VStack(alignment: .leading) {
            Spacer()
            Text(verbatim: title).font(
              .system(size: g.size.width * 0.14, weight: .heavy, design: .serif)
            ).tracking(-1).lineLimit(2).minimumScaleFactor(0.75).foregroundStyle(.white).shadow(
              color: .black.opacity(0.4), radius: 1, y: 1)
          }.padding(g.size.width * 0.07).frame(maxWidth: .infinity, alignment: .leading)
        }.clipped()
      }
    }.clipped().task(id: art) {
      loaded = nil
      guard let art, let sample = await CoverFlowArtwork.shared.sample(art), !Task.isCancelled else { return }
      loaded = sample.image
    }
  }
}

private struct ClickWheel: View {
  let size: CGFloat, songMode: Bool
  let menu: () -> Void, center: () -> Void, step: (Int) -> Void, play: () -> Void
  @State private var angle: Double?
  @State private var accumulated = 0.0
  @State private var lastWheelDrag = -Double.infinity
  var body: some View {
    let p = size * 0.365
    ZStack {
      Circle().fill(
        LinearGradient(
          colors: [Color(white: 1), Color(white: 0.94)], startPoint: .topLeading,
          endPoint: .bottomTrailing)
      )
      .overlay(Circle().stroke(Color(white: 0.64), lineWidth: 1)).shadow(
        color: .white, radius: 0.8, y: 1)
      key("MENU", "菜单", "library.menu", 0, -p, menu)
      key("backward.end.fill", "上一首", "library.previous", -p, 0) { step(-1) }
      key("forward.end.fill", "下一首", "library.next", p, 0) { step(1) }
      key("playpause.fill", "播放或暂停", "library.playPause", 0, p, play)
      Button {
        press(center)
      } label: {
        Circle().fill(
          LinearGradient(
            colors: [Color(white: 0.87), Color(white: 0.77), Color(white: 0.9)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(Circle().stroke(Color.black.opacity(0.16))).frame(
          width: max(44, size * 0.39), height: max(44, size * 0.39))
      }.buttonStyle(.plain).accessibilityLabel(songMode ? "播放或暂停" : "打开专辑").accessibilityIdentifier(
        songMode ? "library.center" : "library.openAlbum")
    }.frame(width: size, height: size).contentShape(Circle()).simultaneousGesture(
      DragGesture(minimumDistance: 9, coordinateSpace: .local).onChanged { value in
        lastWheelDrag = ProcessInfo.processInfo.systemUptime
        let x = value.location.x - size / 2
        let y = value.location.y - size / 2
        guard hypot(x, y) > size * 0.205 else {
          angle = nil
          accumulated = 0
          return
        }
        let now = atan2(y, x)
        let start = atan2(value.startLocation.y - size / 2, value.startLocation.x - size / 2)
        var delta = now - (angle ?? start)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        angle = now
        accumulated += delta
        while abs(accumulated) >= 0.72 {
          let d = accumulated > 0 ? 1 : -1
          step(d)
          accumulated -= Double(d) * 0.72
        }
      }.onEnded { _ in
        lastWheelDrag = ProcessInfo.processInfo.systemUptime
        angle = nil
        accumulated = 0
      }
    )
  }
  private func press(_ action: () -> Void) {
    // A ring gesture can end over a physical button. Do not also fire its tap.
    if ProcessInfo.processInfo.systemUptime - lastWheelDrag > 0.18 { action() }
  }
  private func key(
    _ symbol: String, _ label: LocalizedStringKey, _ id: String, _ x: CGFloat, _ y: CGFloat,
    _ action: @escaping () -> Void
  ) -> some View {
    Button {
      press(action)
    } label: {
      Group {
        if symbol == "MENU" {
          Text(verbatim: symbol).font(.system(size: 13, weight: .bold)).tracking(0.6)
        } else {
          Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
        }
      }.foregroundStyle(Color(white: 0.36)).frame(minWidth: 44, minHeight: 44).contentShape(
        Rectangle())
    }.buttonStyle(.plain).offset(x: x, y: y).accessibilityLabel(label).accessibilityIdentifier(id)
  }
}

private struct AlbumDetail: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var library: Library
  let album: ShelfAlbum
  let play: ([Song], Int) -> Void
  @State private var removing: Song?
  @EnvironmentObject private var downloads: DownloadCenter
  @State private var catalog: [Song] = []
  @State private var selectedMissing: String?
  @State private var artwork: ArtworkSelection?
  private var key: AlbumCatalogKey? {
    guard let key = AlbumCatalogKey(album.tracks.first?.album, album.artist),
      album.tracks.allSatisfy(key.contains)
    else { return nil }
    return key
  }
  var body: some View {
    let local =
      key.map { key in
        library.localSongs.filter(key.contains).sorted {
          let a = library.trackOrder($0)
          let b = library.trackOrder($1)
          return a != b ? a < b : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
      } ?? library.localTracks(album.tracks.map(\.id))
    let rows = AlbumCatalogRow.merge(local: local, catalog: catalog)
    let tracks = rows.filter(\.owned).map(\.song)
    ScrollView {
      VStack(spacing: 9) {
        Jacket(art: tracks.lazy.compactMap { library.albumArtwork(for: $0) }.first, title: album.title).aspectRatio(
          1, contentMode: .fit
        ).clipShape(
          RoundedRectangle(cornerRadius: 9)
        ).shadow(color: .black.opacity(0.16), radius: 15, y: 9).frame(maxWidth: 268).padding(
          .bottom, 12)
        Text(verbatim: album.title).font(.title2.bold()).multilineTextAlignment(.center)
          .accessibilityIdentifier("library.albumDetail")
        Text(verbatim: album.artist).font(.title3).foregroundStyle(.pink)
        HStack(spacing: 12) {
          Button {
            play(tracks, 0)
          } label: {
            Label("播放", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 32)
          }
          Button {
            play(tracks.shuffled(), 0)
          } label: {
            Label("随机播放", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 32)
          }
        }.disabled(tracks.isEmpty).buttonStyle(.bordered).tint(.pink).padding(.vertical, 12)
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
          let song = row.song
          Divider()
          if row.owned {
            Button {
              if let index = tracks.firstIndex(where: { $0.id == song.id }) { play(tracks, index) }
            } label: {
              HStack(spacing: 12) {
                Text(
                  "\(library.trackOrder(song).1 == Int.max ? (row.number ?? i+1) : library.trackOrder(song).1)"
                )
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(
                  minWidth: 20)
                VStack(alignment: .leading, spacing: 3) {
                  Text(verbatim: song.title).font(.body)
                  if let q = song.quality {
                    Label(q, systemImage: "waveform").font(.caption2).foregroundStyle(.secondary)
                  }
                }
                Spacer()
                if let t = song.duration, t.isFinite, t >= 0 {
                  Text(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)).font(
                    .caption.monospacedDigit()
                  ).foregroundStyle(.secondary)
                }
              }.padding(.vertical, 5).frame(minHeight: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).contextMenu {
              Button(library.isFavorite(song) ? "Remove from favorites" : "Add to favorites") {
                library.favorite(song)
              }
              Button("Delete cached track", role: .destructive) { removing = song }
              Button("Replace song artwork") { artwork = ArtworkSelection(song, album: false) }
              ForEach(library.playlists) { list in
                Button(list.name) { library.add(song, to: list.id) }
              }
            }
          } else {
            missingRow(song, number: row.number ?? i + 1)
          }
        }
      }.padding(.horizontal, 20).padding(.bottom, 28).frame(maxWidth: 640).frame(
        maxWidth: .infinity)
    }.modifier(CacheRemoval(song: $removing)).toolbar {
      if let seed = tracks.first {
        ToolbarItem(placement: .navigationBarLeading) {
          Menu {
            Button("Replace album artwork") { artwork = ArtworkSelection(seed, album: true) }
          } label: {
            Label("Album actions", systemImage: "ellipsis.circle")
          }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
        }.accessibilityLabel("关闭")
      }
    }.sheet(item: $artwork) { ArtworkPickerSheet(seed: $0.song, albumMode: $0.album) }
      .task(id: key) {
        catalog = []
        guard let key else { return }
        let result = await AlbumCatalog.shared.tracks(for: key)
        if !Task.isCancelled { catalog = result }
      }
  }

  private func missingRow(_ song: Song, number: Int) -> some View {
    let key = DownloadCenter.Key(song)
    let pending = downloads.pending.contains(key)
    return HStack(spacing: 0) {
      Button {
        selectedMissing = song.id
      } label: {
        HStack(spacing: 12) {
          Text("\(number)").font(.subheadline.monospacedDigit()).frame(minWidth: 20)
          VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: song.title)
            if let reason = downloads.failures[key] { Text(verbatim: reason).font(.caption2) }
          }
          Spacer()
        }.frame(minHeight: 44).contentShape(Rectangle())
      }.accessibilityAddTraits(selectedMissing == song.id ? .isSelected : [])
      Button {
        selectedMissing = song.id
        downloads.enqueue([song])
      } label: {
        Group {
          if pending {
            ProgressView()
          } else {
            Image(systemName: "arrow.down.circle").font(.title3)
          }
        }.frame(width: 44, height: 44)
      }.disabled(pending).accessibilityLabel("Download \(song.title)")
    }.buttonStyle(.plain).foregroundStyle(.secondary)
      .background(
        selectedMissing == song.id ? Color.secondary.opacity(0.1) : .clear,
        in: RoundedRectangle(cornerRadius: 6))
  }
}

private struct ArtworkSelection: Identifiable {
  let id = UUID(), song: Song, album: Bool
  init(_ song: Song, album: Bool) {
    self.song = song
    self.album = album
  }
}

private struct CacheRemoval: ViewModifier {
  @EnvironmentObject private var library: Library
  @Binding var song: Song?
  func body(content: Content) -> some View {
    content.alert(
      "Delete cached track?",
      isPresented: Binding(get: { song != nil }, set: { if !$0 { song = nil } }), presenting: song
    ) { track in
      Button("Delete", role: .destructive) { library.removeCachedTrack(track) }
      Button("Cancel", role: .cancel) {}
    } message: { track in
      Text(verbatim: track.title)
    }
  }
}

private struct CollectionsView: View {
  @EnvironmentObject var library: Library
  @Environment(\.dismiss) var dismiss
  @Binding var selection: ShelfCollection
  let play: ([Song], Int) -> Void
  @State private var namingPlaylist = false
  @State private var name = ""
  @State private var removing: Song?
  var body: some View {
    List {
      row(.favorites, icon: "heart")
      row(.all, icon: "music.note.list")
      Section("Playlists") {
        ForEach(library.playlists) { item in
          row(.playlist(item.id), icon: "music.note.list").swipeActions {
            Button("Delete", role: .destructive) {
              if selection == .playlist(item.id) { selection = .all }
              library.deletePlaylist(item.id)
            }
          }
        }
        Button {
          name = ""
          namingPlaylist = true
        } label: {
          Label("New playlist", systemImage: "plus")
        }
      }
      Section(selection.title(in: library)) {
        LibraryTracks(
          queue: selection.tracks(in: library), playlist: playlistID, play: play,
          removing: $removing)
      }
    }.navigationTitle("Library").toolbar {
      ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
    }.modifier(CacheRemoval(song: $removing))
      .alert("New playlist", isPresented: $namingPlaylist) {
        TextField("Playlist name", text: $name)
        Button("Create") { library.createPlaylist(name) }
        Button("Cancel", role: .cancel) {}
      }
  }
  private var playlistID: UUID? {
    if case .playlist(let id) = selection { return id }
    return nil
  }
  private func row(_ item: ShelfCollection, icon: String) -> some View {
    Button {
      selection = item
    } label: {
      HStack {
        Label(item.title(in: library), systemImage: icon)
        Spacer()
        if selection == item { Image(systemName: "checkmark").accessibilityHidden(true) }
      }
    }.accessibilityAddTraits(selection == item ? .isSelected : [])
  }
}

private struct LibraryTracks: View {
  @EnvironmentObject var library: Library
  @State private var artwork: Song?
  let queue: [Song]
  let playlist: UUID?
  let play: ([Song], Int) -> Void
  @Binding var removing: Song?

  var body: some View {
    if queue.isEmpty { Text("No songs yet").foregroundStyle(.secondary) }
    ForEach(Array(queue.enumerated()), id: \.element.id) { index, song in
      HStack {
        Button {
          play(queue, index)
        } label: {
          VStack(alignment: .leading) {
            Text(song.title).lineLimit(1)
            Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Menu {
          Button(library.isFavorite(song) ? "Remove from favorites" : "Add to favorites") {
            library.favorite(song)
          }
          if !library.playlists.isEmpty {
            Menu("Add to playlist") {
              ForEach(library.playlists) { item in
                Button(item.name) { library.add(song, to: item.id) }.disabled(
                  item.songIDs.contains(song.id))
              }
            }
          }
          Button("Delete cached track", role: .destructive) { removing = song }
          Button("Replace song artwork") { artwork = song }
          if let playlist {
            Button("Remove from playlist", role: .destructive) {
              library.remove(song, from: playlist)
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle").padding(6)
        }
        .accessibilityLabel("Actions for \(song.title)")
      }
    }.sheet(item: $artwork) { ArtworkPickerSheet(seed: $0, albumMode: false) }
  }
}
