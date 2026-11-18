import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var app
    /// Goes up each time the open tab is tapped again.
    var reselected = 0
    @State private var filter = Filter.all
    @State private var sections: [HomeSection] = []
    @State private var playlists: [Playlist] = []
    @State private var stations: [Station] = []
    @State private var genres: [Genre] = []
    @State private var loading = true
    @State private var error: String?

    enum Filter { case all, playlists, downloads, books }
    struct HomeSection: Identifiable { let id: String; let title: LocalizedStringKey; let albums: [Album] }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header.id(Self.top)
                if !app.isOnline { OfflineBanner() }
                if !hasMusic { BooksHomeContent() } else {
                switch filter {
                case .all: allContent
                case .books: BooksHomeContent()
                case .playlists: grid(playlists.map { .playlist($0) }, empty: "No playlists yet.")
                case .downloads:
                    grid(downloadItems,
                         empty: "Nothing downloaded yet. Use the download button on an album or playlist, or “Download” in a song’s menu.")
                }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackground()
        .task(id: "\(app.currentId?.uuidString ?? "")\(app.current?.serverURL ?? "")\(Theme.shared.hiddenHomeRows.sorted())\(app.isOnline)\(app.playlistsVersion)") { await load() }
        .refreshable { await pulled { await Task { await load() }.value; await app.books.load(force: true) } }
        .task(id: "\(app.currentId?.uuidString ?? "")\(app.books.connected)") { await app.books.load() }
        .onChange(of: app.books.connected) { _, on in if !on && filter == .books { filter = .all } }
        .onChange(of: reselected) {
            // Like the tab bar of any iPhone app: the open tab tapped again goes to the top
            filter = .all
            withAnimation(.easeOut(duration: 0.3)) { scroller.scrollTo(Self.top, anchor: .top) }
        }
        }
    }

    private static let top = "home.top"

    private var hasMusic: Bool { app.current?.hasMusic ?? true }

    private var header: some View {
        HStack(spacing: 8) {
            ProfileButton().padding(.trailing, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if hasMusic {
                        Chip(title: "All", selected: filter == .all) { filter = .all }
                        Chip(title: "Playlists", selected: filter == .playlists) { filter = filter == .playlists ? .all : .playlists }
                        Chip(title: "Downloads", selected: filter == .downloads) { filter = filter == .downloads ? .all : .downloads }
                    }
                    if app.books.connected {
                        Chip(title: "Audiobooks", selected: filter == .books || !hasMusic) { if hasMusic { filter = filter == .books ? .all : .books } }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder private var allContent: some View {
        quickGrid
        if !app.books.continueListening.isEmpty {
            BookShelf(title: String(localized: "Continue listening"), items: app.books.continueListening)
        }
        mixes
        radioShelf
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
        // Music and audiobooks take turns, it's one home page
        let music = sections.filter { !$0.albums.isEmpty }
        let books = app.books.shelves.filter { $0.id != "continue-listening" }
        ForEach(0..<max(music.count, books.count), id: \.self) { i in
            if i < music.count { AlbumRow(title: music[i].title, albums: music[i].albums, more: .albums(music[i].id)) }
            if i < books.count { BookShelf(title: books[i].title, items: books[i].items) }
        }
    }

    /// Everything downloaded: all songs first (single songs and favorites aren't an album or playlist), then collections.
    private var downloadItems: [QuickItem] {
        let dl = app.downloads
        guard !dl.index.songs.isEmpty else { return [] }
        let favorites = dl.index.songs.values.contains { $0.song.starred != nil }
        return [.downloads] + (favorites ? [.favorites] : [])
            + dl.index.playlists.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { .playlist($0) }
            + dl.index.albums.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { .album($0) }
    }

    /// Two columns of small tiles at the top: favorites, a few playlists, recently played albums.
    private var quickGrid: some View {
        let recent = sections.first { $0.id == "recent" }?.albums ?? sections.first?.albums ?? []
        let items: [QuickItem] = [.favorites] + playlists.prefix(3).map { .playlist($0) } + recent.map { .album($0) }
        return VStack(spacing: 8) {
            if app.player.dj.ready { DJHomeTile() }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(items.prefix(8)) { QuickTile(item: $0) }
            }
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

    /// Endless radios first (your favorites, the artist playing now, the biggest genres), then the server's stations.
    private var radioShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Radio", more: .stations)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    SmartRadioCards(genres: Array(genres.prefix(4)), size: 130)
                    ForEach(stations) { StationCard(station: $0, all: stations) }
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
                        case .favorites:
                            CollectionCard(title: String(localized: "Favorite songs"), subtitle: String(localized: "\(favoriteDownloads) downloaded"),
                                           route: .favorites) { FavoritesArt() }
                        case .downloads:
                            CollectionCard(title: String(localized: "Downloads"), subtitle: String(localized: "\(app.downloads.index.songs.count) songs"),
                                           route: .downloads) { DownloadsArt() }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var favoriteDownloads: Int { app.downloads.index.songs.values.filter { $0.song.starred != nil }.count }

    private func load() async {
        guard let client = app.client else { return }
        let rows = Theme.homeRows.filter { !Theme.shared.hiddenHomeRows.contains($0.id) }
        // The last known state first: the page is there at once, even before (or without) the network
        if sections.isEmpty {
            if let saved = client.cached("getPlaylists")?.playlists?.playlist { playlists = saved }
            if let saved = client.cached("getInternetRadioStations")?.internetRadioStations?.internetRadioStation { stations = saved }
            if let saved = client.cached("getGenres")?.genres?.genre { genres = radioGenres(saved) }
            sections = rows.map { row in
                HomeSection(id: row.id, title: row.name,
                            albums: client.cached("getAlbumList2", ["type": row.id, "size": "20", "offset": "0"])?.albumList2?.album ?? [])
            }
        }
        loading = true; error = nil
        // All rows at the same time – faster, and one slow or failing row doesn't hold up the others
        async let freshPlaylists = try? client.playlists()
        async let freshStations = try? client.stations()
        async let freshGenres = try? client.genres()
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
        if let s = await freshStations { stations = s }
        if let g = await freshGenres { genres = radioGenres(g) }
        let old = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.albums) })
        sections = rows.map { HomeSection(id: $0.id, title: $0.name, albums: fresh[$0.id] ?? old[$0.id] ?? []) }
        // Only worth a message when there's nothing to show at all
        if let failure, fresh.isEmpty, sections.allSatisfy({ $0.albums.isEmpty }), app.isOnline { error = failure.userMessage }
        loading = false
    }
}

enum QuickItem: Identifiable {
    case favorites
    case downloads
    case playlist(Playlist)
    case album(Album)

    var id: String {
        switch self {
        case .favorites: "fav"
        case .downloads: "dl"
        case .playlist(let p): "p" + p.id
        case .album(let a): "a" + a.id
        }
    }
}

/// Small horizontal tile in the two-column grid at the top of Home.
struct QuickTile: View {
    @Environment(AppModel.self) private var app
    let item: QuickItem

    /// This is what plays (or is paused) right now: its tile shows it.
    private var current: Bool {
        guard let c = app.player.context else { return false }
        switch item {
        case .favorites: return c.kind == .favorites
        case .downloads: return c.kind == .downloads
        case .playlist(let p): return c.kind == .playlist && c.id == p.id
        case .album(let a): return c.kind == .album && c.id == a.id
        }
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 8) {
                art.frame(width: 56, height: 56).clipped()
                Text(title).font(.system(size: 13, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(current ? Color.accent : .primary)
                Spacer(minLength: 4)
            }
            .frame(height: 56)
            .background(current ? Color.accent.opacity(0.22) : Color.elevated)
            .overlay(alignment: .leading) { if current { Rectangle().fill(Color.accent).frame(width: 3) } }
            // The small level meter sits in the corner of the tile, out of the way of cover and title
            .overlay(alignment: .topTrailing) {
                if current { PlayingBars(active: app.player.isPlaying).frame(width: 13, height: 11).padding(.top, 8).padding(.trailing, 9) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var route: Route {
        switch item {
        case .favorites: .favorites
        case .downloads: .downloads
        case .playlist(let p): .playlist(p.id)
        case .album(let a): .album(a.id)
        }
    }

    private var title: String {
        switch item {
        case .favorites: String(localized: "Favorite songs")
        case .downloads: String(localized: "Downloads")
        case .playlist(let p): p.name
        case .album(let a): a.name
        }
    }

    @ViewBuilder private var art: some View {
        switch item {
        case .favorites: FavoritesArt()
        case .downloads: DownloadsArt()
        case .playlist(let p): CoverView(id: p.coverArt ?? p.id, size: 120, corner: 0)
        case .album(let a): CoverView(id: a.coverArt ?? a.id, size: 120, corner: 0)
        }
    }
}

/// Big tile like a playlist card, for the built-in collections (favorites, downloads).
struct CollectionCard<Art: View>: View {
    let title: String
    let subtitle: String
    let route: Route
    @ViewBuilder let art: () -> Art
    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                art().aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 4))
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.subtle).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var width: CGFloat? = 150
    var body: some View {
        NavigationLink(value: Route.playlist(playlist.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(id: playlist.coverArt ?? playlist.id, size: Int(300 * Theme.shared.coverSize.scale), corner: 4)
                Text(playlist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(playlist.songCount ?? 0) songs").font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
            }
            .frame(width: width.map { $0 * Theme.shared.coverSize.scale })
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
    var size: CGFloat = 150
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
                    // Small cards: the icon moves to the corner, so longer titles have room
                    Image(systemName: icon).font(.system(size: size < 150 ? 22 : 44, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: size < 150 ? .topTrailing : .center)
                        .padding(size < 150 ? 10 : 0)
                    if busy { ProgressView().tint(.white).padding(10) }
                    Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).padding(10)
                        .opacity(busy ? 0 : 1)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(2)
                    .frame(width: size, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

/// The artists, albums and favorites the search compares against, kept for a few minutes per account (in memory only),
/// so not every pause in typing fetches them again.
@MainActor enum SearchPool {
    private static var libraries: [UUID: (at: Date, artists: [Artist], albums: [Album])] = [:]
    private static var favs: [UUID: (at: Date, body: SearchBody)] = [:]

    static func library(_ client: SubsonicClient, _ account: UUID) async -> (artists: [Artist], albums: [Album]) {
        if let c = libraries[account], Date().timeIntervalSince(c.at) < 600 { return (c.artists, c.albums) }
        async let artists = try? await client.artists()
        async let albums = try? await client.albumList("alphabeticalByName", size: 500)
        let (a, b) = await (artists ?? [], albums ?? [])
        if !a.isEmpty || !b.isEmpty { libraries[account] = (Date(), a, b) }
        return (a, b)
    }

    static func favorites(_ client: SubsonicClient, _ account: UUID) async -> SearchBody {
        if let c = favs[account], Date().timeIntervalSince(c.at) < 180 { return c.body }
        let body = (try? await client.starred()) ?? SearchBody()
        favs[account] = (Date(), body)
        return body
    }

    static func forget(_ account: UUID) { libraries[account] = nil; favs[account] = nil }
}

/// What the search suggested last, per account, in memory only.
@MainActor enum SuggestionCache { static var songs: [UUID: (list: [Song], at: Date)] = [:] }

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    /// Goes up each time the open tab is tapped again.
    var reselected = 0
    @State private var query = ""
    @State private var result: SearchBody?
    @State private var books = ABSSearchResults()
    /// Until both servers answered "nothing found" would be premature.
    @State private var searching = false
    @State private var genres: [Genre] = []
    @State private var error: String?
    /// Goes up to ask again – pulling down, or "Try again".
    @State private var attempt = 0
    @FocusState private var focused: Bool
    /// Earlier searches of this account, newest first. Only kept on this device.
    @State private var recent: [RecentItem] = []
    /// Audiobooks being listened to, next to the songs in the suggestions.
    @State private var suggestedBooks: [ABSItem] = []
    /// When the servers found nothing but something fits closely: "Did you mean …?"
    @State private var didYouMean: String?
    /// Songs that fit what was listened to lately, shown while the field is empty.
    @State private var suggested: [Song] = []
    /// The search is open: from tapping into the field until "Cancel". Scrolling closes the keyboard, so this can't follow `focused`.
    @State private var suggesting = false
    /// Briefly true after the tab was tapped again, see `onChange(of: reselected)`.
    @State private var resetting = false
    /// A search sent with the search key before its results were in: kept once they are, and only if there are any.
    @State private var pendingQuery: String?
    @State private var confirmClear = false
    /// Nothing fits well: the closest few are shown, under "Similar results".
    @State private var similarOnly = false

    private var accountId: String { app.current?.id.uuidString ?? "none" }
    private var recentKey: String { "search.recent2." + accountId }
    private var loadRecent: [RecentItem] { RecentStore.load(recentKey, legacy: "search.recent." + accountId) }
    private var hasAnyResult: Bool {
        let r = result ?? SearchBody()
        return !(r.artist ?? []).isEmpty || !(r.album ?? []).isEmpty || !(r.song ?? []).isEmpty || !books.items.isEmpty
            || !books.authors.isEmpty || !books.series.isEmpty || !books.narrators.isEmpty
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                TabHeader(title: "Search").padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14).id("search.top")
                Section {
                    if query.trimmingCharacters(in: .whitespaces).count >= 2 { results } else { browse }
                } header: {
                    HStack(spacing: 12) {
                        field
                        if suggesting {
                            Button("Cancel") { query = ""; focused = false; withAnimation(.easeOut(duration: 0.2)) { suggesting = false } }
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12).background(Color.canvas)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackground()
        .onChange(of: reselected) {
            // Tapping the tab again starts the search over. iOS gives the field its focus back when the page returns,
            // so focus gained right after this is turned down
            query = ""; suggesting = false; focused = false; resetting = true
            withAnimation(.easeOut(duration: 0.3)) { scroller.scrollTo("search.top", anchor: .top) }
            Task { try? await Task.sleep(for: .milliseconds(700)); resetting = false }
        }
        .onChange(of: focused) {
            if focused && resetting { focused = false; return }
            if focused { withAnimation(.easeOut(duration: 0.2)) { suggesting = true } }
        }
        .refreshable { await pulled { attempt += 1 } }
        .task(id: "\(query)|\(attempt)") {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { result = nil; books = ABSSearchResults(); searching = false; return }
            searching = true
            didYouMean = nil
            similarOnly = false
            try? await Task.sleep(for: .milliseconds(200)) // wait until typing pauses
            guard !Task.isCancelled else { return }
            // Each server shows its results as they arrive, the slower one doesn't hold up the other
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    guard let client = app.client else { result = nil; return }
                    do {
                        let found = try await client.search(q)
                        if !Task.isCancelled { result = found; error = nil }
                    } catch {
                        // Not the results of an earlier input, they don't belong to this one
                        if !Task.isCancelled { self.error = error.userMessage; result = nil }
                    }
                }
                group.addTask { @MainActor in
                    let found = await app.books.search(q)
                    if !Task.isCancelled { books = found }
                }
            }
            // Little found (a typo, half a name): ask again more loosely, then order by how well it fits
            if !Task.isCancelled, error == nil { await widen(q) }
            guard !Task.isCancelled else { return }
            await taste(q)
            searching = false
            if let p = pendingQuery, SmartMatch.normalize(p) == SmartMatch.normalize(q) {
                pendingQuery = nil
                if hasAnyResult { remember(RecentItem(kind: .query, key: p, title: p)) }
            }
        }
        .onDisappear { focused = false }
        .onAppear { recent = loadRecent }
        .onChange(of: app.current?.id) { recent = loadRecent }
        #if DEBUG
        // Test hook: -demoSearch <text> fills in the search field, typing doesn't reach it in the simulator
        .onAppear { if query.isEmpty, let demo = UserDefaults.standard.string(forKey: "demoSearch") { query = demo } }
        #endif
        .task(id: "\(attempt)|\(app.current?.id.uuidString ?? "")") { await loadSuggestions() }
        .task(id: attempt) {
            guard genres.isEmpty || attempt > 0, let all = try? await app.client?.genres() else { return }
            genres = Array(all.filter { ($0.albumCount ?? 0) > 0 }.sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }.prefix(30))
        }
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
                .onSubmit { rememberQuery(query) }
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

    /// Songs similar to the last few albums played, without the songs of those albums, and the audiobooks being
    /// listened to. Takes the server's own idea of "similar" (the same one the song radio uses), so there are no songs
    /// when the server has none.
    private func loadSuggestions() async {
        suggestedBooks = Array(app.books.continueListening.prefix(2))
        // The same songs for a while: going back and forth doesn't shuffle them. Pulling down asks again.
        let account = app.current?.id
        if attempt == 0, let account, let c = SuggestionCache.songs[account], Date().timeIntervalSince(c.at) < 900 { suggested = c.list; return }
        guard let client = app.client, let albums = try? await client.albumList("recent", size: 4), !albums.isEmpty else { return }
        // Albums and similar songs for the three albums all at once
        let per = await withTaskGroup(of: (Int, [String], [Song]).self) { group in
            for (i, a) in albums.prefix(3).enumerated() {
                group.addTask {
                    guard let songs = (try? await client.album(a.id))?.song, let seed = songs.randomElement() else { return (i, [], []) }
                    return (i, songs.map(\.id), await client.similarSongs(seed.id))
                }
            }
            var out: [(Int, [String], [Song])] = []
            for await x in group { out.append(x) }
            return out.sorted { $0.0 < $1.0 }
        }
        let heard = Set(per.flatMap(\.1))
        let lists = per.map(\.2).filter { !$0.isEmpty }
        // One from each list in turn, so it isn't all about the newest album
        var out: [Song] = []
        var seen = heard
        var i = 0
        while out.count < 10, lists.contains(where: { i < $0.count }) {
            for l in lists where i < l.count && out.count < 10 {
                if seen.insert(l[i].id).inserted { out.append(l[i]) }
            }
            i += 1
        }
        if !Task.isCancelled { suggested = out; if let account { SuggestionCache.songs[account] = (out, Date()) } }
    }

    private var hasSuggestions: Bool { !suggested.isEmpty || !suggestedBooks.isEmpty }

    @ViewBuilder private var suggestedList: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty && hasSuggestions {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested for you").font(.system(size: 17, weight: .bold)).padding(.top, 8)
                ForEach(suggestedBooks) { b in
                    NavigationLink(value: Route.audiobook(b.id)) {
                        ItemRow(title: b.title, subtitle: [String(localized: b.isPodcast ? "Podcast" : "Audiobook"), b.creator].filter { !$0.isEmpty }.joined(separator: " • ")) {
                            BookCover(itemId: b.id, width: 200, corner: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(suggested.enumerated()), id: \.element.id) { i, s in
                    SongRow(song: s, showCover: true) {
                        remember(songItem(s))
                        app.player.play(suggested, from: i, context: .init(kind: .search, name: String(localized: "Suggested for you")))
                    }
                }
            }
        }
    }

    // MARK: Tolerant search

    /// The servers found little: ask again more loosely (single words, the first letters of a word), then put what came
    /// back in order by how well it fits what was typed. With nothing found at all, the closest name is offered.
    private func widen(_ q: String) async {
        let r0 = result ?? SearchBody()
        let have = (r0.artist ?? []).count + (r0.album ?? []).count + (r0.song ?? []).count + books.items.count
            + books.authors.count + books.series.count + books.narrators.count
        guard have < 4 else { return }
        // Something that fits fully is there: nothing to look for more loosely
        var names: [String] = (r0.artist ?? []).map(\.name) + (r0.album ?? []).map(\.name) + (r0.song ?? []).map(\.title)
        names += books.items.map(\.title) + books.authors.map(\.name) + books.series.map(\.name) + books.narrators
        guard have == 0 || !names.contains(where: { SmartMatch.score(query: q, text: $0) >= 1 }) else { return }
        let variants = SmartMatch.variants(for: q)
        try? await Task.sleep(for: .milliseconds(300)) // typing on? then these questions are not needed
        guard !Task.isCancelled else { return }
        var more = SearchBody()
        var moreBooks = ABSSearchResults()
        // The whole library is looked through here, not only what the server finds by the start of a word: a typo
        // anywhere in a name still finds it. Both lists come from the offline copy when it is there.
        var poolArtists: [Artist] = [], poolAlbums: [Album] = []
        var artistScores: [Double] = [], albumScores: [Double] = []
        if let client = app.client, let account = app.current?.id {
            let lib = await SearchPool.library(client, account)
            poolArtists = lib.artists; poolAlbums = lib.albums
            (artistScores, albumScores) = await Self.scoreLibrary(SmartMatch.prepare(q), poolArtists, poolAlbums)
            guard !Task.isCancelled, artistScores.count == poolArtists.count else { return }
            more.artist = zip(poolArtists, artistScores).filter { $0.1 >= 0.72 }.map(\.0)
            more.album = zip(poolAlbums, albumScores).filter { $0.1 >= 0.72 }.map(\.0)
        }
        await withTaskGroup(of: (SearchBody?, ABSSearchResults).self) { group in
            for v in variants {
                group.addTask { @MainActor in
                    let a = try? await app.client?.search(v, wide: true)
                    let b = await app.books.search(v)
                    return (a, b)
                }
            }
            for await (a, b) in group {
                more.artist = (more.artist ?? []) + (a?.artist ?? [])
                more.album = (more.album ?? []) + (a?.album ?? [])
                more.song = (more.song ?? []) + (a?.song ?? [])
                moreBooks.items += b.items; moreBooks.authors += b.authors; moreBooks.series += b.series; moreBooks.narrators += b.narrators
            }
        }
        guard !Task.isCancelled else { return }
        func unique<T: Identifiable>(_ a: [T]) -> [T] where T.ID: Hashable {
            var seen = Set<T.ID>(); return a.filter { seen.insert($0.id).inserted }
        }
        /// What the servers had stays; what the looser questions brought needs a fair fit. Best fit first.
        func rank<T: Identifiable>(_ original: [T], _ extra: [T], _ text: (T) -> String) -> [T] where T.ID: Hashable {
            let keep = Set(original.map(\.id))
            let scored = unique(original + extra).map { ($0, SmartMatch.score(query: q, text: text($0))) }.filter { keep.contains($0.0.id) || $0.1 >= 0.72 }
            return scored.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }.map { $0.element.0 }
        }
        var merged = r0
        merged.artist = rank(r0.artist ?? [], more.artist ?? []) { $0.name }
        merged.album = rank(r0.album ?? [], more.album ?? []) { "\($0.name) \($0.artist ?? "")" }
        merged.song = rank(r0.song ?? [], more.song ?? []) { "\($0.title) \($0.artist ?? "")" }
        var mergedBooks = books
        mergedBooks.items = rank(books.items, moreBooks.items) { "\($0.title) \($0.creator)" }
        mergedBooks.authors = rank(books.authors, moreBooks.authors) { $0.name }
        mergedBooks.series = rank(books.series, moreBooks.series) { $0.name }
        let nIds = Set(books.narrators)
        mergedBooks.narrators = Array(Set(books.narrators + moreBooks.narrators)).map { ($0, SmartMatch.score(query: q, text: $0)) }
            .filter { nIds.contains($0.0) || $0.1 >= 0.72 }.sorted { $0.1 > $1.1 }.map { $0.0 }
        // Nothing fits well: the closest few are better than an empty page
        let none = (merged.artist ?? []).isEmpty && (merged.album ?? []).isEmpty && (merged.song ?? []).isEmpty
            && mergedBooks.items.isEmpty && mergedBooks.authors.isEmpty && mergedBooks.series.isEmpty && mergedBooks.narrators.isEmpty
        if none, have == 0 {
            let nearArtists = Array(zip(poolArtists, artistScores)).filter { $0.1 >= 0.35 }
                .sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
            let nearAlbums = Array(zip(poolAlbums, albumScores)).filter { $0.1 >= 0.35 }
                .sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
            if !nearArtists.isEmpty || !nearAlbums.isEmpty {
                merged.artist = Array(nearArtists); merged.album = Array(nearAlbums)
                similarOnly = true
            }
        }
        result = merged
        books = mergedBooks
        // Nothing at first, something close now: offer it
        guard have == 0 else { return }
        names = (merged.artist ?? []).map(\.name) + (merged.album ?? []).map(\.name) + (merged.song ?? []).map(\.title)
        names += mergedBooks.items.map(\.title) + mergedBooks.authors.map(\.name) + mergedBooks.series.map(\.name) + mergedBooks.narrators
        let best = names.map { ($0, SmartMatch.score(query: q, text: $0)) }.filter { $0.1 >= 0.75 && SmartMatch.normalize($0.0) != SmartMatch.normalize(q) }.max { $0.1 < $1.1 }
        didYouMean = best?.0
    }

    /// Puts what the person likes and knows further up, like the Android app: favorites, songs heard often, albums
    /// and artists played lately, songs played from an earlier search. Favorites that fit are found even when the
    /// server doesn't list them. Everything is ordered by how well it fits plus that little push.
    private func taste(_ q: String) async {
        guard let r = result, let client = app.client, let account = app.current?.id else { return }
        let fav = await SearchPool.favorites(client, account)
        guard !Task.isCancelled else { return }
        let played = PlayHistory.dates(account)
        let searched = Set(recent.compactMap { $0.kind == .song ? $0.song?.id : nil })
        let ranked = await Self.rankTaste(SmartMatch.prepare(q), r, fav, played, searched)
        guard !Task.isCancelled else { return }
        result = ranked
    }

    /// The comparing runs off the main thread: with many favorites it would stall the keyboard.
    private nonisolated static func rankTaste(_ q: SmartMatch.Prepared, _ result: SearchBody, _ fav: SearchBody,
                                              _ played: [String: Double], _ searched: Set<String>) async -> SearchBody {
        var r = result
        let favSongs = Set((fav.song ?? []).map(\.id))
        let favAlbums = Set((fav.album ?? []).map(\.id))
        let favArtists = Set((fav.artist ?? []).map(\.id))

        func order<T: Identifiable>(_ server: [T], _ pool: [T], limit: Int, base: (T) -> Double, boost: (T) -> Double) -> [T] where T.ID: Hashable {
            let have = Set(server.map(\.id))
            let extra = pool.filter { !have.contains($0.id) && base($0) >= 72 }
            let scored = (server + extra).enumerated().map { (i, x) -> (Int, T, Double) in
                var b = base(x)
                if have.contains(x.id) { b = max(b, 55) }
                return (i, x, b + boost(x))
            }
            return Array(scored.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.prefix(limit).map { $0.1 })
        }
        func heard(_ s: Song) -> Double { (s.playCount ?? 0) > 0 ? min(15, log(1 + Double(s.playCount ?? 0)) * 5) : 0 }

        r.song = order(r.song ?? [], fav.song ?? [], limit: 40,
                       base: { max(SmartMatch.score(q, text: $0.title), 0.95 * SmartMatch.score(q, text: "\($0.title) \($0.artist ?? "")")) * 100 },
                       boost: { ($0.starred != nil || favSongs.contains($0.id) ? 12 : 0) + heard($0) + (searched.contains($0.id) ? 10 : 0) })
        r.album = order(r.album ?? [], fav.album ?? [], limit: 20,
                        base: { max(SmartMatch.score(q, text: $0.name), 0.95 * SmartMatch.score(q, text: "\($0.name) \($0.artist ?? "")")) * 100 },
                        boost: { ($0.starred != nil || favAlbums.contains($0.id) ? 12 : 0) + (played["a" + $0.id] != nil ? 8 : 0) })
        r.artist = order(r.artist ?? [], fav.artist ?? [], limit: 10,
                         base: { SmartMatch.score(q, text: $0.name) * 100 },
                         boost: { ($0.starred != nil || favArtists.contains($0.id) ? 12 : 0) + (played["r" + $0.id] != nil ? 8 : 0) })
        return r
    }

    /// Scores of every artist and album of the library for what was typed, computed off the main thread.
    private nonisolated static func scoreLibrary(_ q: SmartMatch.Prepared, _ artists: [Artist], _ albums: [Album]) async -> ([Double], [Double]) {
        var a: [Double] = []; a.reserveCapacity(artists.count)
        for (i, x) in artists.enumerated() {
            if i % 500 == 0, Task.isCancelled { return ([], []) }
            a.append(SmartMatch.score(q, text: x.name))
        }
        var b: [Double] = []; b.reserveCapacity(albums.count)
        for x in albums { b.append(SmartMatch.score(q, text: x.name)) }
        return (a, b)
    }

    // MARK: Recent

    private func remember(_ item: RecentItem) {
        var list = recent
        // What was typed to get here isn't kept next to the thing it found
        if item.kind != .query {
            let typed = SmartMatch.normalize(query)
            if !typed.isEmpty { list.removeAll { $0.kind == .query && SmartMatch.normalize($0.key) == typed } }
        }
        recent = RecentStore.adding(item, to: list)
        RecentStore.save(recent, key: recentKey)
    }

    private func songItem(_ s: Song) -> RecentItem {
        RecentItem(kind: .song, key: s.id, title: s.title, detail: s.artist, cover: s.coverArt ?? s.albumId, song: s)
    }

    /// A search sent with the keyboard's search key. Kept when it found something (right away, or once the results are in).
    private func rememberQuery(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return }
        if searching || t != query.trimmingCharacters(in: .whitespaces) { pendingQuery = t; return }
        if hasAnyResult { remember(RecentItem(kind: .query, key: t, title: t)) }
    }

    private func forget(_ item: RecentItem?) {
        if let item { recent.removeAll { $0.id == item.id } } else { recent = [] }
        RecentStore.save(recent, key: recentKey)
    }

    /// Earlier searches that fit what's typed so far (all of them while the field is empty).
    private var suggestions: [RecentItem] {
        let q = SmartMatch.normalize(query)
        return q.isEmpty ? recent : recent.filter { let t = SmartMatch.normalize($0.title); return t.contains(q) && t != q }
    }

    /// Swiping an earlier song or album like a song row: right plays it next, left adds it to a playlist.
    private func queue(_ item: RecentItem, next: Bool) {
        Task {
            let songs: [Song]
            switch item.kind {
            case .song: songs = item.song.map { [$0] } ?? []
            case .album: songs = (try? await app.client?.album(item.key))?.song ?? []
            default: songs = []
            }
            guard !songs.isEmpty else { return }
            if next {
                let playing = app.player.current != nil
                app.player.playNext(songs)
                if playing { app.notify(String(localized: "Plays next")) }
            } else {
                ui.addToPlaylist(songs)
            }
        }
    }

    private func route(for item: RecentItem) -> Route? {
        switch item.kind {
        case .artist: .artist(item.key)
        case .album: .album(item.key)
        case .book: .audiobook(item.key)
        case .author: .bookAuthor(id: item.key, name: item.title)
        case .series: .bookSeries(id: item.key, name: item.title, library: nil)
        case .narrator: .bookNarrator(name: item.title, library: nil)
        case .song, .query: nil
        }
    }

    private func subtitle(of item: RecentItem) -> String {
        let parts: [String?]
        switch item.kind {
        case .query: parts = [String(localized: "Search")]
        case .artist: parts = [String(localized: "Artist")]
        case .album: parts = [String(localized: "Album"), item.detail]
        case .song: parts = [item.detail]
        case .book: parts = [String(localized: item.podcast == true ? "Podcast" : "Audiobook"), item.detail]
        case .author: parts = [String(localized: "Author")]
        case .series: parts = [String(localized: "Series")]
        case .narrator: parts = [String(localized: "Narrator")]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    @ViewBuilder private func art(of item: RecentItem) -> some View {
        switch item.kind {
        case .artist: CoverView(id: item.cover ?? item.key, size: 120, round: true).frame(width: 52)
        case .album, .song: CoverView(id: item.cover ?? item.key, size: 120, corner: 2).frame(width: 52)
        case .book: BookCover(itemId: item.key, width: 200, corner: 2)
        case .author: AuthorImage(id: item.key, name: item.title).frame(width: 52)
        case .narrator: AuthorImage(id: nil, name: item.title).frame(width: 52)
        case .series:
            Color.elevated.aspectRatio(1, contentMode: .fit).overlay { Image(systemName: "books.vertical").foregroundStyle(Color.subtle) }
                .clipShape(RoundedRectangle(cornerRadius: 2))
        case .query:
            Circle().fill(Color.elevated).overlay { Image(systemName: "magnifyingglass").foregroundStyle(Color.subtle) }.frame(width: 52)
        }
    }

    /// Opens what was opened before, right away: no new search.
    @ViewBuilder private func recentRow(_ item: RecentItem) -> some View {
        let label = ItemRow(title: item.title, subtitle: subtitle(of: item)) { art(of: item) }
        if let route = route(for: item) {
            NavigationLink(value: route) { label }.buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { remember(item) })
        } else if item.kind == .song, let song = item.song {
            Button {
                remember(item)
                app.player.play([song], from: 0, context: .init(kind: .search, name: song.title))
            } label: { label }.buttonStyle(.plain)
        } else {
            Button { query = item.key; remember(item); focused = false } label: { label }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var recentList: some View {
        let list = suggestions
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Recent searches").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button("Clear all") { confirmClear = true }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.subtle)
                }
                .padding(.top, 8).padding(.bottom, 4)
                .confirmationDialog("Clear recent searches?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear all", role: .destructive) { withAnimation { forget(nil) } }
                }
                ForEach(list) { item in
                    HStack(spacing: 4) {
                        recentRow(item)
                            .modifier(SwipeRow(on: item.kind == .album || (item.kind == .song && item.song != nil),
                                               rightIcon: "text.insert", leftIcon: "text.badge.plus",
                                               right: { queue(item, next: true) }, left: { queue(item, next: false) }))
                        Button { withAnimation { forget(item) } } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.subtle)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Remove")
                        .accessibilityHint(item.title)
                    }
                }
            }
        }
    }

    private var browse: some View {
        // The tiles stay what the search shows at first. Tapping into the field swaps them for earlier searches and
        // suggestions – as long as there are any, otherwise the tiles stay.
        let typing = suggesting && (!suggestions.isEmpty || (query.trimmingCharacters(in: .whitespaces).isEmpty && hasSuggestions))
        return VStack(alignment: .leading, spacing: 14) {
            if typing {
                recentList
                suggestedList
            } else {
                if app.client != nil { Text("Browse all").font(.system(size: 17, weight: .bold)).padding(.top, 8) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(genres, id: \.value) { GenreTile(genre: $0.value) }
                }
                if genres.isEmpty && app.isOnline && app.client != nil { ProgressView().frame(maxWidth: .infinity).padding(30) }
            }
        }
        .padding(.horizontal, 16)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.system(size: 17, weight: .bold)).padding(.top, 10)
    }

    @ViewBuilder private func artistRow(_ a: Artist) -> some View {
        NavigationLink(value: Route.artist(a.id)) {
            ItemRow(title: a.name, subtitle: String(localized: "Artist")) {
                CoverView(id: a.coverArt ?? a.id, size: 120, round: true).frame(width: 52)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { remember(RecentItem(kind: .artist, key: a.id, title: a.name, cover: a.coverArt ?? a.id)) })
    }

    @ViewBuilder private var results: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if let error { LoadState(loading: false, error: error) { attempt += 1 } }
            if let didYouMean {
                Button { query = didYouMean } label: {
                    Text("Did you mean “\(didYouMean)”?").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accent)
                }
                .padding(.vertical, 6)
            }
            let r = result ?? SearchBody()
            Group {
                if similarOnly { sectionTitle("Similar results") }
                let typed = SmartMatch.normalize(query)
                let exactArtists = (r.artist ?? []).filter { SmartMatch.normalize($0.name) == typed }
                let otherArtists = (r.artist ?? []).filter { SmartMatch.normalize($0.name) != typed }
                ForEach(exactArtists) { artistRow($0) }
                if !(r.song ?? []).isEmpty { sectionTitle("Songs") }
                let songs = r.song ?? []
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                    SongRow(song: s, showCover: true) {
                        remember(songItem(s))
                        // The song plays, then songs like it follow: not the rest of the results
                        Task {
                            if !(await app.player.radio.start(String(localized: "\(s.title) radio"), seedId: s.id, first: s)) {
                                app.player.play([s], from: 0, context: .init(kind: .search, name: query))
                            }
                        }
                    }
                }
                if !otherArtists.isEmpty { sectionTitle("Artists") }
                ForEach(otherArtists) { artistRow($0) }
                if !books.authors.isEmpty { sectionTitle("Authors") }
                ForEach(books.authors) { a in
                    NavigationLink(value: Route.bookAuthor(id: a.id, name: a.name)) {
                        ItemRow(title: a.name, subtitle: String(localized: "Author")) { AuthorImage(id: a.id, name: a.name).frame(width: 52) }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { remember(RecentItem(kind: .author, key: a.id, title: a.name)) })
                    .contextMenu { AuthorFavoriteMenu(id: a.id, name: a.name) }
                }
                if !(r.album ?? []).isEmpty { sectionTitle("Albums") }
                ForEach(r.album ?? []) { a in
                    NavigationLink(value: Route.album(a.id)) {
                        ItemRow(title: a.name, subtitle: [String(localized: "Album"), a.artist].compactMap { $0 }.joined(separator: " • ")) {
                            CoverView(id: a.coverArt ?? a.id, size: 120, corner: 2).frame(width: 52)
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { remember(RecentItem(kind: .album, key: a.id, title: a.name, detail: a.artist, cover: a.coverArt ?? a.id)) })
                }
                if !books.items.isEmpty { sectionTitle("Audiobooks") }
                ForEach(books.items) { b in
                    NavigationLink(value: Route.audiobook(b.id)) {
                        ItemRow(title: b.title, subtitle: [app.books.isFinished(b.id) ? String(localized: "Finished") : "", String(localized: b.isPodcast ? "Podcast" : "Audiobook"), b.creator].filter { !$0.isEmpty }.joined(separator: " • ")) {
                            BookCover(itemId: b.id, width: 200, corner: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { remember(RecentItem(kind: .book, key: b.id, title: b.title, detail: b.creator, podcast: b.isPodcast)) })
                }
                if !books.series.isEmpty { sectionTitle("Series") }
                ForEach(books.series) { s in
                    NavigationLink(value: Route.bookSeries(id: s.id, name: s.name, library: nil)) {
                        ItemRow(title: s.name, subtitle: String(localized: "Series")) {
                            Color.elevated.aspectRatio(1, contentMode: .fit).overlay { Image(systemName: "books.vertical").foregroundStyle(Color.subtle) }
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { remember(RecentItem(kind: .series, key: s.id, title: s.name)) })
                }
                if !books.narrators.isEmpty { sectionTitle("Narrators") }
                ForEach(books.narrators, id: \.self) { n in
                    NavigationLink(value: Route.bookNarrator(name: n, library: nil)) {
                        ItemRow(title: n, subtitle: String(localized: "Narrator")) { AuthorImage(id: nil, name: n).frame(width: 52) }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { remember(RecentItem(kind: .narrator, key: n, title: n)) })
                }
                let nothing = (r.artist ?? []).isEmpty && (r.album ?? []).isEmpty && songs.isEmpty && books.items.isEmpty
                    && books.authors.isEmpty && books.series.isEmpty && books.narrators.isEmpty
                if nothing && searching {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if nothing {
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
        // Not a .task: that is cancelled when the page is rebuilt (the tab tapped again) and the tile stays without a cover
        .onAppear {
            guard coverId == nil else { return }
            Task { coverId = try? await app.client?.albumList("byGenre", size: 1, genre: genre).first.map { $0.coverArt ?? $0.id } }
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
    /// Goes up each time the open tab is tapped again.
    var reselected = 0
    @State private var filter: Filter?
    @State private var playlists: [Playlist] = []
    @State private var starred: SearchBody?
    @State private var query = ""
    @State private var searching = false
    @AppStorage("library.sort") private var sort: Sort = .recent
    @AppStorage("library.grid") private var grid = false
    @FocusState private var searchFocused: Bool
    /// What you pinned to the top, newest first. Kept on this iPhone per account.
    @State private var pins: [String] = []

    enum Filter { case playlists, albums, artists, downloads, books, podcasts }

    enum Sort: String, CaseIterable {
        case recent, played, name, creator
        var title: LocalizedStringKey {
            switch self {
            case .recent: "Recently added"
            case .played: "Recently played"
            case .name: "Alphabetical"
            case .creator: "Artist or creator"
            }
        }
    }

    /// One entry of the library, whatever it is. Of the books, the ones with a heart.
    enum Item: Identifiable {
        case dj, favorites, downloads, playlist(Playlist), album(Album), artist(Artist), book(ABSItem, added: String), author(ABSAuthor, added: String)
        var id: String {
            switch self {
            case .dj: "dj"
            case .favorites: "favorites"
            case .downloads: "downloads"
            case .playlist(let p): "p" + p.id
            case .album(let a): "a" + a.id
            case .artist(let a): "r" + a.id
            case .book(let b, _): "b" + b.id
            case .author(let a, _): "u" + a.id
            }
        }
        var name: String {
            switch self {
            case .dj, .favorites, .downloads: ""
            case .playlist(let p): p.name
            case .album(let a): a.name
            case .artist(let a): a.name
            case .book(let b, _): b.title
            case .author(let a, _): a.name
            }
        }
        var creator: String {
            switch self {
            case .playlist(let p): p.owner ?? ""
            case .album(let a): a.artist ?? ""
            case .artist(let a): a.name
            case .book(let b, _): b.creator
            case .author(let a, _): a.name
            default: ""
            }
        }
        /// When it was added or changed (ISO date from the server, sorts as text).
        var date: String {
            switch self {
            case .playlist(let p): p.changed ?? ""
            case .album(let a): a.starred ?? ""
            case .artist(let a): a.starred ?? ""
            case .book(_, let added): added
            case .author(_, let added): added
            default: ""
            }
        }
        var pinned: Bool { if case .dj = self { true } else if case .favorites = self { true } else if case .downloads = self { true } else { false } }
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TabHeader(title: "Your Library").padding(.top, 8).id(Self.top)
                    // A new identity also scrolls the chips back to their start
                    chips.id(reselected)
                    toolbar
                    if grid {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 18) {
                            ForEach(keyed, id: \.key) { tile($0.item) }
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) { ForEach(keyed, id: \.key) { row($0.item) } }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackground()
            .task(id: "\(app.currentId?.uuidString ?? "")\(app.current?.serverURL ?? "")\(app.playlistsVersion)-\(app.favoritesVersion)") { await load() }
            .refreshable { await pulled { await Task { await load() }.value; await app.books.load(force: true) } }
            .task(id: "\(app.currentId?.uuidString ?? "")\(app.books.connected)") { await app.books.load() }
            .onChange(of: app.currentId) { filter = nil }
            .onChange(of: app.books.connected) { _, on in if !on && (filter == .books || filter == .podcasts) { filter = nil } }
            .onChange(of: reselected) {
                withAnimation(.easeOut(duration: 0.15)) { filter = nil; query = ""; searching = false }
                searchFocused = false
                scroller.scrollTo(Self.top, anchor: .top)
            }
            .onAppear(perform: loadPins)
            .onChange(of: app.currentId) { loadPins() }
            .onChange(of: pins.first) { old, new in
                // Something new pinned: go up to where it lands, so it doesn't vanish from where it was
                if let new, new != old { withAnimation(.snappy(duration: 0.35)) { scroller.scrollTo(Self.top, anchor: .top) } }
            }
        }
    }

    private static let top = "library.top"

    // MARK: Pins

    private var pinsKey: String { "library.pins." + (app.currentId?.uuidString ?? "") }

    private func loadPins() { pins = UserDefaults.standard.stringArray(forKey: pinsKey) ?? [] }

    private func togglePin(_ item: Item) {
        var next = pins
        if let i = next.firstIndex(of: item.id) { next.remove(at: i) } else { next.insert(item.id, at: 0) }
        UserDefaults.standard.set(next, forKey: pinsKey)
        // Wait until the long-press menu has closed and the row is back in place. The row then fades out
        // where it was and in where it goes – sliding it across a long list makes it fly through everything
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeInOut(duration: 0.3)) { pins = next }
        }
    }

    private func isPinned(_ item: Item) -> Bool { item.pinned || pins.contains(item.id) }

    /// Long press: pin or unpin. Favorites and Downloads always stay on top.
    @ViewBuilder private func pinMenu(_ item: Item) -> some View {
        if !item.pinned {
            Button { togglePin(item) } label: {
                pins.contains(item.id) ? Label("Unpin", systemImage: "pin.slash") : Label("Pin to top", systemImage: "pin")
            }
        }
    }

    // MARK: Filter bar

    /// All chips stay where they are; the chosen one lights up, tapping it again shows everything.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if hasMusic {
                    chip("Playlists", .playlists)
                    chip("Albums", .albums)
                    chip("Artists", .artists)
                    chip("Downloads", .downloads)
                }
                if app.books.connected {
                    if app.books.libraries.contains(where: { !$0.isPodcasts }) { chip("Audiobooks", .books) }
                    if app.books.libraries.contains(where: \.isPodcasts) { chip("Podcasts", .podcasts) }
                }
            }
        }
    }

    private var hasMusic: Bool { app.current?.hasMusic ?? true }

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
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label { Text(sort.title) } icon: { Image(systemName: "arrow.up.arrow.down") }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
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
        if items.isEmpty {
            Text(emptyText).font(.subheadline).foregroundStyle(Color.subtle)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 40)
        }
        // The library holds what you saved; the whole server is one tap away
        if app.books.connected, query.isEmpty, filter == .books || (filter == nil && !hasMusic), app.books.libraries.contains(where: { !$0.isPodcasts }) {
            browseLink("Browse all audiobooks", icon: "book.closed", route: .booksAll(podcasts: false))
        }
        if app.books.connected, query.isEmpty, filter == .podcasts {
            browseLink("Browse all podcasts", icon: "mic", route: .booksAll(podcasts: true))
        }
        if filter == .albums || filter == .artists {
            NavigationLink(value: filter == .albums ? Route.albums("alphabeticalByName") : Route.artists) {
                HStack {
                    Image(systemName: filter == .albums ? "square.stack" : "music.mic").foregroundStyle(Color.accent).frame(width: 28)
                    Text(filter == .albums ? "Browse all albums on the server" : "Browse all artists on the server")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.subtle)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16).frame(height: 52)
                .background(Color.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    private func browseLink(_ title: LocalizedStringKey, icon: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack {
                Image(systemName: icon).foregroundStyle(Color.accent).frame(width: 28)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.subtle)
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16).frame(height: 52)
            .background(Color.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var emptyText: LocalizedStringKey {
        if !query.isEmpty { return "Nothing in your library matches “\(query)”." }
        if filter == .books || (filter == nil && !hasMusic) { return "No favorite audiobooks yet. Tap the heart on a book or author to add them here." }
        if filter == .podcasts { return "No favorite podcasts yet. Tap the heart on a podcast to add it here." }
        if filter == .albums { return "No favorite albums yet. Tap the heart on an album to add it here." }
        if filter == .artists { return "No favorite artists yet. Tap the heart on an artist to add them here." }
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
            // The DJ is part of the library for people who turned it on
            pinned = hasMusic ? (app.player.dj.ready && app.isOnline ? [.dj] : []) + [.favorites] : []
            rest = hasMusic ? playlists.map(Item.playlist) + (starred?.album ?? []).map(Item.album) + (starred?.artist ?? []).map(Item.artist) : []
            rest += bookItems { _ in true } + authorItems
        case .playlists:
            pinned = [.favorites]
            rest = playlists.map(Item.playlist)
        case .albums:
            rest = (starred?.album ?? []).map(Item.album)
        case .artists:
            rest = (starred?.artist ?? []).map(Item.artist) + authorItems
        case .downloads:
            pinned = [.downloads] + (downloadedFavorites > 0 ? [.favorites] : [])
            rest = dl.index.playlists.values.map(Item.playlist) + dl.index.albums.values.map(Item.album)
            rest += app.books.downloads.sorted.map { .book($0.item, added: "") }
        case .books:
            rest = bookItems { !$0.isPodcast } + authorItems
        case .podcasts:
            rest = bookItems(\.isPodcast)
        }
        // Pinned ones first (newest pin on top), everything else in the chosen order
        let all = sorted(rest)
        let top = pins.compactMap { id in all.first { $0.id == id } }
        let list = top + all.filter { !pins.contains($0.id) }
        return query.isEmpty ? pinned + list : matching(list)
    }

    /// The books with a heart, like the albums and artists with one. Newest heart first.
    private func bookItems(_ wanted: (ABSItem) -> Bool) -> [Item] {
        let b = app.books
        guard b.connected else { return [] }
        let dates = ISO8601DateFormatter()
        return b.favorites.values.filter { wanted($0.item) }.map { .book($0.item, added: dates.string(from: $0.date)) }
    }

    /// The authors with a heart. They count as artists too, and belong with the audiobooks.
    private var authorItems: [Item] {
        guard app.books.connected else { return [] }
        let dates = ISO8601DateFormatter()
        return app.books.favoriteAuthors.values.map { .author($0.author, added: dates.string(from: $0.date)) }
    }

    /// When it was last played: music from what this iPhone noted, audiobooks from the server's progress.
    private func lastPlayed(_ item: Item, _ history: [String: Double]) -> Double {
        switch item {
        case .book(let b, _): (app.books.progress(of: b)?.lastUpdate ?? 0) / 1000
        default: history[item.id] ?? 0
        }
    }

    private func sorted(_ list: [Item]) -> [Item] {
        switch sort {
        case .played:
            // Last played first; what was never played follows, newest hearts first
            _ = app.player.context // what is played now changes the list, so the page follows it
            let history = PlayHistory.dates(app.currentId)
            return list.enumerated().sorted { a, b in
                let (x, y) = (lastPlayed(a.element, history), lastPlayed(b.element, history))
                if x != y { return x > y }
                return a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset
            }.map(\.element)
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
        case .dj: .dj
        case .favorites: .favorites
        case .downloads: .downloads
        case .playlist(let p): .playlist(p.id)
        case .album(let a): .album(a.id)
        case .artist(let a): .artist(a.id)
        case .book(let b, _): .audiobook(b.id)
        case .author(let a, _): .bookAuthor(id: a.id, name: a.name)
        }
    }

    private func subtitle(_ item: Item) -> String {
        switch item {
        case .dj: app.player.context?.kind == .dj && app.player.isPlaying ? app.player.dj.line ?? String(localized: "Playing now") : String(localized: "Sets picked from your library")
        case .favorites:
            filter == .downloads
                ? String(localized: "\(downloadedFavorites) of \(starred?.song?.count ?? 0) downloaded")
                : String(localized: "Playlist • \(starred?.song?.count ?? 0) songs")
        case .downloads: String(localized: "\(app.downloads.downloadedSongs.count) songs")
        case .playlist(let p): [String(localized: "Playlist"), p.owner].compactMap { $0 }.joined(separator: " • ")
        case .album(let a): [String(localized: "Album"), a.artist].compactMap { $0 }.joined(separator: " • ")
        case .artist: String(localized: "Artist")
        case .author: String(localized: "Author")
        case .book(let b, _):
            [app.books.isFinished(b.id) ? String(localized: "Finished") : nil, b.isPodcast ? String(localized: "Podcast") : String(localized: "Audiobook"), b.creator.isEmpty ? nil : b.creator].compactMap { $0 }.joined(separator: " • ")
        }
    }

    /// Whether an album, playlist or the favorites are on the phone – from what was downloaded, not the server's list.
    private func download(_ item: Item) -> DownloadState {
        let store = app.downloads
        switch item {
        case .album(let a): return store.index.albums[a.id].map { store.state($0.song ?? []) } ?? .none
        case .playlist(let p): return store.index.playlists[p.id].map { store.state($0.entry ?? []) } ?? .none
        case .favorites: return store.state(starred?.song ?? [])
        case .book(let b, _): return app.books.downloads.mark(b)
        default: return .none
        }
    }

    private func title(_ item: Item) -> String {
        switch item {
        case .dj: "DJ"
        case .favorites: String(localized: "Favorite songs")
        case .downloads: String(localized: "Downloads")
        default: item.name
        }
    }

    @ViewBuilder private func art(_ item: Item, size: Int) -> some View {
        switch item {
        case .dj: DJArt()
        case .favorites: FavoritesArt()
        case .downloads: DownloadsArt()
        case .playlist(let p): CoverView(id: p.coverArt ?? p.id, size: size, corner: 2)
        case .album(let a): CoverView(id: a.coverArt ?? a.id, size: size, corner: 2)
        case .artist(let a): CoverView(id: a.coverArt ?? a.id, size: size, round: true)
        case .book(let b, _):
            BookCover(itemId: b.id, width: size, corner: 2)
                .overlay(alignment: .bottom) {
                    if !app.books.isFinished(b.id), let p = app.books.progress(of: b)?.progress, p > 0 { BookProgressBar(value: p) }
                }
        case .author(let a, _): AuthorImage(id: a.id, name: a.name, width: size, initial: CGFloat(size) / 8)
        }
    }

    /// Everything opens its page – only the DJ starts playing.
    @ViewBuilder private func link(_ item: Item, @ViewBuilder label: @escaping () -> some View) -> some View {
        if case .dj = item {
            DJStarter(label: label)
                .contextMenu { NavigationLink(value: Route.dj) { Label("DJ settings", systemImage: "gearshape") } }
        } else {
            NavigationLink(value: route(item), label: label)
                .buttonStyle(.plain)
                .contextMenu { pinMenu(item); bookMenu(item) }
        }
    }

    private func row(_ item: Item) -> some View {
        link(item) {
            ItemRow(title: title(item), subtitle: subtitle(item), pinned: isPinned(item), download: download(item)) { art(item, size: 160) }
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    @ViewBuilder private func bookMenu(_ item: Item) -> some View {
        if case .book(let b, _) = item {
            Button { app.books.toggleFavorite(b) } label: {
                app.books.isFavorite(b.id) ? Label("Remove from favorites", systemImage: "heart.slash") : Label("Add to favorites", systemImage: "heart")
            }
        }
        if case .author(let a, _) = item { AuthorFavoriteMenu(id: a.id, name: a.name) }
    }

    /// Pinning gives a row a new identity, so it fades instead of sliding to its new place.
    private var keyed: [(key: String, item: Item)] {
        items.map { ((pins.contains($0.id) ? "pin." : "") + $0.id, $0) }
    }

    private func tile(_ item: Item) -> some View {
        link(item) {
            VStack(alignment: .leading, spacing: 6) {
                art(item, size: 300).aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                Text(title(item)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if isPinned(item) { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.accent).rotationEffect(.degrees(45)) }
                    DownloadMark(state: download(item))
                    Text(subtitle(item)).font(.system(size: 12)).foregroundStyle(Color.subtle).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .transition(.opacity)
    }

    // MARK: Loading

    private func load() async {
        guard let client = app.client else { playlists = []; starred = nil; return }
        if playlists.isEmpty, let saved = client.cached("getPlaylists")?.playlists?.playlist { playlists = saved }
        if starred == nil, let saved = client.cached("getStarred2")?.starred2 { starred = saved }
        async let p = try? client.playlists()
        async let s = try? client.starred()
        if let p = await p { playlists = p }
        if let s = await s { starred = s }
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
            LoadState(loading: albums.isEmpty && !done && error == nil, error: error) { await reload() }
        }
        .refreshable { await pulled { await reload() } }
        .navigationTitle(genre ?? String(localized: "Albums"))
        .toolbar {
            if genre == nil {
                Menu {
                    Picker("Sort", selection: $type) { ForEach(sorts, id: \.0) { Text($0.1).tag($0.0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .task(id: type) { await reload() }
    }

    private func reload() async {
        // A page that is still on its way would add its answer to the new list: it is dropped there (see more)
        albums = []; done = false; error = nil
        await more()
    }

    private func more() async {
        guard !done, let client = app.client else { return }
        let asked = type
        do {
            let page = try await client.albumList(asked, size: 60, offset: albums.count, genre: genre)
            // The sort was switched while this was on its way: this answer belongs to the old list
            guard asked == type else { return }
            albums += page.filter { a in !albums.contains(where: { $0.id == a.id }) }
            if page.count < 60 { done = true }
        } catch {
            guard asked == type, !Task.isCancelled else { return } // a cancelled request must not end the new list
            self.error = error.userMessage; done = true
        }
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
        .overlay { LoadState(loading: artists.isEmpty && error == nil, error: error) { await load() } }
        .refreshable { await pulled { await load() } }
        .navigationTitle("Artists")
        .searchable(text: $filter)
        .task { await load() }
    }

    private func load() async {
        do { artists = try await app.client?.artists() ?? []; error = nil } catch { self.error = error.userMessage }
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
        .overlay { LoadState(loading: !loaded, error: playlists.isEmpty ? error : nil) { await load() } }
        .refreshable { await pulled { await load() } }
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
        do { playlists = try await app.client?.playlists() ?? []; error = nil } catch { if !error.isCancellation { self.error = error.userMessage } }
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
