import Foundation
import Observation
import UIKit

// Audiobooks and podcasts from an Audiobookshelf server, connected to a Tonalo account.

/// The connection, kept inside the account in the Keychain. The password is never stored, only the tokens.
struct AudiobookServer: Codable, Hashable {
    var url: String
    var username: String
    var accessToken: String
    var refreshToken: String?
    var headers: [HeaderField] = []
    /// Optional address inside the home network, used on Wi-Fi when the same server answers there.
    var localURL: String?
    /// Random, only so the server can tell its listening sessions apart. Says nothing about the device.
    var deviceId = UUID().uuidString

    var httpHeaders: [String: String] {
        var out: [String: String] = [:]
        for h in headers {
            let name = h.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[name] = h.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return out
    }
    var authorized: [String: String] { httpHeaders.merging(["Authorization": "Bearer " + accessToken]) { _, new in new } }
    var host: String { URL(string: url)?.host ?? url }

    /// What to talk to right now. Custom headers are for the proxy outside, they don't go to the home address.
    func route(atHome: Bool) -> AudiobookServer {
        guard atHome, let localURL else { return self }
        var home = self
        home.url = localURL
        home.headers = []
        return home
    }
}

// MARK: - Data from the server

struct ABSLibrary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let mediaType: String?
    var isPodcasts: Bool { mediaType == "podcast" }
}

struct ABSChapter: Codable, Hashable, Identifiable {
    let start: Double
    let end: Double
    let title: String?
    var id: Double { start }
}

/// One audio file of a book or episode, as the expanded item lists it.
struct ABSFile: Codable, Hashable {
    let ino: String?
    let index: Int?
    let startOffset: Double?
    let duration: Double?
    let metadata: Info?
    struct Info: Codable, Hashable {
        let ext: String?
        let size: Double?
    }
}

struct ABSEpisode: Codable, Hashable, Identifiable {
    let id: String
    let title: String?
    let subtitle: String?
    let duration: Double?
    let publishedAt: Double?
    /// Newest shelves leave the duration on the audio file.
    let audioFile: ABSFile?
    var length: Double { duration ?? audioFile?.duration ?? 0 }
}

struct ABSAuthor: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    var description: String?
    var numBooks: Int?
}

struct ABSSeriesRef: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    var sequence: String?
}

/// The full item lists the series of a book, some shelves only the one they're about.
struct ABSSeriesList: Codable, Hashable {
    var all: [ABSSeriesRef] = []
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let many = try? c.decode([ABSSeriesRef].self) { all = many }
        else if let one = try? c.decode(ABSSeriesRef.self) { all = [one] }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(all)
    }
}

struct ABSItem: Codable, Identifiable, Hashable {
    let id: String
    let libraryId: String?
    let mediaType: String?
    let media: Media
    /// On the shelves with new episodes: which episode is meant.
    let recentEpisode: ABSEpisode?
    /// When it came to the server, in milliseconds.
    let addedAt: Double?
    /// In the list of what's being listened to: when that last happened, in milliseconds.
    let progressLastUpdate: Double?

    struct Media: Codable, Hashable {
        let metadata: Metadata
        let duration: Double?
        let chapters: [ABSChapter]?
        let episodes: [ABSEpisode]?
        let numEpisodes: Int?
        let tracks: [ABSFile]?
    }
    struct Metadata: Codable, Hashable {
        let title: String?
        let subtitle: String?
        let authorName: String?
        let author: String?
        let authors: [ABSAuthor]?
        let narratorName: String?
        let narrators: [String]?
        let seriesName: String?
        let series: ABSSeriesList?
        let description: String?
        let publishedYear: String?
    }

    var isPodcast: Bool { mediaType == "podcast" }
    var title: String { media.metadata.title ?? "" }
    var creator: String { media.metadata.authorName ?? media.metadata.author ?? "" }
}

struct ABSProgress: Codable, Hashable {
    let libraryItemId: String
    let episodeId: String?
    var progress: Double?
    var currentTime: Double?
    var isFinished: Bool?
    var lastUpdate: Double?
    var duration: Double?
    var key: String { Self.key(libraryItemId, episodeId) }
    static func key(_ item: String, _ episode: String?) -> String { episode.map { item + "/" + $0 } ?? item }
}

struct ABSSession: Codable {
    let id: String
    let libraryItemId: String
    let episodeId: String?
    let displayTitle: String?
    let displayAuthor: String?
    let duration: Double
    let currentTime: Double
    let chapters: [ABSChapter]?
    let audioTracks: [Track]
    /// Played from the files on this iPhone rather than through the server.
    var isLocal: Bool { id.hasPrefix("local-") }

    struct Track: Codable {
        let index: Int
        let startOffset: Double
        let duration: Double
    }
}

/// What a search finds on the server, besides the books themselves.
struct ABSSearchResults {
    var items: [ABSItem] = []
    var authors: [ABSAuthor] = []
    var series: [ABSSeriesRef] = []
    var narrators: [String] = []
}

/// A series in the overview, with the book whose cover stands for it.
struct ABSSeriesEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let library: String
    let cover: String?
    let count: Int
}

/// A book with a heart. Audiobookshelf has no favorites of its own, so they stay on this iPhone, per account.
struct FavoriteBook: Codable {
    let item: ABSItem
    let date: Date
}

/// An author with a heart, kept the same way.
struct FavoriteAuthor: Codable {
    let author: ABSAuthor
    let date: Date
}

/// What the library needs without a connection, and positions the server hasn't heard about yet.
private struct SavedBookState: Codable {
    var favorites: [String: FavoriteBook] = [:]
    var inProgress: [ABSItem] = []
    var progress: [ABSProgress] = []
    var unsent: [ABSProgress] = []
    /// Optional, so what was saved before it existed still loads.
    var authors: [String: FavoriteAuthor]?
}

/// Where everything of the audiobooks stays on this iPhone, one folder per account. Separate from the music
/// downloads, so disconnecting the music server keeps it. Can be fetched again, so it stays out of the iCloud backup.
enum AudiobookFiles {
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobooks", isDirectory: true)
    }
    nonisolated static func folder(_ account: String) -> URL { root.appendingPathComponent(account, isDirectory: true) }
    nonisolated static func prepare() {
        var url = root
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
    nonisolated static func deleteAccount(_ id: UUID) { try? FileManager.default.removeItem(at: folder(id.uuidString)) }
}

private struct RawShelf: Decodable { let id: String; let label: String?; let type: String?; let entities: [Lossy<ABSItem>]? }

/// A shelf or a list keeps its other entries when one of them has a shape we don't know.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum AudiobookError: LocalizedError {
    case login
    case notConnected
    case unexpected
    case refused
    var errorDescription: String? {
        switch self {
        case .login: String(localized: "Wrong user name or password.")
        case .notConnected: String(localized: "Audiobookshelf isn't connected.")
        case .refused: String(localized: "The server didn't accept your login. Is this really the same Audiobookshelf server?")
        case .unexpected: String(localized: "That doesn't look like an Audiobookshelf server. If it's behind a proxy such as Cloudflare Access, check the custom headers.")
        }
    }
}

// MARK: - Connection and library

@MainActor
@Observable
final class AudiobookLibrary {
    struct Shelf: Identifiable, Hashable {
        let id: String
        let title: String
        var items: [ABSItem]
    }

    @ObservationIgnored weak var app: AppModel?
    private(set) var libraries: [ABSLibrary] = []
    private(set) var shelves: [Shelf] = []
    private(set) var progress: [String: ABSProgress] = [:]
    private(set) var loading = false
    private(set) var error: String?
    /// What you started and haven't finished, however many. Kept for opening them without a connection.
    private(set) var inProgress: [ABSItem] = []
    private(set) var favorites: [String: FavoriteBook] = [:]
    private(set) var favoriteAuthors: [String: FavoriteAuthor] = [:]
    /// The server decides per user whether downloading is allowed.
    private(set) var canDownload = true
    /// Whether the home address is in use right now. The app checks that whenever the network changes.
    private(set) var atHome = false
    let downloads = BookDownloads()
    @ObservationIgnored private var unsent: [ABSProgress] = []
    @ObservationIgnored private var restoredFor: UUID?
    @ObservationIgnored private var refreshing: Task<Bool, Never>?
    @ObservationIgnored private var loadedFor: String?

    init() {
        downloads.library = self
        BookDownloadSession.shared.store = downloads
    }

    /// The connection as it's saved. To talk to the server, use `server`.
    var stored: AudiobookServer? { app?.current?.audiobooks }
    var server: AudiobookServer? { stored?.route(atHome: atHome) }
    var connected: Bool { stored != nil }
    private var stateFile: URL? { app?.currentId.map { AudiobookFiles.folder($0.uuidString).appendingPathComponent("state.json") } }
    /// What was started and not finished, for the shelf on the home page.
    var continueListening: [ABSItem] { shelves.first { $0.id == "continue-listening" }?.items ?? [] }

    func isFinished(_ id: String) -> Bool { progress[id]?.isFinished == true }

    func progress(of item: ABSItem, episode: ABSEpisode? = nil) -> ABSProgress? {
        progress[ABSProgress.key(item.id, episode?.id ?? item.recentEpisode?.id)]
    }

    func coverURL(_ itemId: String, width: Int = 400) -> URL? {
        server.flatMap { URL(string: "\($0.url)/api/items/\(itemId)/cover?width=\(width)&format=jpeg") }
    }

    /// The cover from the iPhone when it's downloaded, otherwise from the server.
    func coverImage(_ itemId: String, width: Int) async -> UIImage? {
        if let file = downloads.localCover(itemId), let data = try? Data(contentsOf: file), let saved = UIImage(data: data) { return saved }
        guard let url = coverURL(itemId, width: width), let headers = server?.authorized else { return nil }
        return await ImageLoader.shared.image(url, headers: headers)
    }

    func authorImageURL(_ id: String, width: Int = 200) -> URL? {
        server.flatMap { URL(string: "\($0.url)/api/authors/\(id)/image?width=\(width)&format=jpeg") }
    }

    // MARK: Kept on this iPhone

    /// Brings back the last known state, so the library shows at once and without a connection.
    func restore() {
        guard let id = app?.currentId, restoredFor != id, connected else { return }
        restoredFor = id
        downloads.reload()
        guard let file = stateFile, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(SavedBookState.self, from: data) else { return }
        favorites = saved.favorites
        favoriteAuthors = saved.authors ?? [:]
        inProgress = saved.inProgress
        unsent = saved.unsent
        progress = Dictionary((saved.progress + saved.unsent).map { ($0.key, $0) }) { _, new in new }
    }

    private func saveState() {
        guard let file = stateFile else { return }
        AudiobookFiles.prepare()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = SavedBookState(favorites: favorites, inProgress: inProgress, progress: Array(progress.values), unsent: unsent, authors: favoriteAuthors)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: file, options: .atomic) }
    }

    func isFavorite(_ id: String) -> Bool { favorites[id] != nil }

    func toggleFavorite(_ item: ABSItem) {
        favorites[item.id] = favorites[item.id] == nil ? FavoriteBook(item: item, date: Date()) : nil
        saveState()
    }

    func isFavoriteAuthor(_ id: String) -> Bool { favoriteAuthors[id] != nil }

    func toggleFavoriteAuthor(id: String, name: String) {
        favoriteAuthors[id] = favoriteAuthors[id] == nil ? FavoriteAuthor(author: ABSAuthor(id: id, name: name), date: Date()) : nil
        saveState()
    }

    /// The best copy known without asking the server.
    func savedItem(_ id: String) -> ABSItem? {
        downloads.books.values.first { $0.item.id == id }?.item ?? favorites[id]?.item ?? inProgress.first { $0.id == id }
    }

    /// What is playing right now: the progress bars and the "Continue listening" shelf follow it at once,
    /// without waiting for the server. The server hears about it through the playback session.
    func noteListening(_ item: ABSItem, episode: ABSEpisode?, currentTime: Double, duration: Double) {
        let id = episode?.id ?? item.recentEpisode?.id
        let key = ABSProgress.key(item.id, id)
        var entry = progress[key] ?? ABSProgress(libraryItemId: item.id, episodeId: id)
        entry.currentTime = currentTime
        entry.duration = duration
        entry.progress = duration > 0 ? min(1, currentTime / duration) : 0
        entry.isFinished = duration > 0 && currentTime >= duration - 5
        entry.lastUpdate = Date().timeIntervalSince1970 * 1000
        progress[key] = entry
        guard entry.isFinished != true else { return }
        // A podcast episode other than the one the shelf shows comes with the next refresh from the server
        guard episode == nil || episode?.id == item.recentEpisode?.id else { return }
        let shown = item
        let shelf = Shelf(id: "continue-listening", title: Self.title(of: "continue-listening", fallback: ""), items: [])
        var list = shelves.first { $0.id == shelf.id } ?? shelf
        if list.items.first?.shelfKey == shown.shelfKey { return }
        list.items.removeAll { $0.shelfKey == shown.shelfKey }
        list.items.insert(shown, at: 0)
        if let i = shelves.firstIndex(where: { $0.id == shelf.id }) { shelves[i] = list } else { shelves.insert(list, at: 0) }
        if !inProgress.contains(where: { $0.id == item.id }) { inProgress.insert(item, at: 0) }
        saveState()
    }

    /// Tells the server where a downloaded book stands; without a connection it's sent on the next occasion.
    func saveProgress(item: String, episode: String?, currentTime: Double, duration: Double) {
        var entry = ABSProgress(libraryItemId: item, episodeId: episode)
        entry.currentTime = currentTime
        entry.progress = duration > 0 ? min(1, currentTime / duration) : 0
        entry.isFinished = currentTime >= duration - 5
        entry.lastUpdate = Date().timeIntervalSince1970 * 1000
        entry.duration = duration
        progress[entry.key] = entry
        unsent.removeAll { $0.key == entry.key }
        unsent.append(entry)
        saveState()
        Task { await sendUnsent() }
    }

    private func sendUnsent() async {
        struct Body: Encodable { let currentTime: Double?; let progress: Double?; let isFinished: Bool?; let duration: Double? }
        for entry in unsent {
            let path = "/api/me/progress/\(entry.libraryItemId)" + (entry.episodeId.map { "/\($0)" } ?? "")
            let body = Body(currentTime: entry.currentTime, progress: entry.progress, isFinished: entry.isFinished, duration: entry.duration)
            guard (try? await send(path, method: "PATCH", body: body, timeout: 10)) != nil else { return }
            unsent.removeAll { $0.key == entry.key && $0.lastUpdate == entry.lastUpdate }
        }
        saveState()
    }

    // MARK: Connect

    /// Signs in and gives back the connection, without saving anything yet.
    func signIn(address: String, username: String, password: String, headers: [HeaderField]) async throws -> AudiobookServer {
        let url = SubsonicClient.normalize(address)
        do {
            return try await Self.login(url: url, username: username, password: password, headers: headers)
        } catch let first as URLError {
            // No scheme typed and https didn't connect: plain http, but only for home-network addresses
            guard !address.lowercased().contains("://"), SubsonicClient.isLocal(url) else { throw first }
            return try await Self.login(url: "http://" + url.dropFirst("https://".count), username: username, password: password, headers: headers)
        }
    }

    private static func login(url: String, username: String, password: String, headers: [HeaderField]) async throws -> AudiobookServer {
        // http only ever when typed like that or in the home network: a VPN name can be plain http on purpose
        guard let host = URL(string: url) else { throw AudiobookError.unexpected }
        var new = AudiobookServer(url: url, username: username, accessToken: "", headers: headers)
        var request = URLRequest(url: host.appendingPathComponent("login"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without this the server keeps the refresh token in a cookie, for browsers
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        for (k, v) in new.httpHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, response) = try await ServerSession.shared.fetch(request, retry: nil)
        guard let http = response as? HTTPURLResponse else { throw AudiobookError.unexpected }
        if http.statusCode == 401 { throw AudiobookError.login }
        struct Login: Decodable {
            struct User: Decodable { let accessToken: String?; let refreshToken: String?; let token: String? }
            let user: User
        }
        guard http.statusCode == 200, let login = try? JSONDecoder().decode(Login.self, from: data),
              let token = login.user.accessToken ?? login.user.token else { throw AudiobookError.unexpected }
        new.accessToken = token
        new.refreshToken = login.user.refreshToken
        return new
    }

    /// Adds Audiobookshelf to the account that's in use.
    func connect(address: String, username: String, password: String, headers: [HeaderField], home: String? = nil) async throws {
        var new = try await signIn(address: address, username: username, password: password, headers: headers)
        new.localURL = home
        try app?.setAudiobooks(new)
        clear()
        app?.checkRoute()
        await load(force: true)
    }

    /// Changes where the server is found, keeping the login, the downloads and the hearts.
    /// A server that was only known by its home address keeps that as the address at home.
    func updateConnection(address: String, home: String?, headers: [HeaderField]) async throws {
        guard let old = stored else { throw AudiobookError.notConnected }
        var new = old
        new.url = SubsonicClient.normalize(address)
        new.headers = headers
        new.localURL = home
        if home == nil, old.localURL == nil, SubsonicClient.isLocal(old.url), !SubsonicClient.isLocal(new.url) { new.localURL = old.url }
        if new.localURL == new.url { new.localURL = nil }
        do {
            new = try await Self.checked(new)
        } catch let first as URLError {
            guard !address.lowercased().contains("://"), SubsonicClient.isLocal(new.url) else { throw first }
            new.url = "http://" + new.url.dropFirst("https://".count)
            new = try await Self.checked(new)
        }
        try app?.setAudiobooks(new)
        atHome = false
        loadedFor = nil
        app?.checkRoute()
        app?.bookPlayer.addressChanged()
        downloads.restartAll()
        await load(force: true)
    }

    /// Whether this address and these headers get through to the server the login is from. A login that ran out is renewed.
    private static func checked(_ server: AudiobookServer) async throws -> AudiobookServer {
        func status(_ s: AudiobookServer) async throws -> Int {
            guard let url = URL(string: s.url + "/api/me") else { throw AudiobookError.unexpected }
            var request = URLRequest(url: url, timeoutInterval: 15)
            for (k, v) in s.authorized { request.setValue(v, forHTTPHeaderField: k) }
            struct Me: Decodable { let id: String }
            let (data, response) = try await ServerSession.shared.fetch(request, retry: nil)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A proxy's login page can answer 200 too
            if code == 200, (try? JSONDecoder().decode(Me.self, from: data)) == nil { throw AudiobookError.unexpected }
            return code
        }
        var s = server
        var code = try await status(s)
        if code == 401, let renewed = await renewed(s) {
            s = renewed
            code = try await status(s)
        }
        if code == 401 { throw AudiobookError.refused }
        guard code == 200 else { throw AudiobookError.unexpected }
        return s
    }

    /// Asked without the login: which server answers at an address.
    static func identity(_ server: AudiobookServer) async -> String? {
        guard let url = URL(string: server.url + "/status") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        for (k, v) in server.httpHeaders { request.setValue(v, forHTTPHeaderField: k) }
        struct Status: Decodable { let app: String?; let serverVersion: String? }
        guard let (data, response) = try? await ServerSession.shared.fetch(request, retry: nil),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let status = try? JSONDecoder().decode(Status.self, from: data), let version = status.serverVersion else { return nil }
        return "\(status.app ?? "")|\(version)"
    }

    func setAtHome(_ value: Bool) {
        // Away from home: downloads started at home (maybe before the app was even opened) can't finish there
        if !value, let s = stored, let home = s.localURL.flatMap({ URL(string: $0)?.host }), home != s.host {
            downloads.restartTasks(onHost: home)
        }
        guard value != atHome else { return }
        atHome = value
        // Leaving home: a stream from the home address breaks. Arriving needs nothing, the outside address keeps working.
        if !value { app?.bookPlayer.addressChanged() }
        if loadedFor == nil { Task { await load() } }
    }

    func disconnect() {
        app?.bookPlayer.close()
        downloads.removeAll()
        if let id = app?.currentId { AudiobookFiles.deleteAccount(id) }
        favorites = [:]
        favoriteAuthors = [:]
        let old = server
        try? app?.setAudiobooks(nil)
        clear()
        if let old { logout(old) }
    }

    /// Ends the login on the server too, so the tokens stop working.
    func logout(_ server: AudiobookServer) {
        guard let refresh = server.refreshToken, let url = URL(string: server.url + "/logout") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        for (k, v) in server.httpHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        Task { _ = try? await ServerSession.shared.fetch(request, retry: nil) }
    }

    func accountChanged() {
        app?.bookPlayer.close()
        clear()
    }

    private func clear() {
        libraries = []; shelves = []; progress = [:]; error = nil; loadedFor = nil; atHome = false
        inProgress = []; favorites = [:]; favoriteAuthors = [:]; unsent = []; restoredFor = nil; canDownload = true
    }

    // MARK: Requests

    func send(_ path: String, method: String = "GET", body: (any Encodable)? = nil, timeout: TimeInterval = 20) async throws -> Data {
        guard let first = server else { throw AudiobookError.notConnected }
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        func attempt(_ s: AudiobookServer) async throws -> (Data, Int) {
            guard let url = URL(string: s.url + path) else { throw AudiobookError.unexpected }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData
            for (k, v) in s.authorized { request.setValue(v, forHTTPHeaderField: k) }
            if let bodyData {
                request.httpBody = bodyData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await ServerSession.shared.fetch(request, retry: nil)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var (data, status) = try await attempt(first)
        if status == 401, await refreshToken(), let again = server { (data, status) = try await attempt(again) }
        guard (200..<300).contains(status) else {
            if status == 401 { throw AudiobookError.login }
            throw NSError(domain: "Audiobookshelf", code: status, userInfo: [NSLocalizedDescriptionKey: String(localized: "The server answered with error \(status).")])
        }
        return data
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let data = try await send(path)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw AudiobookError.unexpected }
    }

    /// The access token lasts about an hour. Several requests failing at once share one renewal.
    private func refreshToken() async -> Bool {
        if let refreshing { return await refreshing.value }
        guard let s = server, let saved = stored?.url else { return false }
        let task = Task<Bool, Never> { @MainActor in
            guard let answer = await Self.renewed(s), var new = stored, new.url == saved else { return false }
            new.accessToken = answer.accessToken
            new.refreshToken = answer.refreshToken
            try? app?.setAudiobooks(new)
            return true
        }
        refreshing = task
        let ok = await task.value
        refreshing = nil
        return ok
    }

    private static func renewed(_ s: AudiobookServer) async -> AudiobookServer? {
        guard let refresh = s.refreshToken, let url = URL(string: s.url + "/auth/refresh") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        for (k, v) in s.httpHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
        // Every renewal replaces the refresh token, and without this the server only hands the new one to a cookie
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        struct Answer: Decodable {
            struct User: Decodable { let accessToken: String; let refreshToken: String? }
            let user: User
        }
        guard let (data, response) = try? await ServerSession.shared.fetch(request, retry: nil),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        var new = s
        new.accessToken = answer.user.accessToken
        new.refreshToken = answer.user.refreshToken ?? refresh
        return new
    }

    // MARK: Library

    /// Libraries, shelves and progress. Pages call this as they appear; it only asks again when forced.
    func load(force: Bool = false) async {
        restore()
        guard let s = stored else { return }
        let key = s.url + s.username
        if !force && loadedFor == key { return }
        loading = true
        defer { loading = false }
        do {
            await sendUnsent()
            struct Me: Decodable {
                struct Permissions: Decodable { let download: Bool? }
                let mediaProgress: [Lossy<ABSProgress>]?
                let permissions: Permissions?
            }
            struct Started: Decodable { let libraryItems: [Lossy<ABSItem>]? }
            async let me = try? get(Me.self, "/api/me")
            async let started = try? get(Started.self, "/api/me/items-in-progress?limit=100")
            let libs = try await fetchLibraries()
            // All libraries at once, one slow one doesn't hold up the others
            let answers = await withTaskGroup(of: (Int, [RawShelf]).self) { group in
                for (i, lib) in libs.enumerated() {
                    group.addTask { [self] in
                        (i, await (try? get([RawShelf].self, "/api/libraries/\(lib.id)/personalized?limit=12&minified=1")) ?? [])
                    }
                }
                var out: [(Int, [RawShelf])] = []
                for await answer in group { out.append(answer) }
                return out.sorted { $0.0 < $1.0 }
            }
            var merged: [Shelf] = []
            for (_, raw) in answers {
                for shelf in raw where ["book", "podcast", "episode"].contains(shelf.type ?? "") {
                    let items = (shelf.entities ?? []).compactMap(\.value)
                    if items.isEmpty { continue }
                    if let i = merged.firstIndex(where: { $0.id == shelf.id }) { merged[i].items += items }
                    else { merged.append(Shelf(id: shelf.id, title: Self.title(of: shelf.id, fallback: shelf.label ?? ""), items: items)) }
                }
            }
            let user = await me
            libraries = libs
            shelves = merged
            if let user {
                progress = Dictionary((user.mediaProgress ?? []).compactMap(\.value).map { ($0.key, $0) }) { a, _ in a }
                for entry in unsent { progress[entry.key] = entry }
                canDownload = user.permissions?.download ?? true
            }
            if let list = await started?.libraryItems { inProgress = list.compactMap(\.value) }
            loadedFor = key
            error = nil
            saveState()
            downloads.resume()
        } catch {
            // What's already on screen is still good, an error page would only hide it
            if shelves.isEmpty, let message = error.userMessage { self.error = message }
        }
    }

    private func fetchLibraries() async throws -> [ABSLibrary] {
        struct Libraries: Decodable { let libraries: [ABSLibrary] }
        return try await get(Libraries.self, "/api/libraries").libraries
    }

    private static func title(of shelf: String, fallback: String) -> String {
        switch shelf {
        case "continue-listening": String(localized: "Continue listening")
        case "continue-series": String(localized: "Continue the series")
        case "recently-added": String(localized: "New audiobooks & podcasts")
        case "episodes-recently-added": String(localized: "New episodes")
        case "recommended": String(localized: "Recommended for you")
        case "listen-again": String(localized: "Listen again")
        case "discover": String(localized: "Discover audiobooks")
        default: fallback
        }
    }

    /// One page of a library. `filter` is what the server calls a group and a value, like the books of a narrator.
    func items(in library: String, page: Int = 0, pageSize: Int = 60, sort: String = "media.metadata.title", descending: Bool = false,
               filter: (group: String, value: String)? = nil) async throws -> (items: [ABSItem], total: Int) {
        struct Page: Decodable { let results: [Lossy<ABSItem>]; let total: Int? }
        var path = "/api/libraries/\(library)/items?limit=\(pageSize)&page=\(page)&sort=\(sort)&desc=\(descending ? 1 : 0)&minified=1"
        if let filter, let value = Data(filter.value.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&filter=\(filter.group).\(value)"
        }
        let p = try await get(Page.self, path)
        return (p.results.compactMap(\.value), p.total ?? 0)
    }

    func item(_ id: String) async throws -> ABSItem {
        try await get(ABSItem.self, "/api/items/\(id)?expanded=1")
    }

    private func ensureLibraries() async {
        if libraries.isEmpty, let libs = try? await fetchLibraries() { libraries = libs }
    }

    /// The ids of this server's libraries – the same server shows the same ones, under whatever address.
    func libraryIds() async -> [String] {
        await ensureLibraries()
        return libraries.map(\.id)
    }

    /// The libraries of one kind, what the overview pages go through.
    func libraries(podcasts: Bool) async -> [ABSLibrary] {
        await ensureLibraries()
        return libraries.filter { $0.isPodcasts == podcasts }
    }

    /// The books of a series or narrator, in all audiobook libraries unless it's known which.
    func filtered(group: String, value: String, library: String?, sort: String = "media.metadata.title") async throws -> [ABSItem] {
        let ids = if let library { [library] } else { await libraries(podcasts: false).map(\.id) }
        var out: [ABSItem] = []
        for id in ids {
            var page = 0
            while true {
                let answer = try await items(in: id, page: page, pageSize: 200, sort: sort, filter: (group, value))
                out += answer.items
                page += 1
                if answer.items.isEmpty || page * 200 >= answer.total { break }
            }
        }
        return out
    }

    func author(_ id: String) async throws -> (author: ABSAuthor, items: [ABSItem], series: [ABSSeriesEntry]) {
        struct Series: Decodable { let id: String; let name: String; let items: [Lossy<ABSItem>]? }
        struct Answer: Decodable {
            let id: String
            let name: String
            let description: String?
            let libraryItems: [Lossy<ABSItem>]?
            let series: [Lossy<Series>]?
        }
        let a = try await get(Answer.self, "/api/authors/\(id)?include=items,series")
        let series = (a.series ?? []).compactMap(\.value).map { s in
            let books = (s.items ?? []).compactMap(\.value)
            return ABSSeriesEntry(id: s.id, name: s.name, library: books.first?.libraryId ?? "", cover: books.first?.id, count: books.count)
        }
        return (ABSAuthor(id: a.id, name: a.name, description: a.description), (a.libraryItems ?? []).compactMap(\.value),
                series.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    func allAuthors() async throws -> [ABSAuthor] {
        struct Answer: Decodable { let authors: [Lossy<ABSAuthor>] }
        var out: [ABSAuthor] = []
        for lib in await libraries(podcasts: false) {
            out += try await get(Answer.self, "/api/libraries/\(lib.id)/authors").authors.compactMap(\.value)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func allSeries() async throws -> [ABSSeriesEntry] {
        struct Answer: Decodable {
            struct Entry: Decodable { let id: String; let name: String; let books: [Lossy<ABSItem>]? }
            let results: [Lossy<Entry>]
        }
        var out: [ABSSeriesEntry] = []
        for lib in await libraries(podcasts: false) {
            let a = try await get(Answer.self, "/api/libraries/\(lib.id)/series?limit=500&page=0&sort=name&minified=1")
            out += a.results.compactMap(\.value).map { e in
                let books = (e.books ?? []).compactMap(\.value)
                return ABSSeriesEntry(id: e.id, name: e.name, library: lib.id, cover: books.first?.id, count: books.count)
            }
        }
        return out
    }

    /// Asks all libraries at once and only needs to know which ones there are.
    func search(_ query: String) async -> ABSSearchResults {
        guard connected, let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return ABSSearchResults() }
        await ensureLibraries()
        struct Match: Decodable { let libraryItem: ABSItem }
        struct SeriesMatch: Decodable { let series: ABSSeriesRef }
        struct Narrator: Decodable { let name: String }
        struct Answer: Decodable {
            let book: [Lossy<Match>]?
            let podcast: [Lossy<Match>]?
            let authors: [Lossy<ABSAuthor>]?
            let series: [Lossy<SeriesMatch>]?
            let narrators: [Lossy<Narrator>]?
        }
        let answers = await withTaskGroup(of: Answer?.self) { group in
            for lib in libraries {
                group.addTask { [self] in try? await get(Answer.self, "/api/libraries/\(lib.id)/search?q=\(q)&limit=8") }
            }
            var out: [Answer] = []
            for await answer in group { if let answer { out.append(answer) } }
            return out
        }
        var results = ABSSearchResults()
        for a in answers {
            results.items += ((a.book ?? []) + (a.podcast ?? [])).compactMap { $0.value?.libraryItem }
            results.authors += (a.authors ?? []).compactMap(\.value)
            results.series += (a.series ?? []).compactMap { $0.value?.series }
            results.narrators += (a.narrators ?? []).compactMap { $0.value?.name }
        }
        return results
    }

    func setFinished(_ item: ABSItem, episode: ABSEpisode?, finished: Bool) async throws {
        struct Body: Encodable { let isFinished: Bool }
        let path = "/api/me/progress/\(item.id)" + (episode.map { "/\($0.id)" } ?? "")
        _ = try await send(path, method: "PATCH", body: Body(isFinished: finished))
        await load(force: true)
    }

    // MARK: Listening sessions

    func startSession(item: String, episode: String?) async throws -> ABSSession {
        guard let s = server else { throw AudiobookError.notConnected }
        struct Device: Encodable { let clientName: String; let deviceId: String }
        struct Body: Encodable {
            let forceDirectPlay = true
            let forceTranscode = false
            let mediaPlayer = "tonalo"
            let supportedMimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-aiff", "audio/ogg"]
            let deviceInfo: Device
        }
        let body = Body(deviceInfo: Device(clientName: "Tonalo iOS", deviceId: s.deviceId))
        let path = "/api/items/\(item)/play" + (episode.map { "/\($0)" } ?? "")
        let data = try await send(path, method: "POST", body: body)
        do { return try JSONDecoder().decode(ABSSession.self, from: data) } catch { throw AudiobookError.unexpected }
    }

    /// Tells the server the position and how much was really listened to since the last time.
    func syncSession(_ id: String, currentTime: Double, timeListened: Double, duration: Double, close: Bool = false) async throws {
        struct Body: Encodable { let currentTime: Double; let timeListened: Double; let duration: Double }
        _ = try await send("/api/session/\(id)/\(close ? "close" : "sync")", method: "POST",
                           body: Body(currentTime: currentTime, timeListened: timeListened, duration: duration), timeout: 10)
    }
}
