import Foundation
import Combine

struct SourceScript: Codable, Identifiable {
    let id: String
    let name: String
    let text: String

    var exported: [String: String]? = nil

    var metadata: [String: String] {
        if let exported { return exported }
        guard let opening = text.range(of: "/*"), let closing = text[opening.upperBound...].range(of: "*/") else { return [:] }
        var values = [String: String]()
        for line in text[opening.upperBound..<closing.lowerBound].split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*")).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[0].first == "@" { values[String(parts[0].dropFirst())] = String(parts[1]) }
        }
        return values
    }

    var executable: String {
        guard text.range(of: #"\bmodule\s*\.\s*exports\b"#, options: .regularExpression) != nil else { return text }
        return """
        (() => {
          const module = {exports:{}};
          const fetch = (url, options={}) => new Promise((resolve,reject) => {
            lx.request(url, options, (err,res,body) => {
              if(err) return reject(err);
              const text = typeof body === 'string' ? body : JSON.stringify(body);
              resolve({ok:res.statusCode>=200 && res.statusCode<300, status:res.statusCode,
                       text:async()=>text, json:async()=>JSON.parse(text)});
            });
          });
          (function(module,exports,require,fetch){
        \(text)
          })(module,module.exports,()=>undefined,fetch);
          if(typeof module.exports.getMusicUrl !== 'function') throw Error('缺少 getMusicUrl');
          lx.on(lx.EVENT_NAMES.request, async ({info}) => module.exports.getMusicUrl(info.musicInfo.title, info.musicInfo.artist, info.musicInfo.songmid, info.type));
          const metadata = {};
          for (const key of ['id','author','name','version','srcUrl']) {
            if (typeof module.exports[key] === 'string') metadata[key] = module.exports[key];
          }
          lx.send(lx.EVENT_NAMES.inited,{cyMetadata:metadata,sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac']}}});
        })();
        """
    }
}

@MainActor final class SourceEngine: ObservableObject {
    enum Quality: String, Codable, CaseIterable { case low = "128k", standard = "320k", lossless = "flac" }
    private struct Store: Codable { var scripts: [SourceScript]; var quality: Quality? }
    @Published private(set) var quality = Quality.low

    func setQuality(_ value: Quality) throws { try save(scripts, quality: value) }
    @Published private(set) var scripts: [SourceScript] = []
    @Published private(set) var statuses: [String: String] = [:]
    private var tests: [String: Task<Void, Never>] = [:]
    @Published private(set) var notice: String?
    private let store: URL
    private let preload: URL?
    private let matcher: (Song) async throws -> [Song]

    init(store: URL? = nil, preload: URL? = Bundle.main.url(forResource: "user-api-preload", withExtension: "js"),
         matcher: @escaping (Song) async throws -> [Song] = PoolMatcher.candidates(for:)) {
        self.matcher = matcher
        self.store = store ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cymusic/providers.json")
        self.preload = preload
        do {
            if FileManager.default.fileExists(atPath: self.store.path) {
                let state = try JSONDecoder().decode(Store.self, from: Data(contentsOf: self.store))
                scripts = state.scripts
                quality = state.quality ?? .low
            }
        } catch { notice = error.localizedDescription }
    }

    // Restore only a fresh native store. Copy script text; do not evaluate it on launch.
    func restoreLegacy(_ values: [String: String]) throws {
        guard !FileManager.default.fileExists(atPath: store.path), let encoded = values["music.musicApi"] else { return }
        struct Entry: Decodable { let id: String; let name: String?; let script: String; let isSelected: Bool? }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(encoded.utf8))
        var seen = Set<String>()
        let list = entries.compactMap { entry -> SourceScript? in
            guard !entry.script.isEmpty, seen.insert(entry.id).inserted else { return nil }
            return SourceScript(id: entry.id, name: entry.name ?? entry.id, text: entry.script)
        }
        try save(list)
    }

    func importScript(_ text: String, name: String) async throws {
        let item = SourceScript(id: UUID().uuidString, name: name, text: text)
        let session = ProviderSession(preload: preload)
        let metadata: [String: String]
        do { metadata = try await session.load(item) ?? item.metadata }
        catch { await session.close(); throw error }
        await session.close()
        var list = scripts
        let index = list.firstIndex { $0.text == text || (metadata["id"]?.isEmpty == false && $0.exported?["id"] == metadata["id"]) }
        let installed = SourceScript(id: index.map { list[$0].id } ?? item.id, name: metadata["name"] ?? name, text: text, exported: metadata)
        if let index { list[index] = installed } else { list.append(installed) }
        try save(list)
        resetTest(installed.id)
    }

    func remove(_ item: SourceScript) throws {
        try save(scripts.filter { $0.id != item.id })
        resetTest(item.id)
    }

    private func resetTest(_ id: String) {
        tests.removeValue(forKey: id)?.cancel()
        statuses[id] = nil
    }

    func testAll() {
        for item in scripts where tests[item.id] == nil {
            statuses[item.id] = "测试中…"
            tests[item.id] = Task {
                let status: String
                do { try await check(item); status = "正常" }
                catch { status = error.localizedDescription }
                guard !Task.isCancelled else { return }
                statuses[item.id] = status
                tests[item.id] = nil
            }
        }
    }

    func check(_ item: SourceScript) async throws {
        let sample = Song(id: "004IArbh3ytHgR", title: "稻香", artist: "周杰伦", platform: "tx")
        _ = try await pooled(sample, scripts: [item], quality: .lossless, accept: Self.checkMedia)
    }

    private func save(_ scripts: [SourceScript], quality: Quality? = nil) throws {
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Store(scripts: scripts, quality: quality ?? self.quality)).write(to: store, options: .atomic)
        self.scripts = scripts
        if let quality { self.quality = quality }
        notice = nil
    }

    typealias Media = (url: URL, match: Song, source: String, quality: String?)

    func resolve(_ song: Song) async throws -> URL { try await resolveMedia(song).url }

    func resolveMedia(_ song: Song) async throws -> Media {
        try await pooled(song, scripts: scripts, quality: quality, accept: Self.checkMedia)
    }

    // Use the real transfer as the acceptance test. A failed or corrupt download
    // can therefore fall through even after the server has sent a successful header.
    func downloadMedia(_ song: Song, save: @escaping (URL) async throws -> URL) async throws -> Media {
        try await pooled(song, scripts: scripts, quality: quality, accept: save)
    }

    nonisolated private static func checkMedia(_ url: URL) async throws -> URL {
        if url.isFileURL {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw URLError(.fileDoesNotExist) }
            return url
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        let mime = response.mimeType?.lowercased() ?? ""
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !mime.contains("json"), !mime.contains("html"), !mime.contains("xml") else { throw URLError(.badServerResponse) }
        var prefix = Data()
        for try await byte in bytes { prefix.append(byte); if prefix.count == 64 { break } }
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("{"), !text.hasPrefix("["),
              !mime.hasPrefix("text/") || text.hasPrefix("#EXTM3U") else { throw SourceFailure("链接未返回音频") }
        return url
    }

    private func pooled(_ song: Song, scripts: [SourceScript], quality: Quality,
                        accept: @escaping (URL) async throws -> URL) async throws -> Media {
        var last: Error = SourceFailure(scripts.isEmpty ? "请先导入音源" : "没有可用的匹配音源")
        if let url = song.url, url.isFileURL || ProviderSession.webURL(url.absoluteString) != nil {
            do { return (try await accept(url), song, song.audioSource ?? (url.isFileURL ? "本地文件" : "直连"), song.quality) }
            catch { try Task.checkCancellation(); last = error }
        }
        guard !scripts.isEmpty else { throw last }
        var sessions = [String: ProviderSession](), failed = Set<String>(), seen = Set<[String]>()
        func load(_ item: SourceScript) async throws -> ProviderSession? {
            if let session = sessions[item.id] { return session }
            guard !failed.contains(item.id) else { return nil }
            let session = ProviderSession(preload: preload)
            do { _ = try await session.load(item); sessions[item.id] = session; return session }
            catch { await session.close(); try Task.checkCancellation(); failed.insert(item.id); last = error; return nil }
        }
        func attempt(_ candidate: Song) async throws -> Media? {
            guard seen.insert([ProviderSession.platform(candidate), candidate.id]).inserted else { return nil }
            for item in scripts {
                try Task.checkCancellation()
                guard let session = try await load(item) else { continue }
                for level in await session.qualities(for: candidate, preferred: quality) {
                    do {
                        let url = try await session.requestURL(candidate, quality: level)
                        return (try await accept(url), candidate, item.name, level)
                    } catch { try Task.checkCancellation(); last = error }
                }
            }
            return nil
        }
        func run() async throws -> Media {
            if let result = try await attempt(song) { return result }
            for item in scripts {
                guard let session = try await load(item) else { continue }
                for platform in await session.searchPlatforms {
                    let hits: [Song]
                    do { hits = try await session.search(song, platform: platform) }
                    catch { try Task.checkCancellation(); last = error; continue }
                    for hit in hits { if let result = try await attempt(hit) { return result } }
                }
            }
            let matches = try await matcher(song)
            for match in matches { if let result = try await attempt(match) { return result } }
            throw last
        }
        do {
            let result = try await run()
            for session in sessions.values { await session.close() }
            try Task.checkCancellation()
            return result
        } catch { for session in sessions.values { await session.close() }; throw error }
    }
}
