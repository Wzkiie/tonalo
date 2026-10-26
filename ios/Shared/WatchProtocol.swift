import Foundation

/// What the iPhone and the watch app tell each other over WatchConnectivity. Payloads travel as JSON in
/// the "data" field so both sides share these types.
enum Watch {
    /// Commands from the watch: toggle, next, previous, favorite, shuffle, repeat, play, list, cover, state
    static let command = "cmd"
    static let data = "data"
    static let id = "id"
    static let kind = "kind"
    static let index = "index"
    static let shuffle = "shuffle"

    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Any?) -> T? {
        (data as? Data).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// The phone's player, as the watch shows it. The watch moves the position on by itself from `sentAt`.
struct WatchNowPlaying: Codable, Equatable {
    var songId: String
    var title: String
    var artist: String
    var context: String?
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var sentAt: Date
    var starred: Bool
    var shuffle: Bool
    var repeatMode: String
    var accentHex: String
    var cover: Data?
}

/// A row in the watch library: a playlist, album, mix or song.
struct WatchItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case favorites, mix, playlist, album, song }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var coverId: String?
}

struct WatchSection: Codable, Hashable, Identifiable {
    var id: String { title }
    var title: String
    var items: [WatchItem]
}
