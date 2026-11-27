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
        id: key, title: s.album ?? "未知专辑", artist: s.albumArtist ?? s.artist,
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
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @State private var wideViewport = false
  private var immersive: Bool {
    UIDevice.current.userInterfaceIdiom == .phone && (verticalSizeClass == .compact || wideViewport)
  }
  @State private var albums: [ShelfAlbum] = []
  @State private var selected = 0
  private enum Page: Hashable { case albums, tracks(ShelfCollection), playing }
  @State private var pages: [Page] = [.albums]
  private var page: Page { pages.last ?? .albums }
  private var collection: ShelfCollection {
    for entry in pages.reversed() {
      switch entry {
      case .tracks(let scope): return scope
      case .albums: return .all
      case .playing: continue
      }
    }
    return .all
  }
  @State private var sheetSelection = ShelfCollection.all
  @State private var detail: ShelfAlbum?
  @State private var drawerOpen = false
  @State private var librarySheet = false
  @State private var menuFocus = Page.albums
  @State private var songs: [Song] = []
  @State private var songIndex = 0
  private var menuPages: [Page] {
    [.tracks(.favorites), .albums, .tracks(.all)] + library.playlists.map { .tracks(.playlist($0.id)) } + [.playing]
  }
  private var browsingSongs: Bool { if case .tracks = page { return true }; return false }
  private var hasQueue: Bool { !playback.queue.isEmpty && playback.current != nil }
  private var inQueue: Bool {
    page == .playing && hasQueue
  }
  private var album: ShelfAlbum? { albums.indices.contains(selected) ? albums[selected] : nil }
  private var count: Int { browsingSongs ? songs.count : (page == .playing ? playback.queue.count : albums.count) }
  private var focus: Int { browsingSongs ? songIndex : (inQueue ? playback.index : selected) }
  private var focusedSong: Song? { browsingSongs && songs.indices.contains(songIndex) ? songs[songIndex] : (inQueue ? playback.current : nil) }
  private var focusedTitle: String { focusedSong?.title ?? (page == .albums ? album?.title : nil) ?? "" }
  private var focusedArt: URL? { focusedSong?.artwork ?? (page == .albums ? album?.art : nil) }
  private func step(_ n: Int) {
    if drawerOpen {
      let rows = menuPages.filter { $0 != .playing || hasQueue }
      guard let index = rows.firstIndex(of: menuFocus) else { return }
      let next = rows[min(rows.count - 1, max(0, index + n))]
      if next != menuFocus { menuFocus = next; UISelectionFeedbackGenerator().selectionChanged() }
      return
    }
    guard count > 0 else { return }
    let next = min(count - 1, max(0, focus + n))
    guard next != focus else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    if browsingSongs { songIndex = next } else if inQueue { playback.select(next) } else { selected = next }
  }
  private func center() {
    if drawerOpen { navigate(menuFocus); return }
    if browsingSongs { playPause(); return }
    if inQueue {
      playback.toggle()
    } else if let album {
      detail = album
    }
  }
  private func setDrawer(_ open: Bool) {
    if open { menuFocus = page }
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.30)) { drawerOpen = open }
  }
  private func menu() { setDrawer(!drawerOpen) }
  private func navigate(_ destination: Page) {
    if page != destination { pages.append(destination) }
    setDrawer(false)
  }
  private func refreshSongs(preserveFocus: Bool) {
    let previous = preserveFocus ? focusedSong?.id : nil
    if case .tracks(let scope) = page { songs = scope.tracks(in: library) } else { songs = [] }
    songIndex = previous.flatMap { id in songs.firstIndex { $0.id == id } } ?? 0
  }
  private func shuffle() {
    let songs = collection.tracks(in: library).shuffled()
    guard !songs.isEmpty else { return }
    playback.play(songs, index: 0)
    navigate(.playing)
  }
  private func playPause() {
    if drawerOpen { return }
    if browsingSongs {
      guard songs.indices.contains(songIndex) else { return }
      playback.play(songs, index: songIndex)
      navigate(.playing)
      return
    }
    if inQueue {
      playback.toggle()
    } else if let album {
      playback.play(album.tracks, index: 0)
      navigate(.playing)
    }
  }
  var body: some View {
    GeometryReader { g in
      Group {
        if immersive {
          landscapeDisplay
        } else {
          let width = max(1, min(g.size.width - 12, 560))
          let height = max(1, min(g.size.height * 0.65, width * 1.20))
          let dial = max(1, min(width * 0.61, g.size.height - height - 22, 270))
          VStack(spacing: 0) {
            display(width: width, height: height).padding(.top, 4)
            Spacer(minLength: 8)
            ClickWheel(size: dial, centerLabel: drawerOpen ? "确认选择" : browsingSongs ? "播放歌曲" : inQueue ? "播放或暂停" : "打开专辑",
                       centerID: drawerOpen ? "library.confirm" : browsingSongs ? "library.playSong" : inQueue ? "library.center" : "library.openAlbum",
                       menu: menu, center: center, step: step, play: playPause)
          }
          .padding(.bottom, max(8, (g.size.height - height - dial) * 0.30))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.82), Color(white: 0.93)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }

      }
      .onGeometryChange(for: Bool.self) { proxy in
        proxy.size.width > proxy.size.height * 1.35
      } action: { wideViewport = $0 }
    }
    .ignoresSafeArea(.container, edges: immersive ? .all : [])
    .statusBarHidden(immersive)
    .persistentSystemOverlays(immersive ? .hidden : .automatic)
    .toolbar(immersive ? .hidden : .automatic, for: .tabBar, .navigationBar)
    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button { setDrawer(false); librarySheet = true } label: { Image(systemName: "line.3.horizontal") }
          .accessibilityLabel("资料库菜单").accessibilityIdentifier("library.toolbarMenu")
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: shuffle) { Label("随机播放", systemImage: "shuffle") }.disabled(browsingSongs ? songs.isEmpty : collection.tracks(in: library).isEmpty)
          .accessibilityIdentifier("library.shuffle")
      }
    }
    .onChange(of: page) { _ in refreshSongs(preserveFocus: false) }
    .onChange(of: library.shelfRevision) { _ in refreshShelf(); refreshSongs(preserveFocus: true) }
    .onChange(of: library.playlists.map(\.id)) { ids in
      pages.removeAll { page in
        if case .tracks(.playlist(let id)) = page { return !ids.contains(id) }
        return false
      }
      if case .playlist(let id) = sheetSelection, !ids.contains(id) { sheetSelection = .all }
      if !menuPages.contains(menuFocus) { menuFocus = page }
    }
    .onAppear { refreshShelf() }
    .task { await library.indexLocalFiles() }
    .onChange(of: scenePhase) { if $0 == .active { Task { await library.indexLocalFiles() } } }
    .sheet(item: $detail) { album in
      NavigationStack {
        AlbumDetail(album: album) { tracks, index in
          playback.play(tracks, index: index)
          navigate(.playing)
          detail = nil
        }
      }.presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $librarySheet) {
      NavigationStack {
        CollectionsView(selection: $sheetSelection) { tracks, i in
          playback.play(tracks, index: i)
          navigate(.playing)
          librarySheet = false
        }
      }.presentationDragIndicator(.visible)
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
  private var collectionOverlay: some View {
    ZStack(alignment: .leading) {
      if drawerOpen {
        Color.black.opacity(0.22).onTapGesture { setDrawer(false) }
          .accessibilityHidden(true).transition(.opacity)
        drawerPanel.transition(reduceMotion ? .identity : .move(edge: .leading))
      }
    }.allowsHitTesting(drawerOpen)
  }
  private var drawerPanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("资料库").font(.headline)
        Spacer()
        Button { setDrawer(false) } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
          .accessibilityLabel("关闭菜单")
      }.padding(.bottom, 12)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            ForEach(menuPages, id: \.self) { row in menuRow(row).id(row) }
          }
        }.onAppear { proxy.scrollTo(menuFocus) }.onChange(of: menuFocus) { proxy.scrollTo($0) }
      }
    }
    .padding(12).frame(maxWidth: 252, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.45), lineWidth: 1))
    .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
    .foregroundStyle(.primary).padding(8)
    .zIndex(1)

  }

  private func menuRow(_ row: Page) -> some View {
    let label: (String, String)
    switch row {
    case .albums: label = ("专辑列表", "square.stack")
    case .playing: label = ("正在播放", "play.circle")
    case .tracks(.favorites): label = ("我喜欢的", "heart")
    case .tracks(.all): label = ("全部歌曲", "music.note.list")
    case .tracks(let scope): label = (scope.title(in: library), "music.note.list")
    }
    return Button { navigate(row) } label: {
      HStack { Label(label.0, systemImage: label.1); Spacer() }
        .padding(12).contentShape(Rectangle())
        .background(menuFocus == row ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).accessibilityAddTraits(menuFocus == row ? .isSelected : [])
      .disabled(row == .playing && !hasQueue)
  }

  private func refreshShelf() {
    let oldID = album?.id
    albums = ShelfAlbum.collect(library, songs: library.localSongs)
    selected = albums.firstIndex { $0.id == oldID } ?? min(selected, max(0, albums.count - 1))
  }
  private var landscapeDisplay: some View {
    VStack(spacing: 0) {
      if count > 0 {
        shelf(activate: playPause)
        caption
      } else {
        Spacer()
        Text("No songs yet").font(.headline)
        Spacer()
      }
      Button(action: playPause) {
        Image(systemName: inQueue && playback.isPlaying ? "pause.fill" : "play.fill")
          .font(.title2).frame(width: 56, height: 48)
      }
      .buttonStyle(.plain).disabled(count == 0)
      .accessibilityLabel("播放或暂停").accessibilityIdentifier("library.landscape.playPause")
      .padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(.white)
    .background(CoverFlowBackdrop(art: focusedArt, title: focusedTitle))
  }

  private func shelf(activate: @escaping () -> Void) -> some View {
    let tracks = browsingSongs ? songs : playback.queue
    let songShelf = page != .albums
    return CoverFlowShelf(count: count, focus: focus, reduceMotion: reduceMotion, step: step, activate: activate) { [albums] i in
      songShelf ? SleeveItem(art: tracks[i].artwork, title: tracks[i].title) : SleeveItem(art: albums[i].art, title: albums[i].title)
    }
      .accessibilityElement(children: .ignore).accessibilityLabel("Cover Flow")
      .accessibilityValue(focusedTitle)
      .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }.accessibilityAction {
        activate()
      }.accessibilityIdentifier("library.coverflow")
  }

  private var caption: some View {
    ShelfCaption(raw: inQueue ? playback.current?.lyrics : nil, elapsed: playback.elapsed) {
      VStack(spacing: 2) {
        Text(verbatim: focusedTitle).font(
          .headline
        ).accessibilityIdentifier(inQueue ? "library.currentTitle" : browsingSongs ? "library.songTitle" : "library.albumTitle")
        Text(verbatim: focusedSong?.artist ?? album?.artist ?? "").font(
          .subheadline
        ).foregroundStyle(Color(white: 0.76))
        if let badge = focusedSong?.quality {
          Text(verbatim: L10n.quality(badge)).font(.caption2.monospaced()).foregroundStyle(Color(white: 0.76))
        }
      }.lineLimit(1).padding(.horizontal, 8).padding(.bottom, 12).foregroundStyle(.white)
    }
  }

  private func display(width: CGFloat, height: CGFloat) -> some View {

    return VStack(spacing: 0) {
      HStack {
        if pages.count > 1 {
          Button {
            pages.removeLast()
          } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
            .accessibilityLabel("返回").accessibilityIdentifier("library.back")
        }
        if case .tracks(let scope) = page {
          Text(scope.title(in: library)).bold().accessibilityIdentifier("library.trackScope")
          Spacer()
        } else {
          Text(inQueue ? String(localized: "Now Playing") : "专辑列表").fontWeight(
            .bold)
          Spacer()
          if inQueue { Image(systemName: playback.isPlaying ? "play.fill" : "pause.fill") }
        }
        Text(count == 0 ? "—" : "\(focus + 1) / \(count)").monospacedDigit()
      }
      .font(.caption).foregroundStyle(.primary).padding(.horizontal, 12).frame(height: pages.count > 1 ? 36 : 27)
      .background(.regularMaterial)
      .overlay(alignment: .bottom) { Divider() }
      if count > 0 {
        shelf(activate: center)
        caption.frame(minHeight: min(108, height * 0.26)).layoutPriority(1)
      } else {
        Spacer()
        Image(systemName: "music.note.list").font(.largeTitle)
        Text(browsingSongs ? "暂无歌曲" : "No songs yet").font(.headline).padding(.top, 5)
        Text("可在设置中导入歌曲").font(.subheadline).padding(8)
        Spacer()
      }
    }.foregroundStyle(.white).frame(width: max(1, width - 12), height: max(1, height - 12)).background(
      CoverFlowBackdrop(art: focusedArt, title: focusedTitle)
    ).accessibilityHidden(drawerOpen).overlay(alignment: .leading) { collectionOverlay }
      .clipShape(RoundedRectangle(cornerRadius: 5)).padding(6)
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
    if let index = ShelfLyrics.index(at: elapsed, in: lines) {
      let line = lines[index]
      ZStack {
        VStack(spacing: 2) {
          neighbor(index > 0 ? lines[index - 1].text : "", id: "library.lyric.previous")
          Text(attributed(line)).font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
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
      Text(verbatim: " ").font(.subheadline).hidden().accessibilityHidden(true)
    } else {
      Text(verbatim: text).font(.subheadline).lineLimit(1)
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
    // A blank cue leaves the shelf caption in place. Keep all cues in the shared full-player parser.
    let parsed = parse(raw).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
  let size: CGFloat, centerLabel: LocalizedStringKey, centerID: String
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
      }.buttonStyle(.plain).accessibilityLabel(centerLabel).accessibilityIdentifier(centerID)
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
          Text(label).font(.system(size: 13, weight: .bold)).tracking(0.6)
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
                    Label(L10n.quality(q), systemImage: "waveform").font(.caption2).foregroundStyle(.secondary)
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
              Button(library.isFavorite(song) ? "取消收藏" : "添加到收藏") {
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
          NavigationLink {
            SheetPlaylistDetail(playlistID: item.id, play: play)
          } label: {
            HStack {
              PlaylistCover(tracks: library.localTracks(item.songIDs))
                .frame(width: 44, height: 44).accessibilityHidden(true)
              Text(verbatim: item.name)
            }
          }.swipeActions {
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
          queue: selection.tracks(in: library), playlist: playlistID, play: play, sheetStyle: true,
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

private struct SheetPlaylistDetail: View {
  @EnvironmentObject var library: Library
  let playlistID: UUID
  let play: ([Song], Int) -> Void
  @State private var adding = false
  @State private var removing: Song?

  var body: some View {
    let selection = ShelfCollection.playlist(playlistID)
    let tracks = selection.tracks(in: library)
    List {
      VStack(spacing: 12) {
        PlaylistCover(tracks: tracks).frame(width: 168, height: 168)
        Text(verbatim: selection.title(in: library)).font(.title2.bold())
        Text("\(tracks.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity).padding(.vertical).listRowSeparator(.hidden)
      LibraryTracks(queue: tracks, playlist: playlistID, play: play, sheetStyle: true, removing: $removing)
    }.listStyle(.plain).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button { adding = true } label: { Label("添加歌曲", systemImage: "plus") }
            .accessibilityIdentifier("playlist.addSongs")
        }
      }.sheet(isPresented: $adding) { PlaylistSongPicker(playlistID: playlistID) }
      .modifier(CacheRemoval(song: $removing))
  }
}

private struct CollectionTracksView: View {
  @EnvironmentObject var library: Library
  let selection: ShelfCollection
  let play: ([Song], Int) -> Void
  @State private var removing: Song?
  var body: some View {
    List {
      let tracks = selection.tracks(in: library)

      LibraryTracks(
          queue: tracks, playlist: playlistID, play: play,
          removing: $removing)
    }.listStyle(.plain).modifier(CacheRemoval(song: $removing))

  }
  private var playlistID: UUID? {
    if case .playlist(let id) = selection { return id }
    return nil
  }

}

private struct LibraryTracks: View {
  @EnvironmentObject var library: Library
  @State private var artwork: Song?
  let queue: [Song]
  let playlist: UUID?
  let play: ([Song], Int) -> Void
  var sheetStyle = false
  @Binding var removing: Song?

  var body: some View {
    if queue.isEmpty { Text("暂无歌曲").foregroundStyle(.secondary) }
    ForEach(Array(queue.enumerated()), id: \.element.id) { index, song in
      HStack {
        Button {
          play(queue, index)
        } label: {
          HStack {
            if sheetStyle {
              Jacket(art: song.artwork, title: song.title).frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
            }
            VStack(alignment: .leading) {
              Text(song.title).lineLimit(1)
              Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              if let quality = song.quality {
                Group {
                  if sheetStyle { Text(verbatim: L10n.quality(quality)) }
                  else { Label(L10n.quality(quality), systemImage: "waveform") }
                }.font(.caption2).foregroundStyle(.secondary)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("library.track." + song.id)
        Menu {
          Button(library.isFavorite(song) ? "取消收藏" : "添加到收藏") {
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
