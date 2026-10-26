import CarPlay
import MediaPlayer
import Observation
import UIKit

/// CarPlay: tabs for Home, Library and Downloads, song lists, and the system Now Playing screen with
/// shuffle, repeat and a heart. iOS only connects this scene when the app has Apple's CarPlay audio
/// entitlement (see ios/CARPLAY.md) – without it nothing here runs.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interface: CPInterfaceController?
    private var downloads: CPListTemplate?
    private var app: AppModel { AppModel.shared }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        interface = interfaceController
        let downloads = downloadsTab()
        self.downloads = downloads
        let tabs = CPTabBarTemplate(templates: [homeTab(), libraryTab(), downloads])
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

        let mixes = [
            item(String(localized: "Shuffle mix"), detail: String(localized: "Random songs from your library"), symbol: "shuffle") { [weak self] in
                guard let songs = try? await client.randomSongs(150) else { return }
                self?.play(songs, context: .init(kind: .mix, name: String(localized: "Shuffle mix")))
            },
            item(String(localized: "Favorites mix"), detail: String(localized: "Your favorite songs, shuffled"), symbol: "heart.fill") { [weak self] in
                guard let songs = try? await client.starred().song, !songs.isEmpty else { return }
                self?.play(songs, shuffled: true, context: .init(kind: .favorites, name: String(localized: "Favorite songs")))
            },
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

    private func libraryTab() -> CPListTemplate {
        let favorites = item(String(localized: "Favorite songs"), symbol: "heart.fill") { [weak self] in
            guard let self, let songs = try? await self.app.client?.starred().song else { return }
            self.pushSongs(String(localized: "Favorite songs"), songs, context: .init(kind: .favorites, name: String(localized: "Favorite songs")))
        }
        let playlists = item(String(localized: "Playlists"), symbol: "music.note.list") { [weak self] in
            guard let self, let list = try? await self.app.client?.playlists() else { return }
            self.push(CPListTemplate(title: String(localized: "Playlists"), sections: [CPListSection(items: list.prefix(self.limit).map(self.playlistItem))]))
        }
        let albums = item(String(localized: "Albums"), symbol: "square.stack") { [weak self] in
            guard let self, let list = try? await self.app.client?.albumList("alphabeticalByName", size: self.limit) else { return }
            self.push(CPListTemplate(title: String(localized: "Albums"), sections: [CPListSection(items: list.map(self.albumItem))]))
        }
        let artists = item(String(localized: "Artists"), symbol: "music.mic") { [weak self] in
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
            item(String(localized: "Play all"), detail: String(localized: "\(songs.count) songs"), symbol: "play.fill") { [weak self] in self?.play(songs, context: context) },
            item(String(localized: "Shuffle"), symbol: "shuffle") { [weak self] in self?.play(songs, shuffled: true, context: context) },
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

    private func item(_ text: String, detail: String? = nil, symbol: String? = nil, image: UIImage? = nil,
                      action: @escaping @MainActor () async -> Void) -> CPListItem {
        let i = CPListItem(text: text, detailText: detail, image: image ?? symbol.flatMap { UIImage(systemName: $0) })
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
        let placeholder = UIImage(systemName: "music.note") ?? UIImage()
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
        let shuffle = item(String(localized: "Shuffle"), symbol: "shuffle") { [weak self] in self?.play(shown, shuffled: true, context: context) }
        let rows = shown.enumerated().map { n, s in
            let i = item(s.title, detail: s.artist) { [weak self] in self?.play(shown, from: n, context: context) }
            i.isPlaying = app.player.current?.id == s.id
            if app.downloads.isDownloaded(s.id) { i.accessoryType = .none; i.setAccessoryImage(UIImage(systemName: "arrow.down.circle.fill")) }
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
                  let img = await ImageLoader.shared.image(url, headers: client.account.httpHeaders) else { return }
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
            _ = app.downloads.index.songs.count
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.interface != nil else { return }
                self.updateButtons()
                if let d = self.downloads { self.fillDownloads(d) }
                self.watchPlayer()
            }
        }
        updateButtons()
    }

    private func updateButtons() {
        let p = app.player
        let starred = p.current?.starred != nil
        let heart = CPNowPlayingImageButton(image: UIImage(systemName: starred ? "heart.fill" : "heart") ?? UIImage()) { [weak self] _ in
            guard let self, let song = self.app.player.current else { return }
            self.app.toggleStar(song)
        }
        let shuffle = CPNowPlayingShuffleButton { _ in p.toggleShuffle() }
        let repeatButton = CPNowPlayingRepeatButton { _ in p.cycleRepeat() }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffle, heart, repeatButton])
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = p.shuffle ? .items : .off
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = p.repeatMode == .one ? .one : p.repeatMode == .all ? .all : .off
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            let p = self.app.player
            let rows = p.upNext.prefix(self.limit).enumerated().map { n, s in
                self.item(s.title, detail: s.artist) { p.jump(to: p.index + 1 + n) }
            }
            self.push(CPListTemplate(title: String(localized: "Up next"), sections: [CPListSection(items: Array(rows))]))
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}
