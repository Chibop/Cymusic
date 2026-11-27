import MediaPlayer
import SwiftUI

struct PlayerScreen: View {
  @EnvironmentObject var playback: Playback
  @Environment(\.dismiss) private var dismiss
  @State private var lyrics = true
  @State private var picker: LyricPickerContext?
  @State private var showQueue = false
  @State private var scrub: Double?
  @AppStorage("playback.lyricSize") private var lyricSize = 23.0
  @AppStorage("playback.lyricOffset") private var lyricOffset = 0.0
  @AppStorage("playback.awake") private var keepAwake = true
  @State private var savedIdle: Bool?

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Color(red: 0.10, green: 0.13, blue: 0.14)
        if let url = playback.current?.artwork {
          AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Color.clear
          }.frame(width: geo.size.width, height: geo.size.height).blur(radius: 55).clipped()
            .accessibilityHidden(true)
        }
        LinearGradient(
          colors: [.black.opacity(0.35), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
      }.ignoresSafeArea()
      VStack(spacing: 0) {
        Button {
          dismiss()
        } label: {
          Capsule().fill(.secondary).frame(width: 38, height: 5).frame(width: 80, height: 44)
        }.accessibilityLabel("收起播放器")
        if playback.current == nil {
          Spacer()
          Image(systemName: "music.note.list").font(.largeTitle)
          Text("还没有正在播放的歌曲").padding()
          Spacer()
        } else if lyrics {
          PlaybackLyrics(
            raw: playback.current?.lyrics, elapsed: playback.elapsed, size: lyricSize,
            offset: lyricOffset, seek: playback.seek).id(playback.current?.lyrics)
          HStack {
            icon("rectangle.stack", "返回封面") { lyrics = false }
            Spacer()
            Button("歌词版本") {
              if let song = playback.current { picker = LyricPickerContext(id: playback.generation, song: song) }
            }
            Spacer()
            lyricMenu
          }.padding(.horizontal, 26)
        } else {
          ScrollView {
            VStack(spacing: 16) {
              Spacer(minLength: 0)
              albumArt.frame(
                width: min(geo.size.width - 64, max(120, geo.size.height * 0.41)),
                height: min(geo.size.width - 64, max(120, geo.size.height * 0.41))
              ).clipShape(RoundedRectangle(cornerRadius: 12)).shadow(
                color: .black.opacity(0.3), radius: 12, y: 8
              ).accessibilityHidden(true)
              Spacer(minLength: 0)
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(playback.current?.title ?? "").font(.title2.bold()).lineLimit(2)
                  Text(playback.current?.artist ?? "").font(.headline).foregroundStyle(.secondary)
                    .lineLimit(1)
                  if let source = playback.current?.audioSource { Text("音频来源：\(source)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                options
              }
              if let error = playback.errorMessage {
                Button {
                  playback.resume()
                } label: {
                  Label("\(error) · 重试", systemImage: "arrow.clockwise").font(.footnote)
                }
              }
              VStack(spacing: 0) {
                Slider(
                  value: Binding(
                    get: { scrub ?? min(playback.elapsed, max(playback.duration, 1)) },
                    set: { scrub = $0 }), in: 0...max(playback.duration, 1),
                  onEditingChanged: { editing in
                    if !editing, let scrub {
                      playback.seek(scrub)
                      self.scrub = nil
                    }
                  }
                ).accessibilityLabel("播放进度").disabled(playback.duration <= 0)
                HStack {
                  Text(clock(scrub ?? playback.elapsed))
                  Spacer()
                  Text(
                    playback.duration > 0
                      ? "−" + clock(playback.duration - (scrub ?? playback.elapsed)) : "--:--")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
              HStack(spacing: 30) {
                icon("backward.fill", "上一首", 26) { playback.previous() }
                Button {
                  playback.toggle()
                } label: {
                  ZStack {
                    if playback.loading {
                      ProgressView().tint(.white).scaleEffect(1.3)
                    } else {
                      Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(
                        .system(size: 46, weight: .medium))
                    }
                  }.frame(width: 68, height: 66)
                }.accessibilityLabel(playback.isPlaying || playback.loading ? "暂停" : "播放")
                icon("forward.fill", "下一首", 26) { playback.next() }
              }
              HStack {
                Image(systemName: "speaker.fill")
                PlaybackVolume().frame(height: 32)
                Image(systemName: "speaker.wave.3.fill")
              }.font(.caption).foregroundStyle(.secondary)
              HStack {
                icon("quote.bubble", "歌词") { lyrics = true }
                Spacer()
                Menu {
                  ForEach(PlaybackMode.allCases, id: \.self) { mode in
                    Button {
                      playback.mode = mode
                    } label: {
                      Label(
                        mode.title, systemImage: playback.mode == mode ? "checkmark" : mode.icon)
                    }
                  }
                } label: {
                  glyph(playback.mode.icon)
                }.accessibilityLabel("播放模式：\(playback.mode.title)")
                Spacer()
                icon("list.bullet", "播放队列") { showQueue = true }
              }
            }.padding(.horizontal, min(geo.size.width * 0.08, 48)).frame(maxWidth: 610).frame(
              minHeight: max(0, geo.size.height - 50)
            ).frame(maxWidth: .infinity)
          }.scrollIndicators(.hidden)
        }
      }.foregroundStyle(.white).tint(.white).buttonStyle(.plain).frame(
        width: geo.size.width, height: geo.size.height)
    }.environment(\.colorScheme, .dark).sheet(isPresented: $showQueue) {
      PlaybackQueue().environmentObject(playback)
    }.sheet(item: $picker) { context in
      LyricVersionPicker(context: context).environmentObject(playback)
    }.onChange(of: playback.generation) { _ in scrub = nil; picker = nil }.onChange(of: lyrics) { _ in
      updateIdle()
    }.onChange(of: keepAwake) { _ in updateIdle() }.onDisappear { restoreIdle() }.onAppear {
      updateIdle()
    }
  }
  private func updateIdle() {
    if lyrics && keepAwake {
      if savedIdle == nil { savedIdle = UIApplication.shared.isIdleTimerDisabled }
      UIApplication.shared.isIdleTimerDisabled = true
    } else {
      restoreIdle()
    }
  }
  private func restoreIdle() {
    if let savedIdle {
      UIApplication.shared.isIdleTimerDisabled = savedIdle
      self.savedIdle = nil
    }
  }
  private var albumArt: some View {
    ZStack {
      Color(red: 0.17, green: 0.22, blue: 0.23)
      Image(systemName: "opticaldisc").resizable().scaledToFit().padding(48).foregroundStyle(
        .white.opacity(0.28))
      if let url = playback.current?.artwork {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Color.clear
        }
      }
    }
  }
  private func clock(_ t: Double) -> String {
    let n = Int(max(0, t))
    return String(format: "%d:%02d", n / 60, n % 60)
  }
  private func glyph(_ name: String, _ size: Double = 20) -> some View {
    Image(systemName: name).font(.system(size: size, weight: .medium)).frame(
      minWidth: 44, minHeight: 44)
  }
  private func icon(
    _ name: String, _ title: String, _ size: Double = 20, _ action: @escaping () -> Void
  ) -> some View { Button(action: action) { glyph(name, size) }.accessibilityLabel(title) }
  private var options: some View {
    Menu {
      Button {
        playback.cacheCurrent()
      } label: {
        Label(
          playback.offline ? "已在本地" : playback.caching ? "正在缓存…" : "缓存到本地",
          systemImage: "arrow.down.circle")
      }.disabled(playback.offline || playback.caching || playback.loading)
      if let message = playback.cacheMessage { Text(message) }
      Toggle("自动缓存", isOn: $playback.autoCache)
      Toggle("精确跳转", isOn: $playback.preciseSeeking)
      Menu {
        ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { n in
          Button("\(n) 分钟") { playback.sleep(minutes: n) }
        }
        Button("播完当前歌曲") { playback.sleepAtEnd() }
        Button("关闭定时") { playback.sleep(minutes: nil) }
      } label: {
        Label(
          playback.sleepUntil.map { "定时至 " + $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)) }
            ?? (playback.sleepAfterTrack ? "播完当前歌曲后停止" : "定时关闭"), systemImage: "moon.zzz")
      }
    } label: {
      glyph("ellipsis.circle")
    }.accessibilityLabel("播放选项")
  }
  private var lyricMenu: some View {
    Menu {
      ControlGroup {
        Button("缩小") { lyricSize = max(14, lyricSize - 2) }
        Button("放大") { lyricSize = min(44, lyricSize + 2) }
      } label: {
        Text("字号 \(Int(lyricSize))")
      }
      Button("歌词提前 0.5 秒") { lyricOffset += 0.5 }
      Button("歌词延后 0.5 秒") { lyricOffset -= 0.5 }
      Button("重置偏移（\(lyricOffset, specifier: "%.1f") 秒）") { lyricOffset = 0 }
      Toggle("歌词页保持常亮", isOn: $keepAwake)
    } label: {
      glyph("textformat.size")
    }.accessibilityLabel("歌词设置")
  }
}

private struct PlaybackVolume: UIViewRepresentable {
  func makeUIView(context: Context) -> MPVolumeView {
    let view = MPVolumeView()
    view.tintColor = .white
    return view
  }
  func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
private struct PlaybackLyrics: View {
  var raw: String?, elapsed: Double, size: Double, offset: Double, seek: (Double) -> Void
  @State private var lines: [PlaybackLyric] = []
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var active: Int? { PlaybackLyric.active(at: elapsed + offset, in: lines) }
  var body: some View {
    let active = self.active
    GeometryReader { geo in
      ScrollViewReader { proxy in
        ScrollView {
          if lines.isEmpty {
            Text("此歌曲暂无歌词").foregroundStyle(.secondary).frame(
              maxWidth: .infinity, minHeight: geo.size.height)
          } else {
            LazyVStack(spacing: 22) {
              ForEach(lines) { line in
                Button {
                  if let time = line.time { seek(max(0, time - offset)) }
                } label: {
                  Text(line.text).font(
                    .system(size: size, weight: line.id == active ? .bold : .medium)
                  ).foregroundStyle(
                    line.id == active
                      ? Color(red: 1, green: 0.56, blue: 0.57) : .white.opacity(0.78)
                  ).frame(maxWidth: .infinity)
                }.disabled(line.time == nil).id(line.id)
              }
            }.padding(.horizontal, 24).padding(
              .vertical, lines.first?.time != nil ? geo.size.height * 0.43 : 22)
          }
        }.onChange(of: active) { id in
          if let id = id ?? lines.first?.id {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
              proxy.scrollTo(id, anchor: .center)
            }
          }
        }
      }
    }.onAppear { lines = PlaybackLyric.parse(raw) }.onChange(of: raw) {
      lines = PlaybackLyric.parse($0)
    }
  }
}
private struct PlaybackQueue: View {
  @EnvironmentObject var playback: Playback
  @Environment(\.dismiss) var dismiss
  @State private var confirm = false
  var body: some View {
    NavigationStack {
      List {
        ForEach(Array(playback.queue.enumerated()), id: \.offset) { i, song in
          Button {
            playback.select(i)
          } label: {
            HStack {
              Image(systemName: i == playback.index ? "waveform" : "music.note").foregroundStyle(
                i == playback.index ? Color.accentColor : .secondary
              ).frame(width: 24)
              VStack(alignment: .leading) {
                Text(song.title).foregroundStyle(.primary)
                Text(song.artist).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
            }
          }.accessibilityAddTraits(i == playback.index ? .isSelected : [])
        }.onDelete { offsets in for i in offsets.sorted(by: >) { playback.remove(at: i) } }
      }.navigationTitle("播放队列").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button("清空", role: .destructive) { confirm = true }.disabled(playback.queue.isEmpty)
        }
      }.confirmationDialog("清空播放队列并停止播放？", isPresented: $confirm, titleVisibility: .visible) {
        Button("清空并停止", role: .destructive) {
          playback.clear()
          dismiss()
        }
      }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}
