import Foundation

// MARK: - Accounts

/// Extra HTTP header sent with every request, e.g. for Cloudflare Access.
struct HeaderField: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

/// One server login. Stored as a whole in the Keychain, because token and header values are secrets.
struct Account: Codable, Hashable, Identifiable {
    var id = UUID()
    var serverURL: String
    var username: String
    var salt: String
    var token: String
    var headers: [HeaderField] = []
    /// Optional address inside the home network (e.g. http://192.168.1.10:4533), used on Wi-Fi when it answers.
    var localURL: String?

    var host: String { URL(string: serverURL)?.host ?? serverURL }

    /// Only headers with a name are sent; values are trimmed so pasted secrets don't break.
    var httpHeaders: [String: String] {
        var out: [String: String] = [:]
        for h in headers {
            let name = h.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[name] = h.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return out
    }
}

// MARK: - Subsonic data

struct Song: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    var artist: String?
    var album: String?
    var albumId: String?
    var artistId: String?
    var coverArt: String?
    var duration: Int?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var starred: String?
    var suffix: String?
    var bitRate: Int?
    var replayGain: ReplayGain?
}

/// Loudness values from the file tags (OpenSubsonic). Navidrome sends 0 dB when a file has none.
struct ReplayGain: Codable, Hashable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?
}

struct Album: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var year: Int?
    var songCount: Int?
    var duration: Int?
    var starred: String?
    var genre: String?
    var song: [Song]?
}

struct Artist: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    var coverArt: String?
    var albumCount: Int?
    var starred: String?
    var album: [Album]?
}

struct Playlist: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var owner: String?
    var comment: String?
    var `public`: Bool?
    var changed: String?
    var entry: [Song]?
}

/// The queue as the server keeps it for the user – whichever app saved it last.
struct PlayQueue: Codable {
    var entry: [Song]?
    var current: String?
    /// Milliseconds
    var position: Int?
    var changed: String?
    var changedBy: String?

    var changedDate: Date? {
        // Navidrome sends nanoseconds; the date parser only takes milliseconds
        guard let changed else { return nil }
        let trimmed = changed.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: trimmed) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }
}

struct Genre: Codable, Hashable {
    var value: String
    var albumCount: Int?
    var songCount: Int?
}

struct ArtistInfo: Codable {
    var biography: String?
    var similarArtist: [Artist]?
}

struct LyricLine: Codable, Hashable {
    var start: Int?
    var value: String
}

struct Lyrics: Codable {
    var synced: Bool
    var lines: [LyricLine]
}

// MARK: - Response envelope

struct SubsonicErrorBody: Codable { let code: Int; let message: String? }

struct AlbumList: Codable { var album: [Album]? }
struct SongList: Codable { var song: [Song]? }
struct ArtistIndex: Codable { var name: String; var artist: [Artist]? }
struct ArtistsBody: Codable { var index: [ArtistIndex]? }
struct PlaylistsBody: Codable { var playlist: [Playlist]? }
struct GenresBody: Codable { var genre: [Genre]? }
struct SearchBody: Codable { var artist: [Artist]?; var album: [Album]?; var song: [Song]? }
struct StructuredLyrics: Codable { var synced: Bool?; var line: [LyricLine]? }
struct LyricsListBody: Codable { var structuredLyrics: [StructuredLyrics]? }

/// Everything a Subsonic call can return – each endpoint fills one of these fields.
struct Payload: Codable {
    let status: String
    var error: SubsonicErrorBody?
    var albumList2: AlbumList?
    var album: Album?
    var artists: ArtistsBody?
    var artist: Artist?
    var artistInfo2: ArtistInfo?
    var topSongs: SongList?
    var similarSongs2: SongList?
    var randomSongs: SongList?
    var playlists: PlaylistsBody?
    var playlist: Playlist?
    var starred2: SearchBody?
    var searchResult3: SearchBody?
    var lyricsList: LyricsListBody?
    var genres: GenresBody?
    var playQueue: PlayQueue?
}

struct Envelope: Codable {
    let response: Payload
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

// MARK: - Helpers

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatDuration(_ seconds: Int) -> String {
    let m = seconds / 60
    if m < 60 { return String(localized: "\(m) min") }
    return String(localized: "\(m / 60) h \(m % 60) min")
}
