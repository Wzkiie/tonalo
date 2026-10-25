import SwiftUI
import UIKit

/// Lets iOS hand finished background downloads back to the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadSession.shared.backgroundCompletion = completionHandler
        _ = DownloadSession.shared.session // reconnect to the background session
    }
}

@main
struct TonaloApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

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
    case artists
    case playlists
    case favorites
    case downloads
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let id): AlbumView(id: id)
            case .artist(let id): ArtistView(id: id)
            case .playlist(let id): PlaylistView(id: id)
            case .albums(let type): AlbumsView(type: type)
            case .artists: ArtistsView()
            case .playlists: PlaylistsView()
            case .favorites: FavoritesView()
            case .downloads: DownloadsView()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var showNowPlaying = false
    @State private var tab = Theme.shared.startTab

    var body: some View {
        @Bindable var app = app
        Group {
            if app.accounts.isEmpty {
                NavigationStack { AccountEditorView(account: nil) }
            } else {
                TabView(selection: $tab) {
                    page { HomeView() }.tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
                    page { SearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
                    page { LibraryView() }.tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(2)
                    page { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
                }
                .id(app.currentId) // fresh navigation state when switching accounts
            }
        }
        .fullScreenCover(isPresented: $app.showsAccountPicker) { AccountPickerView() }
        .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        .environment(\.openNowPlaying, OpenNowPlaying { showNowPlaying = true })
        .tint(.accent) // reads Theme, so a new accent color applies everywhere at once
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack { content().routes() }
            .safeAreaInset(edge: .bottom) { MiniPlayer().padding(.horizontal, 8).padding(.bottom, 4) }
    }
}

struct OpenNowPlaying { var action: () -> Void = {} ; func callAsFunction() { action() } }

private struct OpenNowPlayingKey: EnvironmentKey { static let defaultValue = OpenNowPlaying() }
extension EnvironmentValues {
    var openNowPlaying: OpenNowPlaying {
        get { self[OpenNowPlayingKey.self] }
        set { self[OpenNowPlayingKey.self] = newValue }
    }
}
