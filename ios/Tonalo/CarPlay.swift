import CarPlay
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// CarPlay: tabs for Home, Radio, Library and Downloads, song lists, and the system Now Playing screen with
/// shuffle, a heart and repeat. iOS only connects this scene when the app has Apple's CarPlay audio
/// entitlement (see docs/CARPLAY.md) – without it nothing here runs.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interface: CPInterfaceController?
    private var downloads: CPListTemplate?
    private var app: AppModel { AppModel.shared }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        let downloads = downloadsTab()
        self.downloads = downloads
        let tabs = CPTabBarTemplate(templates: [homeTab(), radioTab(), libraryTab(), downloads])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        CPNowPlayingTemplate.shared.add(self)
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
        CPNowPlayingTemplate.shared.upNextTitle = String(localized: "Up next")
        watchPlayer()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        interface = nil
        downloads = nil
    }

    // MARK: Tabs

    private func homeTab() -> CPListTemplate {
        let t = CPListTemplate(title: String(localized: "Home"), sections: [])
        t.tabTitle = String(localized: "Home")
        t.tabImage = UIImage(systemName: "house.fill")
        t.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        Task { await fillHome(t) }
        return t
    }

    private func fillHome(_ t: CPListTemplate) async {
        guard let client = app.client else { return }
        var sections: [CPListSection] = []

        // The same mixes as on the phone, in the same colors
        let mixes = [
            item(String(localized: "Shuffle mix"), detail: String(localized: "Random songs from your library"), image: ArtTile.image(symbol: "shuffle", hue: 0.62)) { [weak self] in
                guard let songs = try? await client.randomSongs(150) else { return }
                self?.play(songs, context: .init(kind: .mix, name: String(localized: "Shuffle mix")))
            },
            item(String(localized: "Favorites mix"), detail: String(localized: "Your favorite songs, shuffled"), image: ArtTile.image(symbol: "heart.fill", hue: 0.92)) { [weak self] in
                guard let songs = try? await client.starred().song, !songs.isEmpty else { return }
                self?.play(songs, shuffled: true, context: .init(kind: .favorites, name: String(localized: "Favorite songs")))
            },
            item(String(localized: "Discover"), detail: String(localized: "Albums you haven’t heard in a while"), image: ArtTile.image(symbol: "sparkles", hue: 0.12)) { [weak self] in
                guard let albums = try? await client.albumList("random", size: 6) else { return }
                var songs: [Song] = []
                for a in albums { songs += ((try? await client.album(a.id).song) ?? []).shuffled().prefix(4) }
                self?.play(songs.shuffled(), context: .init(kind: .mix, name: String(localized: "Discover")))
            },
            yourRadio(),
        ]
        sections.append(CPListSection(items: mixes, header: String(localized: "Made for you"), sectionIndexTitle: nil))

        if let recent = try? await client.albumList("recent", size: 12), !recent.isEmpty {
            sections.append(CPListSection(items: [albumGrid(String(localized: "Recently played"), recent)]))
        }
        if let newest = try? await client.albumList("newest", size: 12), !newest.isEmpty {
            sections.append(CPListSection(items: [albumGrid(String(localized: "Recently added"), newest)]))
        }
        if let playlists = try? await client.playlists(), !playlists.isEmpty {
            sections.append(CPListSection(items: playlists.prefix(limit).map(playlistItem), header: String(localized: "Your playlists"), sectionIndexTitle: nil))
        }
        t.updateSections(sections)
        if sections.count == 1 && !app.isOnline { t.emptyViewSubtitleVariants = [String(localized: "You’re offline")] }
    }

    /// The endless radios and the stations set up on the server – like the Radio page on the phone.
    private func radioTab() -> CPListTemplate {
        let t = CPListTemplate(title: String(localized: "Radio"), sections: [])
        t.tabTitle = String(localized: "Radio")
        t.tabImage = UIImage(systemName: "dot.radiowaves.left.and.right")
        t.emptyViewSubtitleVariants = [String(localized: "Loading…")]
        Task { await fillRadio(t) }
        return t
    }

    private func fillRadio(_ t: CPListTemplate) async {
        guard let client = app.client else { return }
        async let loadStations = try? client.stations()
        async let loadGenres = try? client.genres()
        let stations = await loadStations ?? []
        let genres = radioGenres(await loadGenres ?? [])

        var radios = [yourRadio()]
        if let song = app.player.station == nil ? app.player.current : nil, let name = song.artist {
            radios.append(item(String(localized: "More like \(name)"), detail: String(localized: "Radio from the song playing now"),
                               image: ArtTile.image(symbol: "music.mic", hue: 0.75)) { [weak self] in
                await self?.app.player.radio.start(String(localized: "\(name) radio"), seedId: song.artistId ?? song.id, seeds: [song])
                self?.showNowPlaying()
            })
        }
        radios += genres.prefix(limit - 2).map { g in
            item(g.value, detail: String(localized: "Genre radio"), image: ArtTile.image(symbol: "guitars", hue: stableHue(g.value))) { [weak self] in
                await self?.app.player.radio.start(String(localized: "\(g.value) radio"), genre: g.value)
                self?.showNowPlaying()
            }
        }
        var sections = [CPListSection(items: radios, header: String(localized: "Endless radio"), sectionIndexTitle: nil)]
        if !stations.isEmpty {
            let rows = stations.prefix(limit).map { s in
                item(s.name, image: ArtTile.image(symbol: "dot.radiowaves.left.and.right", hue: stableHue(s.name))) { [weak self] in
                    self?.app.player.play(s, in: stations)
                    self?.showNowPlaying()
                }
            }
            sections.append(CPListSection(items: rows, header: String(localized: "Stations"), sectionIndexTitle: nil))
        }
        t.updateSections(sections)
    }

    private func yourRadio() -> CPListItem {
        item(String(localized: "Your radio"), detail: String(localized: "Endless, based on your favorites"),
             image: ArtTile.image(symbol: "dot.radiowaves.left.and.right", hue: 0.52)) { [weak self] in
            guard let self else { return }
            let favorites = ((try? await self.app.client?.starred().song) ?? []).shuffled()
            await self.app.player.radio.start(String(localized: "Your radio"), seedId: favorites.first?.id, seeds: Array(favorites.prefix(8)))
            self.showNowPlaying()
        }
    }

    private func libraryTab() -> CPListTemplate {
        let favorites = item(String(localized: "Favorite songs"), image: symbol("heart.fill")) { [weak self] in
            guard let self, let songs = try? await self.app.client?.starred().song else { return }
            self.pushSongs(String(localized: "Favorite songs"), songs, context: .init(kind: .favorites, name: String(localized: "Favorite songs")))
        }
        let playlists = item(String(localized: "Playlists"), image: symbol("music.note.list")) { [weak self] in
            guard let self, let list = try? await self.app.client?.playlists() else { return }
            self.push(CPListTemplate(title: String(localized: "Playlists"), sections: [CPListSection(items: list.prefix(self.limit).map(self.playlistItem))]))
        }
        let albums = item(String(localized: "Albums"), image: symbol("square.stack")) { [weak self] in
            guard let self, let list = try? await self.app.client?.albumList("alphabeticalByName", size: self.limit) else { return }
            self.push(CPListTemplate(title: String(localized: "Albums"), sections: [CPListSection(items: list.map(self.albumItem))]))
        }
        let artists = item(String(localized: "Artists"), image: symbol("music.mic")) { [weak self] in
            guard let self, let list = try? await self.app.client?.artists() else { return }
            self.push(CPListTemplate(title: String(localized: "Artists"), sections: [CPListSection(items: list.prefix(self.limit).map(self.artistItem))]))
        }
        let t = CPListTemplate(title: String(localized: "Library"), sections: [CPListSection(items: [favorites, playlists, albums, artists])])
        t.tabTitle = String(localized: "Library")
        t.tabImage = UIImage(systemName: "books.vertical.fill")
        return t
    }

    /// Works without network – the place to go when driving through a dead zone.
    private func downloadsTab() -> CPListTemplate {
        let t = CPListTemplate(title: String(localized: "Downloads"), sections: [])
        t.tabTitle = String(localized: "Downloads")
        t.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        t.emptyViewTitleVariants = [String(localized: "No downloads")]
        t.emptyViewSubtitleVariants = [String(localized: "Download albums and playlists on your iPhone to listen without network.")]
        fillDownloads(t)
        return t
    }

    private func fillDownloads(_ t: CPListTemplate) {
        let store = app.downloads
        let songs = store.downloadedSongs
        guard !songs.isEmpty else { t.updateSections([]); return }
        let context = PlayerModel.Context(kind: .downloads, name: String(localized: "Downloads"))
        let all = [
            item(String(localized: "Play all"), detail: String(localized: "\(songs.count) songs"), image: symbol("play.fill")) { [weak self] in self?.play(songs, context: context) },
            item(String(localized: "Shuffle"), image: symbol("shuffle")) { [weak self] in self?.play(songs, shuffled: true, context: context) },
        ]
        var sections = [CPListSection(items: all)]
        let playlists = store.index.playlists.values.sorted { $0.name < $1.name }
        if !playlists.isEmpty { sections.append(CPListSection(items: playlists.map(playlistItem), header: String(localized: "Playlists"), sectionIndexTitle: nil)) }
        let albums = store.index.albums.values.sorted { $0.name < $1.name }
        if !albums.isEmpty { sections.append(CPListSection(items: albums.prefix(limit).map(albumItem), header: String(localized: "Albums"), sectionIndexTitle: nil)) }
        t.updateSections(sections)
    }

    // MARK: Items

    private var limit: Int { min(CPListTemplate.maximumItemCount, 200) }

    private var accent: UIColor { UIColor(Theme.shared.accent) }

    /// A symbol in the accent color picked in the app.
    private func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name)?.withTintColor(accent, renderingMode: .alwaysOriginal)
    }

    private func item(_ text: String, detail: String? = nil, image: UIImage? = nil,
                      action: @escaping @MainActor () async -> Void) -> CPListItem {
        let i = CPListItem(text: text, detailText: detail, image: image)
        i.handler = { _, done in
            Task { @MainActor in await action(); done() }
        }
        return i
    }

    private func albumItem(_ a: Album) -> CPListItem {
        let i = item(a.name, detail: a.artist) { [weak self] in await self?.openAlbum(a.id) }
        loadCover(a.coverArt ?? a.id) { i.setImage($0) }
        return i
    }

    private func playlistItem(_ p: Playlist) -> CPListItem {
        let i = item(p.name, detail: String(localized: "\(p.songCount ?? p.entry?.count ?? 0) songs")) { [weak self] in
            guard let self else { return }
            let full = (try? await self.app.client?.playlist(p.id)) ?? self.app.downloads.index.playlists[p.id]
            guard let full else { return }
            self.pushSongs(full.name, full.entry ?? [], context: .init(kind: .playlist, id: full.id, name: full.name))
        }
        loadCover(p.coverArt ?? p.id) { i.setImage($0) }
        return i
    }

    private func artistItem(_ a: Artist) -> CPListItem {
        let i = item(a.name) { [weak self] in
            guard let self, let artist = try? await self.app.client?.artist(a.id) else { return }
            let albums = (artist.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            self.push(CPListTemplate(title: artist.name, sections: [CPListSection(items: albums.map(self.albumItem))]))
        }
        loadCover(a.coverArt ?? a.id) { i.setImage($0) }
        return i
    }

    /// A row of album covers, like a shelf on the phone's home screen.
    private func albumGrid(_ title: String, _ albums: [Album]) -> CPListImageRowItem {
        let shown = Array(albums.prefix(CPMaximumNumberOfGridImages))
        let placeholder = ArtTile.image(symbol: "music.note", hue: 0.62)
        var images = Array(repeating: placeholder, count: shown.count)
        let row = CPListImageRowItem(text: title, images: images)
        row.listImageRowHandler = { [weak self] _, index, done in
            Task { @MainActor in await self?.openAlbum(shown[index].id); done() }
        }
        row.handler = { _, done in done() }
        for (n, a) in shown.enumerated() {
            loadCover(a.coverArt ?? a.id) { img in
                images[n] = img
                row.update(images)
            }
        }
        return row
    }

    private func openAlbum(_ id: String) async {
        let album = (try? await app.client?.album(id)) ?? app.downloads.index.albums[id]
        guard let album else { return }
        pushSongs(album.name, album.song ?? [], context: .init(kind: .album, id: album.id, name: album.name))
    }

    /// Song list with "Shuffle" on top; tapping a song plays the list from there.
    private func pushSongs(_ title: String, _ songs: [Song], context: PlayerModel.Context) {
        let shown = Array(songs.prefix(limit - 1))
        let shuffle = item(String(localized: "Shuffle"), image: symbol("shuffle")) { [weak self] in self?.play(shown, shuffled: true, context: context) }
        let rows = shown.enumerated().map { n, s in
            let i = item(s.title, detail: s.artist) { [weak self] in self?.play(shown, from: n, context: context) }
            i.isPlaying = app.player.current?.id == s.id
            if app.downloads.isDownloaded(s.id) { i.accessoryType = .none; i.setAccessoryImage(symbol("arrow.down.circle.fill")) }
            loadCover(s.coverArt ?? s.albumId) { i.setImage($0) }
            return i
        }
        push(CPListTemplate(title: title, sections: [CPListSection(items: [shuffle]), CPListSection(items: rows)]))
    }

    private func push(_ t: CPTemplate) {
        interface?.pushTemplate(t, animated: true, completion: nil)
    }

    private func play(_ songs: [Song], from start: Int = 0, shuffled: Bool = false, context: PlayerModel.Context) {
        guard !songs.isEmpty else { return }
        app.player.play(songs, from: start, shuffled: shuffled, context: context)
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let interface, interface.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func loadCover(_ id: String?, _ apply: @escaping @MainActor (UIImage) -> Void) {
        Task { @MainActor in
            if let local = app.downloads.localCover(id), let img = UIImage(contentsOfFile: local.path) { apply(img); return }
            guard let client = app.client, let url = client.coverURL(id, size: 200),
                  let img = await ImageLoader.shared.image(url, headers: client.headers) else { return }
            apply(img)
        }
    }

    // MARK: Now Playing

    /// Keeps the heart, shuffle and repeat buttons in sync with the player.
    private func watchPlayer() {
        withObservationTracking {
            _ = app.player.current?.id
            _ = app.player.current?.starred
            _ = app.player.shuffle
            _ = app.player.repeatMode
            _ = app.player.station
            _ = app.downloads.index.songs.count
            _ = Theme.shared.accentHex
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.interface != nil else { return }
                self.updateButtons()
                if let d = self.downloads { self.fillDownloads(d) }
                self.watchPlayer()
            }
        }
        updateButtons()
    }

    /// Own buttons instead of the system's shuffle and repeat: they show their state in the accent color,
    /// and a tap does exactly one thing. A station has no queue to shuffle and no song to like.
    private func updateButtons() {
        let p = app.player
        guard p.station == nil else { CPNowPlayingTemplate.shared.updateNowPlayingButtons([]); return }
        let starred = p.current.map(app.isFavorite) ?? false
        let shuffle = button("shuffle", on: p.shuffle) { p.toggleShuffle() }
        let heart = button(starred ? "heart.fill" : "heart", on: starred) { [weak self] in
            guard let self, let song = self.app.player.current else { return }
            self.app.toggleStar(song)
        }
        let repeatButton = button(p.repeatMode == .one ? "repeat.1" : "repeat", on: p.repeatMode != .off) { p.cycleRepeat() }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffle, heart, repeatButton])
    }

    private func button(_ name: String, on: Bool, action: @escaping @MainActor () -> Void) -> CPNowPlayingImageButton {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(on ? accent : .white, renderingMode: .alwaysOriginal) ?? UIImage()
        let b = CPNowPlayingImageButton(image: image) { _ in MainActor.assumeIsolated { action() } }
        b.isSelected = on
        return b
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            let p = self.app.player
            let rows = p.upNext.prefix(self.limit).enumerated().map { n, s in
                let i = self.item(s.title, detail: s.artist) { p.jump(to: p.index + 1 + n) }
                self.loadCover(s.coverArt ?? s.albumId) { i.setImage($0) }
                return i
            }
            self.push(CPListTemplate(title: String(localized: "Up next"), sections: [CPListSection(items: Array(rows))]))
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}

/// A colored square with a symbol, like the mix cards and station art on the phone.
enum ArtTile {
    static func image(symbol: String, hue: Double, size: CGFloat = 120) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { ctx in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor,
                          UIColor(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.35, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.36, weight: .semibold)
            if let s = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(UIColor(white: 1, alpha: 0.92), renderingMode: .alwaysOriginal) {
                s.draw(at: CGPoint(x: (size - s.size.width) / 2, y: (size - s.size.height) / 2))
            }
        }
    }
}
