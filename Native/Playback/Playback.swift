import AVFoundation
import MediaPlayer
import SwiftUI

enum PlaybackMode: String, CaseIterable {
  case queue, one, shuffle, sequential
  var icon: String {
    switch self {
    case .queue: return "repeat"
    case .one: return "repeat.1"
    case .shuffle: return "shuffle"
    case .sequential: return "arrow.right"
    }
  }
  var title: String {
    switch self {
    case .queue: return "列表循环"
    case .one: return "单曲循环"
    case .shuffle: return "随机播放"
    case .sequential: return "顺序播放"
    }
  }
}

@MainActor final class Playback: ObservableObject {
  @Published var current: Song?
  @Published var isPlaying = false
  @Published private(set) var queue: [Song] = []
  @Published private(set) var index = 0
  @Published private(set) var elapsed = 0.0
  @Published private(set) var duration = 0.0
  @Published private(set) var loading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var cacheMessage: String?
  @Published private(set) var caching = false
  @Published private(set) var offline = false
  @Published private(set) var sleepUntil: Date?
  @Published private(set) var sleepAfterTrack = false
  @Published var mode =
    PlaybackMode(rawValue: UserDefaults.standard.string(forKey: "playback.mode") ?? "") ?? .queue
  { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "playback.mode") } }
  @Published var autoCache =
    (UserDefaults.standard.object(forKey: "playback.autoCache") as? Bool) ?? true
  {
    didSet {
      UserDefaults.standard.set(autoCache, forKey: "playback.autoCache")
      if autoCache { cacheCurrent() }
    }
  }
  @Published var preciseSeeking = UserDefaults.standard.bool(forKey: "playback.preciseSeeking") {
    didSet { UserDefaults.standard.set(preciseSeeking, forKey: "playback.preciseSeeking") }
  }
  var resolve: ((Song) async throws -> URL)?
  var cached: ((Song, URL) -> Void)?
  private let player = AVPlayer()
  private var generation = UUID(), wantsAudio = false, interrupted = false, finished = false
  private var source: URL?, artwork: MPMediaItemArtwork?
  private var loadTask: Task<Void, Never>?, artworkTask: Task<Void, Never>?,
    sleepTask: Task<Void, Never>?
  private var transfers: [URL: Task<Void, Never>] = [:]
  private var status: NSKeyValueObservation?, control: NSKeyValueObservation?
  private final class Observers {
    var clock: Any?, player: AVPlayer?
    var notices: [NSObjectProtocol] = [], commands: [(MPRemoteCommand, Any)] = []
    deinit {
      if let clock { player?.removeTimeObserver(clock) }
      notices.forEach { NotificationCenter.default.removeObserver($0) }
      commands.forEach { $0.0.removeTarget($0.1) }
    }
  }
  private let observers = Observers()
  init() {
    observers.player = player
    observers.clock = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.tick() } }
    control = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.refresh() }
    }
    let nc = NotificationCenter.default
    for name in [
      Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime,
    ] {
      observers.notices.append(
        nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          let item = note.object as? AVPlayerItem
          Task { @MainActor in
            guard let self, let item, self.player.currentItem === item else { return }
            if name == .AVPlayerItemDidPlayToEndTime { self.ended() } else { self.fail(item.error) }
          }
        })
    }
    observers.notices.append(
      nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
        [weak self] n in
        let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let options = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor in
          guard let self else { return }
          if type == AVAudioSession.InterruptionType.began.rawValue {
            let resume = self.wantsAudio
            self.pause()
            self.interrupted = resume
          } else if self.interrupted {
            self.interrupted = false
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
              self.resume()
            }
          }
        }
      })
    observers.notices.append(
      nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
        [weak self] n in
        if n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        {
          Task { @MainActor in self?.pause() }
        }
      })
    let center = MPRemoteCommandCenter.shared()
    func bind(_ cmd: MPRemoteCommand, _ action: @escaping @MainActor (Playback) -> Void) {
      cmd.isEnabled = true
      observers.commands.append(
        (
          cmd,
          cmd.addTarget { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
            return .success
          }
        ))
    }
    bind(center.playCommand) { $0.resume() }
    bind(center.pauseCommand) { $0.pause() }
    bind(center.togglePlayPauseCommand) { $0.toggle() }
    bind(center.nextTrackCommand) { $0.next() }
    bind(center.previousTrackCommand) { $0.previous() }
    let seek = center.changePlaybackPositionCommand
    observers.commands.append(
      (
        seek,
        seek.addTarget { [weak self] event in
          guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
            return .commandFailed
          }
          Task { @MainActor in self?.seek(position) }
          return .success
        }
      ))
  }
  deinit {
    loadTask?.cancel()
    artworkTask?.cancel()
    sleepTask?.cancel()
    transfers.values.forEach { $0.cancel() }
  }
  func play(_ songs: [Song], index: Int) {
    guard songs.indices.contains(index) else { return }
    queue = songs
    select(index)
  }
  func select(_ i: Int) {
    guard queue.indices.contains(i) else { return }
    let song = queue[i]
    let token = UUID()
    generation = token
    loadTask?.cancel()
    artworkTask?.cancel()
    status = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    index = i
    current = song
    elapsed = 0
    duration = 0
    source = nil
    artwork = nil
    errorMessage = nil
    cacheMessage = nil
    finished = false
    interrupted = false
    wantsAudio = true
    loading = true
    isPlaying = false
    let local = PlaybackFiles.existing(song)
    offline = local != nil || song.url?.isFileURL == true
    caching = transfers[PlaybackFiles.folder(song)] != nil
    nowPlaying()
    fetchArt(song.artwork, token)
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let url: URL
        if let local {
          url = local
        } else if let supplied = song.url, supplied.isFileURL || self.resolve == nil {
          url = supplied
        } else if let resolve = self.resolve {
          url = try await resolve(song)
        } else {
          throw URLError(.resourceUnavailable)
        }
        guard self.generation == token else { return }
        self.source = url
        self.offline = url.isFileURL
        let asset = AVURLAsset(
          url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: self.preciseSeeking])
        let item = AVPlayerItem(asset: asset)
        self.player.replaceCurrentItem(with: item)
        self.status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
          Task { @MainActor in
            guard let self, self.generation == token else { return }
            if item.status == .failed {
              self.fail(item.error)
            } else {
              self.tick()
              self.refresh()
              self.nowPlaying()
            }
          }
        }
        if self.wantsAudio { self.startAudio() }
        if self.autoCache { self.cacheCurrent() }
      } catch { if self.generation == token { self.fail(error) } }
    }
  }
  private func startAudio() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
      player.play()
      refresh()
    } catch { fail(error) }
  }
  private func fail(_ error: Error?) {
    pause()
    errorMessage = error?.localizedDescription ?? "音频无法播放，请检查音源后重试。"
  }
  private func refresh() {
    let playing = wantsAudio && player.timeControlStatus == .playing
    if isPlaying != playing {
      isPlaying = playing
      nowPlaying()
    }
    loading =
      wantsAudio && !playing && errorMessage == nil
      && (player.currentItem?.status != .readyToPlay
        || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
  }
  private func tick() {
    guard let item = player.currentItem else { return }
    let d = item.duration.seconds
    let t = player.currentTime().seconds
    if d.isFinite, d > 0, duration != d {
      duration = d
      nowPlaying()
    }
    if t.isFinite { elapsed = max(0, t) }
  }
  func toggle() { wantsAudio ? pause() : resume() }
  func pause() {
    interrupted = false
    wantsAudio = false
    player.pause()
    isPlaying = false
    loading = false
    nowPlaying()
  }
  func resume() {
    guard current != nil else { return }
    if errorMessage != nil || finished {
      select(index)
      return
    }
    wantsAudio = true
    if player.currentItem != nil { startAudio() } else { loading = true }
  }
  func seek(_ seconds: Double) {
    guard seconds.isFinite, duration > 0 else { return }
    let target = min(duration, max(0, seconds))
    let time = CMTime(seconds: target, preferredTimescale: 600)
    finished = false
    elapsed = target
    let tolerance = preciseSeeking ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    nowPlaying()
  }
  func next() {
    guard !queue.isEmpty else { return }
    let step = mode == .shuffle && queue.count > 1 ? Int.random(in: 1..<queue.count) : 1
    select((index + step) % queue.count)
  }
  func previous() {
    guard !queue.isEmpty else { return }
    select((index + queue.count - 1) % queue.count)
  }
  private func ended() {
    if sleepAfterTrack || (mode == .sequential && index == queue.count - 1) {
      if sleepAfterTrack { sleep(minutes: nil) }
      finished = true
      pause()
    } else if wantsAudio {
      mode == .one ? select(index) : next()
    }
  }
  func remove(at i: Int) {
    guard queue.indices.contains(i) else { return }
    queue.remove(at: i)
    if queue.isEmpty {
      clear()
    } else if i == index {
      select(min(i, queue.count - 1))
    } else if i < index {
      index -= 1
      nowPlaying()
    }
  }
  func enqueue(_ songs: [Song]) { queue.append(contentsOf: songs) }
  func clear() {
    generation = UUID()
    loadTask?.cancel()
    artworkTask?.cancel()
    status = nil
    current = nil
    queue = []
    index = 0
    pause()
    player.replaceCurrentItem(with: nil)
    source = nil
    elapsed = 0
    duration = 0
    offline = false
    caching = false
    cacheMessage = nil
    errorMessage = nil
    sleep(minutes: nil)
  }
  func sleep(minutes: Int?) {
    sleepTask?.cancel()
    sleepAfterTrack = false
    sleepUntil = nil
    guard let minutes, (1...1440).contains(minutes) else { return }
    sleepUntil = Date().addingTimeInterval(Double(minutes) * 60)
    sleepTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
        self?.pause()
        self?.sleepUntil = nil
      } catch {}
    }
  }
  func sleepAtEnd() {
    sleep(minutes: nil)
    sleepAfterTrack = true
  }
  func cacheCurrent() {
    guard let song = current, let source, !source.isFileURL else { return }
    let key = PlaybackFiles.folder(song)
    if let url = PlaybackFiles.existing(song) {
      offline = true
      cached?(song, url)
      return
    }
    guard transfers[key] == nil else { return }
    caching = true
    cacheMessage = nil
    transfers[key] = Task { [weak self] in
      do {
        let url = try await PlaybackFiles.save(song, source: source)
        if self?.current.map(PlaybackFiles.folder) == key { self?.offline = true }
        self?.cached?(song, url)
      } catch {
        if self?.current.map(PlaybackFiles.folder) == key {
          self?.cacheMessage = error.localizedDescription
        }
      }
      self?.transfers[key] = nil
      if self?.current.map(PlaybackFiles.folder) == key { self?.caching = false }
    }
  }
  private func fetchArt(_ url: URL?, _ token: UUID) {
    guard let url else { return }
    artworkTask = Task { [weak self] in
      do {
        let data: Data
        if url.isFileURL {
          data = try await Task.detached { try Data(contentsOf: url) }.value
        } else {
          data = try await URLSession.shared.data(from: url).0
        }
        guard self?.generation == token, let image = UIImage(data: data), image.size.width > 0
        else { return }
        self?.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self?.nowPlaying()
      } catch {}
    }
  }
  private func nowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    guard let current else {
      center.nowPlayingInfo = nil
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
      MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    center.nowPlayingInfo = info
  }
}
