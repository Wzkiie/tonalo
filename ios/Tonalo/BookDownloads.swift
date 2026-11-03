import Foundation
import Observation

// Audiobooks and podcast episodes saved for listening without a connection. Kept apart from the music downloads:
// other files, another server, and they stay when the music server is disconnected.

struct DownloadedBook: Codable, Identifiable {
    struct File: Codable {
        let index: Int
        let startOffset: Double
        let duration: Double
        let ino: String
        let name: String
        var size: Int64
        var done = false
    }
    let key: String
    let item: ABSItem
    let episode: ABSEpisode?
    let duration: Double
    let chapters: [ABSChapter]
    var files: [File]
    var id: String { key }
    var title: String { episode?.title ?? item.title }
    var complete: Bool { files.allSatisfy(\.done) }
    var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum BookDownloadState: Equatable {
    case none
    case loading(Double)
    case failed
    case complete
}

@MainActor
@Observable
final class BookDownloads {
    @ObservationIgnored weak var library: AudiobookLibrary?
    private(set) var books: [String: DownloadedBook] = [:]
    /// Bytes received per book and file, for the progress.
    private(set) var received: [String: [Int: Int64]] = [:]
    /// Downloads that stopped and wait for another try.
    private(set) var failed: Set<String> = []
    /// Tapped, and still asking the server which files there are.
    private(set) var starting: Set<String> = []
    /// What the current run started with, so the counter stays until all of it is done, like with the music.
    private(set) var batch: Set<String> = []
    var allowCellular = UserDefaults.standard.bool(forKey: "book.downloadCellular") {
        didSet {
            UserDefaults.standard.set(allowCellular, forKey: "book.downloadCellular")
            // Waiting transfers keep the setting they were started with
            if allowCellular != oldValue { restartAll() }
        }
    }
    @ObservationIgnored private var resumed = false
    /// A login that ran out gets one new try per book, a server that keeps refusing doesn't get asked forever.
    @ObservationIgnored private var loginRetries: Set<String> = []

    private var account: String? { library?.app?.currentId?.uuidString }
    var totalBytes: Int64 { books.values.reduce(0) { $0 + ($1.complete ? $1.bytes : 0) } }
    var sorted: [DownloadedBook] { books.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var waitingForWiFi: Bool { !allowCellular && library?.app?.cellularOnly == true && books.values.contains { !$0.complete } }

    static func key(_ item: String, _ episode: String?) -> String { episode.map { item + "_" + $0 } ?? item }

    nonisolated static func folder(account: String, key: String) -> URL {
        AudiobookFiles.folder(account).appendingPathComponent("books", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }
    nonisolated static func coverFile(account: String, item: String) -> URL {
        AudiobookFiles.folder(account).appendingPathComponent("covers", isDirectory: true).appendingPathComponent(item + ".jpg")
    }
    private var indexFile: URL? { account.map { AudiobookFiles.folder($0).appendingPathComponent("downloads.json") } }

    func localCover(_ item: String) -> URL? {
        guard let account else { return nil }
        let file = Self.coverFile(account: account, item: item)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func state(_ item: ABSItem, episode: ABSEpisode? = nil) -> BookDownloadState {
        let key = Self.key(item.id, episode?.id)
        if starting.contains(key) { return .loading(0) }
        guard let book = books[key] else { return .none }
        if book.complete { return .complete }
        if failed.contains(key) { return .failed }
        return .loading(fraction(book))
    }

    /// The small sign next to a subtitle, the same as on albums.
    func mark(_ item: ABSItem) -> DownloadState {
        switch state(item) {
        case .complete: .complete
        case .loading(let value): .downloading(done: Int(value * 100), total: 100)
        default: .none
        }
    }

    func bytesLoaded(_ book: DownloadedBook) -> Int64 {
        book.files.reduce(Int64(0)) { $0 + ($1.done ? $1.size : received[book.key]?[$1.index] ?? 0) }
    }

    private func fraction(_ book: DownloadedBook) -> Double { min(1, Double(bytesLoaded(book)) / Double(max(1, book.bytes))) }

    /// What's loading right now, without what failed.
    var active: [DownloadedBook] { sorted.filter { !$0.complete && !failed.contains($0.key) } }
    var failedBooks: [DownloadedBook] { sorted.filter { failed.contains($0.key) } }
    var finished: [DownloadedBook] { sorted.filter(\.complete) }

    private func isLoading(_ key: String) -> Bool {
        if starting.contains(key) { return true }
        guard let book = books[key] else { return false }
        return !book.complete && !failed.contains(key)
    }

    /// How far the current run is, 0…1; nil when nothing is loading (or it waits for Wi-Fi).
    var batchProgress: Double? {
        guard !waitingForWiFi, batch.contains(where: isLoading) else { return nil }
        let done = batch.reduce(0.0) { sum, key in
            sum + (isLoading(key) ? books[key].map(fraction) ?? 0 : 1)
        }
        return done / Double(batch.count)
    }

    var batchCounts: (done: Int, total: Int) { (batch.filter { !isLoading($0) }.count, batch.count) }

    private func settleBatch() { if !batch.contains(where: isLoading) { batch = [] } }

    // MARK: Index

    func reload() {
        books = [:]; received = [:]; failed = []; resumed = false; loginRetries = []; starting = []; batch = []
        guard let file = indexFile, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: DownloadedBook].self, from: data) else { return }
        books = saved
        batch = Set(saved.values.filter { !$0.complete }.map(\.key))
    }

    private func save() {
        guard let file = indexFile else { return }
        AudiobookFiles.prepare()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(books) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Start and stop

    func download(_ item: ABSItem, episode: ABSEpisode? = nil) {
        guard let library, let account else { return }
        guard library.canDownload else {
            library.app?.notify(String(localized: "Your Audiobookshelf user isn't allowed to download."))
            return
        }
        let key = Self.key(item.id, episode?.id)
        guard books[key] == nil, !starting.contains(key) else { return }
        // The ring shows from the tap on, also while the server is asked which files there are
        starting.insert(key)
        batch.insert(key)
        Task {
            defer {
                starting.remove(key)
                settleBatch()
            }
            do {
                // The full item, which is also what renews a login that ran out, so the transfers start with a fresh one
                let full = try await library.item(item.id)
                let found = full.media.episodes?.first { $0.id == episode?.id }
                let sources: [ABSFile] = episode != nil ? [found?.audioFile].compactMap { $0 } : full.media.tracks ?? []
                var offset = 0.0
                var files: [DownloadedBook.File] = []
                for (i, f) in sources.enumerated() {
                    guard let ino = f.ino else { continue }
                    let ext = (f.metadata?.ext ?? ".mp3").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let start = f.startOffset ?? offset
                    files.append(.init(index: i, startOffset: start, duration: f.duration ?? 0, ino: ino, name: "\(i).\(ext)", size: Int64(f.metadata?.size ?? 0)))
                    offset = start + (f.duration ?? 0)
                }
                guard !files.isEmpty else { throw AudiobookError.unexpected }
                try FileManager.default.createDirectory(at: Self.folder(account: account, key: key), withIntermediateDirectories: true)
                books[key] = DownloadedBook(key: key, item: full, episode: found, duration: found?.length ?? full.media.duration ?? offset,
                                            chapters: full.media.chapters ?? [], files: files)
                failed.remove(key)
                save()
                saveCover(item.id, account: account)
                enqueue(key)
            } catch {
                library.app?.notify(error.userMessage ?? String(localized: "This can't be downloaded right now."))
            }
        }
    }

    private func saveCover(_ item: String, account: String) {
        guard let library, let url = library.coverURL(item, width: 800), let headers = library.server?.authorized else { return }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        Task {
            guard let (data, response) = try? await ServerSession.shared.fetch(request), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let file = Self.coverFile(account: account, item: item)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func enqueue(_ key: String) {
        guard let book = books[key], let account, let server = library?.server else { return }
        let session = BookDownloadSession.shared.session
        for file in book.files where !file.done {
            guard let url = URL(string: "\(server.url)/api/items/\(book.item.id)/file/\(file.ino)/download") else { continue }
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowCellular
            for (k, v) in server.authorized { request.setValue(v, forHTTPHeaderField: k) }
            let task = session.downloadTask(with: request)
            task.taskDescription = [account, key, String(file.index), file.name].joined(separator: "|")
            task.resume()
        }
    }

    private func cancelTasks(_ wanted: @escaping @Sendable (String) -> Bool, then: (@MainActor @Sendable () -> Void)? = nil) {
        BookDownloadSession.shared.session.getAllTasks { tasks in
            for task in tasks {
                let key = task.taskDescription?.components(separatedBy: "|").dropFirst().first ?? ""
                if wanted(key) { task.cancel() }
            }
            Task { @MainActor in then?() }
        }
    }

    /// After a start: goes on with what iOS dropped or what stopped. Once per run, so failing files aren't asked for over and over.
    func resume() {
        guard !resumed else { return }
        resumed = true
        BookDownloadSession.shared.session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription?.components(separatedBy: "|").dropFirst().first })
            Task { @MainActor in
                for (key, book) in self.books where !book.complete && !running.contains(key) { self.enqueue(key) }
            }
        }
    }

    func retry(_ key: String) {
        failed.remove(key)
        batch.insert(key)
        loginRetries.remove(key)
        renewAndEnqueue(key)
    }

    /// Asking the server renews a login that ran out, the new transfers then carry the new one.
    private func renewAndEnqueue(_ key: String) {
        Task {
            await library?.load(force: true)
            cancelTasks({ $0 == key }) { [weak self] in self?.enqueue(key) }
        }
    }

    /// Transfers to an address that's out of reach now start over from the one in use.
    func restartTasks(onHost host: String) {
        BookDownloadSession.shared.session.getAllTasks { tasks in
            let keys = Set(tasks.compactMap { t -> String? in
                guard t.originalRequest?.url?.host == host else { return nil }
                return t.taskDescription?.components(separatedBy: "|").dropFirst().first
            })
            guard !keys.isEmpty else { return }
            Task { @MainActor in
                self.cancelTasks({ keys.contains($0) }) { [weak self] in
                    for key in keys { self?.enqueue(key) }
                }
            }
        }
    }

    func restartAll() {
        let open = Set(books.values.filter { !$0.complete }.map(\.key))
        guard !open.isEmpty else { return }
        cancelTasks({ open.contains($0) }) { [weak self] in
            guard let self else { return }
            for key in open { self.enqueue(key) }
        }
    }

    func remove(_ key: String) {
        guard let account, let book = books[key] else { return }
        if let player = library?.app?.bookPlayer, player.session?.isLocal == true, player.item?.id == book.item.id, player.episode?.id == book.episode?.id { player.close() }
        books[key] = nil
        received[key] = nil
        failed.remove(key)
        batch.remove(key)
        settleBatch()
        save()
        cancelTasks({ $0 == key })
        try? FileManager.default.removeItem(at: Self.folder(account: account, key: key))
        if !books.values.contains(where: { $0.item.id == book.item.id }) {
            try? FileManager.default.removeItem(at: Self.coverFile(account: account, item: book.item.id))
        }
    }

    func cancelAll() {
        for book in active { remove(book.key) }
    }

    func retryFailed() {
        for book in failedBooks { retry(book.key) }
    }

    func removeAll() {
        for key in books.keys { remove(key) }
    }

    // MARK: Transfers

    func didProgress(account: String, key: String, index: Int, written: Int64) {
        guard account == self.account else { return }
        received[key, default: [:]][index] = written
    }

    func didFinish(account: String, key: String, index: Int, size: Int64) {
        guard account == self.account, var book = books[key], let i = book.files.firstIndex(where: { $0.index == index }) else { return }
        book.files[i].done = true
        if size > 0 { book.files[i].size = size }
        books[key] = book
        received[key]?[index] = nil
        save()
        settleBatch()
    }

    func didFail(account: String, key: String, status: Int?) {
        guard account == self.account, books[key] != nil else { return }
        if status == 403 {
            remove(key)
            library?.app?.notify(String(localized: "Your Audiobookshelf user isn't allowed to download."))
        } else if status == 401, !loginRetries.contains(key) {
            // The login ran out during a long download. All files of the book fail about now, one new try is enough
            loginRetries.insert(key)
            renewAndEnqueue(key)
        } else {
            failed.insert(key)
            settleBatch()
        }
    }

    // MARK: Playing

    /// What the player needs when all files of a book are here.
    func localSession(item: String, episode: String?, position: Double) -> ABSSession? {
        guard let book = books[Self.key(item, episode)], book.complete else { return nil }
        return ABSSession(id: "local-" + UUID().uuidString, libraryItemId: item, episodeId: episode, displayTitle: book.title,
                          displayAuthor: book.item.creator, duration: book.duration, currentTime: position, chapters: book.chapters,
                          audioTracks: book.files.map { .init(index: $0.index, startOffset: $0.startOffset, duration: $0.duration) })
    }

    func localFile(item: String, episode: String?, index: Int) -> URL? {
        let key = Self.key(item, episode)
        guard let account, let name = books[key]?.files.first(where: { $0.index == index })?.name else { return nil }
        return Self.folder(account: account, key: key).appendingPathComponent(name)
    }
}

/// Background URLSession of its own: the transfers go on while the app is suspended or closed.
final class BookDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BookDownloadSession()
    static let identifier = "io.github.wzkiie.tonalo.bookdownloads"
    var backgroundCompletion: (() -> Void)?
    /// Set when the app starts, the delegate can be called before anything else asks for it.
    @MainActor weak var store: BookDownloads?

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 3
        config.httpCookieStorage = nil // no proxy cookies on disk, see ServerSession
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private func parse(_ task: URLSessionTask) -> (account: String, key: String, index: Int, name: String)? {
        let parts = (task.taskDescription ?? "").components(separatedBy: "|")
        guard parts.count == 4, let index = Int(parts[2]) else { return nil }
        return (parts[0], parts[1], index, parts[3])
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = parse(downloadTask) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        // A JSON/HTML answer means an error page (e.g. a Cloudflare login page), not audio
        guard let status = http?.statusCode, status == 200 || status == 206, !type.contains("json"), !type.contains("html") else {
            let status = http?.statusCode
            Task { @MainActor in self.store?.didFail(account: info.account, key: info.key, status: status) }
            return
        }
        // The file has to be moved before this method returns, otherwise iOS deletes it
        let dest = BookDownloads.folder(account: info.account, key: info.key).appendingPathComponent(info.name)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            let size = downloadTask.countOfBytesReceived
            Task { @MainActor in self.store?.didFinish(account: info.account, key: info.key, index: info.index, size: size) }
        } catch {
            Task { @MainActor in self.store?.didFail(account: info.account, key: info.key, status: nil) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = parse(downloadTask) else { return }
        Task { @MainActor in self.store?.didProgress(account: info.account, key: info.key, index: info.index, written: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = parse(task), (error as? URLError)?.code != .cancelled else { return }
        Task { @MainActor in self.store?.didFail(account: info.account, key: info.key, status: nil) }
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
