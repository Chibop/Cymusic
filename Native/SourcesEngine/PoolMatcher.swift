import Foundation

enum PoolMatcher {
    static func candidates(for song: Song, services: Set<String> = ["tx", "wy"]) async throws -> [Song] {
        try Task.checkCancellation()
        guard !services.isEmpty else { return [] }
        let query = [song.title, song.artist].joined(separator: " ")
        switch song.platform?.lowercased() {
        case "tx", "qq":
            guard !song.id.isEmpty else { return [] }
            var native = song
            native.platform = "tx"
            return [native]
        case "wy":
            guard let id = Int64(song.id), id > 0 else { return [] }
            let qq = services.contains("tx") ? try? await PoolCatalog.qq(query) : nil
            try Task.checkCancellation()
            return [song] + [match(song, in: qq ?? [])].compactMap { $0 }
        default:
            guard !key(song.title).isEmpty, !key(song.artist).isEmpty else { return [] }
            async let qq = services.contains("tx") ? try? PoolCatalog.qq(query) : nil
            async let wy = services.contains("wy") ? try? PoolCatalog.netEase(query) : nil
            let pools = await (qq, wy)
            try Task.checkCancellation()
            guard pools.0 != nil || pools.1 != nil else { throw URLError(.cannotLoadFromNetwork) }
            return [match(song, in: pools.0 ?? []), match(song, in: pools.1 ?? [])].compactMap { $0 }
        }
    }

    // Preserve version words, featured artists, digits and word boundaries.
    private static func key(_ text: String?) -> String {
        guard let text else { return "" }
        let folded = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let simplified = folded.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? folded
        return simplified.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func albumVersions(_ album: String) -> Set<String> {
        let words = Set(album.split(separator: " ").map(String.init))
        let qualifiers = words.intersection(["live", "acoustic", "instrumental", "karaoke", "remix", "demo", "remastered", "remaster", "mono", "sped", "slowed", "rerecorded", "unplugged"])
        return qualifiers.union(["演唱会", "现场", "伴奏", "纯音乐", "重制", "混音"].filter { album.contains($0) })
    }

    // Select at most one ID per service. An exact album or ISRC can resolve a tie.
    static func match(_ source: Song, in rows: [Song]) -> Song? {
        let title = key(source.title), artist = key(source.artist), album = key(source.album), isrc = key(source.isrc)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let versions = albumVersions(album)
        var best: Song?, bestRank = -1, ambiguous = false
        for candidate in rows {
            guard !candidate.id.isEmpty, key(candidate.title) == title, key(candidate.artist) == artist else { continue }
            let otherAlbum = key(candidate.album), otherISRC = key(candidate.isrc)
            guard versions == albumVersions(otherAlbum) else { continue }
            let sameAlbum = !album.isEmpty && album == otherAlbum
            let sameISRC = !isrc.isEmpty && isrc == otherISRC
            if !isrc.isEmpty && !otherISRC.isEmpty && !sameISRC { continue }
            if let a = source.duration, let b = candidate.duration, a > 0, b > 0 {
                guard abs(a - b) <= min(3, 0.02 * a) else { continue }
            } else if !sameISRC && !sameAlbum { continue }
            let rank = (sameISRC ? 2 : 0) + (sameAlbum ? 1 : 0)
            if rank > bestRank {
                best = candidate
                bestRank = rank
                ambiguous = false
            } else if rank == bestRank && best?.id != candidate.id { ambiguous = true }
        }
        return ambiguous ? nil : best
    }
}
