import UIKit

/// Loads the whole library onto the iPhone once: every album, artist and playlist page goes into the
/// library cache, so everything opens at once and offline – not only what was browsed before.
/// Only music metadata is stored, like the rest of the cache. Running it again later picks up changes.
@MainActor @Observable final class LibrarySync {
    struct Summary: Codable {
        var date: Date
        var albums: Int
        var artists: Int
        var playlists: Int
        var genres: Int
        var songs: Int
    }

    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var phase = ""
    private(set) var error: String?
    private(set) var summary: Summary?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var accountId: UUID?

    /// Requests at the same time – fast, without hammering a small home server.
    private let parallel = 4

    /// A sync older than this is worth repeating; the settings say so.
    var isStale: Bool { summary.map { Date().timeIntervalSince($0.date) > 30 * 24 * 3600 } ?? false }

    private static func key(_ id: UUID) -> String { "librarySync." + id.uuidString }

    /// Shows the state of this account's library; a sync for another account stops.
    func show(_ id: UUID?) {
        guard id != accountId else { return }
        cancel()
        accountId = id
        error = nil
        summary = id.flatMap { UserDefaults.standard.data(forKey: Self.key($0)) }
            .flatMap { try? JSONDecoder().decode(Summary.self, from: $0) }
    }

    /// The cache was cleared or the account removed: nothing is synced any more.
    func forget(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.key(id))
        if id == accountId { cancel(); summary = nil }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    func start(_ client: SubsonicClient) {
        guard !running else { return }
        let id = client.account.id
        accountId = id
        running = true
        error = nil
        done = 0
        total = 0
        phase = String(localized: "Loading overview…")
        // Keeps going for a while when the app is left, so a short switch doesn't break the sync
        let background = UIApplication.shared.beginBackgroundTask(withName: "Library sync")
        task = Task {
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                let result = try await run(client)
                guard !Task.isCancelled else { return }
                summary = result
                UserDefaults.standard.set(try? JSONEncoder().encode(result), forKey: Self.key(id))
            } catch {
                if !error.isCancellation && !(error is CancellationError) { self.error = error.userMessage }
            }
            if !Task.isCancelled { running = false; task = nil }
        }
    }

    private func run(_ client: SubsonicClient) async throws -> Summary {
        async let artistsPayload = client.refresh("getArtists")
        async let genresPayload = client.refresh("getGenres")
        async let playlistsPayload = client.refresh("getPlaylists")
        async let starred = client.refresh("getStarred2")
        let artists = (try await artistsPayload.artists?.index ?? []).flatMap { $0.artist ?? [] }
        let genres = try await genresPayload.genres?.genre ?? []
        let playlists = try await playlistsPayload.playlists?.playlist ?? []
        _ = try await starred

        // The album list in pages, exactly like the library page asks for it
        var albums: [Album] = []
        while true {
            try Task.checkCancellation()
            phase = String(localized: "Loading albums… \(albums.count)")
            let page = try await client.refresh("getAlbumList2", ["type": "alphabeticalByName", "size": "60", "offset": "\(albums.count)"])
                .albumList2?.album ?? []
            albums += page
            if page.count < 60 { break }
        }

        // Then every album, artist and playlist page on its own
        let jobs = albums.map { ("getAlbum", $0.id) } + artists.map { ("getArtist", $0.id) } + playlists.map { ("getPlaylist", $0.id) }
        total = jobs.count
        phase = String(localized: "Loading albums, artists and playlists…")
        var start = 0
        while start < jobs.count {
            try Task.checkCancellation()
            let batch = jobs[start..<min(start + parallel, jobs.count)]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (method, id) in batch {
                    group.addTask {
                        do { _ = try await client.refresh(method, ["id": id]) } catch where error.isServerAnswer {
                            // One album the server can't find (just deleted, say) doesn't stop the sync
                        }
                    }
                }
                try await group.waitForAll()
            }
            start += batch.count
            done = start
        }
        return Summary(date: Date(), albums: albums.count, artists: artists.count, playlists: playlists.count,
                       genres: genres.count, songs: albums.reduce(0) { $0 + ($1.songCount ?? 0) })
    }
}
