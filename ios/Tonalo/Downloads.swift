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
    private(set) var batch: Set<String> = []

    /// How far the current run is, 0…1; nil when nothing is loading (or it waits for Wi-Fi).
    var batchProgress: Double? {
        guard !index.queued.isEmpty, !waitingForWiFi, !batch.isEmpty else { return nil }
        let done = batch.reduce(0.0) { sum, id in
            sum + (index.queued[id] != nil ? progress[id] ?? 0 : 1)
        }
        return done / Double(batch.count)
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

    private static func prepareRoot() {
        var url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Index

    func reload() {
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
        batch = Set(idx.queued.keys)
        // iOS may have dropped transfers in the meantime – don't leave those stuck as "downloading"
        DownloadSession.shared.session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription?.components(separatedBy: "|").dropFirst().first })
            Task { @MainActor in
                let stale = self.index.queued.keys.filter { !running.contains($0) }
                guard !stale.isEmpty else { return }
                for id in stale { self.failed[id] = self.index.queued.removeValue(forKey: id) }
                self.save()
                self.batchEnded()
            }
        }
    }

    /// Applies a change to another account's index on disk (a download finished while someone else was active).
    private func updateOther(_ account: String, _ change: (inout DownloadIndex) -> Void) {
        let file = Self.folder(account).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: file), var idx = try? JSONDecoder().decode(DownloadIndex.self, from: data) else { return }
        change(&idx)
        try? JSONEncoder().encode(idx).write(to: file, options: .atomic)
    }

    private func save() {
        guard let key = accountKey else { return }
        Self.prepareRoot()
        try? FileManager.default.createDirectory(at: Self.folder(key), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: Self.folder(key).appendingPathComponent("index.json"), options: .atomic)
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

    private func saveLyrics(_ songId: String, client: SubsonicClient, account: String) {
        let dest = Self.lyricsFile(account: account, id: songId)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        Task {
            guard let lyrics = await client.lyrics(songId), let data = try? JSONEncoder().encode(lyrics) else { return }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
    }

    func localCover(_ id: String?) -> URL? {
        guard let key = accountKey, let id, !id.isEmpty else { return nil }
        let url = Self.coverFile(account: key, id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var totalBytes: Int64 { index.songs.values.reduce(0) { $0 + $1.size } }
    var downloadedSongs: [Song] { index.songs.values.map(\.song).sorted { ($0.artist ?? "", $0.album ?? "", $0.track ?? 0) < ($1.artist ?? "", $1.album ?? "", $1.track ?? 0) } }

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
        guard let client = app?.client, let key = accountKey else { return }
        Self.prepareRoot()
        for song in songs where index.songs[song.id] == nil && index.queued[song.id] == nil {
            guard let url = client.downloadURL(song, quality: quality) else { continue }
            let ext = quality.resolved(for: song).fileExtension(for: song)
            var req = client.request(url)
            req.timeoutInterval = 120
            req.allowsCellularAccess = allowCellular
            let task = DownloadSession.shared.session.downloadTask(with: req)
            task.taskDescription = [key, song.id, ext].joined(separator: "|")
            index.queued[song.id] = song
            batch.insert(song.id)
            failed.removeValue(forKey: song.id)
            progress[song.id] = 0
            task.resume()
            saveCover(song.coverArt ?? song.albumId, client: client, account: key)
            saveLyrics(song.id, client: client, account: key)
        }
        save()
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
        guard let id, let client, let account, localCover(id) == nil, let url = client.coverURL(id, size: 600) else { return }
        let dest = Self.coverFile(account: account, id: id)
        Task.detached {
            var req = URLRequest(url: url)
            for (k, v) in client.headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, resp) = try? await ServerSession.shared.fetch(req, retry: nil), // see ImageLoader
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
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
        cancel(songs.map(\.id).filter { !index.loose.contains($0) && !neededByAlbums($0, except: album) && !neededByPlaylists($0, except: playlist) })
        if !songs.contains(where: { isDownloaded($0.id) }) {
            if let album { index.albums.removeValue(forKey: album) }
            if let playlist { index.playlists.removeValue(forKey: playlist) }
            save()
        }
    }

    private func cancelTasks(_ ids: Set<String>, then: (@Sendable () -> Void)? = nil) {
        let account = accountKey
        DownloadSession.shared.session.getAllTasks { tasks in
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
        DownloadSession.shared.session.getAllTasks { tasks in
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
        for id in songIds {
            if let d = index.songs.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: Self.songFile(account: key, name: d.file))
                try? FileManager.default.removeItem(at: Self.lyricsFile(account: key, id: id))
            }
            index.queued.removeValue(forKey: id)
            index.loose.remove(id)
            progress.removeValue(forKey: id)
            batch.remove(id)
        }
        if index.queued.isEmpty { batch = [] }
        save()
    }

    /// Removes songs downloaded on their own (the favorites), but keeps those a downloaded album or playlist needs.
    func removeLoose(_ songIds: [String]) {
        index.loose.subtract(songIds)
        remove(songIds.filter { !neededByAlbums($0) && !neededByPlaylists($0) })
    }

    /// Removes an album's songs, except those that a downloaded playlist or a single download still needs.
    func removeAlbum(_ id: String) {
        guard let album = index.albums.removeValue(forKey: id) else { return }
        remove((album.song ?? []).map(\.id).filter { !index.loose.contains($0) && !neededByAlbums($0) && !neededByPlaylists($0) })
    }

    func removePlaylist(_ id: String) {
        guard let pl = index.playlists.removeValue(forKey: id) else { return }
        remove((pl.entry ?? []).map(\.id).filter { !index.loose.contains($0) && !neededByAlbums($0) && !neededByPlaylists($0) })
    }

    private func neededByPlaylists(_ id: String, except: String? = nil) -> Bool {
        index.playlists.contains { $0.key != except && ($0.value.entry ?? []).contains { $0.id == id } }
    }
    private func neededByAlbums(_ id: String, except: String? = nil) -> Bool {
        index.albums.contains { $0.key != except && ($0.value.song ?? []).contains { $0.id == id } }
    }

    func removeAll() {
        cancelTasks(Set(index.queued.keys))
        if let key = accountKey { try? FileManager.default.removeItem(at: Self.folder(key)) }
        index = DownloadIndex(); progress = [:]; failed = [:]; batch = []
    }

    nonisolated static func deleteAccount(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id.uuidString))
    }

    // MARK: Session callbacks

    /// `expected` is -1 when the server converts the file on the fly and doesn't send a size;
    /// the size is then estimated from the song length and the chosen bitrate.
    func didProgress(account: String, songId: String, written: Int64, expected: Int64) {
        guard account == accountKey else { return }
        bytes[songId] = written
        if expected > 0 {
            progress[songId] = Double(written) / Double(expected)
        } else if let song = index.queued[songId], let duration = song.duration, duration > 0 {
            let q = quality.resolved(for: song)
            let rate = q.format != nil ? q.bitRate : (song.bitRate ?? 900)
            progress[songId] = min(0.97, Double(written) / Double(duration * rate * 125))
        }
    }

    func didFinish(account: String, songId: String, file: String, size: Int64) {
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
        } else if index.songs[songId] == nil {
            // Cancelled while the last bytes were arriving: don't leave an orphaned file behind
            try? FileManager.default.removeItem(at: Self.songFile(account: account, name: file))
        }
        progress.removeValue(forKey: songId)
        bytes.removeValue(forKey: songId)
        save()
        batchEnded()
    }

    func didFail(account: String, songId: String) {
        guard account == accountKey else { updateOther(account) { $0.queued.removeValue(forKey: songId) }; return }
        failed[songId] = index.queued.removeValue(forKey: songId)
        progress.removeValue(forKey: songId)
        bytes.removeValue(forKey: songId)
        save()
        batchEnded()
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

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "io.github.wzkiie.tonalo.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 3
        config.httpCookieStorage = nil // no proxy cookies on disk, see ServerSession
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

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
            Task { @MainActor in DownloadStore.shared.didFail(account: info.account, songId: info.songId) }
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
            Task { @MainActor in DownloadStore.shared.didFinish(account: info.account, songId: info.songId, file: name, size: size) }
        } catch {
            Task { @MainActor in DownloadStore.shared.didFail(account: info.account, songId: info.songId) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = parse(downloadTask) else { return }
        Task { @MainActor in
            DownloadStore.shared.didProgress(account: info.account, songId: info.songId,
                                             written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = parse(task), (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in DownloadStore.shared.didFail(account: info.account, songId: info.songId) }
    }

    /// Custom headers (secrets) must not follow a redirect to another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(ServerSession.allowsRedirect(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
