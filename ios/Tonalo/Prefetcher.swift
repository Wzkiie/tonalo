import Foundation
import CryptoKit

/// Loads the next songs of the queue ahead of time, so a weak or patchy connection doesn't stop the music.
/// A small rotating cache: only the song that's playing and the ones coming up are kept, everything else goes.
/// Files hold nothing but audio; the request addresses (with the login token) aren't stored.
@MainActor final class Prefetcher {
    nonisolated static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Prefetch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var runner: Task<Void, Never>?

    private static func file(account: UUID, song: Song, quality: AudioQuality) -> URL {
        let name = SHA256.hash(data: Data("\(account)|\(song.id)|\(quality.rawValue)".utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension(quality.fileExtension(for: song))
    }

    /// The loaded file for a song, if it's there in the quality that would be streamed now.
    func localFile(account: UUID, song: Song, quality: AudioQuality) -> URL? {
        let url = Self.file(account: account, song: song, quality: quality)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps `current` and `upcoming`, removes the rest and loads what's missing – one song at a time,
    /// so the song that's playing keeps most of the bandwidth.
    func update(current: Song?, upcoming: [Song], client: SubsonicClient, quality: AudioQuality) {
        runner?.cancel()
        let account = client.account.id
        let wanted = ([current].compactMap { $0 } + upcoming).map { Self.file(account: account, song: $0, quality: quality.resolved(for: $0)) }
        let keep = Set(wanted.map(\.lastPathComponent))
        for file in (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        guard !upcoming.isEmpty else { return }
        runner = Task {
            for song in upcoming {
                guard !Task.isCancelled else { return }
                let q = quality.resolved(for: song)
                let target = Self.file(account: account, song: song, quality: q)
                guard !FileManager.default.fileExists(atPath: target.path), let url = client.streamURL(song, quality: q) else { continue }
                do {
                    let (tmp, response) = try await ServerSession.shared.session.download(for: client.request(url))
                    let http = response as? HTTPURLResponse
                    // Subsonic reports errors as a JSON/XML answer – that's no song
                    let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                    guard http?.statusCode == 200, !type.contains("json"), !type.contains("xml"), !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: tmp)
                        continue
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: tmp, to: target)
                } catch {
                    return // no connection: try again when the next song starts
                }
            }
        }
    }

    func clear() {
        runner?.cancel()
        runner = nil
        for file in (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
