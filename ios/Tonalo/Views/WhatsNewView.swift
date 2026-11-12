import SwiftUI

/// What changed in each version. Shown once after an update, and any time from Settings.
/// For a new version: add a release at the top – its version must match MARKETING_VERSION.
struct AppRelease: Identifiable {
    let version: String
    let items: [Item]
    var id: String { version }

    struct Item: Identifiable {
        let icon: String
        let color: Color
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        var id: String { icon }
    }
}

enum WhatsNew {
    static let releases: [AppRelease] = [
        AppRelease(version: "1.5.0", items: [
            .init(icon: "music.note.list", color: .purple, title: "DJ",
                  text: "An AI picks sets from your library, and you steer it with moods or a wish. Off until you set it up under Settings, with your own key or your own Ollama."),
            .init(icon: "car.fill", color: .blue, title: "DJ in the car and at home",
                  text: "Start and steer the DJ on CarPlay. If you like, your paired TV and computer get the same setup."),
        ]),
        AppRelease(version: "1.4.5", items: [
            .init(icon: "heart.fill", color: .pink, title: "Jukebox hearts",
                  text: "Songs from a guest show your own hearts, and the heart on CarPlay now switches the right song."),
            .init(icon: "line.3.horizontal", color: .blue, title: "Reorder the queue",
                  text: "Hold a song in the queue and drag it up or down."),
        ]),
        AppRelease(version: "1.4.4", items: [
            .init(icon: "applewatch", color: .green, title: "Better on the watch",
                  text: "Play and pause on the watch no longer stop the phone by mistake, covers show up, and skipping on the phone shows on the watch too."),
            .init(icon: "wifi", color: .blue, title: "Connection to TV and computer",
                  text: "The phone follows your TV and your computer at once and shows the one that is playing, also when the app is opened several times in a row."),
        ]),
        AppRelease(version: "1.4.3", items: [
            .init(icon: "book.fill", color: .indigo, title: "Audiobooks on the TV",
                  text: "A book playing on your TV or computer shows up here, and you control it from the phone. Play on moves it over, from the same spot."),
            .init(icon: "wifi", color: .blue, title: "Steadier connection",
                  text: "The phone finds your TV or computer more reliably after the app opens."),
        ]),
        AppRelease(version: "1.4.2", items: [
            .init(icon: "tv", color: .blue, title: "TV connection",
                  text: "Songs the TV can't play are converted, a switched-off TV is let go of sooner, and it's found again by itself."),
            .init(icon: "arrow.counterclockwise", color: .orange, title: "Starting over",
                  text: "A song you stopped long ago starts from the beginning. Audiobooks still continue where you were."),
        ]),
        AppRelease(version: "1.4.1", items: [
            .init(icon: "wrench.and.screwdriver.fill", color: .orange, title: "Fixes and speed",
                  text: "Big playlists download much faster, Continue listening follows the book you're playing, and seeking in music works again after an audiobook."),
            .init(icon: "applewatch", color: .pink, title: "Apple Watch and CarPlay",
                  text: "Audiobooks and podcasts show up on the watch and in the car, and switching between music and a book follows along."),
            .init(icon: "paintpalette.fill", color: .purple, title: "Look",
                  text: "Dark gray instead of pure black, with corner shape and cover size under Settings, Appearance. The library can sort by Recently played."),
        ]),
        AppRelease(version: "1.4.0", items: [
            .init(icon: "book.fill", color: .indigo, title: "Audiobooks and podcasts",
                  text: "Connect your Audiobookshelf server under Settings and listen in the same app, with chapters, speed, a sleep timer and your progress in sync."),
            .init(icon: "arrow.down.circle.fill", color: .teal, title: "Listen offline",
                  text: "Download books and episodes just like music. Your position goes to the server as soon as there's a connection again."),
            .init(icon: "heart.fill", color: .pink, title: "Your favorites in the library",
                  text: "Give books, podcasts and authors a heart and they show up in Your Library. Finished books have a check mark and a paler cover."),
            .init(icon: "person.crop.circle", color: .orange, title: "Authors and series",
                  text: "Open an author to see their books and series, sort them, and switch between tiles and a compact list."),
            .init(icon: "network", color: .blue, title: "At home and on the go",
                  text: "Audiobookshelf can have an address for outside and one for home, plus custom headers for Cloudflare Access and similar."),
            .init(icon: "sparkles", color: .purple, title: "Small things",
                  text: "Tapping the open tab again clears its filter, and the player and tabs no longer sit on top of the keyboard."),
        ]),
        AppRelease(version: "1.3.0", items: [
            .init(icon: "desktopcomputer", color: .teal, title: "Play on your computer",
                  text: "Tonalo now runs on Windows too. Pair your PC under Devices, and it works like the TV: see what's playing there and send music to it."),
            .init(icon: "person.2.wave.2", color: .purple, title: "Devices and Jukebox",
                  text: "Your own TV or computer is under Devices. Hosting a Jukebox and joining one have their own page."),
            .init(icon: "heart.fill", color: .pink, title: "Favorites offline",
                  text: "Your favorite songs open at once without a connection, from the saved copy or your downloads."),
        ]),
        AppRelease(version: "1.2.0", items: [
            .init(icon: "tv", color: .blue, title: "Play on your TV",
                  text: "While your TV plays Tonalo, the iPhone shows what's playing there, and music you pick plays on the TV. Pair once under TV & Jukebox."),
            .init(icon: "person.2.wave.2", color: .purple, title: "Jukebox",
                  text: "Friends join with a code, add songs and skip – on the TV at home, or in the car with your iPhone as the host, no Wi-Fi needed."),
            .init(icon: "car.fill", color: .green, title: "Better CarPlay",
                  text: "A Radio tab, colorful mixes, and shuffle, repeat and the heart show when they're on. A song that drops out goes on where it stopped."),
        ]),
        AppRelease(version: "1.1.0", items: [
            .init(icon: "dot.radiowaves.left.and.right", color: .purple, title: "Endless radio",
                  text: "Start a radio from a song, an artist, a genre or your favorites. It plays more of what you listen to and like, and less of what you skip."),
            .init(icon: "antenna.radiowaves.left.and.right", color: .red, title: "Radio stations",
                  text: "The stations set up on your server play live, with the song on air. If it's in your library, one tap plays it from there."),
            .init(icon: "infinity", color: .orange, title: "Autoplay",
                  text: "When an album or playlist ends, similar songs keep playing. You can turn it off in Settings."),
            .init(icon: "line.3.horizontal", color: .blue, title: "Reorder the queue",
                  text: "Hold a song in the queue and drag it where you want it."),
            .init(icon: "arrow.down.circle.fill", color: .teal, title: "Faster downloads",
                  text: "Five songs load at once, and a small counter above the player shows how far they are on every page."),
            .init(icon: "car.fill", color: .green, title: "CarPlay",
                  text: "Your music, playlists and downloads on the car screen, with a heart for your favorites."),
            .init(icon: "applewatch", color: .pink, title: "Apple Watch",
                  text: "Play, skip, like and change the volume from your wrist, and start your playlists there."),
        ]),
    ]

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var current: AppRelease? { releases.first { $0.version == currentVersion } }

    private static let key = "whatsNewSeen"

    /// After an update, once per version. A fresh install has nothing new to tell, so it only remembers the version.
    static func shouldShow(hasAccounts: Bool) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-whatsNew") { return current != nil }
        #endif
        let seen = UserDefaults.standard.string(forKey: key)
        if seen == currentVersion { return false }
        if seen == nil && !hasAccounts { markSeen(); return false }
        return current != nil
    }

    static func markSeen() { UserDefaults.standard.set(currentVersion, forKey: key) }
}

/// The sheet after an update: one new thing per page – tap or swipe to the next.
struct WhatsNewSheet: View {
    let release: AppRelease
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private var last: Bool { page == release.items.count - 1 }

    var body: some View {
        let color = release.items[page].color
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("What's New in Tonalo").font(.system(size: 17, weight: .bold))
                Text("Version \(release.version)").font(.subheadline).foregroundStyle(Color.subtle)
            }
            .padding(.top, 36)
            TabView(selection: $page) {
                ForEach(Array(release.items.enumerated()), id: \.element.id) { i, item in
                    WhatsNewPage(item: item, shown: page == i)
                        .contentShape(Rectangle())
                        .onTapGesture { next() }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 8) {
                ForEach(release.items.indices, id: \.self) { i in
                    Capsule().fill(i == page ? color : Color.white.opacity(0.22))
                        .frame(width: i == page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.35), value: page)
            .padding(.bottom, 26)
            Button { next() } label: {
                Text(last ? "Continue" : "Next").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(color)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .background {
            // A soft glow in the color of the page, changing with it
            RadialGradient(colors: [color.opacity(0.35), .clear], center: .init(x: 0.5, y: 0.38), startRadius: 10, endRadius: 360)
                .animation(.easeInOut(duration: 0.4), value: page)
                .background(Color.canvas)
                .ignoresSafeArea()
        }
        .presentationDragIndicator(.visible)
    }

    private func next() {
        if last { dismiss() } else { withAnimation(.easeInOut(duration: 0.3)) { page += 1 } }
    }
}

private struct WhatsNewPage: View {
    let item: AppRelease.Item
    let shown: Bool

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            Image(systemName: item.icon)
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: item.color.opacity(0.5), radius: 24, y: 8)
                .symbolEffect(.bounce, value: shown)
            VStack(spacing: 12) {
                Text(item.title).font(.system(size: 28, weight: .bold))
                Text(item.text).font(.body).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}

private struct WhatsNewRow: View {
    let item: AppRelease.Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 16, weight: .semibold))
                Text(item.text).font(.subheadline).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Every version, newest first – from Settings. A card per version; tap to open it.
struct VersionHistoryView: View {
    @State private var open: Set<String> = [WhatsNew.releases.first?.version ?? ""]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(WhatsNew.releases) { release in
                    card(release)
                }
            }
            .padding(16)
        }
        .background(Color.canvas)
        .navigationTitle("What's New")
    }

    private func card(_ release: AppRelease) -> some View {
        let isOpen = open.contains(release.version)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35)) {
                    if isOpen { open.remove(release.version) } else { open.insert(release.version) }
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Version \(release.version)").font(.system(size: 19, weight: .bold))
                            if release.version == WhatsNew.currentVersion {
                                Text("Current").font(.system(size: 11, weight: .bold)).textCase(.uppercase)
                                    .foregroundStyle(Color.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(Color.accent.opacity(0.16), in: Capsule())
                            }
                        }
                        // What's in it, at a glance
                        HStack(spacing: -6) {
                            ForEach(release.items) { item in
                                Image(systemName: item.icon)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(item.color.gradient, in: Circle())
                                    .overlay(Circle().stroke(Color.panel, lineWidth: 2))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.subtle)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(release.items) { WhatsNewRow(item: $0) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
