import Foundation

/// When each playlist, album and artist was last played, for "Recently played" in the library.
/// Stays on this iPhone (per account) and is not sent anywhere. Audiobooks have it from the server's progress.
enum PlayHistory {
    private static let limit = 300

    private static func key(_ account: UUID?) -> String { "playHistory." + (account?.uuidString ?? "") }

    /// The library entry (same ids as the library list) a queue was started from.
    static func entryId(_ context: PlayerModel.Context) -> String? {
        switch context.kind {
        case .album: context.id.map { "a" + $0 }
        case .playlist: context.id.map { "p" + $0 }
        case .artist: context.id.map { "r" + $0 }
        case .favorites: "favorites"
        case .downloads: "downloads"
        default: nil
        }
    }

    static func dates(_ account: UUID?) -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: key(account)) as? [String: Double]) ?? [:]
    }

    static func note(_ context: PlayerModel.Context?, account: UUID?) {
        guard let context, let id = entryId(context) else { return }
        var all = dates(account)
        all[id] = Date().timeIntervalSince1970
        if all.count > limit { // the oldest go first
            for old in all.sorted(by: { $0.value < $1.value }).prefix(all.count - limit) { all.removeValue(forKey: old.key) }
        }
        UserDefaults.standard.set(all, forKey: key(account))
    }

    static func forget(_ account: UUID) { UserDefaults.standard.removeObject(forKey: key(account)) }
}
