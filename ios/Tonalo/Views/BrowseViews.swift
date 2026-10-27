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
        .refreshable { await Task { await load() }.value }
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
        LoadState(loading: loading && sections.allSatisfy { $0.albums.isEmpty }, error: error) { await load() }
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
        let rows = Theme.homeRows.filter { !Theme.shared.hiddenHomeRows.contains($0.id) }
        // The last known state first: the page is there at once, even before (or without) the network
        if sections.isEmpty {
            if let saved = client.cached("getPlaylists")?.playlists?.playlist { playlists = saved }
            sections = rows.map { row in
                HomeSection(id: row.id, title: row.name,
                            albums: client.cached("getAlbumList2", ["type": row.id, "size": "20", "offset": "0"])?.albumList2?.album ?? [])
            }
        }
        loading = true; error = nil
        // All rows at the same time – faster, and one slow or failing row doesn't hold up the others
        async let freshPlaylists = try? client.playlists()
        var fresh: [String: [Album]] = [:]
        var failure: Error?
        await withTaskGroup(of: (String, Result<[Album], Error>).self) { group in
            for row in rows {
                group.addTask {
                    do { return (row.id, .success(try await client.albumList(row.id, size: 20))) } catch { return (row.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let albums): fresh[id] = albums
                case .failure(let e): failure = e
                }
            }
        }
        if let p = await freshPlaylists { playlists = p }
        let old = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.albums) })
        sections = rows.map { HomeSection(id: $0.id, title: $0.name, albums: fresh[$0.id] ?? old[$0.id] ?? []) }
        // Only worth a message when there's nothing to show at all
        if let failure, fresh.isEmpty, sections.allSatisfy({ $0.albums.isEmpty }), app.isOnline { error = failure.userMessage }
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
            do { result = try await client.search(q); error = nil } catch { self.error = error.userMessage }
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
    @State private var query = ""
    @State private var searching = false
    @State private var foundAlbums: [Album] = []
    @AppStorage("library.sort") private var sort: Sort = .recent
    @AppStorage("library.grid") private var grid = false
    @FocusState private var searchFocused: Bool

    enum Filter { case playlists, albums, artists, downloads }

    enum Sort: String, CaseIterable {
        case recent, name, creator
        var title: LocalizedStringKey {
            switch self {
            case .recent: "Recently added"
            case .name: "Alphabetical"
            case .creator: "Artist or creator"
            }
        }
        /// The album list the server sorts this way.
        var albumListType: String {
            switch self {
            case .recent: "newest"
            case .name: "alphabeticalByName"
            case .creator: "alphabeticalByArtist"
            }
        }
    }

    /// One entry of the library, whatever it is.
    enum Item: Identifiable {
        case favorites, downloads, playlist(Playlist), album(Album), artist(Artist)
        var id: String {
            switch self {
            case .favorites: "favorites"
            case .downloads: "downloads"
            case .playlist(let p): "p" + p.id
            case .album(let a): "a" + a.id
            case .artist(let a): "r" + a.id
            }
        }
        var name: String {
            switch self {
            case .favorites, .downloads: ""
            case .playlist(let p): p.name
            case .album(let a): a.name
            case .artist(let a): a.name
            }
        }
        var creator: String {
            switch self {
            case .playlist(let p): p.owner ?? ""
            case .album(let a): a.artist ?? ""
            case .artist(let a): a.name
            default: ""
            }
        }
        /// When it was added or changed (ISO date from the server, sorts as text).
        var date: String {
            switch self {
            case .playlist(let p): p.changed ?? ""
            case .album(let a): a.starred ?? ""
            case .artist(let a): a.starred ?? ""
            default: ""
            }
        }
        var pinned: Bool { if case .favorites = self { true } else if case .downloads = self { true } else { false } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeader(title: "Your Library").padding(.top, 8)
                chips
                toolbar
                if grid {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 18) {
                        ForEach(items) { tile($0) }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) { ForEach(items) { row($0) } }
                }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackground()
        .task(id: "\(app.currentId?.uuidString ?? "")\(app.playlistsVersion)") { await load() }
        .task(id: "\(filter.map { "\($0)" } ?? "")\(sort.rawValue)") { await loadFilter() }
        .task(id: query) { await searchAlbums() }
        .refreshable { await Task { await load(); albums = []; albumsDone = false; await loadFilter() }.value }
    }

    // MARK: Filter bar

    /// All chips stay where they are; the chosen one lights up, tapping it again shows everything.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Playlists", .playlists)
                chip("Albums", .albums)
                chip("Artists", .artists)
                chip("Downloads", .downloads)
            }
        }
    }

    private func chip(_ title: LocalizedStringKey, _ f: Filter) -> some View {
        Chip(title: title, selected: filter == f) {
            withAnimation(.easeOut(duration: 0.15)) { filter = filter == f ? nil : f }
        }
    }

    /// Sort order on the left, search and list/grid on the right – or the search field while searching.
    private var toolbar: some View {
        HStack(spacing: 14) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.subtle)
                    TextField("Search your library", text: $query)
                        .focused($searchFocused).submitLabel(.search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(Color.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Cancel") { withAnimation(.easeOut(duration: 0.15)) { query = ""; searching = false } }
                    .foregroundStyle(.white)
            } else {
                if filter != .artists {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label { Text(sort.title) } icon: { Image(systemName: "arrow.up.arrow.down") }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { searching = true }; searchFocused = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search your library")
                Button { withAnimation(.easeOut(duration: 0.2)) { grid.toggle() } } label: {
                    Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(grid ? "Show as list" : "Show as grid")
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(height: 36)
    }

    @ViewBuilder private var footer: some View {
        if filter == .albums && query.isEmpty && !albumsDone {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if items.isEmpty {
            Text(emptyText).font(.subheadline).foregroundStyle(Color.subtle)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 40)
        }
    }

    private var emptyText: LocalizedStringKey {
        if !query.isEmpty { return "Nothing in your library matches “\(query)”." }
        return filter == .downloads ? "Nothing downloaded yet. Tap the arrow on an album, playlist or your favorites to listen offline." : "Nothing here yet."
    }

    // MARK: Items

    private var downloadedFavorites: Int {
        (starred?.song ?? []).filter { app.downloads.localURL($0.id) != nil }.count
    }

    private var items: [Item] {
        let dl = app.downloads
        var pinned: [Item] = []
        var rest: [Item]
        switch filter {
        case nil:
            pinned = [.favorites, .downloads]
            rest = playlists.map(Item.playlist) + (starred?.album ?? []).map(Item.album) + (starred?.artist ?? []).map(Item.artist)
        case .playlists:
            rest = playlists.map(Item.playlist)
        case .albums:
            // The server already sorts the album list; a search asks the server, so all albums are found
            return (query.isEmpty ? albums : foundAlbums).map(Item.album)
        case .artists:
            rest = artists.map(Item.artist)
            return matching(rest)
        case .downloads:
            pinned = [.downloads] + (downloadedFavorites > 0 ? [.favorites] : [])
            rest = dl.index.playlists.values.map(Item.playlist) + dl.index.albums.values.map(Item.album)
        }
        return query.isEmpty ? pinned + sorted(rest) : matching(sorted(rest))
    }

    private func sorted(_ list: [Item]) -> [Item] {
        switch sort {
        case .recent:
            // Newest first; things without a date keep the server's order behind them
            return list.enumerated().sorted { a, b in
                a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset
            }.map(\.element)
        case .name:
            return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .creator:
            return list.sorted {
                let c = $0.creator.localizedStandardCompare($1.creator)
                return c == .orderedSame ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : c == .orderedAscending
            }
        }
    }

    private func matching(_ list: [Item]) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.localizedStandardContains(q) || $0.creator.localizedStandardContains(q) }
    }

    private func route(_ item: Item) -> Route {
        switch item {
        case .favorites: .favorites
        case .downloads: .downloads
        case .playlist(let p): .playlist(p.id)
        case .album(let a): .album(a.id)
        case .artist(let a): .artist(a.id)
        }
    }

    private func subtitle(_ item: Item) -> String {
        switch item {
        case .favorites:
            filter == .downloads
                ? String(localized: "\(downloadedFavorites) of \(starred?.song?.count ?? 0) downloaded")
                : String(localized: "Playlist • \(starred?.song?.count ?? 0) songs")
        case .downloads: String(localized: "\(app.downloads.downloadedSongs.count) songs")
        case .playlist(let p): [String(localized: "Playlist"), p.owner].compactMap { $0 }.joined(separator: " • ")
        case .album(let a): [String(localized: "Album"), a.artist].compactMap { $0 }.joined(separator: " • ")
        case .artist: String(localized: "Artist")
        }
    }

    private func title(_ item: Item) -> String {
        switch item {
        case .favorites: String(localized: "Favorite songs")
        case .downloads: String(localized: "Downloads")
        default: item.name
        }
    }

    @ViewBuilder private func art(_ item: Item, size: Int) -> some View {
        switch item {
        case .favorites: FavoritesArt()
        case .downloads: DownloadsArt()
        case .playlist(let p): CoverView(id: p.coverArt ?? p.id, size: size, corner: 2)
        case .album(let a): CoverView(id: a.coverArt ?? a.id, size: size, corner: 2)
        case .artist(let a): CoverView(id: a.coverArt ?? a.id, size: size, round: true)
        }
    }

    private func row(_ item: Item) -> some View {
        NavigationLink(value: route(item)) {
            ItemRow(title: title(item), subtitle: subtitle(item), pinned: item.pinned) { art(item, size: 160) }
        }
        .buttonStyle(.plain)
        .onAppear { if case .album(let a) = item, a.id == albums.last?.id { Task { await moreAlbums() } } }
    }

    private func tile(_ item: Item) -> some View {
        NavigationLink(value: route(item)) {
            VStack(alignment: .leading, spacing: 6) {
                art(item, size: 300).aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                Text(title(item)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle(item)).font(.system(size: 12)).foregroundStyle(Color.subtle).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { if case .album(let a) = item, a.id == albums.last?.id { Task { await moreAlbums() } } }
    }

    // MARK: Loading

    private func load() async {
        guard let client = app.client else { return }
        if playlists.isEmpty, let saved = client.cached("getPlaylists")?.playlists?.playlist { playlists = saved }
        if starred == nil, let saved = client.cached("getStarred2")?.starred2 { starred = saved }
        async let p = try? client.playlists()
        async let s = try? client.starred()
        if let p = await p { playlists = p }
        if let s = await s { starred = s }
    }

    private func loadFilter() async {
        guard let client = app.client else { return }
        switch filter {
        case .albums:
            albums = []; albumsDone = false
            await moreAlbums()
        case .artists where artists.isEmpty: artists = (try? await client.artists()) ?? []
        default: break
        }
    }

    private func moreAlbums() async {
        guard filter == .albums, !albumsDone, let client = app.client else { return }
        let type = sort.albumListType
        guard let page = try? await client.albumList(type, size: 60, offset: albums.count) else { albumsDone = true; return }
        guard type == sort.albumListType else { return } // the sort changed meanwhile
        albums += page.filter { a in !albums.contains { $0.id == a.id } }
        if page.count < 60 { albumsDone = true }
    }

    /// Searching among albums asks the server, since only part of a large album list is loaded.
    private func searchAlbums() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard filter == .albums, !q.isEmpty, let client = app.client else { foundAlbums = []; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let found = try? await client.search(q).album else { return }
        foundAlbums = found
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
        } catch { self.error = error.userMessage; done = true }
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
            do { artists = try await app.client?.artists() ?? [] } catch { self.error = error.userMessage }
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
        do { playlists = try await app.client?.playlists() ?? [] } catch { self.error = error.userMessage }
        loaded = true
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = app.client else { return }
        do {
            try await client.createPlaylist(name: name, songIds: [])
            app.playlistsChanged()
        } catch {
            if let message = error.userMessage { app.notify(message) }
        }
    }
}
