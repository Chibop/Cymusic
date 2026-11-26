import Foundation

struct Song: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var url: URL? = nil
    var artwork: URL? = nil
    var platform: String? = nil
    var lyrics: String? = nil
}
