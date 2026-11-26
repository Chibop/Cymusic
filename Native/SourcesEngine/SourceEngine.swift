import Foundation
import Combine

struct SourceScript: Codable, Identifiable {
    let id: String
    let name: String
    let text: String

    var metadata: [String: String] {
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
          lx.send(lx.EVENT_NAMES.inited,{sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac']}}});
        })();
        """
    }
}

@MainActor final class SourceEngine: ObservableObject {
    private struct Store: Codable { var scripts: [SourceScript]; var selected: String? }
    @Published private(set) var scripts: [SourceScript] = []
    @Published private(set) var selected: String?
    @Published private(set) var notice: String?
    private let store: URL
    private let preload: URL?
    private var session: ProviderSession?
    private var revision = UUID()
    private var restoring: Task<Void, Error>?

    init(store: URL? = nil, preload: URL? = Bundle.main.url(forResource: "user-api-preload", withExtension: "js")) {
        self.store = store ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cymusic/providers.json")
        self.preload = preload
        do {
            if FileManager.default.fileExists(atPath: self.store.path) {
                let state = try JSONDecoder().decode(Store.self, from: Data(contentsOf: self.store))
                scripts = state.scripts
                selected = state.selected
            }
        } catch { notice = error.localizedDescription }
    }

    func importScript(_ text: String, name: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceFailure("音源脚本为空") }
        let existing = scripts.first { $0.text == text }
        let raw = SourceScript(id: existing?.id ?? UUID().uuidString, name: name, text: text)
        let item = SourceScript(id: raw.id, name: raw.metadata["name"] ?? (name.isEmpty ? "自定义音源" : name), text: text)
        try await activate(item, adding: existing == nil)
    }

    func select(_ item: SourceScript) async throws { try await activate(item, adding: false) }

    private func activate(_ item: SourceScript, adding: Bool) async throws {
        let token = UUID()
        revision = token
        let candidate = ProviderSession(preload: preload)
        do {
            try await candidate.load(item)
            guard revision == token else { throw CancellationError() }
            var list = scripts
            if adding { list.append(item) }
            try save(list, selected: item.id)
            session?.close()
            session = candidate
        } catch { candidate.close(); throw error }
    }

    func remove(_ item: SourceScript) throws {
        let active = selected == item.id
        try save(scripts.filter { $0.id != item.id }, selected: active ? nil : selected)
        revision = UUID()
        if active { session?.close(); session = nil }
    }

    private func save(_ scripts: [SourceScript], selected: String?) throws {
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Store(scripts: scripts, selected: selected)).write(to: store, options: .atomic)
        self.scripts = scripts
        self.selected = selected
        notice = nil
    }

    func resolve(_ song: Song) async throws -> URL {
        if let url = song.url, url.isFileURL || ProviderSession.webURL(url.absoluteString) != nil { return url }
        if session == nil, let item = scripts.first(where: { $0.id == selected }) {
            if let restoring { try await restoring.value }
            else {
                let task = Task { try await select(item) }
                restoring = task
                defer { restoring = nil }
                try await task.value
            }
        }
        guard let session else { throw SourceFailure("请先在音源页面导入并选择音源") }
        return try await session.resolve(song)
    }
}
