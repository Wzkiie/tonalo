import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var sections: [HomeSection] = []
    @State private var loading = true
    @State private var error: String?

    struct HomeSection: Identifiable { let id: String; let title: LocalizedStringKey; let albums: [Album] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !app.isOnline { OfflineBanner() }
                HStack(spacing: 12) {
                    quickButton("Shuffle mix", icon: "shuffle") {
                        if let songs = try? await app.client?.randomSongs(150) { app.player.play(songs) }
                    }
                    NavigationLink(value: Route.favorites) {
                        Label("Favorites", systemImage: "heart.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                LoadState(loading: loading && sections.isEmpty, error: error) { await load() }
                ForEach(sections) { s in
                    if !s.albums.isEmpty { AlbumRow(title: s.title, albums: s.albums, more: .albums(s.id)) }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(greeting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.showsAccountPicker = true } label: {
                    Text(String(app.current?.username.prefix(1) ?? "?").uppercased())
                        .font(.subheadline.bold()).foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                        .background(avatarColor(app.current?.username ?? ""), in: Circle())
                }
                .accessibilityLabel("Switch user")
            }
        }
        .task(id: "\(app.currentId?.uuidString ?? "")\(Theme.shared.hiddenHomeRows.sorted())\(app.isOnline)") { await load() }
        .refreshable { await load() }
    }

    private var greeting: LocalizedStringKey {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 5 ? "Good night" : h < 11 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private func quickButton(_ title: LocalizedStringKey, icon: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true; error = nil
        let kinds: [(String, LocalizedStringKey)] = [("recent", "Recently played"), ("newest", "Recently added"),
                                                     ("frequent", "Most played"), ("random", "Discover"), ("starred", "Favorite albums")]
        do {
            var result: [HomeSection] = []
            for (type, title) in kinds where !Theme.shared.hiddenHomeRows.contains(type) {
                result.append(HomeSection(id: type, title: title, albums: try await client.albumList(type, size: 20)))
            }
            sections = result
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var result: SearchBody?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error { LoadState(loading: false, error: error) }
                if let r = result {
                    if let artists = r.artist, !artists.isEmpty {
                        section("Artists") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) { ForEach(artists) { ArtistCard(artist: $0) } }.padding(.horizontal)
                            }
                        }
                    }
                    if let albums = r.album, !albums.isEmpty { AlbumRow(title: "Albums", albums: albums) }
                    if let songs = r.song, !songs.isEmpty {
                        section("Songs") {
                            LazyVStack(spacing: 14) {
                                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                                    SongRow(song: s, showCover: true) { app.player.play(songs, from: i) }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    if (r.artist ?? []).isEmpty && (r.album ?? []).isEmpty && (r.song ?? []).isEmpty {
                        Text("No results for “\(query)”").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artists, albums or songs")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { result = nil; return }
            try? await Task.sleep(for: .milliseconds(350)) // wait until typing pauses
            guard !Task.isCancelled, let client = app.client else { return }
            do { result = try await client.search(q); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            content()
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    var body: some View {
        List {
            NavigationLink(value: Route.downloads) { Label("Downloads", systemImage: "arrow.down.circle") }
            NavigationLink(value: Route.favorites) { Label("Favorites", systemImage: "heart") }
            NavigationLink(value: Route.playlists) { Label("Playlists", systemImage: "music.note.list") }
            NavigationLink(value: Route.albums("alphabeticalByName")) { Label("Albums", systemImage: "square.stack") }
            NavigationLink(value: Route.artists) { Label("Artists", systemImage: "music.mic") }
        }
        .navigationTitle("Library")
    }
}

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @State var type: String
    @State private var albums: [Album] = []
    @State private var done = false
    @State private var error: String?

    private let sorts: [(String, LocalizedStringKey)] = [("alphabeticalByName", "A–Z"), ("alphabeticalByArtist", "Artist"),
        ("newest", "Recently added"), ("recent", "Recently played"), ("frequent", "Most played"), ("random", "Random"), ("starred", "Favorites")]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums) { album in
                    AlbumCard(album: album, width: nil).onAppear { if album.id == albums.last?.id { Task { await more() } } }
                }
            }
            .padding()
            LoadState(loading: albums.isEmpty && !done && error == nil, error: error)
        }
        .navigationTitle("Albums")
        .toolbar {
            Menu {
                Picker("Sort", selection: $type) { ForEach(sorts, id: \.0) { Text($0.1).tag($0.0) } }
            } label: { Image(systemName: "arrow.up.arrow.down") }
        }
        .task(id: type) { albums = []; done = false; await more() }
    }

    private func more() async {
        guard !done, let client = app.client else { return }
        do {
            let page = try await client.albumList(type, size: 60, offset: albums.count)
            albums += page.filter { a in !albums.contains(where: { $0.id == a.id }) }
            if page.count < 60 { done = true }
        } catch { self.error = error.localizedDescription; done = true }
    }
}

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @State private var artists: [Artist] = []
    @State private var filter = ""
    @State private var error: String?

    var body: some View {
        let shown = filter.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        List(shown) { a in
            NavigationLink(value: Route.artist(a.id)) {
                HStack(spacing: 12) {
                    CoverView(id: a.coverArt ?? a.id, size: 120, round: true).frame(width: 44)
                    Text(a.name)
                }
            }
        }
        .listStyle(.plain)
        .overlay { LoadState(loading: artists.isEmpty && error == nil, error: error) }
        .navigationTitle("Artists")
        .searchable(text: $filter)
        .task {
            do { artists = try await app.client?.artists() ?? [] } catch { self.error = error.localizedDescription }
        }
    }
}

struct PlaylistsView: View {
    @Environment(AppModel.self) private var app
    @State private var playlists: [Playlist] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List(playlists) { p in
            NavigationLink(value: Route.playlist(p.id)) {
                HStack(spacing: 12) {
                    CoverView(id: p.coverArt ?? p.id, size: 120, corner: 4).frame(width: 52)
                    VStack(alignment: .leading) {
                        Text(p.name).lineLimit(1)
                        Text("\(p.songCount ?? 0) songs").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { LoadState(loading: !loaded, error: error) }
        .navigationTitle("Playlists")
        .task {
            do { playlists = try await app.client?.playlists() ?? [] } catch { self.error = error.localizedDescription }
            loaded = true
        }
    }
}

struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @State private var data: SearchBody?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LoadState(loading: data == nil && error == nil, error: error)
                if let d = data {
                    let songs = d.song ?? []
                    if !songs.isEmpty {
                        PlayButtons(play: { app.player.play(songs) }, shuffle: { app.player.play(songs, shuffled: true) }).padding(.horizontal)
                    }
                    if let albums = d.album, !albums.isEmpty { AlbumRow(title: "Albums", albums: albums) }
                    if let artists = d.artist, !artists.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) { ForEach(artists) { ArtistCard(artist: $0) } }.padding(.horizontal)
                        }
                    }
                    LazyVStack(spacing: 14) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                            SongRow(song: s, showCover: true) { app.player.play(songs, from: i) }
                        }
                    }
                    .padding(.horizontal)
                    if songs.isEmpty && (d.album ?? []).isEmpty && (d.artist ?? []).isEmpty {
                        Text("No favorites yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Favorites")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { data = try await app.client?.starred() } catch { self.error = error.localizedDescription }
    }
}
