import SwiftUI

// Shared building blocks for the app's look: dark surfaces, pills, round play button, profile avatar.

extension Color {
    static let elevated = Color(white: 0.16)   // tiles, chips, cards
    static let subtle = Color(white: 0.70)     // secondary text
}

/// Things deep inside the view tree can ask the root view to do.
struct UIActions {
    var nowPlaying: () -> Void = {}
    var profileMenu: () -> Void = {}
    var open: (Route) -> Void = { _ in }
    var addToPlaylist: ([Song]) -> Void = { _ in }
}

private struct UIActionsKey: EnvironmentKey { static let defaultValue = UIActions() }
extension EnvironmentValues {
    var ui: UIActions {
        get { self[UIActionsKey.self] }
        set { self[UIActionsKey.self] = newValue }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(avatarColor(name), in: Circle())
    }
}

/// The current user's avatar; opens the side menu with accounts and settings.
struct ProfileButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    var body: some View {
        Button { ui.profileMenu() } label: { Avatar(name: app.current?.username ?? "?") }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")
    }
}

/// Avatar plus a big bold title, used at the top of Search and Library.
struct TabHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            ProfileButton()
            Text(title).font(.system(size: 24, weight: .bold))
            Spacer()
            trailing()
        }
    }
}

extension TabHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
}

/// Rounded filter pill.
struct Chip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.black : .white)
                .padding(.horizontal, 14).frame(height: 32)
                .background(selected ? Color.accent : Color.elevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Big round play/pause button in the accent color.
struct PlayCircle: View {
    let playing: Bool
    var size: CGFloat = 52
    var color: Color = .accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.black)
                .offset(x: playing ? 0 : size * 0.03) // the triangle looks centered when nudged right
                .frame(width: size, height: size)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? Text("Pause") : Text("Play"))
    }
}

/// Section title with an optional "Show all" link.
struct ShelfHeader: View {
    let title: LocalizedStringKey
    var more: Route?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 22, weight: .bold))
            Spacer()
            if let more {
                NavigationLink(value: more) { Text("Show all").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.subtle) }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Square tile for "Favorite songs": heart on an accent gradient.
struct FavoritesArt: View {
    var body: some View {
        LinearGradient(colors: [Color.accent, Color.accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(Color.black)
            .overlay { Image(systemName: "heart.fill").font(.system(size: 22)).foregroundStyle(.white) }
            .aspectRatio(1, contentMode: .fit)
    }
}

struct DownloadsArt: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay { Image(systemName: "arrow.down.circle.fill").font(.system(size: 24)).foregroundStyle(Color.accent) }
            .aspectRatio(1, contentMode: .fit)
    }
}

/// Library-style row: cover, title, gray subtitle.
struct ItemRow<Art: View>: View {
    let title: String
    let subtitle: String
    var pinned = false
    @ViewBuilder let art: () -> Art
    var body: some View {
        HStack(spacing: 12) {
            art().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Color.accent).rotationEffect(.degrees(45)) }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Average cover color, from a downloaded cover if there is one.
@MainActor func loadCoverColor(_ app: AppModel, _ id: String?) async -> Color? {
    if let local = app.downloads.localCover(id), let img = UIImage(contentsOfFile: local.path) { return img.averageColor }
    guard let client = app.client, let url = client.coverURL(id, size: 120),
          let img = await ImageLoader.shared.image(url, headers: client.headers) else { return nil }
    return img.averageColor
}

extension AppModel {
    func toggleStar(_ song: Song) {
        Task { await setFavorite(song, song.starred == nil) }
    }

    @discardableResult
    func setFavorite(_ song: Song, _ on: Bool) async -> Bool {
        guard let client, (try? await client.setStar(songId: song.id, on: on)) != nil else { return false }
        player.setStarred(song, on)
        return true
    }
}

extension View {
    /// Solid black behind the status bar, so content scrolling up doesn't run into the clock.
    func statusBarBackground() -> some View {
        overlay(alignment: .top) { Color.black.frame(height: 0).ignoresSafeArea(edges: .top) }
    }
}
