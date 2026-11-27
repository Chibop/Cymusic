import Foundation

struct Song: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var url: URL? = nil
    var artwork: URL? = nil
    var platform: String? = nil
    // Provider-native identifiers can differ by site and are not interchangeable.
    var nativeIDs: [String: String]? = nil
    var lyrics: String? = nil
    var album: String? = nil
    var albumArtist: String? = nil
    var duration: Double? = nil
    var isrc: String? = nil
    var quality: String? = nil
    var audioSource: String? = nil
    var searchScriptID: String? = nil
    var requestedQuality: String? = nil
}
