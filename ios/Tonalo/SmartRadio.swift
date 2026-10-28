import Foundation

/// Radio that keeps going: when the queue runs low it adds songs like the ones played to the end or
/// given a heart, and fewer of the artists that get skipped. Without Last.fm on the server it stays in
/// the genre instead. What it learns is kept only while the app runs.
@MainActor
final class SmartRadio {
    weak var player: PlayerModel?

    /// Songs the radio is based on, newest last.
    private var seeds: [Song] = []
    /// A genre radio stays in its genre.
    private var genre: String?
    /// Skipped songs per artist: one skip plays them later, two leave them out.
    private var skips: [String: Int] = [:]
    /// Everything the radio already played or queued – nothing comes twice.
    private var seen: Set<String> = []
    /// The server found no similar songs (no Last.fm): don't keep asking.
    private var noSimilar = false
    private var filling = false

    /// Starts a radio from a song or artist (`seedId` – the server finds similar songs for both),
    /// from a few songs, or from a genre. `first` plays before the radio songs.
    @discardableResult
    func start(_ name: String, seedId: String? = nil, seeds: [Song] = [], genre: String? = nil, first: Song? = nil) async -> Bool {
        guard let client = player?.app?.client else { return false }
        self.seeds = (first.map { [$0] } ?? []) + seeds
        self.genre = genre
        skips = [:]
        seen = Set(self.seeds.map(\.id))
        var songs: [Song] = []
        noSimilar = false
        if let seedId {
            let similar = await client.similarSongs(seedId)
            noSimilar = similar.isEmpty
            songs = fresh(similar)
        }
        if songs.count < 10 { songs += await candidates(count: 25 - songs.count) }
        songs = (first.map { [$0] } ?? []) + songs.filter { $0.id != first?.id }
        guard !songs.isEmpty else { return false }
        seen.formUnion(songs.map(\.id))
        player?.play(songs, context: .init(kind: .radio, name: name))
        return true
    }

    /// The queue ended: keep playing with songs like the last ones (autoplay).
    func continueAfter(_ queue: [Song]) async -> [Song] {
        seeds = Array(queue.suffix(5))
        genre = nil
        noSimilar = false
        seen = Set(queue.map(\.id))
        let songs = await candidates(count: 15)
        seen.formUnion(songs.map(\.id))
        return songs
    }

    func listened(_ song: Song) { remember(song) }

    func liked(_ song: Song) {
        // A heart counts more than just listening: it may be picked as the starting point twice as often
        remember(song)
        remember(song, again: true)
    }

    func skipped(_ song: Song) {
        if let artist = song.artist { skips[artist, default: 0] += 1 }
        seeds.removeAll { $0.id == song.id }
    }

    /// Called on every song change of a radio: tops up the queue before it runs out.
    func refillIfNeeded() {
        guard let player, !filling, player.upNext.count < 5 else { return }
        filling = true
        Task {
            defer { filling = false }
            let songs = await candidates(count: 15)
            guard player.context?.kind == .radio, !songs.isEmpty else { return }
            seen.formUnion(songs.map(\.id))
            player.enqueue(songs)
        }
    }

    // MARK: Picking songs

    private func remember(_ song: Song, again: Bool = false) {
        if !again { seeds.removeAll { $0.id == song.id } }
        seeds.append(song)
        if seeds.count > 20 { seeds.removeFirst(seeds.count - 20) }
    }

    /// Similar songs to one of the recent favorites, or – without Last.fm, and for a genre radio – songs of the same genre.
    private func candidates(count: Int) async -> [Song] {
        guard let client = player?.app?.client else { return [] }
        let recent = seeds.isEmpty ? (player?.current.map { [$0] } ?? []) : Array(seeds.suffix(5))
        let seed = recent.randomElement()
        var pool: [Song] = []
        if genre == nil, !noSimilar, let seed {
            let similar = await client.similarSongs(seed.id)
            noSimilar = similar.isEmpty
            pool = fresh(similar)
        }
        if pool.count < count {
            let g = genre ?? seed?.genre
            pool += fresh((try? await client.randomSongs(60, genre: g)) ?? [])
            if pool.count < count, g != nil, genre == nil { pool += fresh((try? await client.randomSongs(40)) ?? []) }
        }
        // Skipped artists to the back (or out), and at most two songs per artist in one go
        var perArtist: [String: Int] = [:]
        var picked: [Song] = []
        var ids: Set<String> = []
        for song in pool.shuffled().sorted(by: { skipCount($0) < skipCount($1) }) where skipCount(song) < 2 && !ids.contains(song.id) {
            let artist = song.artist ?? ""
            guard perArtist[artist, default: 0] < 2 else { continue }
            perArtist[artist, default: 0] += 1
            ids.insert(song.id)
            picked.append(song)
            if picked.count == count { break }
        }
        return spreadOut(picked)
    }

    private func skipCount(_ song: Song) -> Int { song.artist.flatMap { skips[$0] } ?? 0 }

    private func fresh(_ songs: [Song]) -> [Song] {
        let queued = Set(player?.queue.map(\.id) ?? [])
        return songs.filter { !seen.contains($0.id) && !queued.contains($0.id) }
    }

    /// Two songs of the same artist shouldn't follow each other.
    private func spreadOut(_ songs: [Song]) -> [Song] {
        var rest = songs, out: [Song] = []
        while !rest.isEmpty {
            let i = rest.firstIndex { $0.artist != out.last?.artist } ?? 0
            out.append(rest.remove(at: i))
        }
        return out
    }
}
