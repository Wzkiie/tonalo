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
        // Seeking doesn't change anything the tracking above sees: look for a jump in the position every few seconds
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in WatchBridge.shared.push() } }
    }

    // MARK: Player state → watch

    private func watchPlayer() {
        withObservationTracking {
            let p = app.player
            _ = (p.current?.id, p.current?.starred, p.isPlaying, p.shuffle, p.repeatMode, p.duration, p.context, p.station?.id, p.stationTitle)
            let b = app.bookPlayer
            _ = (b.item?.id, b.session?.id, b.isPlaying, b.rate, b.chapter?.title)
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
        if let b = p.book, let item = b.item {
            let id = "abs:" + item.id
            return WatchNowPlaying(songId: id, title: b.chapter?.title ?? b.title, artist: b.chapter != nil ? b.title : b.creator, context: b.creator,
                                   isPlaying: b.isPlaying, position: b.position, duration: b.duration, sentAt: .now,
                                   starred: false, shuffle: false, repeatMode: "off",
                                   accentHex: Theme.shared.accentHex, cover: cover?.id == id ? cover?.data : nil,
                                   isBook: true, rate: Double(b.rate), skipBack: b.skipBack, skipForward: b.skipForward)
        }
        // A station plays: the song that is still in the queue is not what you hear, and a heart, shuffle or repeat means nothing
        if let station = p.station {
            return WatchNowPlaying(songId: "station:" + station.id, title: p.stationTitle ?? station.name, artist: station.name, context: station.name,
                                   isPlaying: p.isPlaying, position: 0, duration: 0, sentAt: .now,
                                   starred: false, shuffle: false, repeatMode: "off",
                                   accentHex: Theme.shared.accentHex, cover: nil)
        }
        guard let song = p.current else { return nil }
        let coverId = song.coverArt ?? song.albumId ?? song.id
        return WatchNowPlaying(songId: song.id, title: song.title, artist: song.artist ?? "", context: p.context?.name ?? song.album,
                               isPlaying: p.isPlaying, position: p.position, duration: p.duration, sentAt: .now,
                               starred: song.starred != nil, shuffle: p.shuffle, repeatMode: p.repeatMode.rawValue,
                               accentHex: Theme.shared.accentHex, cover: cover?.id == coverId ? cover?.data : nil)
    }

    private func push() {
        #if DEBUG
        let ready = WCSession.default.activationState == .activated // the simulator doesn't report the watch app as installed
        #else
        let ready = WCSession.default.activationState == .activated && WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
        #endif
        guard ready else { return }
        guard var s = state else {
            // Nothing plays any more (the book ended, the queue is gone): the watch shouldn't keep showing the last thing
            if lastSent != nil {
                lastSent = nil
                try? WCSession.default.updateApplicationContext([Watch.data: Data()])
                if WCSession.default.isReachable { WCSession.default.sendMessage([Watch.data: Data()], replyHandler: nil, errorHandler: nil) }
            }
            return
        }
        // The cover only changes with the song: load it once, then send the state again with it
        let coverId = app.player.book != nil ? s.songId : (app.player.current?.coverArt ?? app.player.current?.albumId ?? s.songId)
        if cover?.id != coverId {
            Task {
                guard let data = await thumbnail(coverId, size: 200, quality: 0.5) else { return } // small: every state update carries it
                cover = (coverId, data)
                push()
            }
        }
        // Positions keep changing; only send when something the watch shows has changed
        var compare = s; compare.position = lastSent?.position ?? 0; compare.sentAt = lastSent?.sentAt ?? .now
        // Compare with where the watch counts to by now, so a jump (seeking on the phone) is sent, normal playing is not
        var expected = lastSent?.position ?? 0
        if let last = lastSent, last.isPlaying { expected += Date.now.timeIntervalSince(last.sentAt) * (last.rate ?? 1) }
        if compare == lastSent && abs(expected - s.position) < 2 { return }
        s.sentAt = .now
        lastSent = s
        if let data = Watch.encode(s) {
            do { try WCSession.default.updateApplicationContext([Watch.data: data]) } catch { NSLog("WATCHDBG context failed (%d bytes): %@", data.count, "\(error)") }
            // The context may wait a while; with the watch app open, a message gets there at once (music ↔ book switches)
            if WCSession.default.isReachable { WCSession.default.sendMessage([Watch.data: data], replyHandler: nil, errorHandler: nil) }
        }
    }

    // MARK: Commands from the watch

    fileprivate func handle(_ message: [String: Any]) async -> [String: Any] {
        let p = app.player
        let book = p.book
        switch message[Watch.command] as? String {
        case "toggle": if let book { book.toggle() } else { p.toggle() }
        case "resume": if let book { if !book.isPlaying { book.toggle() } } else if !p.isPlaying { p.toggle() }
        case "pause": if let book { if book.isPlaying { book.toggle() } } else if p.isPlaying { p.toggle() }
        case "next": if let book { book.nextChapter() } else { p.next() }
        case "previous": if let book { book.previousChapter() } else { p.previous() }
        case "skip":
            if let book, let s = message[Watch.index] as? Double { book.skip(s) }
        case "shuffle": if book == nil, p.station == nil { p.toggleShuffle() }
        case "repeat": if book == nil, p.station == nil { p.cycleRepeat() }
        case "favorite":
            if book == nil, p.station == nil, let song = p.current { await app.setFavorite(song, song.starred == nil) }
        case "seek":
            if let s = message[Watch.index] as? Double { if let book { book.seek(to: s) } else { p.seek(to: s) } }
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
        guard let client = app.client else { return kind == nil ? bookSections() : [] }
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
            return bookSections() + sections
        }
    }

    /// The books and episodes you are in the middle of – first on the watch, they are what you pick up again.
    private func bookSections() -> [WatchSection] {
        guard app.books.connected else { return [] }
        let started = app.books.continueListening.isEmpty ? app.books.inProgress : app.books.continueListening
        guard !started.isEmpty else { return [] }
        return [WatchSection(title: String(localized: "Continue listening"), items: started.prefix(10).map {
            WatchItem(id: $0.id + ($0.recentEpisode.map { "|" + $0.id } ?? ""), kind: .book, title: $0.recentEpisode?.title ?? $0.title,
                      subtitle: $0.recentEpisode != nil ? $0.title : $0.creator, coverId: "abs:" + $0.id)
        })]
    }

    private func play(_ kind: WatchItem.Kind, id: String?, index: Int, shuffled: Bool) async {
        if kind == .book, let id {
            // "item" or "item|episode"
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            let known = (app.books.continueListening + app.books.inProgress).first { $0.id == parts[0] }
            var found = known
            if found == nil { found = try? await app.books.item(parts[0]) }
            guard let item = found else { return }
            app.bookPlayer.play(item) // continues with the episode in progress
            return
        }
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
        case .song, .book: break
        }
    }

    /// Small JPEG of a cover for the watch (WatchConnectivity messages have to stay small).
    private func thumbnail(_ id: String, size: CGFloat, quality: CGFloat = 0.7) async -> Data? {
        var image: UIImage?
        if id.hasPrefix("abs:") { image = await app.books.coverImage(String(id.dropFirst(4)), width: 300) }
        else if let local = app.downloads.localCover(id) { image = UIImage(contentsOfFile: local.path) }
        if image == nil, !id.hasPrefix("abs:"), let client = app.client, let url = client.coverURL(id, size: 300) {
            image = await ImageLoader.shared.image(url, headers: client.headers)
        }
        guard let image else { return nil }
        let target = CGSize(width: size, height: size)
        // Scale 1: the default is the phone's screen scale, which makes a 200 point image 600 pixels wide (3x the bytes)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let small = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return small.jpegData(compressionQuality: quality)
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
