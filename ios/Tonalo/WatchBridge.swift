import Observation
import UIKit
import WatchConnectivity

/// The iPhone end of the watch app: sends the player state to the watch and carries out its commands.
/// The watch never talks to the server itself, so logins and custom headers stay on the phone.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    private var app: AppModel { AppModel.shared }
    private var lastSent: WatchNowPlaying?
    private var cover: (id: String, data: Data)?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        watchPlayer()
    }

    // MARK: Player state → watch

    private func watchPlayer() {
        withObservationTracking {
            let p = app.player
            _ = (p.current?.id, p.current?.starred, p.isPlaying, p.shuffle, p.repeatMode, p.duration, p.context)
            _ = Theme.shared.accentHex
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.push()
                self?.watchPlayer()
            }
        }
        push()
    }

    private var state: WatchNowPlaying? {
        let p = app.player
        guard let song = p.current else { return nil }
        let coverId = song.coverArt ?? song.albumId ?? song.id
        return WatchNowPlaying(songId: song.id, title: song.title, artist: song.artist ?? "", context: p.context?.name ?? song.album,
                               isPlaying: p.isPlaying, position: p.position, duration: p.duration, sentAt: .now,
                               starred: song.starred != nil, shuffle: p.shuffle, repeatMode: p.repeatMode.rawValue,
                               accentHex: Theme.shared.accentHex, cover: cover?.id == coverId ? cover?.data : nil)
    }

    private func push() {
        guard WCSession.default.activationState == .activated, WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              var s = state else { return }
        // The cover only changes with the song: load it once, then send the state again with it
        let coverId = app.player.current?.coverArt ?? app.player.current?.albumId ?? s.songId
        if cover?.id != coverId {
            Task {
                guard let data = await thumbnail(coverId, size: 300) else { return }
                cover = (coverId, data)
                push()
            }
        }
        // Positions keep changing; only send when something the watch shows has changed
        var compare = s; compare.position = lastSent?.position ?? 0; compare.sentAt = lastSent?.sentAt ?? .now
        if compare == lastSent && abs((lastSent?.position ?? 0) - s.position) < 3 { return }
        s.sentAt = .now
        lastSent = s
        if let data = Watch.encode(s) { try? WCSession.default.updateApplicationContext([Watch.data: data]) }
    }

    // MARK: Commands from the watch

    fileprivate func handle(_ message: [String: Any]) async -> [String: Any] {
        let p = app.player
        switch message[Watch.command] as? String {
        case "toggle": p.toggle()
        case "next": p.next()
        case "previous": p.previous()
        case "shuffle": p.toggleShuffle()
        case "repeat": p.cycleRepeat()
        case "favorite":
            if let song = p.current { await app.setFavorite(song, song.starred == nil) }
        case "seek":
            if let s = message[Watch.index] as? Double { p.seek(to: s) }
        case "list":
            let kind = (message[Watch.kind] as? String).flatMap(WatchItem.Kind.init)
            let sections = await list(kind, id: message[Watch.id] as? String)
            return [Watch.data: Watch.encode(sections) ?? Data()]
        case "play":
            guard let kind = (message[Watch.kind] as? String).flatMap(WatchItem.Kind.init) else { break }
            await play(kind, id: message[Watch.id] as? String, index: message[Watch.index] as? Int ?? 0,
                       shuffled: message[Watch.shuffle] as? Bool ?? false)
        case "cover":
            if let id = message[Watch.id] as? String, let data = await thumbnail(id, size: 120) { return [Watch.data: data] }
            return [:]
        default: break
        }
        lastSent = nil // always answer with a fresh state
        return [Watch.data: state.flatMap(Watch.encode) ?? Data()]
    }

    /// Home screen of the watch, or the songs of a playlist/album/favorites.
    private func list(_ kind: WatchItem.Kind?, id: String?) async -> [WatchSection] {
        guard let client = app.client else { return [] }
        func songs(_ list: [Song]) -> [WatchSection] {
            [WatchSection(title: "", items: list.prefix(200).map {
                WatchItem(id: $0.id, kind: .song, title: $0.title, subtitle: $0.artist, coverId: $0.coverArt ?? $0.albumId)
            })]
        }
        switch kind {
        case .favorites:
            return songs((try? await client.starred().song) ?? [])
        case .playlist:
            guard let id else { return [] }
            return songs(((try? await client.playlist(id)) ?? app.downloads.index.playlists[id])?.entry ?? [])
        case .album:
            guard let id else { return [] }
            return songs(((try? await client.album(id)) ?? app.downloads.index.albums[id])?.song ?? [])
        default:
            var sections = [WatchSection(title: String(localized: "Made for you"), items: [
                WatchItem(id: "favorites", kind: .favorites, title: String(localized: "Favorite songs"), subtitle: nil),
                WatchItem(id: "shuffle", kind: .mix, title: String(localized: "Shuffle mix"), subtitle: String(localized: "Random songs from your library")),
            ])]
            if let p = try? await client.playlists(), !p.isEmpty {
                sections.append(WatchSection(title: String(localized: "Your playlists"), items: p.prefix(30).map {
                    WatchItem(id: $0.id, kind: .playlist, title: $0.name, subtitle: String(localized: "\($0.songCount ?? 0) songs"), coverId: $0.coverArt ?? $0.id)
                }))
            }
            if let a = try? await client.albumList("recent", size: 15), !a.isEmpty {
                sections.append(WatchSection(title: String(localized: "Recently played"), items: a.map {
                    WatchItem(id: $0.id, kind: .album, title: $0.name, subtitle: $0.artist, coverId: $0.coverArt ?? $0.id)
                }))
            }
            return sections
        }
    }

    private func play(_ kind: WatchItem.Kind, id: String?, index: Int, shuffled: Bool) async {
        guard let client = app.client else { return }
        switch kind {
        case .mix:
            if let songs = try? await client.randomSongs(150) {
                app.player.play(songs, context: .init(kind: .mix, name: String(localized: "Shuffle mix")))
            }
        case .favorites:
            if let songs = try? await client.starred().song, !songs.isEmpty {
                app.player.play(songs, from: index, shuffled: shuffled, context: .init(kind: .favorites, name: String(localized: "Favorite songs")))
            }
        case .playlist:
            guard let id, let p = (try? await client.playlist(id)) ?? app.downloads.index.playlists[id] else { return }
            app.player.play(p.entry ?? [], from: index, shuffled: shuffled, context: .init(kind: .playlist, id: p.id, name: p.name))
        case .album:
            guard let id, let a = (try? await client.album(id)) ?? app.downloads.index.albums[id] else { return }
            app.player.play(a.song ?? [], from: index, shuffled: shuffled, context: .init(kind: .album, id: a.id, name: a.name))
        case .song: break
        }
    }

    /// Small JPEG of a cover for the watch (WatchConnectivity messages have to stay small).
    private func thumbnail(_ id: String, size: CGFloat) async -> Data? {
        var image: UIImage?
        if let local = app.downloads.localCover(id) { image = UIImage(contentsOfFile: local.path) }
        if image == nil, let client = app.client, let url = client.coverURL(id, size: 300) {
            image = await ImageLoader.shared.image(url, headers: client.headers)
        }
        guard let image else { return nil }
        let target = CGSize(width: size, height: size)
        let small = UIGraphicsImageRenderer(size: target).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return small.jpegData(compressionQuality: 0.7)
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.lastSent = nil; self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.lastSent = nil; self.push() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.lastSent = nil; self.push() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in reply(await self.handle(message)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        nonisolated(unsafe) let message = message
        Task { @MainActor in _ = await self.handle(message) }
    }
}
