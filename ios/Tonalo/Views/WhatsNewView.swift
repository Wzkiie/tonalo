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
        /// A small live picture of the feature instead of the plain symbol
        var visual: Visual? = nil
        var id: String { icon + "\(title)" }
    }

    enum Visual { case dj, devices }
}

enum WhatsNew {
    static let releases: [AppRelease] = [
        AppRelease(version: "1.5.0", items: [
            .init(icon: "music.note.list", color: .purple, title: "DJ",
                  text: "An AI picks sets from your library, and you steer it with moods or a wish. Off until you set it up under Settings, with your own key or your own Ollama.", visual: .dj),
            .init(icon: "car.fill", color: .blue, title: "DJ in the car and at home",
                  text: "Start and steer the DJ on CarPlay. If you like, your paired TV and computer get the same setup.", visual: .devices),
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

/// The sheet after an update: a welcome page, then one new thing per page – tap or swipe to the next.
struct WhatsNewSheet: View {
    let release: AppRelease
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var showAll = false

    /// Page 0 is the welcome, the rest are the items
    private var count: Int { release.items.count + 1 }
    private var last: Bool { page == count - 1 }
    private var color: Color { page == 0 ? Color.accent : release.items[page - 1].color }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !last {
                    Button { dismiss() } label: { Text("Skip").font(.system(size: 16, weight: .medium)).foregroundStyle(Color.subtle) }
                        .transition(.opacity)
                }
            }
            .frame(height: 32)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            TabView(selection: $page) {
                WhatsNewWelcome(release: release, shown: page == 0)
                    .contentShape(Rectangle())
                    .onTapGesture { next() }
                    .tag(0)
                ForEach(Array(release.items.enumerated()), id: \.element.id) { i, item in
                    WhatsNewPage(item: item, shown: page == i + 1)
                        .contentShape(Rectangle())
                        .onTapGesture { next() }
                        .tag(i + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule().fill(i == page ? color : Color.white.opacity(0.22))
                        .frame(width: i == page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.35), value: page)
            .padding(.bottom, 22)
            Button { next() } label: {
                Text(last ? "Continue" : "Next").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(color)
            .padding(.horizontal, 28)
            Button { showAll = true } label: {
                Text("Show changelog").font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .animation(.easeInOut(duration: 0.25), value: last)
        .background {
            // A soft glow in the color of the page, changing with it
            RadialGradient(colors: [color.opacity(0.35), .clear], center: .init(x: 0.5, y: 0.34), startRadius: 10, endRadius: 380)
                .animation(.easeInOut(duration: 0.4), value: page)
                .background(Color.canvas)
                .ignoresSafeArea()
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showAll) {
            NavigationStack {
                VersionHistoryView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAll = false } } }
            }
            .presentationDetents([.large])
        }
    }

    private func next() {
        if last { dismiss() } else { withAnimation(.easeInOut(duration: 0.3)) { page += 1 } }
    }
}

/// The first page: the app, and that it was updated.
private struct WhatsNewWelcome: View {
    let release: AppRelease
    let shown: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            TonaloLogo(size: 128)
                .scaleEffect(shown ? 1 : 0.86)
                .opacity(shown ? 1 : 0.4)
                .animation(.spring(duration: 0.6, bounce: 0.3), value: shown)
            VStack(spacing: 10) {
                Text("Tonalo was updated").font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                Text("Version \(release.version)").font(.title3.weight(.medium)).foregroundStyle(Color.accent)
                Text("Here's what's new.").font(.body).foregroundStyle(Color.subtle)
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}

private struct WhatsNewPage: View {
    let item: AppRelease.Item
    let shown: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Group {
                switch item.visual {
                case .dj: DJPreview(shown: shown)
                case .devices: DevicesPreview(shown: shown, tint: item.color)
                case nil:
                    Image(systemName: item.icon)
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 120, height: 120)
                        .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: item.color.opacity(0.5), radius: 24, y: 8)
                        .symbolEffect(.bounce, value: shown)
                }
            }
            .frame(height: 300)
            VStack(spacing: 12) {
                Text(item.title).font(.system(size: 28, weight: .bold))
                Text(item.text).font(.body).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}

/// The DJ's sheet in miniature: a set that keeps changing, and the chips that steer it.
private struct DJPreview: View {
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    private let timer = Timer.publish(every: 2.4, on: .main, in: .common).autoconnect()
    private let sets: [[[Color]]] = [
        [[.orange, .red], [.pink, .purple], [.purple, .indigo], [.pink, .red]],
        [[.teal, .blue], [.indigo, .blue], [.mint, .teal], [.blue, .purple]],
        [[.yellow, .orange], [.orange, .pink], [.red, .purple], [.yellow, .red]],
    ]
    private var chips: [LocalizedStringKey] { ["More like this", "Calmer", "More energy"] }

    var body: some View {
        let set = sets[step % sets.count]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                DJMark().frame(width: 18, height: 18)
                Text("DJ").font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Color.accent)
            Text("Up next").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(Color.subtle)
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: set[i], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(alignment: .bottomLeading) {
                            Capsule().fill(.white.opacity(0.55)).frame(width: 22, height: 4).padding(7)
                        }
                        .scaleEffect(shown ? 1 : 0.6)
                        .opacity(shown ? 1 : 0)
                        .animation(.spring(duration: 0.5, bounce: 0.3).delay(Double(i) * 0.07), value: shown)
                        .id("\(step)-\(i)")
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.5, bounce: 0.25), value: step)
            Text("Steer the DJ").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(Color.subtle)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Text(chips[i])
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(i == step % 3 ? Color.accent : Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(i == step % 3 ? Color.black : Color.primary)
                        .scaleEffect(i == step % 3 ? 1.06 : 1)
                        .animation(.spring(duration: 0.35), value: step)
                }
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .onReceive(timer) { _ in if shown, !reduceMotion { step += 1 } }
    }
}

/// The DJ reaching the TV and the car: rings that spread from the phone to the devices around it.
private struct DevicesPreview: View {
    let shown: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle().stroke(tint.opacity(0.5 - Double(i) * 0.14), lineWidth: 2)
                    .frame(width: 110 + CGFloat(i) * 70, height: 110 + CGFloat(i) * 70)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(Double(i) * 0.25), value: pulse)
            }
            device("tv", x: -108, y: -70, delay: 0.1)
            device("car.fill", x: 108, y: -70, delay: 0.2)
            device("desktopcomputer", x: 0, y: 112, delay: 0.3)
            Image(systemName: "iphone")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 74, height: 74)
                .background(Color.accent.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    DJMark().frame(width: 22, height: 22).foregroundStyle(.white)
                        .padding(5).background(tint.gradient, in: Circle()).offset(x: 8, y: -8)
                }
                .scaleEffect(shown ? 1 : 0.7)
                .animation(.spring(duration: 0.5, bounce: 0.35), value: shown)
        }
        .frame(width: 300, height: 300)
        .onAppear { pulse = true }
    }

    private func device(_ symbol: String, x: CGFloat, y: CGFloat, delay: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: tint.opacity(0.45), radius: 14, y: 6)
            .offset(x: shown ? x : x * 0.3, y: shown ? y : y * 0.3)
            .scaleEffect(shown ? 1 : 0.4)
            .opacity(shown ? 1 : 0)
            .animation(.spring(duration: 0.6, bounce: 0.3).delay(delay), value: shown)
    }
}

private struct WhatsNewRow: View {
    let item: AppRelease.Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 17, weight: .semibold))
                Text(item.text).font(.subheadline).foregroundStyle(Color.subtle).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Every version, newest first – from Settings or from the update sheet. All of it open, one after the other.
struct VersionHistoryView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(Array(WhatsNew.releases.enumerated()), id: \.element.id) { index, release in
                    section(release, newest: index == 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color.canvas)
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.large)
    }

    private func section(_ release: AppRelease, newest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(release.version).font(.system(size: 30, weight: .bold, design: .rounded))
                if release.version == WhatsNew.currentVersion {
                    Text("Current").font(.system(size: 11, weight: .bold)).textCase(.uppercase)
                        .foregroundStyle(Color.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accent.opacity(0.16), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(release.items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 70) }
                    WhatsNewRow(item: item).padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 16)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if newest {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.accent.opacity(0.35), lineWidth: 1)
                }
            }
        }
    }
}
