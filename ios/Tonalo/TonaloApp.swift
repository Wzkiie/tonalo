import SwiftUI
import UIKit

/// Lets iOS hand finished background downloads back to the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { WatchBridge.shared.start() }
        // Earlier versions let iOS cache server responses on disk, login token in the addresses included – remove that
        URLCache.shared.removeAllCachedResponses()
        Task.detached(priority: .background) { ImageLoader.trimDisk() }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == BookDownloadSession.identifier {
            BookDownloadSession.shared.backgroundCompletion = completionHandler
            _ = BookDownloadSession.shared.session
            return
        }
        DownloadSession.shared.backgroundCompletion = completionHandler
        _ = DownloadSession.shared.session // reconnect to the background session
    }
}

@main
struct TonaloApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .overlay(alignment: .top) { PullSpinner().animation(.easeOut(duration: 0.2), value: PullState.shared.active) }
                .preferredColorScheme(.dark)
        }
    }
}

/// Navigation targets shared by all tabs.
enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case albums(String)
    case genre(String)
    case artists
    case playlists
    case favorites
    case downloads
    case stations
    case settings
    case devices
    case jukebox
    case dj
    case audiobook(String)
    case bookAuthor(id: String, name: String)
    case bookSeries(id: String, name: String, library: String?)
    case bookNarrator(name: String, library: String?)
    case booksAll(podcasts: Bool)
    case bookDownloads
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            Group { switch route {
            case .album(let id): AlbumView(id: id)
            case .audiobook(let id): AudiobookView(id: id)
            case .bookAuthor(let id, let name): BookAuthorView(id: id, name: name)
            case .bookSeries(let id, let name, let library): BookGroupView(title: name, group: "series", value: id, library: library, sort: "sequence")
            case .bookNarrator(let name, let library): BookGroupView(title: name, group: "narrators", value: name, library: library)
            case .booksAll(let podcasts): BooksBrowseView(podcasts: podcasts)
            case .bookDownloads: BookDownloadsView()
            case .artist(let id): ArtistView(id: id)
            case .playlist(let id): PlaylistView(id: id)
            case .albums(let type): AlbumsView(type: type)
            case .genre(let name): AlbumsView(type: "byGenre", genre: name)
            case .artists: ArtistsView()
            case .playlists: PlaylistsView()
            case .favorites: FavoritesView()
            case .downloads: DownloadsView()
            case .stations: StationsView()
            case .settings: SettingsView()
            case .devices: DevicesView()
            case .jukebox: JukeboxView()
            case .dj: DJSettingsView()
            } }
            .canvasBackground()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = min(Theme.shared.startTab, 2)
    @State private var paths = [NavigationPath(), NavigationPath(), NavigationPath()]
    @State private var showNowPlaying = false
    @State private var playerOpened = 0
    @State private var showMenu = false
    @State private var barHeight: CGFloat = 0
    @State private var keyboardUp = false
    /// Counts the taps on a tab that's already open and on its start page: its filter goes back to everything.
    @State private var reselected = [0, 0, 0]
    @State private var addBatch: SongBatch?
    @State private var whatsNew: AppRelease?
    #if DEBUG
    @State private var debugTV = false
    @State private var debugJukebox = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        Group {
            if app.accounts.isEmpty {
                NavigationStack { AccountEditorView(account: nil) }
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $app.showsAccountPicker) { AccountPickerView() }
        .environment(\.ui, UIActions(
            nowPlaying: { if !showNowPlaying { playerOpened += 1 }; withAnimation(.spring(duration: 0.4)) { showNowPlaying = true } },
            profileMenu: { withAnimation(.easeOut(duration: 0.25)) { showMenu = true } },
            open: { route in
                withAnimation(.easeOut(duration: 0.25)) { showNowPlaying = false; showMenu = false }
                paths[tab].append(route)
            },
            addToPlaylist: { songs in if !songs.isEmpty { addBatch = SongBatch(songs: songs) } }))
        .sheet(item: $addBatch) { AddToPlaylistSheet(songs: $0.songs) }
        // Someone wants to join the Jukebox this phone hosts: the code to show them
        .sheet(item: Binding(get: { app.jukeboxHost.request }, set: { if $0 == nil { app.jukeboxHost.cancelRequest() } })) { JukeboxCodeView(request: $0) }
        // After an update: what's new, once – but not on top of the account picker
        .sheet(item: $whatsNew, onDismiss: WhatsNew.markSeen) { WhatsNewSheet(release: $0) }
        .task { app.tv.start() }
        .task { try? await Task.sleep(for: .seconds(1)); checkWhatsNew() }
        .onChange(of: app.showsAccountPicker) { _, shown in if !shown { checkWhatsNew() } }
        #if DEBUG
        // Screenshot hook: -demoOpen stations opens the radio page, -demoOpen station plays a station in the player,
        // -demoOpen artist:<id> opens an artist, -demoOpen download downloads the first playlist and opens it,
        // -demoOpen tv / jukebox opens the devices / Jukebox page; -demoJukebox hosts a Jukebox right away
        .sheet(isPresented: $debugTV) { NavigationStack { DevicesView() } }
        .sheet(isPresented: $debugJukebox) { NavigationStack { JukeboxView() } }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-demoJukebox") { app.jukeboxHost.start() }
            // -demoGuests "Mia,Leon" shows made-up guests, -demoToast "<text>" a notice (screenshots)
            if let g = args.firstIndex(of: "-demoGuests"), g + 1 < args.count {
                app.jukeboxHost.demoGuests(args[g + 1].split(separator: ",").map(String.init))
            }
            if let t = args.firstIndex(of: "-demoToast"), t + 1 < args.count {
                let text = args[t + 1]
                Task { try? await Task.sleep(for: .seconds(4)); app.notify(text) }
            }
            // -demoBooks <url> connects to a test server (ios/tools/abs_mock.js)
            if let b = args.firstIndex(of: "-demoBooks"), b + 1 < args.count, app.books.stored?.url != args[b + 1] {
                try? await app.books.connect(address: args[b + 1], username: "demo", password: "demo", headers: [])
            }
            guard let i = args.firstIndex(of: "-demoOpen"), i + 1 < args.count else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if args[i + 1] == "stations" { paths[0].append(Route.stations) }
            if args[i + 1] == "tv" { debugTV = true }
            if args[i + 1].hasPrefix("book:") { paths[0].append(Route.audiobook(String(args[i + 1].dropFirst(5)))) }
            // -demoOpen bookplay:<id>[@seconds] plays it and opens the player
            if args[i + 1].hasPrefix("bookplay:") {
                let parts = args[i + 1].dropFirst(9).split(separator: "@")
                if let item = try? await app.books.item(String(parts[0])) {
                    app.bookPlayer.play(item, at: parts.count > 1 ? Double(parts[1]) : nil)
                    showNowPlaying = true
                }
            }
            if args[i + 1] == "jukebox" { debugJukebox = true }
            if args[i + 1] == "dj" { paths[0].append(Route.dj) }
            if args[i + 1] == "djsheet" { showNowPlaying = true }
            if args[i + 1] == "library" { tab = 2 }
            if args[i + 1].hasPrefix("artist:") { paths[0].append(Route.artist(String(args[i + 1].dropFirst(7)))) }
            if args[i + 1].hasPrefix("playlist:") { paths[0].append(Route.playlist(String(args[i + 1].dropFirst(9)))) }
            if args[i + 1] == "favorites" { paths[0].append(Route.favorites) }
            // -demoAct addsong:<playlist id> adds a song to that playlist, -demoAct heart gives a song a heart – both
            // fourteen seconds later, the way another page of the app would do it (to see the open page reload)
            if let k = args.firstIndex(of: "-demoAct"), k + 1 < args.count {
                try? await Task.sleep(for: .seconds(14))
                let act = args[k + 1]
                if act.hasPrefix("addsong:"), let song = try? await app.client?.randomSongs(1).first {
                    try? await app.client?.updatePlaylist(String(act.dropFirst(8)), add: [song.id])
                    app.playlistsChanged()
                }
                if act == "heart", let song = (try? await app.client?.randomSongs(60))?.first(where: { !app.isFavorite($0) }) {
                    await app.setFavorite(song, true)
                }
            }
            if args[i + 1] == "download", let first = try? await app.client?.playlists().first,
               let list = try? await app.client?.playlist(first.id) {
                app.downloads.downloadPlaylist(list)
                paths[0].append(Route.playlist(list.id))
            }
            if args[i + 1] == "station", let list = try? await app.client?.stations(), let first = list.first {
                app.player.play(first, in: list)
                showNowPlaying = true
            }
        }
        #endif
        .tint(.accent) // reads Theme, so a new accent color applies everywhere at once
        .onChange(of: app.currentId) {
            paths = [NavigationPath(), NavigationPath(), NavigationPath()]
            Task { await app.player.checkServerQueue() }
        }
        // Continue where another device left off – and leave the queue on the server when going away
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.checkRoute(); app.tv.start(); Task { await app.player.checkServerQueue(); await app.player.flushScrobbles() } }
            if phase == .background { app.player.syncBeforeLeaving(); app.tv.stop(); app.downloads.saveNow(wait: true) }
        }
    }

    private func checkWhatsNew() {
        guard whatsNew == nil, !app.showsAccountPicker, WhatsNew.shouldShow(hasAccounts: !app.accounts.isEmpty) else { return }
        whatsNew = WhatsNew.current
    }

    private var tabs: some View {
        ZStack {
            // All three stacks stay alive so each tab keeps its place, like the tab bar of a music app should
            ForEach(0..<3, id: \.self) { i in
                NavigationStack(path: $paths[i]) { root(i).canvasBackground().routes() }
                    .opacity(tab == i ? 1 : 0)
                    .allowsHitTesting(tab == i)
            }
        }
        .id(app.currentId) // fresh views when switching accounts
        // Every scrolling page (plain scroll views and system lists alike) ends above the floating bar
        .contentMargins(.bottom, barHeight, for: .scrollContent)
        .contentMargins(.bottom, barHeight, for: .scrollIndicators)
        // The keyboard covers player and tabs like in any other app, they don't ride on top of it
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            // A hardware keyboard only brings a small bar, the tabs stay usable then
            keyboardUp = ((note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0) > 120
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .overlay(alignment: .bottom) {
            bottomBar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
        .overlay(alignment: .bottom) {
            DownloadBar().padding(.bottom, barHeight + 10)
                .animation(.spring(duration: 0.35), value: app.downloads.batchProgress == nil && app.books.downloads.batchProgress == nil)
        }
        .overlay {
            if showNowPlaying {
                Group {
                    if app.bookPlayer.isActive {
                        BookPlayerView { withAnimation(.spring(duration: 0.35)) { showNowPlaying = false } }
                    } else {
                        NowPlayingView { withAnimation(.spring(duration: 0.35)) { showNowPlaying = false } }
                    }
                }
                    // A fresh one every time: opened again while the last one is still sliding away, that one
                    // would come back still pulled down below the screen
                    .id(playerOpened)
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
                    // Notes like "Only the host can do that" show over the big player too
                    .overlay(alignment: .top) { if let notice = app.notice { noticeView(notice).padding(.top, 54) } }
            }
        }
        .overlay {
            if showMenu {
                ProfileMenu { withAnimation(.easeOut(duration: 0.25)) { showMenu = false } }
                    .zIndex(3)
            }
        }
    }

    @ViewBuilder private func root(_ i: Int) -> some View {
        switch i {
        case 0: HomeView(reselected: reselected[0])
        case 1: SearchView(reselected: reselected[1])
        default: LibraryView(reselected: reselected[2])
        }
    }

    private func noticeView(_ notice: String) -> some View {
        Text(notice).font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.white, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if let notice = app.notice { noticeView(notice).padding(.bottom, 4) }
            if !keyboardUp {
                ContinueBanner().padding(.horizontal, 8)
                MiniPlayer().padding(.horizontal, 8)
                TabBar(tab: $tab) { i in
                    if paths[i].isEmpty { reselected[i] += 1 } else { paths[i] = NavigationPath() }
                }
            }
        }
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: Color.canvas.opacity(0), location: 0), .init(color: Color.canvas.opacity(0.8), location: 0.45),
                                   .init(color: Color.canvas, location: 1)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -24)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

struct TabBar: View {
    @Binding var tab: Int
    /// Tapping the open tab again goes back to its start page, and from there to all of it.
    let reselect: (Int) -> Void

    private let items: [(icon: String, selected: String, title: LocalizedStringKey)] = [
        ("house", "house.fill", "Home"), ("magnifyingglass", "magnifyingglass", "Search"),
        ("books.vertical", "books.vertical.fill", "Your Library"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = tab == i
                Button { if on { reselect(i) } else { tab = i } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: on ? items[i].selected : items[i].icon)
                            .font(.system(size: 22, weight: on ? .semibold : .regular))
                            .frame(height: 26)
                        Text(items[i].title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(on ? Color.white : Color.subtle)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}

/// Slides in from the left when the avatar is tapped: accounts, downloads, settings.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let close: () -> Void
    @State private var shown = false
    @State private var confirmLogout = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(shown ? 0.55 : 0).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 0) {
                if let acc = app.current {
                    HStack(spacing: 12) {
                        Avatar(name: acc.username, size: 52)
                        Text(acc.username).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    }
                    .padding(.bottom, 12)
                    // Both servers, each with the user it's signed in as
                    VStack(alignment: .leading, spacing: 8) {
                        if acc.hasMusic { serverLine("music.note", user: acc.username, host: acc.host) }
                        if let books = acc.audiobooks { serverLine("book.closed", user: books.username, host: books.host) }
                    }
                    .padding(.bottom, 18)
                }
                Rectangle().fill(Color.lifted(0.22)).frame(height: 1).padding(.bottom, 12)
                ForEach(app.accounts.filter { $0.id != app.currentId }) { acc in
                    row(label: Text(acc.username), sub: acc.host) { Avatar(name: acc.username, size: 28) } action: {
                        dismiss(); app.select(acc.id)
                    }
                }
                row(label: Text("Downloads")) { Image(systemName: "arrow.down.circle").font(.system(size: 22)) } action: {
                    ui.open(app.current?.hasMusic == false ? .bookDownloads : .downloads)
                }
                if app.current?.hasMusic != false {
                row(label: Text("Devices")) { Image(systemName: "tv").font(.system(size: 19)) } action: { ui.open(.devices) }
                row(label: Text("Jukebox")) { Image(systemName: "person.2.wave.2").font(.system(size: 20)) } action: { ui.open(.jukebox) }
                row(label: Text("DJ")) { DJMark().frame(width: 24, height: 24) } action: { ui.open(.dj) }
                }
                row(label: Text("Settings")) { Image(systemName: "gearshape").font(.system(size: 22)) } action: { ui.open(.settings) }
                Spacer()
                row(label: Text("Log out")) {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 20))
                } action: { confirmLogout = true }
                .foregroundStyle(Color.subtle)
                .padding(.bottom, 8)
                .logoutDialog(isPresented: $confirmLogout, done: dismiss)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .frame(width: 310)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.lifted(0.1).ignoresSafeArea())
            .offset(x: shown ? 0 : -330)
            .gesture(DragGesture().onEnded { if $0.translation.width < -60 { dismiss() } })
        }
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { shown = true } }
    }

    private func serverLine(_ icon: String, user: String, host: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
            Text("\(user) · \(host)").font(.system(size: 13)).lineLimit(1)
        }
        .foregroundStyle(Color.subtle)
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: close)
    }

    private func row<Icon: View>(label: Text, sub: String? = nil, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                icon().frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    label.font(.system(size: 17))
                    if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(Color.subtle) }
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
