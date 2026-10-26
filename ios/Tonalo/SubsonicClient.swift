import Foundation
import CryptoKit

extension Error {
    /// The request was stopped on purpose (page left, pulled to refresh again) – not something to show.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let e = self as? URLError, e.code == .cancelled { return true }
        return (self as NSError).domain == NSURLErrorDomain && (self as NSError).code == NSURLErrorCancelled
    }

    /// The server answered properly, just with an error (wrong password, not found …).
    var isServerAnswer: Bool {
        if let e = self as? SubsonicError, case .server = e { return true }
        return false
    }

    /// Text for the user, or nil when there's nothing to tell (a cancelled request).
    var userMessage: String? { isCancellation ? nil : localizedDescription }
}

enum SubsonicError: LocalizedError {
    case badURL
    case server(code: Int, message: String)
    case notSubsonic(status: Int)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return String(localized: "The server address is not valid.")
        case .server(let code, let message):
            return code == 40 ? String(localized: "Wrong username or password.") : message
        case .notSubsonic(let status):
            // Typical when Cloudflare Access (or another proxy) answers instead of Navidrome
            return String(localized: "The server answered with something other than Subsonic (HTTP \(status)). Check the address and your custom headers.")
        case .http(let status): return String(localized: "Server error (HTTP \(status)).")
        }
    }
}

/// Network session for everything that talks to the server.
/// - No disk cache: Subsonic puts the login token into every address, and iOS would otherwise keep
///   those addresses (and the responses) in a plain database in the app's Caches folder.
/// - No redirects to other hosts: custom headers (e.g. a Cloudflare Access secret) must only reach the server itself.
final class ServerSession: NSObject, URLSessionTaskDelegate {
    static let shared = ServerSession()
    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        task.originalRequest?.url?.host == request.url?.host ? request : nil
    }
}

/// Library answers saved on the device per account: pages show the last known state at once,
/// and a bad or missing connection shows that instead of an error. Only music metadata is stored –
/// never the request addresses, which carry the login token.
enum LibraryCache {
    /// Endpoints worth keeping. Searches, random picks and anything that changes something are left out.
    static let methods: Set<String> = ["getAlbumList2", "getAlbum", "getArtists", "getArtist", "getArtistInfo2",
                                       "getTopSongs", "getPlaylists", "getPlaylist", "getGenres", "getStarred2"]

    private static let root: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func key(_ method: String, _ params: [String: String]) -> String? {
        guard methods.contains(method) else { return nil }
        return ([method] + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "&")
    }

    private static func file(_ account: UUID, _ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(account.uuidString, isDirectory: true).appendingPathComponent(name + ".json")
    }

    static func load(_ account: UUID, _ key: String) -> Payload? {
        guard let data = try? Data(contentsOf: file(account, key)) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data).response
    }

    static func save(_ data: Data, _ account: UUID, _ key: String) {
        let url = file(account, key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func deleteAccount(_ id: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }
}

/// Talks to a Subsonic/Navidrome server. Every request carries the account's custom headers.
struct SubsonicClient {
    let account: Account
    /// Talking to the home address: faster, and without the custom headers – those belong to the proxy outside.
    let atHome: Bool

    init(account: Account, atHome: Bool = false) {
        self.account = account
        self.atHome = atHome && account.localURL != nil
    }

    var base: String { atHome ? account.localURL ?? account.serverURL : account.serverURL }
    var headers: [String: String] { atHome ? [:] : account.httpHeaders }
    /// Also how other apps recognize us in the shared play queue ("changedBy").
    static let clientName = "Tonalo-iOS"
    private static let apiVersion = "1.16.1"

    static func makeToken(password: String) -> (salt: String, token: String) {
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return (salt, digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Addresses that only exist in the home network: private IPs, localhost, .local and similar names.
    /// Only for those is plain http tried automatically – anywhere else that would send the login unencrypted.
    static func isLocal(_ address: String) -> Bool {
        guard let host = URL(string: address.contains("://") ? address : "http://" + address)?.host?.lowercased() else { return false }
        if host == "localhost" || !host.contains(".") && !host.contains(":") { return true }
        for suffix in [".local", ".lan", ".home", ".home.arpa", ".internal", ".fritz.box"] where host.hasSuffix(suffix) { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
                || (p[0] == 169 && p[1] == 254) || (p[0] == 100 && (64...127).contains(p[1])) // last: Tailscale & co.
        }
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return v6.hasPrefix("fd") || v6.hasPrefix("fc") || v6.hasPrefix("fe80") || v6 == "::1"
    }

    /// Home addresses are usually plain http on the local network.
    static func normalizeLocal(_ address: String) -> String? {
        let s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let hasScheme = s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")
        return normalize(hasScheme ? s : "http://" + s)
    }

    static func normalize(_ address: String) -> String {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/rest") { s.removeLast(5) }
        return s
    }

    func url(_ method: String, _ params: [String: String] = [:]) -> URL? {
        url(method, items: params.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    /// Repeated parameters (several `id`s, for example) need a list instead of a dictionary.
    func url(_ method: String, items extra: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: base + "/rest/" + method) else { return nil }
        var items = [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: account.token),
            URLQueryItem(name: "s", value: account.salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items += extra
        comps.queryItems = items
        // URLComponents leaves "+" alone, but servers read it as a space ("Simon + Garfunkel" would lose its plus)
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func call(_ method: String, _ params: [String: String] = [:]) async throws -> Payload {
        guard let u = url(method, params) else { throw SubsonicError.badURL }
        let key = LibraryCache.key(method, params)
        do {
            let (payload, data) = try await sendRaw(request(u))
            if let key { LibraryCache.save(data, account.id, key) }
            return payload
        } catch {
            // No (usable) connection: the last known answer is better than an error.
            // Not for real answers from the server (wrong password, not found) or cancelled requests.
            if let key, !error.isCancellation, !error.isServerAnswer,
               let saved = LibraryCache.load(account.id, key) { return saved }
            throw error
        }
    }

    /// The saved answer of a library request, without asking the server – for showing a page at once.
    func cached(_ method: String, _ params: [String: String] = [:]) -> Payload? {
        LibraryCache.key(method, params).flatMap { LibraryCache.load(account.id, $0) }
    }

    /// Long lists (a whole queue or playlist) go in a form body instead of the address, which servers limit in length.
    /// Navidrome accepts that ("formPost"); servers that don't get the address version.
    func post(_ method: String, _ params: [URLQueryItem]) async throws -> Payload {
        guard let full = url(method, items: params), var comps = URLComponents(url: full, resolvingAgainstBaseURL: false) else { throw SubsonicError.badURL }
        let query = comps.percentEncodedQuery ?? ""
        comps.query = nil
        guard let endpoint = comps.url else { throw SubsonicError.badURL }
        var r = request(endpoint)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(query.utf8) // "+" is already escaped by url(), see there
        do {
            return try await send(r)
        } catch SubsonicError.server(let code, let message) {
            throw SubsonicError.server(code: code, message: message)
        } catch {
            return try await send(request(full))
        }
    }

    private func send(_ r: URLRequest) async throws -> Payload {
        try await sendRaw(r).0
    }

    private func sendRaw(_ r: URLRequest) async throws -> (Payload, Data) {
        let (data, resp) = try await ServerSession.shared.session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("json") else { throw SubsonicError.notSubsonic(status: status) }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw status >= 400 ? SubsonicError.http(status) : SubsonicError.notSubsonic(status: status)
        }
        if env.response.status != "ok" {
            throw SubsonicError.server(code: env.response.error?.code ?? 0, message: env.response.error?.message ?? "Unknown error")
        }
        return (env.response, data)
    }

    // MARK: Endpoints

    func ping() async throws { _ = try await call("ping") }

    /// Quick check whether this address answers at all – used for the home address.
    func reachable() async -> Bool {
        guard let u = url("ping") else { return false }
        var r = request(u)
        r.timeoutInterval = 3
        return (try? await send(r)) != nil
    }

    func albumList(_ type: String, size: Int = 30, offset: Int = 0, genre: String? = nil) async throws -> [Album] {
        var p = ["type": type, "size": "\(size)", "offset": "\(offset)"]
        if let genre { p["genre"] = genre }
        return try await call("getAlbumList2", p).albumList2?.album ?? []
    }

    func album(_ id: String) async throws -> Album {
        guard let a = try await call("getAlbum", ["id": id]).album else { throw SubsonicError.http(404) }
        return a
    }

    func artists() async throws -> [Artist] {
        (try await call("getArtists").artists?.index ?? []).flatMap { $0.artist ?? [] }
    }

    func artist(_ id: String) async throws -> Artist {
        guard let a = try await call("getArtist", ["id": id]).artist else { throw SubsonicError.http(404) }
        return a
    }

    func artistInfo(_ id: String) async -> ArtistInfo? {
        try? await call("getArtistInfo2", ["id": id, "count": "10"]).artistInfo2
    }

    func topSongs(_ artistName: String) async -> [Song] {
        (try? await call("getTopSongs", ["artist": artistName, "count": "10"]).topSongs?.song) ?? []
    }

    func similarSongs(_ id: String) async -> [Song] {
        (try? await call("getSimilarSongs2", ["id": id, "count": "50"]).similarSongs2?.song) ?? []
    }

    func randomSongs(_ size: Int = 100) async throws -> [Song] {
        try await call("getRandomSongs", ["size": "\(size)"]).randomSongs?.song ?? []
    }

    func playlists() async throws -> [Playlist] {
        try await call("getPlaylists").playlists?.playlist ?? []
    }

    func playlist(_ id: String) async throws -> Playlist {
        guard let p = try await call("getPlaylist", ["id": id]).playlist else { throw SubsonicError.http(404) }
        return p
    }

    func genres() async throws -> [Genre] {
        try await call("getGenres").genres?.genre ?? []
    }

    func starred() async throws -> SearchBody {
        try await call("getStarred2").starred2 ?? SearchBody()
    }

    func search(_ query: String) async throws -> SearchBody {
        try await call("search3", ["query": query, "artistCount": "10", "albumCount": "20", "songCount": "40"]).searchResult3 ?? SearchBody()
    }

    func setStar(songId: String? = nil, albumId: String? = nil, artistId: String? = nil, on: Bool) async throws {
        var p: [String: String] = [:]
        if let songId { p["id"] = songId }
        if let albumId { p["albumId"] = albumId }
        if let artistId { p["artistId"] = artistId }
        _ = try await call(on ? "star" : "unstar", p)
    }

    /// Returns false if the server couldn't be reached, so the scrobble can be sent later.
    @discardableResult
    func scrobble(_ id: String, submission: Bool, time: Date? = nil) async -> Bool {
        var p = ["id": id, "submission": submission ? "true" : "false"]
        if let time { p["time"] = String(Int64(time.timeIntervalSince1970 * 1000)) }
        do { _ = try await call("scrobble", p); return true } catch { return false }
    }

    // MARK: Play queue (continue on another device)

    func playQueue() async -> PlayQueue? {
        try? await call("getPlayQueue").playQueue
    }

    func savePlayQueue(_ ids: [String], current: String, position: Double) async {
        var items = ids.map { URLQueryItem(name: "id", value: $0) }
        items += [URLQueryItem(name: "current", value: current), URLQueryItem(name: "position", value: "\(Int(position * 1000))")]
        _ = try? await post("savePlayQueue", items)
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String, songIds: [String]) async throws -> Playlist? {
        try await post("createPlaylist", [URLQueryItem(name: "name", value: name)] + songIds.map { URLQueryItem(name: "songId", value: $0) }).playlist
    }

    /// Replaces all songs of a playlist – used for reordering, which updatePlaylist can't do.
    func replacePlaylistSongs(_ id: String, songIds: [String]) async throws {
        _ = try await post("createPlaylist", [URLQueryItem(name: "playlistId", value: id)] + songIds.map { URLQueryItem(name: "songId", value: $0) })
    }

    func updatePlaylist(_ id: String, name: String? = nil, add: [String] = [], removeIndexes: [Int] = []) async throws {
        var items = [URLQueryItem(name: "playlistId", value: id)]
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        items += add.map { URLQueryItem(name: "songIdToAdd", value: $0) }
        items += removeIndexes.map { URLQueryItem(name: "songIndexToRemove", value: "\($0)") }
        _ = try await post("updatePlaylist", items)
    }

    func deletePlaylist(_ id: String) async throws {
        _ = try await call("deletePlaylist", ["id": id])
    }

    func lyrics(_ songId: String) async -> Lyrics? {
        guard let list = try? await call("getLyricsBySongId", ["id": songId]).lyricsList?.structuredLyrics, !list.isEmpty else { return nil }
        let pick = list.first(where: { $0.synced == true }) ?? list[0]
        let lines = pick.line ?? []
        return lines.isEmpty ? nil : Lyrics(synced: pick.synced ?? false, lines: lines)
    }

    // MARK: Media URLs

    func coverURL(_ id: String?, size: Int = 300) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        return url("getCoverArt", ["id": id, "size": "\(size)"])
    }

    /// For offline downloads: the original file byte for byte, or the converted version.
    func downloadURL(_ song: Song, quality: AudioQuality) -> URL? {
        let q = quality.resolved(for: song)
        return q.format == nil ? url("download", ["id": song.id]) : streamURL(song, quality: q)
    }

    /// `offset` starts a converted stream later in the song – converted streams can't be seeked otherwise.
    func streamURL(_ song: Song, quality: AudioQuality, offset: Int = 0) -> URL? {
        let q = quality.resolved(for: song)
        guard let format = q.format else { return url("stream", ["id": song.id, "format": "raw"]) }
        var p = ["id": song.id, "format": format, "maxBitRate": "\(q.bitRate)"]
        if offset > 0 { p["timeOffset"] = "\(offset)" }
        return url("stream", p)
    }
}
