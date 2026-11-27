#if APPLE_LIBRARY_FIXTURES
import Foundation
import MediaPlayer
import AVFoundation

// Standalone simulator executable. All metadata here is synthetic and test-only.
@main enum AppleLibraryFixtureChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = AppleLibraryDisk(directory: directory)
        func row(_ id: UInt64, album: UInt64, disc: Int, cloud: Bool, artist: String) -> AppleLibraryTrack {
            AppleLibraryTrack(persistentID: id, albumPersistentID: album, title: "Fixture take \(disc)", artist: artist,
                albumTitle: "Fixture collection", albumArtist: "Fixture ensemble", duration: 192.75,
                disc: disc, track: 1, cloudOnly: cloud)
        }
        let local = row(UInt64.max, album: 42, disc: 2, cloud: false, artist: "Fixture soloist")
        let cloud = row(3, album: 42, disc: 1, cloud: true, artist: "Fixture guest")
        let incomplete = row(7, album: 0, disc: 1, cloud: false, artist: "")
        let data = AppleLibrarySnapshot(rows: [local, cloud, local, incomplete], now: Date(timeIntervalSince1970: 1_700_000_000))
        let success = AppleLibrarySync(disk: disk, authorization: { .authorized }, query: { data })
        await success.refresh()
        precondition(!success.failed && success.snapshot?.tracks.count == 3)
        precondition(success.albums.count == 2 && success.albums.first(where: { $0.id == "album:42" })?.tracks.map(\.id) == [cloud.id, local.id])
        precondition(local.song.platform == "apple-library" && local.song.id == "apple-library:\(UInt64.max)" && local.song.url == nil)
        precondition(!local.cloudOnly && cloud.cloudOnly && !incomplete.canMatch)
        // A real two-second local recording intentionally disagrees with the catalog duration.
        let wave = directory.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: wave, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        }
        let details = await AppleLocalAudio.read(wave)
        precondition(details.quality?.contains("PCM · 16-bit · 44.1 kHz") == true && details.duration == "0:02")
        let missing = await AppleLocalAudio.read(directory.appendingPathComponent("absent.flac"))
        precondition(missing.quality == nil && missing.duration == nil)
        let denied = AppleLibrarySync(disk: disk, authorization: { .denied }, query: { fatalError("Unauthorized query") })
        await denied.refresh()
        precondition(denied.snapshot?.syncedAt == data.syncedAt && denied.snapshot?.tracks.count == 3)
        let failure = AppleLibrarySync(disk: disk, authorization: { .authorized }, query: { throw CocoaError(.fileReadUnknown) })
        await failure.refresh()
        let persisted = try disk.load()
        precondition(failure.failed && failure.snapshot?.tracks.count == 3 && persisted?.tracks.count == 3)
        let empty = AppleLibrarySync(disk: disk, authorization: { .authorized }, query: { AppleLibrarySnapshot(rows: []) })
        await empty.refresh()
        let persistedEmpty = try disk.load()
        precondition(!empty.failed && persistedEmpty?.tracks.isEmpty == true)
        print("PASS: device-local identity, cloud/local metadata, missing artist, deduplication, album order, denied/failed refresh, authorized empty library, file-derived PCM quality/duration, missing-file fallback")
    }
}
#endif
