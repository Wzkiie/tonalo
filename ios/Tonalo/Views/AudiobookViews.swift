import SwiftUI

// Audiobooks and podcasts: shelves, library, detail page, player. Same look as the music pages.

private func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// "5 h 12 min" for lengths and what's left.
private func length(_ seconds: Double) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    f.unitsStyle = .abbreviated
    return f.string(from: max(60, seconds)) ?? ""
}

struct BookCover: View {
    @Environment(AppModel.self) private var app
    let itemId: String
    var width = 300
    var corner: CGFloat = 4
    /// Finished books look washed out and carry a check mark, wherever they show up.
    var marksFinished = true
    /// Already there, so nothing has to appear while the page is moving.
    var preloaded: UIImage?
    @State private var image: UIImage?

    var body: some View {
        let finished = marksFinished && app.books.isFinished(itemId)
        Color.elevated
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = preloaded ?? image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .saturation(finished ? 0.15 : 1).opacity(finished ? 0.5 : 1)
                } else { Image(systemName: "book.closed").font(.system(size: 26)).foregroundStyle(Color.subtle) }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner * Theme.shared.cardShape.scale))
            .overlay {
                if finished {
                    GeometryReader { g in
                        let size = min(44, max(20, g.size.width * 0.22))
                        Image(systemName: "checkmark").font(.system(size: size * 0.52, weight: .heavy)).foregroundStyle(.black)
                            .frame(width: size, height: size)
                            .background(Color.accent, in: Circle())
                            .padding(size * 0.22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    .accessibilityLabel("Finished")
                }
            }
            .task(id: itemId) {
                if preloaded == nil { image = await app.books.coverImage(itemId, width: width) }
            }
    }
}

/// How far along: a thin bar under a cover or a row.
struct BookProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.white.opacity(0.25))
                .overlay(alignment: .leading) { Capsule().fill(Color.accent).frame(width: g.size.width * min(1, max(0, value))) }
        }
        .frame(height: 3)
    }
}

struct BookCard: View {
    @Environment(AppModel.self) private var app
    let item: ABSItem
    /// Without a width it fills its place in a grid.
    var width: CGFloat? = 140

    var body: some View {
        NavigationLink(value: Route.audiobook(item.id)) {
            VStack(alignment: .leading, spacing: 6) {
                BookCover(itemId: item.id)
                let finished = app.books.isFinished(item.id)
                if !finished, let p = app.books.progress(of: item)?.progress, p > 0 { BookProgressBar(value: p) }
                Text(item.recentEpisode?.title ?? item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(finished ? Color.subtle : Color.white)
                if finished {
                    Text("Finished").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accent).lineLimit(1)
                } else {
                    Text(item.recentEpisode != nil ? item.title : item.creator).font(.system(size: 12)).foregroundStyle(Color.subtle).lineLimit(1)
                }
            }
            .frame(width: width.map { $0 * Theme.shared.coverSize.scale }, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct BookShelf: View {
    let title: String
    let items: [ABSItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold)).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items, id: \.shelfKey) { BookCard(item: $0) }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

extension ABSItem {
    var shelfKey: String { id + (recentEpisode?.id ?? "") }
}

/// The audiobook part of the home page.
struct BooksHomeContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let books = app.books
        LoadState(loading: books.loading && books.shelves.isEmpty, error: books.error) { await books.load(force: true) }
        ForEach(books.shelves) { BookShelf(title: $0.title, items: $0.items) }
        if !books.loading && books.error == nil && books.shelves.isEmpty {
            Text("Nothing here yet. Add books to your Audiobookshelf server.")
                .foregroundStyle(Color.subtle).padding(.horizontal, 16)
        }
    }
}

// MARK: - Detail page

/// Round picture of an author; the initial where the server has none, and always for narrators.
struct AuthorImage: View {
    @Environment(AppModel.self) private var app
    let id: String?
    let name: String
    var width = 200
    var initial: CGFloat = 20
    @State private var image: UIImage?

    var body: some View {
        Color.elevated
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Text(String(name.prefix(1)).uppercased()).font(.system(size: initial, weight: .bold)).foregroundStyle(Color.subtle) }
            }
            .clipShape(Circle())
            .task(id: id) {
                guard let id, let url = app.books.authorImageURL(id, width: width), let headers = app.books.server?.authorized else { return }
                image = await ImageLoader.shared.image(url, headers: headers)
            }
    }
}

/// Long press on an author, wherever they're listed.
struct AuthorFavoriteMenu: View {
    @Environment(AppModel.self) private var app
    let id: String
    let name: String

    var body: some View {
        Button { app.books.toggleFavoriteAuthor(id: id, name: name) } label: {
            app.books.isFavoriteAuthor(id) ? Label("Remove from favorites", systemImage: "heart.slash") : Label("Add to favorites", systemImage: "heart")
        }
    }
}

/// Arrow, progress ring or checkmark. Tapping a finished one offers removal.
struct BookDownloadButton: View {
    @Environment(AppModel.self) private var app
    let item: ABSItem
    var episode: ABSEpisode?
    var size: CGFloat = 22
    @State private var confirmRemove = false
    @State private var confirmCancel = false

    var body: some View {
        let store = app.books.downloads
        let state = store.state(item, episode: episode)
        let key = BookDownloads.key(item.id, episode?.id)
        Button {
            switch state {
            case .none: store.download(item, episode: episode)
            case .failed: store.retry(key)
            case .loading: confirmCancel = true
            case .complete: confirmRemove = true
            }
        } label: {
            switch state {
            case .none: Image(systemName: "arrow.down.circle").font(.system(size: size)).foregroundStyle(Color.subtle)
            case .failed: Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: size)).foregroundStyle(.orange)
            case .complete: Image(systemName: "arrow.down.circle.fill").font(.system(size: size)).foregroundStyle(Color.accent)
            case .loading(let value):
                if store.waitingForWiFi { Image(systemName: "wifi.exclamationmark").font(.system(size: size)).foregroundStyle(.orange) }
                else { ProgressRing(value: value, lineWidth: 3).frame(width: size + 4, height: size + 4) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .complete ? Text("Remove download") : state == .none ? Text("Download") : Text("Cancel download"))
        .confirmationDialog("Remove download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { store.remove(key) }
        }
        .confirmationDialog("Cancel download?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel download", role: .destructive) { store.remove(key) }
            Button("Keep downloading", role: .cancel) {}
            if store.waitingForWiFi {
                Button("Download over cellular") { store.allowCellular = true }
            }
        }
    }
}

struct AudiobookView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var item: ABSItem?
    @State private var error: String?
    @State private var expanded = false
    @State private var showChapters = false
    @State private var more: [ABSItem] = []

    var body: some View {
        Group {
            if let item { content(item) } else { ScrollView { LoadState(loading: error == nil, error: error) { await load() }.padding(.top, 60) } }
        }
        .task(id: id) { await load() }
        .refreshable { await pulled(ownSpinner: true) { await Task { await load() }.value } }
    }

    private func load() async {
        // What's known shows at once, and is what's left without a connection
        if item == nil { item = app.books.savedItem(id) }
        do {
            let full = try await app.books.item(id)
            item = full
            error = nil
            if let author = full.media.metadata.authors?.first, let found = try? await app.books.author(author.id) {
                more = found.items.filter { $0.id != id }
            }
        } catch {
            if item == nil { self.error = error.userMessage }
        }
    }

    private func content(_ item: ABSItem) -> some View {
        DetailPage(coverId: nil, title: item.title) {
            BookCover(itemId: item.id, width: 800, corner: 6)
        } info: {
            info(item)
        } actions: {
            actions(item)
        } content: {
            if item.isPodcast { episodes(item) } else { chapters(item) }
            if let d = item.media.metadata.description, !d.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.plain(d)).font(.system(size: 14)).foregroundStyle(Color.subtle).lineLimit(expanded ? nil : 4)
                    Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.top, 8)
            }
            if !more.isEmpty, let author = item.media.metadata.authors?.first {
                BookShelf(title: String(localized: "More by \(author.name)"), items: more).padding(.horizontal, -16).padding(.top, 16)
            }
        }
        .sheet(isPresented: $showChapters) { chapterSheet(item) }
    }

    /// Author, narrator and series each lead to their own page.
    @ViewBuilder private func info(_ item: ABSItem) -> some View {
        let m = item.media.metadata
        if app.books.isFinished(item.id) {
            Label("Finished", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accent)
        }
        if let s = m.subtitle, !s.isEmpty { Text(s).font(.system(size: 15)).foregroundStyle(Color.subtle) }
        if let authors = m.authors, !authors.isEmpty {
            ForEach(authors) { a in
                NavigationLink(value: Route.bookAuthor(id: a.id, name: a.name)) {
                    HStack(spacing: 8) {
                        AuthorImage(id: a.id, name: a.name, width: 60, initial: 12).frame(width: 24)
                        Text(a.name).font(.system(size: 13, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
            }
        } else if !item.creator.isEmpty {
            Text(item.creator).font(.system(size: 13, weight: .bold))
        }
        ForEach(m.narrators ?? [], id: \.self) { n in
            NavigationLink(value: Route.bookNarrator(name: n, library: item.libraryId)) {
                Text("Read by \(n)").font(.system(size: 13)).foregroundStyle(Color.subtle)
            }
            .buttonStyle(.plain)
        }
        ForEach(m.series?.all ?? []) { s in
            NavigationLink(value: Route.bookSeries(id: s.id, name: s.name, library: item.libraryId)) {
                HStack(spacing: 4) {
                    Image(systemName: "books.vertical").font(.system(size: 11))
                    Text(s.sequence.map { "\(s.name) #\($0)" } ?? s.name).font(.system(size: 13))
                }
                .foregroundStyle(Color.subtle)
            }
            .buttonStyle(.plain)
        }
        Text([item.isPodcast ? String(localized: "Podcast") : String(localized: "Audiobook"), m.publishedYear,
              item.media.duration.map(length)].compactMap { $0 }.joined(separator: " • "))
            .font(.system(size: 13)).foregroundStyle(Color.subtle)
    }

    @ViewBuilder private func actions(_ item: ABSItem) -> some View {
        let p = app.books.progress(of: item)
        let started = !item.isPodcast && (p?.currentTime ?? 0) > 0 && p?.isFinished != true
        let favorite = app.books.isFavorite(item.id)
        VStack(alignment: .leading, spacing: 10) {
            if started, let value = p?.progress {
                BookProgressBar(value: value)
                Text("\(length((item.media.duration ?? 0) - (p?.currentTime ?? 0))) left").font(.system(size: 13)).foregroundStyle(Color.subtle)
            }
            HStack(spacing: 24) {
                ActionIcon(icon: favorite ? "heart.fill" : "heart", active: favorite,
                           label: favorite ? "Remove from favorites" : "Add to favorites") { app.books.toggleFavorite(item) }
                if !item.isPodcast { BookDownloadButton(item: item) }
                if !item.isPodcast {
                    Menu {
                        Button(p?.isFinished == true ? "Mark as not finished" : "Mark as finished") {
                            Task { try? await app.books.setFinished(item, episode: nil, finished: p?.isFinished != true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 22)).foregroundStyle(Color.subtle).frame(height: 32)
                    }
                    .accessibilityLabel("More")
                }
                Spacer()
                if !item.isPodcast {
                    PlayCircle(playing: app.bookPlayer.item?.id == item.id && app.bookPlayer.isPlaying) {
                        if app.bookPlayer.item?.id == item.id { app.bookPlayer.toggle() } else { app.bookPlayer.play(item) }
                    }
                }
            }
        }
    }

    /// Descriptions often come with HTML tags.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One row; the list itself only opens when asked for.
    @ViewBuilder private func chapters(_ item: ABSItem) -> some View {
        if let list = item.media.chapters, !list.isEmpty {
            Button { showChapters = true } label: {
                HStack {
                    Image(systemName: "list.bullet").foregroundStyle(Color.subtle).frame(width: 24)
                    Text("Chapters").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(list.count)").font(.system(size: 14)).foregroundStyle(Color.subtle)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.subtle)
                }
                .padding(.horizontal, 14).frame(height: 48)
                .background(Color.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func chapterSheet(_ item: ABSItem) -> some View {
        NavigationStack {
            List(item.media.chapters ?? []) { c in
                Button { app.bookPlayer.play(item, at: c.start); showChapters = false } label: { ChapterRow(chapter: c, current: isCurrent(item, c)) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showChapters = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func isCurrent(_ item: ABSItem, _ c: ABSChapter) -> Bool {
        app.bookPlayer.item?.id == item.id && app.bookPlayer.chapter?.start == c.start
    }

    @ViewBuilder private func episodes(_ item: ABSItem) -> some View {
        Text("Episodes").font(.system(size: 18, weight: .bold)).padding(.top, 4)
        LazyVStack(spacing: 14) {
            ForEach((item.media.episodes ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }) { e in
                let p = app.books.progress(of: item, episode: e)
                HStack(spacing: 12) {
                    Button { app.bookPlayer.play(item, episode: e) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.title ?? "").font(.system(size: 15, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    .foregroundStyle(app.bookPlayer.episode?.id == e.id ? Color.accent : .white)
                                Text(p?.isFinished == true ? String(localized: "Finished") : length(e.length))
                                    .font(.system(size: 12)).foregroundStyle(Color.subtle)
                                if let value = p?.progress, value > 0, p?.isFinished != true { BookProgressBar(value: value) }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "play.circle").font(.system(size: 28))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    BookDownloadButton(item: item, episode: e, size: 24)
                }
            }
        }
    }
}

// MARK: - Whole server

private func bookCount(_ n: Int) -> String { n == 1 ? String(localized: "1 book") : String(localized: "\(n) books") }

// From the top: a progress bar or a longer title under one cover mustn't move its neighbor
private let bookGrid = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]

/// All books or podcasts of the server: titles page by page, and for books also by author and series.
struct BooksBrowseView: View {
    @Environment(AppModel.self) private var app
    let podcasts: Bool
    @State private var section = Section.titles
    @AppStorage("books.sort") private var sort = Sort.title
    @State private var items: [ABSItem] = []
    @State private var authors: [ABSAuthor] = []
    @State private var series: [ABSSeriesEntry] = []
    @State private var libraries: [ABSLibrary] = []
    @State private var library = 0
    @State private var page = 0
    @State private var finished = false
    @State private var loading = false
    @State private var error: String?

    enum Section { case titles, authors, series }
    enum Sort: String, CaseIterable {
        case title, added, creator
        var label: LocalizedStringKey {
            switch self {
            case .title: "Alphabetical"
            case .added: "Recently added"
            case .creator: "Author"
            }
        }
        var key: String {
            switch self {
            case .title: "media.metadata.title"
            case .added: "addedAt"
            case .creator: "media.metadata.authorName"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !podcasts {
                    HStack(spacing: 8) {
                        Chip(title: "Titles", selected: section == .titles) { section = .titles }
                        Chip(title: "Authors", selected: section == .authors) { section = .authors }
                        Chip(title: "Series", selected: section == .series) { section = .series }
                    }
                }
                switch section {
                case .titles: titles
                case .authors: authorList
                case .series: seriesList
                }
                LoadState(loading: loading && items.isEmpty && authors.isEmpty && series.isEmpty, error: error)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.canvas)
        .navigationTitle(podcasts ? "Podcasts" : "Audiobooks")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(section)\(sort)") { await show() }
        .refreshable {
            await pulled {
                await Task {
                    if section != .titles { authors = []; series = [] }
                    await app.books.load(force: true)
                    await show()
                }.value
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                Label { Text(sort.label) } icon: { Image(systemName: "arrow.up.arrow.down") }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            LazyVGrid(columns: bookGrid, alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    BookCard(item: item, width: nil).onAppear { if item.id == items.last?.id { Task { await nextPage() } } }
                }
            }
            if loading && !items.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(20) }
        }
    }

    private var authorList: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(authors) { a in
                NavigationLink(value: Route.bookAuthor(id: a.id, name: a.name)) {
                    ItemRow(title: a.name, subtitle: a.numBooks.map(bookCount) ?? String(localized: "Author")) {
                        AuthorImage(id: a.id, name: a.name).frame(width: 52)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { AuthorFavoriteMenu(id: a.id, name: a.name) }
            }
        }
    }

    private var seriesList: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(series) { s in
                NavigationLink(value: Route.bookSeries(id: s.id, name: s.name, library: s.library)) {
                    ItemRow(title: s.name, subtitle: bookCount(s.count)) {
                        if let cover = s.cover { BookCover(itemId: cover, width: 200, corner: 2) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func show() async {
        error = nil
        do {
            switch section {
            case .titles:
                items = []; library = 0; page = 0; finished = false
                libraries = await app.books.libraries(podcasts: podcasts)
                await nextPage()
            case .authors:
                if authors.isEmpty { loading = true; defer { loading = false }; authors = try await app.books.allAuthors() }
            case .series:
                if series.isEmpty { loading = true; defer { loading = false }; series = try await app.books.allSeries() }
            }
        } catch {
            if !Task.isCancelled { self.error = error.userMessage }
        }
    }

    private func nextPage() async {
        guard !loading, !finished, library < libraries.count else { return }
        loading = true
        defer { loading = false }
        do {
            let answer = try await app.books.items(in: libraries[library].id, page: page, sort: sort.key, descending: sort == .added)
            items += answer.items
            page += 1
            let shownOfThis = page * 60
            if answer.items.isEmpty || shownOfThis >= answer.total {
                library += 1
                page = 0
                finished = library >= libraries.count
            }
        } catch {
            if !Task.isCancelled { self.error = error.userMessage }
        }
    }
}

/// A grid of books under a title: what a narrator read, the books of a series.
/// Books of an author or series as tiles or, more compact for many of them, as a list. Remembered for both.
private struct BookItems: View {
    @Environment(AppModel.self) private var app
    let items: [ABSItem]
    @AppStorage("books.list") private var list = false

    var body: some View {
        if list {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink(value: Route.audiobook(item.id)) {
                        ItemRow(title: item.title, subtitle: subtitle(item), download: app.books.downloads.mark(item)) {
                            BookCover(itemId: item.id, width: 160, corner: 2)
                                .overlay(alignment: .bottom) {
                                    if !app.books.isFinished(item.id), let p = app.books.progress(of: item)?.progress, p > 0 { BookProgressBar(value: p) }
                                }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            LazyVGrid(columns: bookGrid, alignment: .leading, spacing: 18) {
                ForEach(items) { BookCard(item: $0, width: nil) }
            }
        }
    }

    private func subtitle(_ item: ABSItem) -> String {
        [app.books.isFinished(item.id) ? String(localized: "Finished") : nil, item.media.metadata.publishedYear.map { String($0.prefix(4)) },
         item.media.duration.map(length)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

/// Switches `BookItems` between tiles and list.
private struct BookLayoutButton: View {
    @AppStorage("books.list") private var list = false

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { list.toggle() } } label: {
            Image(systemName: list ? "square.grid.2x2" : "list.bullet").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(list ? "Show as grid" : "Show as list")
    }
}

struct BookGroupView: View {
    @Environment(AppModel.self) private var app
    let title: String
    let group: String
    let value: String
    let library: String?
    var sort = "media.metadata.title"
    @State private var items: [ABSItem]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let items {
                VStack(alignment: .trailing, spacing: 12) {
                    if items.count > 1 { BookLayoutButton() }
                    BookItems(items: items)
                }
                .padding(16)
            } else {
                LoadState(loading: error == nil, error: error).padding(.top, 60)
            }
        }
        .background(Color.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await pulled { await Task { await load() }.value } }
    }

    private func load() async {
        do { items = try await app.books.filtered(group: group, value: value, library: library, sort: sort); error = nil }
        catch { if items == nil { self.error = error.userMessage } }
    }
}

struct BookAuthorView: View {
    @Environment(AppModel.self) private var app
    let id: String
    let name: String
    @State private var bio: String?
    @State private var items: [ABSItem] = []
    @State private var series: [ABSSeriesEntry] = []
    @State private var showsSeries = false
    @AppStorage("bookAuthor.sort") private var sort = Sort.title
    @State private var loading = true
    @State private var error: String?
    @State private var expanded = false

    enum Sort: String, CaseIterable {
        case title, newest, oldest, added
        var label: LocalizedStringKey {
            switch self {
            case .title: "Alphabetical"
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .added: "Recently added"
            }
        }
    }

    /// All of an author's books are here already, so sorting doesn't have to ask the server. Without a date they go last.
    private var sorted: [ABSItem] {
        func title(_ a: ABSItem, _ b: ABSItem) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }
        func year(_ item: ABSItem) -> String? { item.media.metadata.publishedYear.flatMap { $0.isEmpty ? nil : $0 } }
        switch sort {
        case .title: return items.sorted(by: title)
        case .added: return items.sorted { ($0.addedAt ?? 0) != ($1.addedAt ?? 0) ? ($0.addedAt ?? 0) > ($1.addedAt ?? 0) : title($0, $1) }
        case .newest, .oldest:
            return items.sorted {
                guard let a = year($0) else { return year($1) == nil && title($0, $1) }
                guard let b = year($1) else { return true }
                return a == b ? title($0, $1) : (sort == .newest ? a > b : a < b)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 12) {
                    AuthorImage(id: id, name: name, width: 400, initial: 54).frame(width: 140)
                    Text(name).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                    if !items.isEmpty { Text(bookCount(items.count)).font(.system(size: 13)).foregroundStyle(Color.subtle) }
                    let favorite = app.books.isFavoriteAuthor(id)
                    ActionIcon(icon: favorite ? "heart.fill" : "heart", active: favorite,
                               label: favorite ? "Remove from favorites" : "Add to favorites") { app.books.toggleFavoriteAuthor(id: id, name: name) }
                }
                .frame(maxWidth: .infinity)
                if let bio, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bio).font(.system(size: 14)).foregroundStyle(Color.subtle).lineLimit(expanded ? nil : 4)
                        Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                LoadState(loading: loading, error: error)
                if !series.isEmpty {
                    HStack(spacing: 8) {
                        Chip(title: "Titles", selected: !showsSeries) { showsSeries = false }
                        Chip(title: "Series", selected: showsSeries) { showsSeries = true }
                    }
                }
                if showsSeries {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(series) { s in
                            NavigationLink(value: Route.bookSeries(id: s.id, name: s.name, library: s.library.isEmpty ? nil : s.library)) {
                                ItemRow(title: s.name, subtitle: bookCount(s.count)) {
                                    if let cover = s.cover { BookCover(itemId: cover, width: 200, corner: 2, marksFinished: false) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    if items.count > 1 {
                        HStack {
                            Menu {
                                Picker("Sort by", selection: $sort) {
                                    ForEach(Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                            } label: {
                                Label { Text(sort.label) } icon: { Image(systemName: "arrow.up.arrow.down") }
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            }
                            Spacer()
                            BookLayoutButton()
                        }
                    }
                    BookItems(items: sorted)
                }
            }
            .padding(16)
        }
        .background(Color.canvas)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await pulled { await Task { await load() }.value } }
    }

    private func load() async {
        defer { loading = false }
        do {
            let found = try await app.books.author(id)
            bio = found.author.description
            items = found.items
            series = found.series
            error = nil
        } catch {
            if items.isEmpty { self.error = error.userMessage }
        }
    }
}

// MARK: - Settings

struct BookPlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var player = app.bookPlayer
        Form {
            Section {
                Picker("Playback speed", selection: $player.rate) {
                    ForEach(BookPlayer.rates, id: \.self) { Text(($0 == 1 ? "1" : $0.formatted(.number.precision(.fractionLength(0...2)))) + "×").tag($0) }
                }
            } footer: {
                Text("Stays the same for all audiobooks and podcasts.")
            }
            Section("Skip buttons") {
                Picker("Back", selection: $player.skipBack) {
                    ForEach(BookPlayer.skipChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Forward", selection: $player.skipForward) {
                    ForEach(BookPlayer.skipChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Everything of Audiobookshelf saved on this iPhone.
struct BookDownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var store = app.books.downloads
        List {
            Section {
                LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
                Toggle("Download over cellular", isOn: $store.allowCellular)
            } footer: {
                if store.waitingForWiFi {
                    Text("You’re on mobile data. Downloads start as soon as you’re on Wi-Fi, or right away if you allow cellular.")
                } else {
                    Text("Audiobooks are big, so without cellular they wait for Wi-Fi. Your position is sent to the server as soon as there's a connection again.")
                }
            }
            if !store.active.isEmpty {
                Section {
                    ForEach(store.active) { book in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title).lineLimit(1)
                                Text(store.bytesLoaded(book) > 0
                                     ? ByteCountFormatter.string(fromByteCount: store.bytesLoaded(book), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: book.bytes, countStyle: .file)
                                     : String(localized: "Waiting…"))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            ProgressRing(value: Double(store.bytesLoaded(book)) / Double(max(1, book.bytes))).frame(width: 22, height: 22)
                        }
                        .swipeActions { Button("Cancel", role: .destructive) { store.remove(book.key) } }
                    }
                } header: {
                    HStack {
                        Text("Downloading (\(store.active.count))")
                        Spacer()
                        Button("Cancel all", role: .destructive) { store.cancelAll() }
                            .font(.footnote.weight(.semibold)).textCase(nil)
                    }
                }
            }
            if !store.failedBooks.isEmpty {
                Section {
                    Button { store.retryFailed() } label: {
                        Label("Retry \(store.failedBooks.count) failed downloads", systemImage: "arrow.clockwise")
                    }
                }
            }
            if store.books.isEmpty {
                Section {
                    Text("Nothing downloaded yet. Tap the arrow on an audiobook or episode to listen offline.").foregroundStyle(Color.subtle)
                }
            }
            if !store.finished.isEmpty {
                Section {
                    ForEach(store.finished) { book in
                        NavigationLink(value: Route.audiobook(book.item.id)) {
                            HStack(spacing: 12) {
                                BookCover(itemId: book.item.id, width: 160, corner: 3).frame(width: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: book.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions { Button("Remove", role: .destructive) { store.remove(book.key) } }
                    }
                }
                Section {
                    Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
                        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                            Button("Delete all downloads", role: .destructive) { store.removeAll() }
                        }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .task { app.books.restore() }
    }
}


private struct ChapterRow: View {
    let chapter: ABSChapter
    let current: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(chapter.title ?? "").font(.system(size: 15, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? Color.accent : .white).lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Text(clock(chapter.end - chapter.start)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Color.subtle)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Mini player

struct BookMiniBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui

    var body: some View {
        let b = app.bookPlayer
        HStack(spacing: 10) {
            if let id = b.item?.id { BookCover(itemId: id, width: 120, corner: 4).frame(width: 40) }
            VStack(alignment: .leading, spacing: 1) {
                Text(b.chapter?.title ?? b.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(b.chapter != nil ? b.title : b.creator).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if b.tvName != nil { Image(systemName: app.tv.ownIsPC ? "desktopcomputer" : "tv.fill").font(.system(size: 14)).foregroundStyle(Color.accent) }
            Button { b.skip(-Double(b.skipBack)) } label: { Image(systemName: "gobackward.\(b.skipBack)").font(.system(size: 20)).frame(width: 36, height: 36) }
                .accessibilityLabel("Back \(b.skipBack) seconds")
            if b.isLoading {
                ProgressView().frame(width: 36, height: 36)
            } else {
                Button { b.toggle() } label: {
                    Image(systemName: b.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 36, height: 36)
                }
                .accessibilityLabel(b.isPlaying ? Text("Pause") : Text("Play"))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            BookProgressBar(value: b.duration > 0 ? b.position / b.duration : 0).frame(height: 2).padding(.horizontal, 8)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
        .contentShape(Rectangle())
        .onTapGesture { ui.nowPlaying() }
        .task(id: b.item?.id) { await b.prepareCover() }
    }
}

// MARK: - Full player

/// Where the book plays: this iPhone or the own TV, while it's connected and signed in to the same Audiobookshelf.
/// Switching takes the book along, from the same spot.
struct BookDeviceButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let b = app.bookPlayer
        let onTV = b.tvName != nil
        Menu {
            Button { if onTV { b.continueHere() } } label: {
                Label("This iPhone", systemImage: onTV ? "iphone" : "checkmark")
            }
            Button { if !onTV { b.playOnTV() } } label: {
                Label(b.tvName ?? app.tv.ownBooks ?? "TV", systemImage: onTV ? "checkmark" : app.tv.ownIsPC ? "desktopcomputer" : "tv")
            }
        } label: {
            Image(systemName: app.tv.ownIsPC ? "desktopcomputer" : onTV ? "tv.fill" : "tv").font(.system(size: 20)).frame(minWidth: 52, minHeight: 40)
                .foregroundStyle(onTV ? Color.accent : .white)
        }
        .accessibilityLabel("Play on")
    }
}

struct BookPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let close: () -> Void
    @State private var drag: CGFloat = 0
    @State private var closing = false
    @State private var height: CGFloat = 900
    @State private var scrub: Double?
    @State private var showChapters = false

    var body: some View {
        let b = app.bookPlayer
        // Within the chapter when there are chapters: a bar over 20 hours can't be moved with a finger
        let start = b.chapter?.start ?? 0
        let end = b.chapter?.end ?? b.duration
        let span = max(1, end - start)
        let shown = scrub ?? b.position

        VStack(spacing: 18) {
            HStack {
                Button(action: close) { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close")
                Spacer()
                Text(b.item?.title ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { b.stop(); close() } label: { Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Stop")
            }
            Spacer(minLength: 0)
            if let id = b.item?.id {
                BookCover(itemId: id, width: 900, corner: 8, marksFinished: false, preloaded: b.cover).frame(maxWidth: 330).shadow(radius: 24, y: 10)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(b.chapter?.title ?? b.title).font(.system(size: 21, weight: .bold)).lineLimit(2)
                Text(b.chapter != nil ? b.title : b.creator).font(.system(size: 15)).foregroundStyle(Color.subtle).lineLimit(1)
                if let name = b.tvName {
                    Label("Playing on \(name)", systemImage: app.tv.ownIsPC ? "desktopcomputer" : "tv")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accent).lineLimit(1).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // To the book's page, with its author and everything else
            .onTapGesture { if let id = b.item?.id { close(); ui.open(.audiobook(id)) } }

            VStack(spacing: 6) {
                GeometryReader { g in
                    let fraction = min(1, max(0, (shown - start) / span))
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * fraction, height: 4) }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { scrub = start + span * min(1, max(0, $0.location.x / g.size.width)) }
                            .onEnded { _ in if let scrub { b.seek(to: scrub) }; scrub = nil })
                }
                .frame(height: 24)
                HStack {
                    Text(clock(shown - start))
                    Spacer()
                    if b.duration > 0 { Text("\(length(b.duration - shown)) left") }
                    Spacer()
                    Text("-" + clock(end - shown))
                }
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.subtle)
            }

            HStack {
                Button { b.previousChapter() } label: { Image(systemName: "backward.end.fill").font(.system(size: 22)) }
                    .accessibilityLabel("Previous chapter").disabled(b.chapters.isEmpty)
                Spacer()
                Button { b.skip(-Double(b.skipBack)) } label: { Image(systemName: "gobackward.\(b.skipBack)").font(.system(size: 32)) }
                    .accessibilityLabel("Back \(b.skipBack) seconds")
                Spacer()
                Button { b.toggle() } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 68, height: 68)
                        if b.isLoading { ProgressView().tint(.black) }
                        else { Image(systemName: b.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28)).foregroundStyle(.black) }
                    }
                }
                .accessibilityLabel(b.isPlaying ? Text("Pause") : Text("Play"))
                Spacer()
                Button { b.skip(Double(b.skipForward)) } label: { Image(systemName: "goforward.\(b.skipForward)").font(.system(size: 32)) }
                    .accessibilityLabel("Forward \(b.skipForward) seconds")
                Spacer()
                Button { b.nextChapter() } label: { Image(systemName: "forward.end.fill").font(.system(size: 22)) }
                    .accessibilityLabel("Next chapter").disabled(b.chapters.isEmpty)
            }
            .buttonStyle(.plain)

            HStack {
                Menu {
                    ForEach(BookPlayer.rates, id: \.self) { r in
                        Button { b.rate = r } label: {
                            if r == b.rate { Label(Self.rateText(r), systemImage: "checkmark") } else { Text(Self.rateText(r)) }
                        }
                    }
                } label: {
                    Text(Self.rateText(b.rate)).font(.system(size: 15, weight: .semibold)).frame(minWidth: 52, minHeight: 40)
                }
                .accessibilityLabel("Playback speed")
                Spacer()
                sleepMenu
                Spacer()
                if b.tvName != nil || app.tv.ownBooks != nil { BookDeviceButton(); Spacer() }
                Button { showChapters = true } label: { Image(systemName: "list.bullet").font(.system(size: 20)).frame(minWidth: 52, minHeight: 40) }
                    .accessibilityLabel("Chapters").disabled(b.chapters.isEmpty)
            }
            .foregroundStyle(.white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { background }
        .offset(y: drag)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .gesture(dismissDrag)
        .sheet(isPresented: $showChapters) { chaptersSheet }
        // Finished or stopped: nothing left to show
        .onChange(of: b.isActive) { _, active in if !active { close() } }
    }

    /// Measured on screen, like in the music player: the page moves with the finger, its own coordinates would make it stutter.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { if !closing { drag = max(0, $0.translation.height) } }
            .onEnded { v in
                guard !closing else { return }
                let speed = v.velocity.height
                if drag > 0, v.translation.height > height * 0.25 || speed > 700 {
                    closing = true
                    let duration = min(0.35, max(0.15, (height - drag) / max(speed, 1800)))
                    withAnimation(.easeOut(duration: duration)) { drag = height }
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { close() }
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) { drag = 0 }
                }
            }
    }

    /// One color from the cover, like the music player. A blurred cover would have to be redrawn all the way up.
    private var background: some View {
        ZStack {
            Color.black
            (Theme.shared.coverTint ? app.bookPlayer.coverTint ?? Color(white: 0.22) : Color(white: 0.22))
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeOut(duration: 0.5), value: app.bookPlayer.coverTint)
        .ignoresSafeArea()
    }

    private static func rateText(_ rate: Float) -> String { (rate == 1 ? "1" : rate.formatted(.number.precision(.fractionLength(0...2)))) + "×" }

    private var sleepMenu: some View {
        let b = app.bookPlayer
        let on = b.sleepAt != nil || b.sleepAtChapterEnd
        return Menu {
            if on { Button("Turn off sleep timer", role: .destructive) { b.cancelSleep() } }
            if !b.chapters.isEmpty { Button("At the end of the chapter") { b.setSleepAtChapterEnd() } }
            ForEach([15, 30, 45, 60], id: \.self) { m in
                Button("\(m) minutes") { b.setSleep(minutes: m) }
            }
        } label: {
            Image(systemName: on ? "moon.fill" : "moon").font(.system(size: 20)).frame(minWidth: 52, minHeight: 40)
                .foregroundStyle(on ? Color.accent : .white)
        }
        .accessibilityLabel("Sleep timer")
    }

    private var chaptersSheet: some View {
        let b = app.bookPlayer
        return NavigationStack {
            ScrollViewReader { scroller in
                List(b.chapters) { c in
                    Button { b.seek(to: c.start); showChapters = false } label: { ChapterRow(chapter: c, current: b.chapter?.start == c.start) }
                        .buttonStyle(.plain)
                        .id(c.start)
                }
                .listStyle(.plain)
                .onAppear { if let at = b.chapter?.start { scroller.scrollTo(at, anchor: .center) } }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showChapters = false } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Connect

/// In the settings: connect this Tonalo account to an Audiobookshelf server.
struct AudiobookshelfSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var home = ""
    @State private var headers: [HeaderField] = []
    @State private var busy = false
    @State private var error: String?
    @State private var filled = false

    private var named: [HeaderField] { headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var homeIsValid: Bool { home.trimmingCharacters(in: .whitespaces).isEmpty || SubsonicClient.isLocal(home) }

    private func changed(from s: AudiobookServer) -> Bool {
        SubsonicClient.normalize(address) != s.url || SubsonicClient.normalizeLocal(home) != s.localURL
            || named.map { [$0.name, $0.value] } != s.headers.map { [$0.name, $0.value] }
    }

    /// Home address, headers and whatever they can come from: the same whether signing in or changing them later.
    @ViewBuilder private var routeRows: some View {
        NavigationLink { HomeAddressView(address: $home, placeholder: "192.168.1.10:13378").canvasBackground() } label: {
            LabeledContent("Address at home", value: home.isEmpty ? String(localized: "Off") : home)
        }
        NavigationLink { HeadersView(headers: $headers, server: address).canvasBackground() } label: {
            LabeledContent("Custom headers", value: named.isEmpty ? String(localized: "None") : "\(named.count)")
        }
        if named.isEmpty, let music = app.current?.headers, !music.isEmpty {
            Button("Use the headers of the music server") { headers = music.map { HeaderField(name: $0.name, value: $0.value) } }
        }
    }

    var body: some View {
        Form {
            if let s = app.books.stored {
                Section {
                    TextField("audiobooks.example.com or 192.168.1.10:13378", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Server address")
                } footer: {
                    if AccountEditorView.plainOverInternet(address) {
                        Label("This address uses http, so your login and custom headers travel unencrypted. Use https.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("The address from outside, like audiobooks.example.com. If the server is only reachable at home or over a VPN, its home address goes here.")
                    }
                }
                Section {
                    routeRows
                } footer: {
                    Text("At home Tonalo uses the home address, everywhere else the server address. For Cloudflare Zero Trust, add a service token under Custom headers.")
                }
                if changed(from: s) {
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    Section {
                        Button {
                            Task { await saveConnection() }
                        } label: {
                            if busy { ProgressView() } else { Text("Save") }
                        }
                        .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty || !homeIsValid)
                    }
                }
                Section {
                    LabeledContent("User", value: s.username)
                    if s.localURL != nil {
                        LabeledContent("Connected through", value: app.books.atHome ? String(localized: "Address at home") : String(localized: "Server address"))
                    }
                    if !app.books.canDownload {
                        Label("Your Audiobookshelf user isn't allowed to download.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Audiobooks and podcasts now show up under Home and Your Library. Your progress stays in sync with the server.")
                }
                Section {
                    if app.current?.hasMusic == false, let acc = app.current {
                        // Without it this account has nothing left
                        Button("Remove account", role: .destructive) { app.remove(acc) }
                    } else {
                        Button("Disconnect", role: .destructive) { app.books.disconnect() }
                    }
                }
            } else {
                Section {
                    TextField("audiobooks.example.com or 192.168.1.10:13378", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    if AccountEditorView.plainOverInternet(address) {
                        Label("This address uses http, so your Audiobookshelf password travels unencrypted. Only use this inside a VPN.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Over a VPN or only at home? The home address is enough, like 192.168.1.10:13378.")
                    }
                }
                Section("Login") {
                    TextField("User name", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section {
                    routeRows
                } footer: {
                    Text("The password is only used to sign in and isn't stored. Tonalo keeps a login token in the Keychain, only on this iPhone.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        if busy { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(busy || address.isEmpty || username.isEmpty || password.isEmpty || !homeIsValid)
                }
            }
        }
        .navigationTitle("Audiobookshelf")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        // Test hook: -demoConnect <address> fills in the stand-in server
        .onAppear {
            if let demo = UserDefaults.standard.string(forKey: "demoConnect") { address = demo; username = "demo"; password = "demo" }
        }
        #endif
        .onAppear {
            // Coming back from the pages for home address and headers keeps what was typed
            if !filled { fill() }
            #if DEBUG
            // Test hook: -demoRoute "<server address>|<home address>|<header name>" fills these in, typing doesn't reach them here
            if let demo = UserDefaults.standard.string(forKey: "demoRoute")?.components(separatedBy: "|"), demo.count == 3, !filledDemo {
                filledDemo = true
                address = demo[0]; home = demo[1]; headers = [HeaderField(name: demo[2], value: "test")]
            }
            #endif
        }
    }

    #if DEBUG
    @State private var filledDemo = false
    #endif

    private func fill() {
        filled = true
        guard let s = app.books.stored else { return }
        address = s.url
        home = s.localURL ?? ""
        headers = s.headers
    }

    private func saveConnection() async {
        busy = true
        defer { busy = false }
        do {
            try await app.books.updateConnection(address: address, home: SubsonicClient.normalizeLocal(home), headers: named)
            error = nil
            fill()
        } catch {
            self.error = error.userMessage
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        do {
            try await app.books.connect(address: address, username: username, password: password, headers: named, home: SubsonicClient.normalizeLocal(home))
            password = ""
            error = nil
            fill()
        } catch {
            self.error = error.userMessage
        }
    }
}
