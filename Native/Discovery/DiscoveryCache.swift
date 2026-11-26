import Combine
import CryptoKit
import Foundation

/// One model per publisher/resource. Keep the v1 disk format to reuse existing selections.
@MainActor final class DiscoveryCache<Item: Codable>: ObservableObject {
    private struct Snapshot: Codable { let fetched: Date; let items: [Item] }
    private let file: URL
    private let now: () -> Date
    private let calendar: Calendar
    private var saved: Snapshot?
    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    private var request: Task<Void, Never>?

    init(key: String, directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Discovery-v1"), now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(digest)
        self.now = now; self.calendar = calendar
        if let bytes = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes) {
            saved = snapshot; items = snapshot.items
        }
    }

    func refresh(force: Bool = false, load: @escaping () async throws -> [Item]) async {
        if let request { await request.value; return }
        let requested = now()
        if !force, let saved, calendar.isDate(saved.fetched, inSameDayAs: requested) { return }
        loading = true; problem = nil
        let task = Task {
            defer { loading = false; request = nil }
            do {
                let rows = try await load()
                guard !rows.isEmpty else { throw URLError(.zeroByteResource) }
                let result = Snapshot(fetched: now(), items: rows)
                saved = result; items = rows
                let data = try JSONEncoder().encode(result)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch { problem = error.localizedDescription }
        }
        request = task
        await task.value
    }
}
