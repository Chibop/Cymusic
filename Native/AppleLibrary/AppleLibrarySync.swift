import MediaPlayer
import Combine

private enum DeviceLibrary {
    static func read() throws -> AppleLibrarySnapshot {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              let items = MPMediaQuery.songs().items else { throw CocoaError(.fileReadNoPermission) }
        let rows = items.map { item in
            func clean(_ text: String?) -> String { text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            return AppleLibraryTrack(persistentID: item.persistentID, albumPersistentID: item.albumPersistentID,
                title: clean(item.title), artist: clean(item.artist), albumTitle: clean(item.albumTitle),
                albumArtist: clean(item.albumArtist), duration: item.playbackDuration.isFinite && item.playbackDuration > 0 ? item.playbackDuration : nil,
                disc: item.discNumber, track: item.albumTrackNumber, cloudOnly: item.isCloudItem)
        }
        let snapshot = AppleLibrarySnapshot(rows: rows)
        guard items.isEmpty || !snapshot.tracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
}

@MainActor final class AppleLibrarySync: ObservableObject {
    @Published private(set) var snapshot: AppleLibrarySnapshot?
    @Published private(set) var albums: [AppleLibraryAlbum] = []
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    @Published private(set) var permission: MPMediaLibraryAuthorizationStatus
    private var loaded = false
    private let disk: AppleLibraryDisk
    private let authorization: @Sendable () -> MPMediaLibraryAuthorizationStatus
    private let query: @Sendable () throws -> AppleLibrarySnapshot

    init(disk: AppleLibraryDisk = AppleLibraryDisk(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AppleLibrary", isDirectory: true)),
         authorization: @escaping @Sendable () -> MPMediaLibraryAuthorizationStatus = { MPMediaLibrary.authorizationStatus() },
         query: @escaping @Sendable () throws -> AppleLibrarySnapshot = { try DeviceLibrary.read() }) {
        self.disk = disk
        self.authorization = authorization
        self.query = query
        permission = authorization()
    }

    func refresh(prompt: Bool = false) async {
        guard !busy else { return }; busy = true; failed = false
        defer { busy = false; permission = authorization() }
        do {
            if !loaded {
                let cached = try await Task.detached(priority: .utility) { [disk] in
                    let cached = try disk.load(); return (cached, cached?.albums ?? [])
                }.value
                snapshot = cached.0; albums = cached.1; loaded = true
            }
        } catch { failed = true } // A corrupt cache must not prevent a fresh authorized query.
        permission = authorization()
        if prompt && permission == .notDetermined {
            guard Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String != nil else { failed = true; return }
            permission = await MPMediaLibrary.requestAuthorization()
        }
        guard permission == .authorized else { return }
        do {
            let result = try await Task.detached(priority: .utility) { [disk, query, authorization] in
                let next = try query(), albums = next.albums
                guard authorization() == .authorized else { throw CocoaError(.fileReadNoPermission) }
                try disk.save(next); return (next, albums)
            }.value
            snapshot = result.0; albums = result.1; loaded = true; failed = false
        } catch { failed = true }
    }
}
