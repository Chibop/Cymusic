import SwiftUI

struct AlbumCoverSyncButton: View {
  @EnvironmentObject private var library: Library

  var body: some View {
    AlbumCoverSyncControls(sync: library.albumCoverSync, library: library)
  }
}

private struct AlbumCoverSyncControls: View {
  @ObservedObject var sync: AlbumCoverSync
  let library: Library
  @Environment(\.locale) private var locale
  private var zh: Bool { locale.identifier.hasPrefix("zh") }

  var body: some View {
    let p = sync.progress
    let busy = p.phase == .running || p.phase == .cancelling
    VStack(alignment: .leading, spacing: 8) {
      if busy {
        ProgressView(value: Double(p.processed), total: Double(max(1, p.total))) {
          Text(zh ? "正在同步专辑封面" : "Syncing album covers")
        }
        if !p.currentAlbum.isEmpty { Text(verbatim: p.currentAlbum).font(.subheadline) }
        Button(zh ? "取消" : "Cancel") { sync.cancel() }.disabled(p.phase == .cancelling)
      } else {
        Button { sync.start(library: library) } label: {
          Label(zh ? "从 Apple Music 同步专辑封面" : "Sync album covers from Apple Music", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      if p.phase == .cancelled { Text(zh ? "已取消" : "Cancelled").font(.subheadline) }
      if p.phase != .idle {
        Text(zh ? "已处理 \(p.processed)/\(p.total) · 更新 \(p.updated) · 跳过 \(p.skipped) · 失败 \(p.failed)" : "\(p.processed)/\(p.total) processed · \(p.updated) updated · \(p.skipped) skipped · \(p.failed) failed")
          .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
      }
    }.buttonStyle(.borderless)
  }
}
