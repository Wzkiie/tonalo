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
    case settings
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): AlbumView(id: id)
            case .artist(let id): ArtistView(id: id)
            case .playlist(let id): PlaylistView(id: id)
            case .albums(let type): AlbumsView(type: type)
            case .genre(let name): AlbumsView(type: "byGenre", genre: name)
            case .artists: ArtistsView()
            case .playlists: PlaylistsView()
            case .favorites: FavoritesView()
            case .downloads: DownloadsView()
            case .settings: SettingsView()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = min(Theme.shared.startTab, 2)
    @State private var paths = [NavigationPath(), NavigationPath(), NavigationPath()]
    @State private var showNowPlaying = false
    @State private var showMenu = false
    @State private var barHeight: CGFloat = 0
    @State private var addBatch: SongBatch?
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
            nowPlaying: { withAnimation(.spring(duration: 0.4)) { showNowPlaying = true } },
            profileMenu: { withAnimation(.easeOut(duration: 0.25)) { showMenu = true } },
            open: { route in
                withAnimation(.easeOut(duration: 0.25)) { showNowPlaying = false; showMenu = false }
                paths[tab].append(route)
            },
            addToPlaylist: { songs in if !songs.isEmpty { addBatch = SongBatch(songs: songs) } }))
        .sheet(item: $addBatch) { AddToPlaylistSheet(songs: $0.songs) }
        .tint(.accent) // reads Theme, so a new accent color applies everywhere at once
        .onChange(of: app.currentId) {
            paths = [NavigationPath(), NavigationPath(), NavigationPath()]
            Task { await app.player.checkServerQueue() }
        }
        // Continue where another device left off – and leave the queue on the server when going away
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.checkRoute(); Task { await app.player.checkServerQueue() } }
            if phase == .background { app.player.syncBeforeLeaving() }
        }
    }

    private var tabs: some View {
        ZStack {
            // All three stacks stay alive so each tab keeps its place, like the tab bar of a music app should
            ForEach(0..<3, id: \.self) { i in
                NavigationStack(path: $paths[i]) { root(i).routes() }
                    .opacity(tab == i ? 1 : 0)
                    .allowsHitTesting(tab == i)
            }
        }
        .id(app.currentId) // fresh views when switching accounts
        // Every scrolling page (plain scroll views and system lists alike) ends above the floating bar
        .contentMargins(.bottom, barHeight, for: .scrollContent)
        .contentMargins(.bottom, barHeight, for: .scrollIndicators)
        .overlay(alignment: .bottom) {
            bottomBar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
        .overlay {
            if showNowPlaying {
                NowPlayingView { withAnimation(.spring(duration: 0.35)) { showNowPlaying = false } }
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
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
        case 0: HomeView()
        case 1: SearchView()
        default: LibraryView()
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if let notice = app.notice {
                Text(notice).font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.white, in: Capsule())
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            ContinueBanner().padding(.horizontal, 8)
            MiniPlayer().padding(.horizontal, 8)
            TabBar(tab: $tab) { paths[$0] = NavigationPath() }
        }
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.8), location: 0.45),
                                   .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                .padding(.top, -24)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

struct TabBar: View {
    @Binding var tab: Int
    /// Tapping the open tab again goes back to its start page.
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
    @State private var adding = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(shown ? 0.55 : 0).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 0) {
                if let acc = app.current {
                    HStack(spacing: 12) {
                        Avatar(name: acc.username, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(acc.username).font(.system(size: 20, weight: .bold))
                            Text(acc.host).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
                        }
                    }
                    .padding(.bottom, 20)
                }
                Rectangle().fill(Color(white: 0.22)).frame(height: 1).padding(.bottom, 12)
                ForEach(app.accounts.filter { $0.id != app.currentId }) { acc in
                    row(label: Text(acc.username), sub: acc.host) { Avatar(name: acc.username, size: 28) } action: {
                        dismiss(); app.select(acc.id)
                    }
                }
                row(label: Text("Add account")) { Image(systemName: "plus").font(.system(size: 20)) } action: { adding = true }
                row(label: Text("Downloads")) { Image(systemName: "arrow.down.circle").font(.system(size: 22)) } action: { ui.open(.downloads) }
                row(label: Text("Settings")) { Image(systemName: "gearshape").font(.system(size: 22)) } action: { ui.open(.settings) }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .frame(width: 310)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.1).ignoresSafeArea())
            .offset(x: shown ? 0 : -330)
            .gesture(DragGesture().onEnded { if $0.translation.width < -60 { dismiss() } })
        }
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { shown = true } }
        .sheet(isPresented: $adding) { NavigationStack { AccountEditorView(account: nil) } }
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
