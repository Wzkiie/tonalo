import Foundation
import Observation

/// One song saved for offline use.
struct DownloadedSong: Codable {
    var song: Song
    var file: String
    var size: Int64
}

/// Everything downloaded for one account. Albums and playlists are kept so they can be opened offline.
struct DownloadIndex: Codable {
    var songs: [String: DownloadedSong] = [:]
    var queued: [String: Song] = [:]
    var albums: [String: Album] = [:]
    var playlists: [String: Playlist] = [:]
    /// Songs downloaded on their own (from a song's menu or the favorites), so removing an album keeps them.
    var loose: Set<String> = []

    init() {}

    /// Missing parts are fine: an index written by an older version must never come back empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = try c.decodeIfPresent([String: DownloadedSong].self, forKey: .songs) ?? [:]
        queued = (try? c.decodeIfPresent([String: Song].self, forKey: .queued)) ?? [:]
        albums = (try? c.decodeIfPresent([String: Album].self, forKey: .albums)) ?? [:]
        playlists = (try? c.decodeIfPresent([String: Playlist].self, forKey: .playlists)) ?? [:]
        loose = (try? c.decodeIfPresent(Set<String>.self, forKey: .loose)) ?? []
    }
}

enum DownloadState: Equatable {
    case none
    case downloading(done: Int, total: Int)
    case partial(done: Int, total: Int)
    case complete
}

/// Offline downloads. Files live in Application Support (excluded from iCloud backup, as Apple requires
/// for content that can be downloaded again), one folder per account.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()
    @ObservationIgnored weak var app: AppModel?

    private(set) var index = DownloadIndex()
    private(set) var progress: [String: Double] = [:]
    /// Songs whose download failed, so they can be retried in one go
    private(set) var failed: [String: Song] = [:]
    /// Bytes received so far, for the "downloading" list
    private(set) var bytes: [String: Int64] = [:]
    /// The songs of the current run – all downloads started since nothing was loading – for the bar at the top.
    /// Kept across launches, so "10 of 40" doesn't turn into "0 of 30" when the app was closed in between.
    private(set) var batch: Set<String> = [] {
        didSet { if let key = accountKey { UserDefaults.standard.set(Array(batch), forKey: "downloadBatch." + key) } }
    }

    /// How far the current run is, 0…1; nil when nothing is loading (or it waits for Wi-Fi).
    var batchProgress: Double? {
        guard !index.queued.isEmpty, !waitingForWiFi, !batch.isEmpty else { return nil }
        let done = batch.reduce(0.0) { sum, id in
            sum + (index.queued[id] != nil ? progress[id] ?? 0 : 1)
        }
        return done / Double(batch.count)
    }

    /// Finished and total songs of the current run, for the label next to the progress.
    var batchCounts: (done: Int, total: Int) {
        (batch.filter { index.queued[$0] == nil }.count, batch.count)
    }

    var quality = AudioQuality.stored("quality.download", legacy: "downloadBitRate", default: .aac256) {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality.download") }
    }
    var allowCellular: Bool = UserDefaults.standard.bool(forKey: "downloadCellular") {
        didSet {
            UserDefaults.standard.set(allowCellular, forKey: "downloadCellular")
            // Waiting transfers keep the setting they were started with, so start them again
            if allowCellular != oldValue { requeue() }
        }
    }

    /// True while transfers sit idle because only mobile data is available.
    var waitingForWiFi: Bool { !index.queued.isEmpty && !allowCellular && app?.cellularOnly == true }

    private var accountKey: String? { app?.currentId?.uuidString }

    /// Files are written and deleted here, one after the other, so a long list never holds up the screen.
    private static let disk = DispatchQueue(label: "io.github.wzkiie.tonalo.downloads.disk", qos: .utility)
    /// The account whose index has changes that aren't on disk yet
    @ObservationIgnored private var unsaved: String?
    @ObservationIgnored private var saveSoon: Task<Void, Never>?
    @ObservationIgnored private var sortedSongs: [Song]?

    /// Covers and lyrics of finished songs, a few at a time: they share the connections to the server with
    /// everything the app shows, so hundreds at once would leave pages waiting for seconds.
    @ObservationIgnored private var extras: [(key: String, fetch: @Sendable () async -> Void)] = []
    @ObservationIgnored private var extraKeys: Set<String> = []
    @ObservationIgnored private var extrasRunning = 0

    // MARK: Paths

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
    nonisolated static func folder(_ account: String) -> URL { root.appendingPathComponent(account, isDirectory: true) }
    nonisolated static func songFile(account: String, name: String) -> URL {
        folder(account).appendingPathComponent("songs", isDirectory: true).appendingPathComponent(name)
    }
    nonisolated static func lyricsFile(account: String, id: String) -> URL {
        folder(account).appendingPathComponent("lyrics", isDirectory: true).appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }
    nonisolated static func coverFile(account: String, id: String) -> URL {
        folder(account).appendingPathComponent("covers", isDirectory: true).appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"))
    }

    nonisolated private static func prepareRoot() {
        var url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Index

    func reload() {
        saveNow(wait: true) // what's left of the account before
        Self.disk.sync {}
        extras = []; extraKeys = []; sortedSongs = nil
        let storedBatch = accountKey.flatMap { UserDefaults.standard.stringArray(forKey: "downloadBatch." + $0) } ?? []
        progress = [:]; failed = [:]; batch = []
        let file = accountKey.map { Self.folder($0).appendingPathComponent("index.json") }
        guard let file, let data = try? Data(contentsOf: file) else { index = DownloadIndex(); return }
        guard let idx = try? JSONDecoder().decode(DownloadIndex.self, from: data) else {
            // Unreadable (shouldn't happen): keep it aside instead of overwriting it with an empty list on the next save
            let aside = file.deletingLastPathComponent().appendingPathComponent("index-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            index = DownloadIndex()
            return
        }
        index = idx
        // The run goes on with what is still loading, plus what of it already finished
        batch = idx.queued.isEmpty ? [] : Set(idx.queued.keys).union(storedBatch.filter { idx.songs[$0] != nil })
        // iOS may have dropped transfers in the meantime – don't leave those stuck as "downloading"
        DownloadSession.shared.allTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription?.components(separatedBy: "|").dropFirst().first })
            Task { @MainActor in
                let stale = self.index.queued.keys.filter { !running.contains($0) }
                guard !stale.isEmpty else { return }
                self.settle(stale)
                self.save()
                self.batchEnded()
            }
        }
    }

    /// Transfers iOS no longer knows of. A file means it arrived just before the app ended, with the index
    /// not written yet, so the song is simply there. Without one it has to be tried again.
    private func settle(_ stale: [String]) {
        guard let key = accountKey else { return }
        let folder = Self.songFile(account: key, name: "x").deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let byName = Dictionary(files.map { ($0.deletingPathExtension().lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        for id in stale {
            guard let song = index.queued.removeValue(forKey: id) else { continue }
            if let file = byName[id.replacingOccurrences(of: "/", with: "_")] {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                index.songs[id] = DownloadedSong(song: song, file: file.lastPathComponent, size: Int64(size))
                sortedSongs = nil
                addExtras(for: song)
            } else {
                failed[id] = song
            }
        }
    }

    /// Applies a change to another account's index on disk (a download finished while someone else was active).
    private func updateOther(_ account: String, _ change: @escaping @Sendable (inout DownloadIndex) -> Void) {
        let file = Self.folder(account).appendingPathComponent("index.json")
        Self.disk.async {
            guard let data = try? Data(contentsOf: file), var idx = try? JSONDecoder().decode(DownloadIndex.self, from: data) else { return }
            change(&idx)
            try? JSONEncoder().encode(idx).write(to: file, options: .atomic)
        }
    }

    /// Writes the index within a second. It holds every downloaded song, so writing it after each one
    /// would get slower with every song. iOS can end the app at any time: `saveNow` where that matters.
    private func save() {
        unsaved = accountKey ?? unsaved
        guard saveSoon == nil else { return }
        saveSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow(wait: Bool = false) {
        saveSoon?.cancel()
        saveSoon = nil
        guard let key = unsaved else { return }
        unsaved = nil
        let snapshot = index
        let write: @Sendable () -> Void = {
            Self.prepareRoot()
            try? FileManager.default.createDirectory(at: Self.folder(key), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: Self.folder(key).appendingPathComponent("index.json"), options: .atomic)
        }
        if wait { Self.disk.sync(execute: write) } else { Self.disk.async(execute: write) }
    }


    func isDownloaded(_ songId: String) -> Bool { index.songs[songId] != nil }

    /// "FLAC", "AAC 256" … for a downloaded song, read from the saved file's extension.
    func qualityLabel(_ song: Song) -> String? {
        guard let file = index.songs[song.id]?.file else { return nil }
        let ext = (file as NSString).pathExtension.uppercased()
        return ext.isEmpty ? nil : ext
    }

    func localURL(_ songId: String) -> URL? {
        guard let key = accountKey, let d = index.songs[songId] else { return nil }
        let url = Self.songFile(account: key, name: d.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Lyrics saved with a downloaded song, so they also show without network.
    func localLyrics(_ songId: String) -> Lyrics? {
        guard let key = accountKey, let data = try? Data(contentsOf: Self.lyricsFile(account: key, id: songId)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    nonisolated private static func fetchLyrics(_ songId: String, client: SubsonicClient, account: String) async {
        let dest = lyricsFile(account: account, id: songId)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let lyrics = await client.lyrics(songId), let data = try? JSONEncoder().encode(lyrics) else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
    }

    func localCover(_ id: String?) -> URL? {
        guard let key = accountKey, let id, !id.isEmpty else { return nil }
        let url = Self.coverFile(account: key, id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalBytes: Int64 { index.songs.values.reduce(0) { $0 + $1.size } }
    var downloadedSongs: [Song] {
        let songs = index.songs
        if let sortedSongs { return sortedSongs }
        let sorted = songs.values.map(\.song).sorted { ($0.artist ?? "", $0.album ?? "", $0.track ?? 0) < ($1.artist ?? "", $1.album ?? "", $1.track ?? 0) }
        sortedSongs = sorted
        return sorted
    }

    func state(_ songs: [Song]) -> DownloadState {
        guard !songs.isEmpty else { return .none }
        let done = songs.filter { isDownloaded($0.id) }.count
        if songs.contains(where: { index.queued[$0.id] != nil }) { return .downloading(done: done, total: songs.count) }
        if done == songs.count { return .complete }
        return done == 0 ? .none : .partial(done: done, total: songs.count)
    }

    // MARK: Downloading

    /// Songs on their own – from a song's menu or the favorites. They stay when an album or playlist with them is removed.
    func download(_ songs: [Song]) {
        index.loose.formUnion(songs.map(\.id))
        start(songs)
    }

    private func start(_ songs: [Song]) {
        guard let client = app?.client, let key = accountKey else { save(); return }
        var transfers: [DownloadSession.Transfer] = []
        var started: Set<String> = []
        for song in songs where index.songs[song.id] == nil && index.queued[song.id] == nil && !started.contains(song.id) {
            guard let url = client.downloadURL(song, quality: quality) else { continue }
            let ext = quality.resolved(for: song).fileExtension(for: song)
            var req = client.request(url)
            req.timeoutInterval = 120
            req.allowsCellularAccess = allowCellular
            transfers.append(.init(request: req, description: [key, song.id, ext].joined(separator: "|")))
            index.queued[song.id] = song
            started.insert(song.id)
            failed.removeValue(forKey: song.id)
            progress[song.id] = 0
        }
        guard !transfers.isEmpty else { save(); return } // e.g. opening a playlist that is already downloaded
        batch.formUnion(started)
        DownloadSession.shared.start(transfers)
        // Right away: transfers that finish after a restart need to find their song in the index
        unsaved = key
        saveNow()
    }

    func downloadAlbum(_ album: Album) {
        index.albums[album.id] = album
        saveCover(album.coverArt ?? album.id, client: app?.client, account: accountKey)
        start(album.song ?? [])
    }

    func downloadPlaylist(_ playlist: Playlist) {
        index.playlists[playlist.id] = playlist
        saveCover(playlist.coverArt ?? playlist.id, client: app?.client, account: accountKey)
        start(playlist.entry ?? [])
    }

    /// Cover art is stored next to the songs so downloaded music looks right offline.
    private func saveCover(_ id: String?, client: SubsonicClient?, account: String?) {
        guard let id, let client, let account, localCover(id) == nil else { return }
        Task.detached { await Self.fetchCover(id, client: client, account: account) }
    }

    nonisolated private static func fetchCover(_ id: String, client: SubsonicClient, account: String) async {
        guard let url = client.coverURL(id, size: 600) else { return }
        let dest = coverFile(account: account, id: id)
        var req = URLRequest(url: url)
        for (k, v) in client.headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await ServerSession.shared.fetch(req, retry: nil), // see ImageLoader
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
    }

    private func addExtras(for song: Song) {
        guard let client = app?.client, let key = accountKey else { return }
        if let cover = song.coverArt ?? song.albumId, !cover.isEmpty, localCover(cover) == nil, extraKeys.insert("c" + cover).inserted {
            extras.insert(("c" + cover, { await Self.fetchCover(cover, client: client, account: key) }), at: 0) // seen right away, and only a few
        }
        let id = song.id
        if extraKeys.insert("l" + id).inserted {
            extras.append(("l" + id, { await Self.fetchLyrics(id, client: client, account: key) }))
        }
        runExtras()
    }

    private func runExtras() {
        while extrasRunning < 2, !extras.isEmpty {
            let next = extras.removeFirst()
            extrasRunning += 1
            Task.detached(priority: .utility) { [weak self] in
                await next.fetch()
                await self?.extraFinished(next.key)
            }
        }
    }

    private func extraFinished(_ key: String) {
        extrasRunning -= 1
        extraKeys.remove(key)
        runExtras()
    }

    // MARK: Cancelling

    /// Stops transfers of this account that haven't finished yet. Already downloaded songs stay.
    func cancel(_ songIds: [String]) {
        let ids = Set(songIds.filter { index.queued[$0] != nil })
        guard !ids.isEmpty else { return }
        cancelTasks(ids)
        for id in ids { index.queued.removeValue(forKey: id); progress.removeValue(forKey: id); bytes.removeValue(forKey: id) }
        batch.subtract(ids)
        if index.queued.isEmpty { batch = [] }
        save()
    }

    func cancelAll() { cancel(Array(index.queued.keys)) }

    func retryFailed() { start(Array(failed.values)) }

    /// Cancels a collection's pending songs – not those another album, playlist or single download still waits for –
    /// and forgets the collection if nothing of it is downloaded yet.
    func cancelCollection(_ songs: [Song], album: String? = nil, playlist: String? = nil) {
        let needed = neededSongs(exceptAlbum: album, exceptPlaylist: playlist)
        cancel(songs.map(\.id).filter { !needed.contains($0) })
        if !songs.contains(where: { isDownloaded($0.id) }) {
            if let album { index.albums.removeValue(forKey: album) }
            if let playlist { index.playlists.removeValue(forKey: playlist) }
            save()
        }
    }

    private func cancelTasks(_ ids: Set<String>, then: (@Sendable () -> Void)? = nil) {
        let account = accountKey
        DownloadSession.shared.allTasks { tasks in
            for t in tasks {
                let parts = (t.taskDescription ?? "").components(separatedBy: "|")
                if parts.count == 3, parts[0] == account, ids.contains(parts[1]) { t.cancel() }
            }
            then?()
        }
    }

    /// Starts the unfinished downloads that talk to `host` again – they now get the current address.
    func restartTasks(onHost host: String) {
        let account = accountKey
        DownloadSession.shared.allTasks { tasks in
            let ids = Set(tasks.compactMap { t -> String? in
                let parts = (t.taskDescription ?? "").components(separatedBy: "|")
                guard parts.count == 3, parts[0] == account, t.originalRequest?.url?.host == host else { return nil }
                return parts[1]
            })
            guard !ids.isEmpty else { return }
            Task { @MainActor in
                let songs = ids.compactMap { self.index.queued[$0] }
                self.cancelTasks(ids) {
                    Task { @MainActor in
                        for s in songs { self.index.queued.removeValue(forKey: s.id) }
                        self.start(songs)
                    }
                }
            }
        }
    }

    /// Lyrics fetched while playing a song that was downloaded before lyrics were saved along.
    func storeLyrics(_ lyrics: Lyrics, for songId: String) {
        guard let key = accountKey, isDownloaded(songId), let data = try? JSONEncoder().encode(lyrics) else { return }
        let dest = Self.lyricsFile(account: key, id: songId)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dest, options: .atomic)
    }

    /// Starts unfinished downloads again with the current settings (e.g. after allowing cellular).
    func requeue() {
        let songs = Array(index.queued.values)
        guard !songs.isEmpty else { return }
        cancelTasks(Set(songs.map(\.id))) {
            Task { @MainActor in
                for s in songs { self.index.queued.removeValue(forKey: s.id) }
                self.start(songs)
            }
        }
    }

    // MARK: Removing

    func remove(_ songIds: [String]) {
        guard let key = accountKey else { return }
        cancelTasks(Set(songIds.filter { index.queued[$0] != nil }))
        var files: [URL] = []
        for id in songIds {
            if let d = index.songs.removeValue(forKey: id) {
                files.append(Self.songFile(account: key, name: d.file))
                files.append(Self.lyricsFile(account: key, id: id))
            }
            index.queued.removeValue(forKey: id)
            index.loose.remove(id)
            progress.removeValue(forKey: id)
        }
        sortedSongs = nil
        Self.disk.async { for file in files { try? FileManager.default.removeItem(at: file) } }
        batch.subtract(songIds)
        if index.queued.isEmpty { batch = [] }
        save()
    }

    /// Removes songs downloaded on their own (the favorites), but keeps those a downloaded album or playlist needs.
    func removeLoose(_ songIds: [String]) {
        index.loose.subtract(songIds)
        let needed = neededSongs()
        remove(songIds.filter { !needed.contains($0) })
    }

    /// Removes an album's songs, except those that a downloaded playlist or a single download still needs.
    func removeAlbum(_ id: String) {
        guard let album = index.albums.removeValue(forKey: id) else { return }
        let needed = neededSongs()
        remove((album.song ?? []).map(\.id).filter { !needed.contains($0) })
    }

    func removePlaylist(_ id: String) {
        guard let pl = index.playlists.removeValue(forKey: id) else { return }
        let needed = neededSongs()
        remove((pl.entry ?? []).map(\.id).filter { !needed.contains($0) })
    }

    /// What still has to stay: single downloads and the songs of downloaded albums and playlists.
    private func neededSongs(exceptAlbum: String? = nil, exceptPlaylist: String? = nil) -> Set<String> {
        var needed = index.loose
        for (id, album) in index.albums where id != exceptAlbum { needed.formUnion((album.song ?? []).map(\.id)) }
        for (id, list) in index.playlists where id != exceptPlaylist { needed.formUnion((list.entry ?? []).map(\.id)) }
        return needed
    }

    func removeAll() {
        cancelTasks(Set(index.queued.keys))
        if let key = accountKey { Self.forget(account: key) }
        index = DownloadIndex(); progress = [:]; failed = [:]; batch = []; sortedSongs = nil
    }

    /// Nothing unsaved may bring back the folder afterwards.
    private static func forget(account: String) {
        if shared.unsaved == account {
            shared.unsaved = nil
            shared.saveSoon?.cancel()
            shared.saveSoon = nil
        }
        let folder = folder(account)
        disk.async { try? FileManager.default.removeItem(at: folder) }
    }

    static func deleteAccount(_ id: UUID) { forget(account: id.uuidString) }

    // MARK: Session callbacks

    /// What the transfers reported since the last time, taken in together so the screen only updates once.
    func apply(_ events: DownloadSession.Events) {
        var newProgress = progress, newBytes = bytes
        for (songId, p) in events.progress where p.account == accountKey && index.queued[songId] != nil {
            newBytes[songId] = p.written
            // -1 when the server converts the file on the fly and doesn't send a size:
            // the size is then estimated from the song length and the chosen bitrate.
            if p.expected > 0 {
                newProgress[songId] = Double(p.written) / Double(p.expected)
            } else if let song = index.queued[songId], let duration = song.duration, duration > 0 {
                let q = quality.resolved(for: song)
                let rate = q.format != nil ? q.bitRate : (song.bitRate ?? 900)
                newProgress[songId] = min(0.97, Double(p.written) / Double(duration * rate * 125))
            }
        }
        for f in events.finished { didFinish(account: f.account, songId: f.songId, file: f.file, size: f.size, progress: &newProgress, bytes: &newBytes) }
        for f in events.failed { didFail(account: f.account, songId: f.songId, progress: &newProgress, bytes: &newBytes) }
        if !events.progress.isEmpty || !events.finished.isEmpty || !events.failed.isEmpty {
            progress = newProgress
            bytes = newBytes
        }
        guard !events.finished.isEmpty || !events.failed.isEmpty else { return }
        save()
        if index.queued.isEmpty { saveNow() }
        batchEnded()
    }

    private func didFinish(account: String, songId: String, file: String, size: Int64, progress: inout [String: Double], bytes: inout [String: Int64]) {
        guard account == accountKey else {
            updateOther(account) { idx in
                if let song = idx.queued.removeValue(forKey: songId) { idx.songs[songId] = DownloadedSong(song: song, file: file, size: size) }
                else if idx.songs[songId] == nil { try? FileManager.default.removeItem(at: Self.songFile(account: account, name: file)) }
            }
            return
        }
        // Also when it was marked failed meanwhile: iOS finished it in the background before telling us
        if let song = index.queued.removeValue(forKey: songId) ?? failed.removeValue(forKey: songId) {
            index.songs[songId] = DownloadedSong(song: song, file: file, size: size)
            sortedSongs = nil
            addExtras(for: song)
        } else if index.songs[songId] == nil {
            // Cancelled while the last bytes were arriving: don't leave an orphaned file behind
            try? FileManager.default.removeItem(at: Self.songFile(account: account, name: file))
        }
        progress.removeValue(forKey: songId)
        bytes.removeValue(forKey: songId)
    }

    private func didFail(account: String, songId: String, progress: inout [String: Double], bytes: inout [String: Int64]) {
        guard account == accountKey else { updateOther(account) { $0.queued.removeValue(forKey: songId) }; return }
        failed[songId] = index.queued.removeValue(forKey: songId)
        progress.removeValue(forKey: songId)
        bytes.removeValue(forKey: songId)
    }

    /// The last song of a run is through: say so, since the page that started it may be long gone.
    private func batchEnded() {
        guard index.queued.isEmpty, !batch.isEmpty else { return }
        let failures = batch.filter { failed[$0] != nil }.count
        batch = []
        app?.notify(failures == 0 ? String(localized: "Downloads finished")
                                  : String(localized: "Downloads finished – \(failures) failed"))
    }
}

/// Background URLSession: downloads continue while the app is suspended or closed.
final class DownloadSession: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadSession()
    var backgroundCompletion: (() -> Void)?

    /// One transfer to hand to iOS.
    struct Transfer: Sendable {
        let request: URLRequest
        let description: String
    }

    /// What happened since the store last looked.
    struct Events: Sendable {
        var progress: [String: (account: String, written: Int64, expected: Int64)] = [:]
        var finished: [(account: String, songId: String, file: String, size: Int64)] = []
        var failed: [(account: String, songId: String)] = []
    }

    private(set) var session: URLSession!
    /// Each new transfer is a trip to the system's download service, which adds up on long playlists. Starting,
    /// listing and cancelling all go through here, so a cancel can't overtake the start it belongs to.
    private let tasks = DispatchQueue(label: "io.github.wzkiie.tonalo.downloads.tasks", qos: .userInitiated)
    private let lock = NSLock()
    private var events = Events()
    private var deliverySoon = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "io.github.wzkiie.tonalo.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // A few songs at once: the server converts each one separately (AAC, Opus …), so more in parallel
        // uses its other cores. More than that only splits the same bandwidth.
        config.httpMaximumConnectionsPerHost = 5
        config.httpCookieStorage = nil // no proxy cookies on disk, see ServerSession
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start(_ transfers: [Transfer]) {
        tasks.async { [session] in
            for transfer in transfers {
                let task = session!.downloadTask(with: transfer.request)
                task.taskDescription = transfer.description
                task.resume()
            }
        }
    }

    func allTasks(_ completion: @escaping @Sendable ([URLSessionTask]) -> Void) {
        tasks.async { [session] in session!.getAllTasks(completionHandler: completion) }
    }

    /// Transfers report many times a second, and a list can finish several songs at once:
    /// the screen gets it all together, a few times a second.
    private func report(_ change: (inout Events) -> Void) {
        lock.lock()
        change(&events)
        let schedule = !deliverySoon
        deliverySoon = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { self.deliver() } }
    }

    @MainActor private func deliver() {
        lock.lock()
        let now = events
        events = Events()
        deliverySoon = false
        lock.unlock()
        DownloadStore.shared.apply(now)
    }

    private func parse(_ task: URLSessionTask) -> (account: String, songId: String, ext: String)? {
        let parts = (task.taskDescription ?? "").components(separatedBy: "|")
        return parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = parse(downloadTask) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        // A JSON/HTML answer means an error page (e.g. Subsonic error or a Cloudflare login page), not audio
        // OGG instead of the requested MP3/AAC means the server couldn't convert and fell back to Opus
        let wrongFormat = ["aac", "mp3"].contains(info.ext) && type.contains("ogg")
        guard http?.statusCode == 200, !type.contains("json"), !type.contains("html"), !wrongFormat else {
            reportFailure(info)
            return
        }
        // The file has to be moved before this method returns, otherwise iOS deletes it
        let name = info.songId.replacingOccurrences(of: "/", with: "_") + "." + info.ext
        let dest = DownloadStore.songFile(account: info.account, name: name)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            let size = downloadTask.countOfBytesReceived
            report {
                $0.progress[info.songId] = nil
                $0.finished.append((info.account, info.songId, name, size))
            }
        } catch {
            reportFailure(info)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = parse(downloadTask) else { return }
        report { $0.progress[info.songId] = (info.account, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = parse(task), (error as? URLError)?.code != .cancelled else { return }
        reportFailure(info)
    }

    private func reportFailure(_ info: (account: String, songId: String, ext: String)) {
        report {
            $0.progress[info.songId] = nil
            $0.failed.append((info.account, info.songId))
        }
    }

    /// Custom headers (secrets) must not follow a redirect to another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(ServerSession.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // iOS suspends the app after the completion: everything has to be on disk by then
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.deliver()
                DownloadStore.shared.saveNow(wait: true)
            }
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
