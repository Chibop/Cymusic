import Foundation
import AVFoundation

/// Inspect the encoded audio track. Apple catalog timings and requested download tiers
/// can differ from the recording that was actually saved.
struct AppleLocalAudio {
    let quality: String?
    let duration: String?

    static func read(_ url: URL) async -> Self {
        let asset = AVURLAsset(url: url)
        let seconds = try? await asset.load(.duration).seconds
        let duration = seconds.flatMap { value -> String? in
            guard value.isFinite, value > 0, value < Double(Int32.max) else { return nil }
            let total = Int(value.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let format = try? await track.load(.formatDescriptions).first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return Self(quality: nil, duration: duration)
        }
        let codec: String?
        switch stream.mFormatID {
        case kAudioFormatLinearPCM: codec = "PCM"
        case kAudioFormatFLAC: codec = "FLAC"
        case kAudioFormatAppleLossless: codec = "ALAC"
        case kAudioFormatMPEGLayer3: codec = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = "AAC"
        default:
            var four = stream.mFormatID.bigEndian
            codec = withUnsafeBytes(of: &four) { String(bytes: $0, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) }
        }
        let bitrate = try? await track.load(.estimatedDataRate)
        let parts = [codec, stream.mBitsPerChannel > 0 ? "\(stream.mBitsPerChannel)-bit" : nil,
                     stream.mSampleRate > 0 ? String(format: "%g kHz", stream.mSampleRate / 1000) : nil,
                     bitrate.flatMap { $0.isFinite && $0 > 0 ? String(format: "%.0f kbps", $0 / 1000) : nil }].compactMap { $0 }
        return Self(quality: parts.isEmpty ? nil : parts.joined(separator: " · "), duration: duration)
    }
}

/// Metadata only: intentionally no asset URL, artwork, account, or playback history.
struct AppleLibraryTrack: Codable, Identifiable {
    let persistentID: UInt64
    let albumPersistentID: UInt64
    let title: String
    let artist: String
    let albumTitle: String
    let albumArtist: String
    let duration: Double?
    let disc: Int
    let track: Int
    let cloudOnly: Bool

    var id: String { "apple-library:\(persistentID)" }
    var song: Song {
        // The library ID is device-local, NOT a store ID. The pool must match by metadata.
        Song(id: id, title: title, artist: artist, platform: "apple-library", album: albumTitle,
             albumArtist: albumArtist, duration: duration)
    }
    var canMatch: Bool { !title.isEmpty && !artist.isEmpty }
    var albumKey: String {
        if albumPersistentID != 0 { return "album:\(albumPersistentID)" }
        guard !albumTitle.isEmpty else { return "unfiled:\(id)" }
        let credit = albumArtist.isEmpty ? artist : albumArtist
        return "tags:\(albumTitle.utf8.count):\(albumTitle)\(credit)"
    }
}

struct AppleLibraryAlbum: Identifiable {
    let id: String
    let tracks: [AppleLibraryTrack]
    var title: String { tracks.first?.albumTitle ?? "" }
    var artist: String { tracks.first?.albumArtist ?? "" }
}

struct AppleLibrarySnapshot: Codable {
    let tracks: [AppleLibraryTrack]
    let syncedAt: Date
    init(rows: [AppleLibraryTrack], now: Date = Date()) {
        var seen = Set<UInt64>()
        tracks = rows.filter { $0.persistentID != 0 && seen.insert($0.persistentID).inserted }
            .sorted { a, b in
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? a.persistentID < b.persistentID : order == .orderedAscending
            }
        syncedAt = now
    }
    var albums: [AppleLibraryAlbum] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, rows in
            AppleLibraryAlbum(id: key, tracks: rows.sorted { ($0.disc, $0.track, $0.title, $0.persistentID) < ($1.disc, $1.track, $1.title, $1.persistentID) })
        }.sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}

struct AppleLibraryDisk {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("library-v1.json") }
    func load() throws -> AppleLibrarySnapshot? {
        do { return try JSONDecoder().decode(AppleLibrarySnapshot.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ snapshot: AppleLibrarySnapshot) throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try folder.setResourceValues(flags)
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
