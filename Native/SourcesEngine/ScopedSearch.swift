import Foundation

enum ScopedSearchPlatform {
    static func name(_ id: String) -> String {
        switch id {
        case "tx": return "QQ 音乐"
        case "wy": return "网易云音乐"
        case "mg": return "咪咕音乐"
        case "kw": return "酷我音乐"
        case "kg": return "酷狗音乐"
        case "xm": return "虾米音乐"
        default: return id
        }
    }
}

struct ScopedSearchResults {
    var songs = [Song]()
    var failures = [String]()
}

extension SourceEngine {
    private func installed(_ script: SourceScript) throws -> SourceScript {
        guard let current = scripts.first(where: { $0.id == script.id && $0.text == script.text }) else {
            throw SourceFailure("音源已变更，请重新选择")
        }
        return current
    }

    private func withScopedSession<T>(_ script: SourceScript, perform: (ProviderSession) async throws -> T) async throws -> T {
        let session = ProviderSession(preload: preload)
        do {
            _ = try await session.load(script)
            let value = try await perform(session)
            await session.close()
            return value
        } catch {
            await session.close()
            throw error
        }
    }

    private func declaredPlatforms(for script: SourceScript, action: String) async throws -> [String] {
        let script = try installed(script)
        let routes: [String: [String]]
        if let cached = script.routes { routes = cached }
        else { routes = try await withScopedSession(script) { await $0.routes } }
        return routes.keys.filter { routes[$0]?.contains(action) == true }.sorted()
    }

    func declaredDownloadPlatforms(for script: SourceScript) async throws -> [String] {
        try await declaredPlatforms(for: script, action: "musicUrl")
    }

    func declaredSearchPlatforms(for script: SourceScript) async throws -> [String] {
        try await declaredPlatforms(for: script, action: "search")
    }

    func matchCatalogSong(_ seed: Song, script: SourceScript, platform: String) async throws -> Song {
        let script = try installed(script)
        guard seed.platform == "apple", !platform.isEmpty, platform.lowercased() != "apple" else {
            throw SourceFailure("请选择 Apple Music 歌曲和下载平台")
        }
        let query = "\(seed.title) \(seed.artist)"
        let candidates = try await withScopedSession(script) { session -> [Song] in
            let actions = await session.routes[platform] ?? []
            guard actions.contains("musicUrl") else { throw SourceFailure("音源未声明所选平台的下载能力") }
            switch platform {
            case "tx": return try await PoolCatalog.qq(query)
            case "wy": return try await PoolCatalog.netEase(query)
            default:
                guard actions.contains("search") else { throw SourceFailure("所选平台不支持歌曲匹配") }
                return try await session.search(seed, platform: platform)
            }
        }
        try Task.checkCancellation()
        _ = try installed(script)
        let scoped = candidates.filter { $0.platform == platform && $0.id != seed.id }
        guard var match = PoolMatcher.match(seed, in: scoped) else { throw SourceFailure("所选平台未找到同一录音版本") }
        match.searchScriptID = script.id
        return match
    }

    func availableLevels(for song: Song, script: SourceScript) async throws -> [String] {
        let script = try installed(script)
        guard song.searchScriptID == script.id, let platform = song.platform,
              !platform.isEmpty, platform.lowercased() != "apple" else { throw SourceFailure("歌曲与所选音源不匹配") }
        let levels = try await withScopedSession(script) { session in
            await session.qualities(for: song, preferred: .lossless, best: true)
        }
        try Task.checkCancellation()
        _ = try installed(script)
        return levels
    }

    func scopedSearch(_ input: String, script: SourceScript, platforms: Set<String>) async throws -> ScopedSearchResults {
        let keyword = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !platforms.isEmpty else { throw SourceFailure("请输入关键词并选择平台") }
        let script = try installed(script)
        func validate(_ allowed: [String]) throws {
            guard platforms.isSubset(of: Set(allowed)) else { throw SourceFailure("音源未声明所选平台的搜索能力") }
        }
        if let routes = script.routes { try validate(routes.keys.filter { routes[$0]?.contains("search") == true }) }
        return try await withScopedSession(script) { session in
            try validate(await session.searchPlatforms)
            var result = ScopedSearchResults()
            for platform in platforms.sorted() {
                try Task.checkCancellation()
                do {
                    var seen = Set<String>()
                    for var song in try await session.search(keyword: keyword, platform: platform) where seen.insert(song.id).inserted {
                        song.searchScriptID = script.id
                        result.songs.append(song)
                    }
                } catch {
                    try Task.checkCancellation()
                    result.failures.append("\(ScopedSearchPlatform.name(platform))：\(L10n.message(for: error))")
                }
            }
            try Task.checkCancellation()
            _ = try installed(script)
            return result
        }
    }
}
