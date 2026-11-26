import Foundation
import UniformTypeIdentifiers

/// This release resets downloaded audio once. Never traverse the system media library,
/// Imports, shared containers, original files, playlists, or the source database.
enum DownloadedAudioCleanup {
    static let marker = "CyMusic.downloadedAudioReset.v1.6.completed"
    static func once(documents: URL, support: URL, defaults: UserDefaults = .standard) throws -> Int {
        guard !defaults.bool(forKey: marker) else { return 0 }
        let fm = FileManager.default
        var removed = 0
        for (parent, suffix, native) in [(support,"PlaybackCache",true),(documents,"musicCache",false),(documents,"download/music",false)] {
            let canonical = parent.resolvingSymlinksInPath().standardizedFileURL
            let root = canonical.appendingPathComponent(suffix).standardizedFileURL
            guard root.resolvingSymlinksInPath().path == root.path, fm.fileExists(atPath: root.path) else { continue }
            var problem: Error?
            let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey]
            guard let items = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, e in problem = e; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let url as URL in items {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { items.skipDescendants(); continue }
                guard values.isRegularFile == true, url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                let ext = url.pathExtension.lowercased()
                guard native ? url.deletingPathExtension().lastPathComponent == "audio" : (UTType(filenameExtension: ext)?.conforms(to: .audio) == true || ["mp4","opus","flac","ogg"].contains(ext)) else { continue }
                try fm.removeItem(at: url); removed += 1
            }
            if let problem { throw problem }
        }
        defaults.set(true, forKey: marker)
        return removed
    }
}
