import SwiftUI

/// Shared layout: tinted header with cover, title and subtitle, followed by content.
private struct DetailPage<Header: View, Content: View>: View {
    let coverId: String?
    var round = false
    let title: String
    @ViewBuilder let subtitle: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoverView(id: coverId, size: 600, round: round, corner: 8)
                    .frame(width: 230)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    .padding(.top, 8)
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                subtitle()
                content()
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(CoverTint(coverId: coverId))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var album: Album?
    @State private var error: String?

    var body: some View {
        if let album {
            let songs = album.song ?? []
            DetailPage(coverId: album.coverArt ?? album.id, title: album.name) {
                VStack(spacing: 4) {
                    if let artistId = album.artistId {
                        NavigationLink(album.artist ?? "", value: Route.artist(artistId)).font(.headline)
                    }
                    Text([album.year.map(String.init), String(localized: "\(songs.count) songs"), formatDuration(album.duration ?? 0)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } content: {
                PlayButtons(play: { app.player.play(songs) }, shuffle: { app.player.play(songs, shuffled: true) })
                HStack(spacing: 28) {
                    starButton
                    DownloadButton(songs: songs, download: { app.downloads.downloadAlbum(album) }, remove: { app.downloads.removeAlbum(album.id) })
                    Button { app.player.enqueue(songs) } label: { Image(systemName: "text.append") }
                }
                .font(.title3).foregroundStyle(.secondary)
                LazyVStack(spacing: 16) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s, number: s.track ?? i + 1) { app.player.play(songs, from: i) }
                    }
                }
            }
        } else {
            LoadState(loading: error == nil, error: error).task { await load() }
        }
    }

    private var starButton: some View {
        Button {
            guard let client = app.client, let a = album else { return }
            let on = a.starred == nil
            Task { try? await client.setStar(albumId: a.id, on: on); album?.starred = on ? "1" : nil }
        } label: { Image(systemName: album?.starred == nil ? "heart" : "heart.fill") }
    }

    private func load() async {
        do {
            album = try await app.client?.album(id)
            // Keep a downloaded album in sync with songs added on the server
            if let a = album, app.downloads.index.albums[id] != nil { app.downloads.downloadAlbum(a) }
        } catch {
            if let saved = app.downloads.index.albums[id] { album = saved } // offline: use the downloaded copy
            else { self.error = error.localizedDescription }
        }
    }
}

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var artist: Artist?
    @State private var top: [Song] = []
    @State private var bio: String?
    @State private var error: String?

    var body: some View {
        if let artist {
            let albums = (artist.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            DetailPage(coverId: artist.coverArt ?? artist.id, round: true, title: artist.name) {
                Text("\(albums.count) albums").font(.caption).foregroundStyle(.secondary)
            } content: {
                PlayButtons(play: { top.isEmpty ? playAll(shuffled: false) : app.player.play(top) },
                            shuffle: { playAll(shuffled: true) })
                Button { radio() } label: { Label("Artist radio", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.bordered).tint(.secondary)
                if let bio, !bio.isEmpty {
                    Text(bio).font(.footnote).foregroundStyle(.secondary).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !top.isEmpty {
                    Text("Top songs").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                    LazyVStack(spacing: 14) {
                        ForEach(Array(top.prefix(10).enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s, showCover: true) { app.player.play(top, from: i) }
                        }
                    }
                }
                Text("Discography").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(albums) { AlbumCard(album: $0, width: nil) }
                }
            }
        } else {
            LoadState(loading: error == nil, error: error).task { await load() }
        }
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
        } catch { self.error = error.localizedDescription }
    }

    private func playAll(shuffled: Bool) {
        guard let client = app.client, let albums = artist?.album else { return }
        Task {
            var songs: [Song] = []
            for a in albums { songs += (try? await client.album(a.id).song) ?? [] }
            app.player.play(songs, shuffled: shuffled)
        }
    }

    private func radio() {
        guard let client = app.client else { return }
        Task { let s = await client.similarSongs(id); if !s.isEmpty { app.player.play(s) } }
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var playlist: Playlist?
    @State private var error: String?

    var body: some View {
        if let p = playlist {
            let songs = p.entry ?? []
            DetailPage(coverId: p.coverArt ?? p.id, title: p.name) {
                Text([p.owner, String(localized: "\(songs.count) songs"), formatDuration(p.duration ?? 0)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } content: {
                PlayButtons(play: { app.player.play(songs) }, shuffle: { app.player.play(songs, shuffled: true) })
                DownloadButton(songs: songs, download: { app.downloads.downloadPlaylist(p) }, remove: { app.downloads.removePlaylist(p.id) })
                    .font(.title3).foregroundStyle(.secondary)
                LazyVStack(spacing: 14) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                        SongRow(song: s, showCover: true) { app.player.play(songs, from: i) }
                    }
                }
            }
        } else {
            LoadState(loading: error == nil, error: error).task { await load() }
        }
    }

    private func load() async {
        do {
            playlist = try await app.client?.playlist(id)
            // A downloaded playlist picks up songs that were added on the server
            if let p = playlist, app.downloads.index.playlists[id] != nil { app.downloads.downloadPlaylist(p) }
        } catch {
            if let saved = app.downloads.index.playlists[id] { playlist = saved }
            else { self.error = error.localizedDescription }
        }
    }
}
