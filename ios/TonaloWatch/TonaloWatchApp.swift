import SwiftUI
import WatchKit

@main
struct TonaloWatchApp: App {
    @State private var connector = Connector.shared

    init() {
        Connector.shared.start()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-library") { Connector.shared.page = 1 } // simulator test hook
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(connector)
        }
    }
}

/// Player on top, library one swipe down – like the big streaming apps on the watch.
struct RootView: View {
    @Environment(Connector.self) private var c

    var body: some View {
        @Bindable var c = c
        NavigationStack(path: $c.path) {
            TabView(selection: $c.page) {
                PlayerPage().tag(0)
                LibraryPage().tag(1)
            }
            .tabViewStyle(.verticalPage)
            .navigationDestination(for: WatchItem.self) { SongsPage(item: $0) }
        }
        .tint(c.accent)
    }
}

// MARK: - Player

struct PlayerPage: View {
    @Environment(Connector.self) private var c

    var body: some View {
        if let n = c.now {
            player(n)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.title2).foregroundStyle(c.accent)
                Text("Play something in Tonalo on your iPhone.").font(.footnote).multilineTextAlignment(.center)
                if let error = c.error { Text(error).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .padding()
        }
    }

    private func player(_ n: WatchNowPlaying) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cover(n).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(n.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            TimelineView(.periodic(from: .now, by: 1)) { t in
                let pos = c.position(at: t.date)
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: n.duration > 0 ? g.size.width * pos / n.duration : 0)
                        }
                }
                .frame(height: 3)
            }
            HStack {
                Button { c.send("previous") } label: { Image(systemName: "backward.fill").font(.title3) }
                    .accessibilityLabel("Previous")
                Spacer()
                Button { c.send("toggle") } label: {
                    Image(systemName: n.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(c.accent, in: Circle())
                }
                .accessibilityLabel(n.isPlaying ? Text("Pause") : Text("Play"))
                Spacer()
                Button { c.send("next") } label: { Image(systemName: "forward.fill").font(.title3) }
                    .accessibilityLabel("Next")
            }
            .buttonStyle(.plain)
            HStack {
                Button { c.send("favorite") } label: {
                    Image(systemName: n.starred ? "heart.fill" : "heart").foregroundStyle(n.starred ? c.accent : .white)
                }
                .accessibilityLabel(n.starred ? Text("Remove from favorites") : Text("Add to favorites"))
                Spacer()
                // Apple's control ignores the frame and draws itself as big as the play button: scale it down,
                // so it sits in the row like the heart and shuffle. It still follows the Digital Crown.
                VolumeControl()
                    .frame(width: 44, height: 44)
                    .scaleEffect(0.62)
                    .frame(width: 28, height: 28)
                Spacer()
                Button { c.send("shuffle") } label: {
                    Image(systemName: "shuffle").foregroundStyle(n.shuffle ? c.accent : .white)
                }
                .accessibilityLabel("Shuffle")
            }
            .font(.system(size: 18))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .containerBackground(for: .tabView) { background(n) }
    }

    @ViewBuilder private func cover(_ n: WatchNowPlaying) -> some View {
        if let data = n.cover, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Rectangle().fill(Color(white: 0.2)).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    /// Blurred cover behind everything, darkened so the controls stay readable.
    @ViewBuilder private func background(_ n: WatchNowPlaying) -> some View {
        ZStack {
            Color.black
            if let data = n.cover, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill().blur(radius: 18).opacity(0.75)
            } else {
                c.accent.opacity(0.35)
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// The iPhone's volume on the Digital Crown.
struct VolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl { WKInterfaceVolumeControl(origin: .companion) }
    func updateWKInterfaceObject(_ object: WKInterfaceVolumeControl, context: Context) {}
}

// MARK: - Library

struct LibraryPage: View {
    @Environment(Connector.self) private var c
    @State private var sections: [WatchSection]?
    @State private var failed = false

    var body: some View {
        List {
            if let sections {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            if item.kind == .mix {
                                Button { c.play(item) } label: { ItemRow(item: item, symbol: "shuffle") }
                            } else {
                                NavigationLink(value: item) {
                                    ItemRow(item: item, symbol: item.kind == .favorites ? "heart.fill" : nil)
                                }
                            }
                        }
                    }
                }
            } else if failed {
                Text(c.error ?? String(localized: "Your iPhone can’t be reached. Open Tonalo on it.")).font(.footnote)
                Button("Try again") { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Library")
        .task { if sections == nil { await load() } }
    }

    private func load() async {
        failed = false
        sections = await c.list()
        failed = sections == nil
    }
}

struct SongsPage: View {
    @Environment(Connector.self) private var c
    let item: WatchItem
    @State private var songs: [WatchItem]?

    var body: some View {
        List {
            if let songs {
                Button { c.play(item, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").foregroundStyle(c.accent) }
                ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                    Button { c.play(item, index: i) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.title).lineLimit(1)
                                .foregroundStyle(c.now?.songId == song.id ? c.accent : .white)
                            if let s = song.subtitle { Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item.title)
        .task { songs = await c.list(item)?.first?.items ?? [] }
    }
}

struct ItemRow: View {
    @Environment(Connector.self) private var c
    let item: WatchItem
    var symbol: String?
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(c.accent.gradient)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(white: 0.2)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15)).lineLimit(2)
                if let s = item.subtitle { Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .task(id: item.coverId) {
            guard symbol == nil, let id = item.coverId, let data = await c.cover(id) else { return }
            image = UIImage(data: data)
        }
    }
}
