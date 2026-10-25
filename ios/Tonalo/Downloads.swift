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
    private(set) var failed: Set<String> = []

    /// kbit/s for downloads, 0 = original file
    var quality: Int = UserDefaults.standard.object(forKey: "downloadBitRate") as? Int ?? 320 {
        didSet { UserDefaults.standard.set(quality, forKey: "downloadBitRate") }
    }
    var allowCellular: Bool = UserDefaults.standard.bool(forKey: "downloadCellular") {
        didSet { UserDefaults.standard.set(allowCellular, forKey: "downloadCellular") }
    }

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
        progress = [:]; failed = []
        guard let key = accountKey, let data = try? Data(contentsOf: Self.folder(key).appendingPathComponent("index.json")),
              let idx = try? JSONDecoder().decode(DownloadIndex.self, from: data) else { index = DownloadIndex(); return }
        index = idx
        // iOS may have dropped transfers in the meantime – don't leave those stuck as "downloading"
        DownloadSession.shared.session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription?.components(separatedBy: "|").dropFirst().first })
            Task { @MainActor in
                let stale = self.index.queued.keys.filter { !running.contains($0) }
                guard !stale.isEmpty else { return }
                for id in stale { self.index.queued.removeValue(forKey: id); self.failed.insert(id) }
                self.save()
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

    func localURL(_ songId: String) -> URL? {
        guard let key = accountKey, let d = index.songs[songId] else { return nil }
        let url = Self.songFile(account: key, name: d.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    func download(_ songs: [Song]) {
        guard let client = app?.client, let key = accountKey else { return }
        Self.prepareRoot()
        for song in songs where index.songs[song.id] == nil && index.queued[song.id] == nil {
            guard let url = client.downloadURL(song.id, maxBitRate: quality) else { continue }
            let ext = quality > 0 ? "mp3" : (song.suffix ?? "audio")
            var req = client.request(url)
            req.timeoutInterval = 120
            req.allowsCellularAccess = allowCellular
            let task = DownloadSession.shared.session.downloadTask(with: req)
            task.taskDescription = [key, song.id, ext].joined(separator: "|")
            index.queued[song.id] = song
            failed.remove(song.id)
            progress[song.id] = 0
            task.resume()
            saveCover(song.coverArt ?? song.albumId, client: client, account: key)
        }
        save()
    }

    func downloadAlbum(_ album: Album) {
        index.albums[album.id] = album
        saveCover(album.coverArt ?? album.id, client: app?.client, account: accountKey)
        download(album.song ?? [])
    }

    func downloadPlaylist(_ playlist: Playlist) {
        index.playlists[playlist.id] = playlist
        saveCover(playlist.coverArt ?? playlist.id, client: app?.client, account: accountKey)
        download(playlist.entry ?? [])
    }

    /// Cover art is stored next to the songs so downloaded music looks right offline.
    private func saveCover(_ id: String?, client: SubsonicClient?, account: String?) {
        guard let id, let client, let account, localCover(id) == nil, let url = client.coverURL(id, size: 600) else { return }
        let dest = Self.coverFile(account: account, id: id)
        Task.detached {
            var req = URLRequest(url: url)
            for (k, v) in client.account.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
    }

    // MARK: Removing

    func remove(_ songIds: [String]) {
        guard let key = accountKey else { return }
        for id in songIds {
            if let d = index.songs.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: Self.songFile(account: key, name: d.file))
            }
            index.queued.removeValue(forKey: id)
            progress.removeValue(forKey: id)
        }
        save()
    }

    /// Removes an album's songs, except those that a downloaded playlist still needs.
    func removeAlbum(_ id: String) {
        guard let album = index.albums.removeValue(forKey: id) else { return }
        remove((album.song ?? []).map(\.id).filter { !neededByPlaylists($0) })
    }

    func removePlaylist(_ id: String) {
        guard let pl = index.playlists.removeValue(forKey: id) else { return }
        remove((pl.entry ?? []).map(\.id).filter { !neededByAlbums($0) && !neededByPlaylists($0) })
    }

    private func neededByPlaylists(_ id: String) -> Bool { index.playlists.values.contains { ($0.entry ?? []).contains { $0.id == id } } }
    private func neededByAlbums(_ id: String) -> Bool { index.albums.values.contains { ($0.song ?? []).contains { $0.id == id } } }

    func removeAll() {
        DownloadSession.shared.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        if let key = accountKey { try? FileManager.default.removeItem(at: Self.folder(key)) }
        index = DownloadIndex(); progress = [:]; failed = []
    }

    nonisolated static func deleteAccount(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id.uuidString))
    }

    // MARK: Session callbacks

    func didProgress(account: String, songId: String, fraction: Double) {
        guard account == accountKey else { return }
        progress[songId] = fraction
    }

    func didFinish(account: String, songId: String, file: String, size: Int64) {
        guard account == accountKey else {
            updateOther(account) { idx in
                if let song = idx.queued.removeValue(forKey: songId) { idx.songs[songId] = DownloadedSong(song: song, file: file, size: size) }
            }
            return
        }
        if let song = index.queued.removeValue(forKey: songId) {
            index.songs[songId] = DownloadedSong(song: song, file: file, size: size)
        }
        progress.removeValue(forKey: songId)
        save()
    }

    func didFail(account: String, songId: String) {
        guard account == accountKey else { updateOther(account) { $0.queued.removeValue(forKey: songId) }; return }
        index.queued.removeValue(forKey: songId)
        progress.removeValue(forKey: songId)
        failed.insert(songId)
        save()
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
        guard http?.statusCode == 200, !type.contains("json"), !type.contains("html") else {
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
        guard let info = parse(downloadTask), totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in DownloadStore.shared.didProgress(account: info.account, songId: info.songId, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = parse(task), (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in DownloadStore.shared.didFail(account: info.account, songId: info.songId) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
