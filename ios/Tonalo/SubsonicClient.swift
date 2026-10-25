import Foundation
import CryptoKit

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

/// Talks to a Subsonic/Navidrome server. Every request carries the account's custom headers.
struct SubsonicClient {
    let account: Account
    private static let clientName = "Tonalo-iOS"
    private static let apiVersion = "1.16.1"

    static func makeToken(password: String) -> (salt: String, token: String) {
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return (salt, digest.map { String(format: "%02x", $0) }.joined())
    }

    static func normalize(_ address: String) -> String {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/rest") { s.removeLast(5) }
        return s
    }

    func url(_ method: String, _ params: [String: String] = [:]) -> URL? {
        guard var comps = URLComponents(string: account.serverURL + "/rest/" + method) else { return nil }
        var items = [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: account.token),
            URLQueryItem(name: "s", value: account.salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        return comps.url
    }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        for (k, v) in account.httpHeaders { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func call(_ method: String, _ params: [String: String] = [:]) async throws -> Payload {
        guard let u = url(method, params) else { throw SubsonicError.badURL }
        let (data, resp) = try await URLSession.shared.data(for: request(u))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("json") else { throw SubsonicError.notSubsonic(status: status) }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw status >= 400 ? SubsonicError.http(status) : SubsonicError.notSubsonic(status: status)
        }
        if env.response.status != "ok" {
            throw SubsonicError.server(code: env.response.error?.code ?? 0, message: env.response.error?.message ?? "Unknown error")
        }
        return env.response
    }

    // MARK: Endpoints

    func ping() async throws { _ = try await call("ping") }

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

    /// For offline downloads: the original file, or a transcoded MP3 when a bitrate is set.
    func downloadURL(_ id: String, maxBitRate: Int) -> URL? {
        maxBitRate > 0 ? streamURL(id, maxBitRate: maxBitRate) : url("download", ["id": id])
    }

    func streamURL(_ id: String, maxBitRate: Int) -> URL? {
        var p = ["id": id]
        if maxBitRate > 0 { p["maxBitRate"] = "\(maxBitRate)"; p["format"] = "mp3" }
        return url("stream", p)
    }
}
