import SwiftUI

/// Shared layout for albums and playlists: cover on a tinted gradient, left-aligned title, action row, songs.
private struct DetailPage<Art: View, Info: View, Actions: View, Content: View>: View {
    let coverId: String?
    let title: String
    @ViewBuilder let art: () -> Art
    @ViewBuilder let info: () -> Info
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content
    @State private var titleHidden = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                art()
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                Text(title).font(.system(size: 24, weight: .bold)).lineLimit(3)
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY < 100 } action: { titleHidden = $0 }
                info()
                actions().padding(.vertical, 4)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .background(alignment: .top) {
                CoverTint(coverId: coverId, height: 560).padding(.horizontal, -16).offset(y: -200)
            }
        }
        .background(Color.black)
        .navigationTitle(titleHidden ? title : "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Gray icon button for the action row under a title.
private struct ActionIcon: View {
    let icon: String
    var active = false
    let label: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(active ? Color.accent : Color.subtle)
        }
        .accessibilityLabel(label)
    }
}

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let id: String
    @State private var album: Album?
    @State private var error: String?

    var body: some View {
        if let album {
            let songs = album.song ?? []
            let context = PlayerModel.Context(kind: .album, id: album.id, name: album.name)
            let playing = app.player.isPlaying(from: .album, id: album.id)
            DetailPage(coverId: album.coverArt ?? album.id, title: album.name) {
                CoverView(id: album.coverArt ?? album.id, size: 600, corner: 4)
            } info: {
                if let artistId = album.artistId {
                    NavigationLink(value: Route.artist(artistId)) {
                        HStack(spacing: 8) {
                            CoverView(id: artistId, size: 60, round: true).frame(width: 24)
                            Text(album.artist ?? "").font(.system(size: 13, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text([String(localized: "Album"), album.year.map(String.init)].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 13)).foregroundStyle(Color.subtle)
            } actions: {
                HStack(spacing: 24) {
                    ActionIcon(icon: album.starred == nil ? "heart" : "heart.fill", active: album.starred != nil,
                               label: album.starred == nil ? "Add to favorites" : "Remove from favorites") { toggleStar() }
                    DownloadButton(songs: songs, download: { app.downloads.downloadAlbum(album) }, remove: { app.downloads.removeAlbum(album.id) },
                                   cancel: { app.downloads.cancelCollection(songs, album: album.id) })
                        .font(.system(size: 22)).foregroundStyle(Color.subtle)
                    Menu {
                        Button { app.player.enqueue(songs) } label: { Label("Add to queue", systemImage: "text.append") }
                        Button { ui.addToPlaylist(songs) } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
                        if let artistId = album.artistId {
                            NavigationLink(value: Route.artist(artistId)) { Label("Go to artist", systemImage: "music.mic") }
                        }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 22)).foregroundStyle(Color.subtle).frame(height: 30) }
                    PlayButtons(playing: playing,
                                play: { playing ? app.player.toggle() : app.player.play(songs, context: context) },
                                shuffle: { app.player.play(songs, shuffled: true, context: context) })
                }
            } content: {
                LazyVStack(spacing: 10) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s) { app.player.play(songs, from: i, context: context) }
                    }
                }
                Text([String(localized: "\(songs.count) songs"), formatDuration(album.duration ?? 0)].joined(separator: " • "))
                    .font(.system(size: 13)).foregroundStyle(Color.subtle).padding(.top, 12)
            }
        } else {
            LoadState(loading: error == nil, error: error).task { await load() }
        }
    }

    private func toggleStar() {
        guard let client = app.client, let a = album else { return }
        let on = a.starred == nil
        album?.starred = on ? "1" : nil
        Task { try? await client.setStar(albumId: a.id, on: on) }
    }

    private func load() async {
        if album == nil, let saved = app.client?.cached("getAlbum", ["id": id])?.album { album = saved } // at once
        do {
            album = try await app.client?.album(id)
            // Keep a downloaded album in sync with songs added on the server
            if let a = album, app.downloads.index.albums[id] != nil { app.downloads.downloadAlbum(a) }
        } catch {
            if let saved = app.downloads.index.albums[id] { album = saved } // offline: use the downloaded copy
            else { self.error = error.userMessage }
        }
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var playlist: Playlist?
    @State private var error: String?
    @State private var editing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let p = playlist {
            let songs = p.entry ?? []
            let context = PlayerModel.Context(kind: .playlist, id: p.id, name: p.name)
            let playing = app.player.isPlaying(from: .playlist, id: p.id)
            DetailPage(coverId: p.coverArt ?? p.id, title: p.name) {
                CoverView(id: p.coverArt ?? p.id, size: 600, corner: 4)
            } info: {
                if let comment = p.comment, !comment.isEmpty {
                    Text(comment).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(3)
                }
                if let owner = p.owner {
                    HStack(spacing: 8) { Avatar(name: owner, size: 24); Text(owner).font(.system(size: 13, weight: .bold)) }
                }
                if p.readonly == true && p.isOwned(by: app) {
                    Label("Managed by your server · songs can’t be changed here", systemImage: "lock")
                        .font(.system(size: 13)).foregroundStyle(Color.subtle)
                }
                Text([String(localized: "\(songs.count) songs"), formatDuration(p.duration ?? 0)].joined(separator: " • "))
                    .font(.system(size: 13)).foregroundStyle(Color.subtle)
            } actions: {
                HStack(spacing: 24) {
                    DownloadButton(songs: songs, download: { app.downloads.downloadPlaylist(p) }, remove: { app.downloads.removePlaylist(p.id) },
                                   cancel: { app.downloads.cancelCollection(songs, playlist: p.id) })
                        .font(.system(size: 22)).foregroundStyle(Color.subtle)
                    Menu {
                        Button { app.player.enqueue(songs) } label: { Label("Add to queue", systemImage: "text.append") }
                        Button { ui.addToPlaylist(songs) } label: { Label("Add to other playlist", systemImage: "text.badge.plus") }
                        if p.isOwned(by: app) {
                            Divider()
                            if p.songsEditable(by: app) {
                                Button { editing = true } label: { Label("Edit songs", systemImage: "list.bullet") }
                            }
                            Button { newName = p.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
                        }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 22)).foregroundStyle(Color.subtle).frame(height: 30) }
                    PlayButtons(playing: playing,
                                play: { playing ? app.player.toggle() : app.player.play(songs, context: context) },
                                shuffle: { app.player.play(songs, shuffled: true, context: context) })
                }
            } content: {
                LazyVStack(spacing: 10) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                        SongRow(song: s, showCover: true) { app.player.play(songs, from: i, context: context) }
                    }
                }
                if songs.isEmpty {
                    Text("This playlist is empty. Add songs with “Add to playlist” in a song’s menu.")
                        .font(.system(size: 14)).foregroundStyle(Color.subtle).padding(.top, 8)
                }
            }
            .sheet(isPresented: $editing) { PlaylistEditor(playlist: p) { Task { await load() } } }
            .alert("Rename playlist", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { Task { await rename() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(p.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) { Task { await delete() } }
            } message: {
                Text("The playlist is removed from your server. The songs stay in your library.")
            }
        } else {
            LoadState(loading: error == nil, error: error).task { await load() }
        }
    }

    private func rename() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = app.client else { return }
        do {
            try await client.updatePlaylist(id, name: name)
            app.playlistsChanged()
            await load()
        } catch {
            if let message = error.userMessage { app.notify(message) }
        }
    }

    private func delete() async {
        guard let client = app.client else { return }
        do {
            try await client.deletePlaylist(id)
            app.playlistsChanged()
            if app.downloads.index.playlists[id] != nil { app.downloads.removePlaylist(id) }
            app.notify(String(localized: "Playlist deleted"))
            dismiss()
        } catch {
            if let message = error.userMessage { app.notify(message) }
        }
    }

    private func load() async {
        if playlist == nil, let saved = app.client?.cached("getPlaylist", ["id": id])?.playlist { playlist = saved } // at once
        do {
            playlist = try await app.client?.playlist(id)
            // A downloaded playlist picks up songs that were added on the server
            if let p = playlist, app.downloads.index.playlists[id] != nil { app.downloads.downloadPlaylist(p) }
        } catch {
            if let saved = app.downloads.index.playlists[id] { playlist = saved }
            else { self.error = error.userMessage }
        }
    }
}

/// Favorite songs, laid out like a playlist.
struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @State private var songs: [Song]?
    @State private var error: String?

    var body: some View {
        let list = (songs ?? []).filter { app.isFavorite($0) } // a heart removed here leaves the list at once
        let context = PlayerModel.Context(kind: .favorites, name: String(localized: "Favorite songs"))
        let playing = app.player.isPlaying(from: .favorites, id: nil)
        DetailPage(coverId: nil, title: String(localized: "Favorite songs")) {
            FavoritesArt().font(.system(size: 64)).clipShape(RoundedRectangle(cornerRadius: 4))
        } info: {
            if let name = app.current?.username {
                HStack(spacing: 8) { Avatar(name: name, size: 24); Text(name).font(.system(size: 13, weight: .bold)) }
            }
            Text("\(list.count) songs").font(.system(size: 13)).foregroundStyle(Color.subtle)
        } actions: {
            HStack(spacing: 24) {
                DownloadButton(songs: list, download: { app.downloads.download(list) }, remove: { app.downloads.remove(list.map(\.id)) })
                    .font(.system(size: 22)).foregroundStyle(Color.subtle)
                PlayButtons(playing: playing,
                            play: { playing ? app.player.toggle() : app.player.play(list, context: context) },
                            shuffle: { app.player.play(list, shuffled: true, context: context) })
            }
        } content: {
            LoadState(loading: songs == nil && error == nil, error: error)
            if songs?.isEmpty == true {
                Text("No favorites yet.").foregroundStyle(Color.subtle).frame(maxWidth: .infinity).padding(40)
            }
            LazyVStack(spacing: 10) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    SongRow(song: s, showCover: true) { app.player.play(list, from: i, context: context) }
                }
            }
        }
        .task { await load() }
        .refreshable { await Task { await load() }.value }
    }

    private func load() async {
        do { songs = try await app.client?.starred().song ?? [] } catch { self.error = error.userMessage }
    }
}

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var artist: Artist?
    @State private var top: [Song] = []
    @State private var bio: String?
    @State private var error: String?
    @State private var showAllTop = false

    var body: some View {
        if let artist {
            let albums = (artist.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            let context = PlayerModel.Context(kind: .artist, id: artist.id, name: artist.name)
            let playing = app.player.isPlaying(from: .artist, id: artist.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero(artist)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(albums.count) albums").font(.system(size: 13)).foregroundStyle(Color.subtle)
                        HStack(spacing: 24) {
                            ActionIcon(icon: artist.starred == nil ? "heart" : "heart.fill", active: artist.starred != nil,
                                       label: artist.starred == nil ? "Add to favorites" : "Remove from favorites") { toggleStar() }
                            Menu {
                                Button { radio() } label: { Label("Artist radio", systemImage: "dot.radiowaves.left.and.right") }
                            } label: { Image(systemName: "ellipsis").font(.system(size: 22)).foregroundStyle(Color.subtle).frame(height: 30) }
                            PlayButtons(playing: playing,
                                        play: { playing ? app.player.toggle() : (top.isEmpty ? playAll(shuffled: false) : app.player.play(top, context: context)) },
                                        shuffle: { playAll(shuffled: true) })
                        }
                        if !top.isEmpty {
                            Text("Popular").font(.system(size: 22, weight: .bold)).padding(.top, 4)
                            LazyVStack(spacing: 10) {
                                ForEach(Array(top.prefix(showAllTop ? 10 : 5).enumerated()), id: \.element.id) { i, s in
                                    SongRow(song: s, number: i + 1, showCover: true) { app.player.play(top, from: i, context: context) }
                                }
                            }
                            if top.count > 5 {
                                Button(showAllTop ? "Show less" : "See more") { withAnimation { showAllTop.toggle() } }
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.subtle)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    if !albums.isEmpty { AlbumRow(title: "Discography", albums: albums).padding(.top, 8) }
                    if let bio, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("About").font(.system(size: 22, weight: .bold))
                            Text(bio).font(.system(size: 14)).foregroundStyle(Color(white: 0.85)).lineLimit(6)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.elevated, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Color.black)
            .ignoresSafeArea(.container, edges: .top)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            LoadState(loading: error == nil, error: error).task { await load() }
        }
    }

    /// Full-width artist image with the name on top, fading into the page.
    private func hero(_ artist: Artist) -> some View {
        CoverView(id: artist.coverArt ?? artist.id, size: 800, corner: 0)
            .frame(maxWidth: .infinity)
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(artist.name).font(.system(size: 40, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
    }

    private func toggleStar() {
        guard let client = app.client, let a = artist else { return }
        let on = a.starred == nil
        artist?.starred = on ? "1" : nil
        Task { try? await client.setStar(artistId: a.id, on: on) }
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            let a = try await client.artist(id)
            artist = a
            top = await client.topSongs(a.name)
            bio = await client.artistInfo(id)?.biography?
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { self.error = error.userMessage }
    }

    private func playAll(shuffled: Bool) {
        guard let client = app.client, let artist else { return }
        Task {
            var songs: [Song] = []
            for a in artist.album ?? [] { songs += (try? await client.album(a.id).song) ?? [] }
            app.player.play(songs, shuffled: shuffled, context: .init(kind: .artist, id: artist.id, name: artist.name))
        }
    }

    private func radio() {
        guard let client = app.client, let artist else { return }
        Task {
            let s = await client.similarSongs(id)
            if !s.isEmpty { app.player.play(s, context: .init(kind: .mix, name: String(localized: "\(artist.name) radio"))) }
        }
    }
}
