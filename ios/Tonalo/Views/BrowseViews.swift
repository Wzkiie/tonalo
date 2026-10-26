import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var filter = Filter.all
    @State private var sections: [HomeSection] = []
    @State private var playlists: [Playlist] = []
    @State private var loading = true
    @State private var error: String?

    enum Filter { case all, playlists, downloads }
    struct HomeSection: Identifiable { let id: String; let title: LocalizedStringKey; let albums: [Album] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !app.isOnline { OfflineBanner() }
                switch filter {
                case .all: allContent
                case .playlists: grid(playlists.map { .playlist($0) }, empty: "No playlists yet.")
                case .downloads:
                    grid(app.downloads.index.playlists.values.sorted { $0.name < $1.name }.map { .playlist($0) }
                         + app.downloads.index.albums.values.sorted { $0.name < $1.name }.map { .album($0) },
                         empty: "Nothing downloaded yet. Use the download button on an album or playlist, or “Download” in a song’s menu.")
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackground()
        .task(id: "\(app.currentId?.uuidString ?? "")\(Theme.shared.hiddenHomeRows.sorted())\(app.isOnline)\(app.playlistsVersion)") { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProfileButton().padding(.trailing, 4)
            Chip(title: "All", selected: filter == .all) { filter = .all }
            Chip(title: "Playlists", selected: filter == .playlists) { filter = filter == .playlists ? .all : .playlists }
            Chip(title: "Downloads", selected: filter == .downloads) { filter = filter == .downloads ? .all : .downloads }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder private var allContent: some View {
        quickGrid
        mixes
        LoadState(loading: loading && sections.isEmpty, error: error) { await load() }
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: "Your playlists", more: .playlists)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(playlists) { PlaylistCard(playlist: $0) }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        ForEach(sections) { s in
            if !s.albums.isEmpty { AlbumRow(title: s.title, albums: s.albums, more: .albums(s.id)) }
        }
    }

    /// Two columns of small tiles at the top: favorites, a few playlists, recently played albums.
    private var quickGrid: some View {
        let recent = sections.first { $0.id == "recent" }?.albums ?? sections.first?.albums ?? []
        let items: [QuickItem] = [.favorites] + playlists.prefix(3).map { .playlist($0) } + recent.map { .album($0) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(items.prefix(8)) { QuickTile(item: $0) }
        }
        .padding(.horizontal, 16)
    }

    private var mixes: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Made for you")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    MixCard(title: "Shuffle mix", subtitle: "Random songs from your library", icon: "shuffle", hue: 0.62) {
                        if let songs = try? await app.client?.randomSongs(150) {
                            app.player.play(songs, context: .init(kind: .mix, name: String(localized: "Shuffle mix")))
                        }
                    }
                    MixCard(title: "Favorites mix", subtitle: "Your favorite songs, shuffled", icon: "heart.fill", hue: 0.92) {
                        if let songs = try? await app.client?.starred().song, !songs.isEmpty {
                            app.player.play(songs, shuffled: true, context: .init(kind: .favorites, name: String(localized: "Favorite songs")))
                        }
                    }
                    MixCard(title: "Discover", subtitle: "Albums you haven’t heard in a while", icon: "sparkles", hue: 0.12) {
                        guard let client = app.client, let albums = try? await client.albumList("random", size: 6) else { return }
                        var songs: [Song] = []
                        for a in albums { songs += ((try? await client.album(a.id).song) ?? []).shuffled().prefix(4) }
                        app.player.play(songs.shuffled(), context: .init(kind: .mix, name: String(localized: "Discover")))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func grid(_ items: [QuickItem], empty: LocalizedStringKey) -> some View {
        Group {
            if items.isEmpty {
                Text(empty).foregroundStyle(Color.subtle).padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 20) {
                    ForEach(items) { item in
                        switch item {
                        case .playlist(let p): PlaylistCard(playlist: p, width: nil)
                        case .album(let a): AlbumCard(album: a, width: nil)
                        case .favorites: EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        loading = true; error = nil
        playlists = (try? await client.playlists()) ?? playlists
        do {
            var result: [HomeSection] = []
            for (type, title) in Theme.homeRows where !Theme.shared.hiddenHomeRows.contains(type) {
                result.append(HomeSection(id: type, title: title, albums: try await client.albumList(type, size: 20)))
            }
            sections = result
        } catch {
            if app.isOnline { self.error = error.localizedDescription }
        }
        loading = false
    }
}

enum QuickItem: Identifiable {
    case favorites
    case playlist(Playlist)
    case album(Album)

    var id: String {
        switch self {
        case .favorites: "fav"
        case .playlist(let p): "p" + p.id
        case .album(let a): "a" + a.id
        }
    }
}

/// Small horizontal tile in the two-column grid at the top of Home.
struct QuickTile: View {
    let item: QuickItem

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 8) {
                art.frame(width: 56, height: 56).clipped()
                Text(title).font(.system(size: 13, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
            }
            .frame(height: 56)
            .background(Color.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var route: Route {
        switch item {
        case .favorites: .favorites
        case .playlist(let p): .playlist(p.id)
        case .album(let a): .album(a.id)
        }
    }

    private var title: String {
        switch item {
        case .favorites: String(localized: "Favorite songs")
        case .playlist(let p): p.name
        case .album(let a): a.name
        }
    }

    @ViewBuilder private var art: some View {
        switch item {
        case .favorites: FavoritesArt()
        case .playlist(let p): CoverView(id: p.coverArt ?? p.id, size: 120, corner: 0)
        case .album(let a): CoverView(id: a.coverArt ?? a.id, size: 120, corner: 0)
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var width: CGFloat? = 150
    var body: some View {
        NavigationLink(value: Route.playlist(playlist.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(id: playlist.coverArt ?? playlist.id, corner: 4)
                Text(playlist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(playlist.songCount ?? 0) songs").font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}

/// Big colored card that starts a generated queue.
struct MixCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    let hue: Double
    let action: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            Task { await action(); busy = false }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue + 0.06, saturation: 0.7, brightness: 0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: 44, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if busy { ProgressView().tint(.white).padding(10) }
                    Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).padding(10)
                        .opacity(busy ? 0 : 1)
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(2)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var result: SearchBody?
    @State private var genres: [Genre] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                TabHeader(title: "Search").padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
                Section {
                    if query.trimmingCharacters(in: .whitespaces).count >= 2 { results } else { browse }
                } header: {
                    field.padding(.horizontal, 16).padding(.bottom, 12).background(Color.black)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackground()
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { result = nil; return }
            try? await Task.sleep(for: .milliseconds(350)) // wait until typing pauses
            guard !Task.isCancelled, let client = app.client else { return }
            do { result = try await client.search(q); error = nil } catch { self.error = error.localizedDescription }
        }
        .task {
            guard genres.isEmpty, let all = try? await app.client?.genres() else { return }
            genres = Array(all.filter { ($0.albumCount ?? 0) > 0 }.sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }.prefix(30))
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold))
            TextField("", text: $query, prompt: Text("What do you want to listen to?").foregroundStyle(Color(white: 0.35)))
                .font(.system(size: 16, weight: .medium))
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("Clear")
            }
        }
        .foregroundStyle(.black)
        .tint(.black)
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Browse all").font(.system(size: 17, weight: .bold)).padding(.top, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(genres, id: \.value) { GenreTile(genre: $0.value) }
            }
            if genres.isEmpty && app.isOnline { ProgressView().frame(maxWidth: .infinity).padding(30) }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var results: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let error { LoadState(loading: false, error: error) }
            if let r = result {
                ForEach(r.artist ?? []) { a in
                    NavigationLink(value: Route.artist(a.id)) {
                        ItemRow(title: a.name, subtitle: String(localized: "Artist")) {
                            CoverView(id: a.coverArt ?? a.id, size: 120, round: true).frame(width: 52)
                        }
                    }
                    .buttonStyle(.plain)
                }
                let songs = r.song ?? []
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                    SongRow(song: s, showCover: true) {
                        app.player.play(songs, from: i, context: .init(kind: .search, name: query))
                    }
                }
                ForEach(r.album ?? []) { a in
                    NavigationLink(value: Route.album(a.id)) {
                        ItemRow(title: a.name, subtitle: [String(localized: "Album"), a.artist].compactMap { $0 }.joined(separator: " • ")) {
                            CoverView(id: a.coverArt ?? a.id, size: 120, corner: 2).frame(width: 52)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if (r.artist ?? []).isEmpty && (r.album ?? []).isEmpty && songs.isEmpty {
                    VStack(spacing: 8) {
                        Text("No results for “\(query)”").font(.system(size: 18, weight: .bold))
                        Text("Check the spelling, or try fewer words.").foregroundStyle(Color.subtle)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Colored genre tile with a tilted album cover, for "Browse all".
struct GenreTile: View {
    @Environment(AppModel.self) private var app
    let genre: String
    @State private var coverId: String?

    var body: some View {
        NavigationLink(value: Route.genre(genre)) {
            ZStack(alignment: .topLeading) {
                color
                if let coverId {
                    CoverView(id: coverId, size: 200, corner: 4)
                        .frame(width: 70)
                        .rotationEffect(.degrees(25))
                        .shadow(color: .black.opacity(0.35), radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(x: 16, y: 6)
                }
                Text(genre).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(2).padding(12).padding(.trailing, 40)
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .task {
            coverId = try? await app.client?.albumList("byGenre", size: 1, genre: genre).first.map { $0.coverArt ?? $0.id }
        }
    }

    /// Stable color per genre name, picked from a hand-made palette so neighbors rarely look alike.
    private var color: Color {
        let palette = ["#C2410C", "#7C3AED", "#0E7490", "#BE185D", "#1D4ED8", "#B45309", "#4D7C0F", "#9D174D",
                       "#0F766E", "#6D28D9", "#B91C1C", "#1E40AF", "#A16207", "#7E22CE", "#15803D", "#C026D3"]
        let h = genre.lowercased().unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Color(hex: palette[h % palette.count])!
    }
}

// MARK: - Library

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter?
    @State private var playlists: [Playlist] = []
    @State private var starred: SearchBody?
    @State private var albums: [Album] = []
    @State private var albumsDone = false
    @State private var artists: [Artist] = []

    enum Filter { case playlists, albums, artists, downloads }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeader(title: "Your Library").padding(.top, 8)
                chips
                LazyVStack(alignment: .leading, spacing: 12) { content }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackground()
        .task(id: "\(app.currentId?.uuidString ?? "")\(app.playlistsVersion)") { await load() }
        .task(id: filter) { await loadFilter() }
        .refreshable { await load(); await loadFilter() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filter != nil {
                    Button { filter = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32).background(Color.elevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
                chip("Playlists", .playlists)
                chip("Albums", .albums)
                chip("Artists", .artists)
                chip("Downloads", .downloads)
            }
        }
    }

    @ViewBuilder private func chip(_ title: LocalizedStringKey, _ f: Filter) -> some View {
        if filter == nil || filter == f {
            Chip(title: title, selected: filter == f) { filter = filter == f ? nil : f }
        }
    }

    @ViewBuilder private var content: some View {
        switch filter {
        case nil:
            NavigationLink(value: Route.favorites) {
                ItemRow(title: String(localized: "Favorite songs"),
                        subtitle: String(localized: "Playlist • \(starred?.song?.count ?? 0) songs"), pinned: true) { FavoritesArt() }
            }
            .buttonStyle(.plain)
            NavigationLink(value: Route.downloads) {
                ItemRow(title: String(localized: "Downloads"),
                        subtitle: String(localized: "\(app.downloads.downloadedSongs.count) songs"), pinned: true) { DownloadsArt() }
            }
            .buttonStyle(.plain)
            ForEach(playlists) { playlistRow($0) }
            ForEach(starred?.album ?? []) { albumRow($0) }
            ForEach(starred?.artist ?? []) { artistRow($0) }
        case .playlists:
            ForEach(playlists) { playlistRow($0) }
        case .albums:
            ForEach(albums) { a in
                albumRow(a).onAppear { if a.id == albums.last?.id { Task { await moreAlbums() } } }
            }
            if !albumsDone { ProgressView().frame(maxWidth: .infinity).padding() }
        case .artists:
            ForEach(artists) { artistRow($0) }
        case .downloads:
            ForEach(app.downloads.index.playlists.values.sorted { $0.name < $1.name }) { playlistRow($0) }
            ForEach(app.downloads.index.albums.values.sorted { $0.name < $1.name }) { albumRow($0) }
        }
    }

    private func playlistRow(_ p: Playlist) -> some View {
        NavigationLink(value: Route.playlist(p.id)) {
            ItemRow(title: p.name, subtitle: [String(localized: "Playlist"), p.owner].compactMap { $0 }.joined(separator: " • ")) {
                CoverView(id: p.coverArt ?? p.id, size: 160, corner: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ a: Album) -> some View {
        NavigationLink(value: Route.album(a.id)) {
            ItemRow(title: a.name, subtitle: [String(localized: "Album"), a.artist].compactMap { $0 }.joined(separator: " • ")) {
                CoverView(id: a.coverArt ?? a.id, size: 160, corner: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ a: Artist) -> some View {
        NavigationLink(value: Route.artist(a.id)) {
            ItemRow(title: a.name, subtitle: String(localized: "Artist")) {
                CoverView(id: a.coverArt ?? a.id, size: 160, round: true)
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let client = app.client else { return }
        if let p = try? await client.playlists() { playlists = p }
        if let s = try? await client.starred() { starred = s }
    }

    private func loadFilter() async {
        guard let client = app.client else { return }
        switch filter {
        case .albums where albums.isEmpty: await moreAlbums()
        case .artists where artists.isEmpty: artists = (try? await client.artists()) ?? []
        default: break
        }
    }

    private func moreAlbums() async {
        guard !albumsDone, let client = app.client else { return }
        guard let page = try? await client.albumList("alphabeticalByName", size: 60, offset: albums.count) else { albumsDone = true; return }
        albums += page.filter { a in !albums.contains { $0.id == a.id } }
        if page.count < 60 { albumsDone = true }
    }
}

// MARK: - Full lists ("Show all")

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @State var type: String
    var genre: String?
    @State private var albums: [Album] = []
    @State private var done = false
    @State private var error: String?

    private let sorts: [(String, LocalizedStringKey)] = [("alphabeticalByName", "A–Z"), ("alphabeticalByArtist", "Artist"),
        ("newest", "Recently added"), ("recent", "Recently played"), ("frequent", "Most played"), ("random", "Random"), ("starred", "Favorites")]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 20) {
                ForEach(albums) { album in
                    AlbumCard(album: album, width: nil).onAppear { if album.id == albums.last?.id { Task { await more() } } }
                }
            }
            .padding(16)
            LoadState(loading: albums.isEmpty && !done && error == nil, error: error)
        }
        .navigationTitle(genre ?? String(localized: "Albums"))
        .toolbar {
            if genre == nil {
                Menu {
                    Picker("Sort", selection: $type) { ForEach(sorts, id: \.0) { Text($0.1).tag($0.0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .task(id: type) { albums = []; done = false; await more() }
    }

    private func more() async {
        guard !done, let client = app.client else { return }
        do {
            let page = try await client.albumList(type, size: 60, offset: albums.count, genre: genre)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(shown) { a in
                    NavigationLink(value: Route.artist(a.id)) {
                        ItemRow(title: a.name, subtitle: String(localized: "Artist")) {
                            CoverView(id: a.coverArt ?? a.id, size: 160, round: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
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
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 20) {
                ForEach(playlists) { PlaylistCard(playlist: $0, width: nil) }
            }
            .padding(16)
        }
        .overlay { LoadState(loading: !loaded, error: error) }
        .navigationTitle("Playlists")
        .toolbar {
            Button { newName = ""; naming = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("New playlist")
        }
        .alert("New playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: app.playlistsVersion) { await load() }
    }

    private func load() async {
        do { playlists = try await app.client?.playlists() ?? [] } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = app.client else { return }
        do {
            try await client.createPlaylist(name: name, songIds: [])
            app.playlistsChanged()
        } catch {
            app.notify(error.localizedDescription)
        }
    }
}
