import SwiftUI

struct AlbumCard: View {
    let album: Album
    var width: CGFloat? = 150

    var body: some View {
        NavigationLink(value: Route.album(album.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(id: album.coverArt ?? album.id, size: Int(300 * Theme.shared.coverSize.scale), corner: 4)
                Text(album.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([album.year.map(String.init), album.artist].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
            }
            .frame(width: width.map { $0 * Theme.shared.coverSize.scale })
        }
        .buttonStyle(.plain)
    }
}

struct ArtistCard: View {
    let artist: Artist
    var body: some View {
        NavigationLink(value: Route.artist(artist.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(id: artist.coverArt ?? artist.id, round: true)
                Text(artist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("Artist").font(.system(size: 13)).foregroundStyle(Color.subtle)
            }
            .frame(width: 140 * Theme.shared.coverSize.scale)
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal shelf with a title and optional "Show all" link.
struct AlbumRow: View {
    let title: LocalizedStringKey
    let albums: [Album]
    var more: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title, more: more)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { AlbumCard(album: $0) }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct SongRow: View {
    @Environment(AppModel.self) private var app
    let song: Song
    var number: Int?
    var showCover = false
    /// Off in the queue: there holding a song picks it up to move it (the "…" button still has the menu)
    var holdMenu = true
    /// Swipe right: play next. Swipe left: choose a playlist. Off where rows already have their own gestures (the queue).
    var swipe = true
    let onTap: () -> Void

    var body: some View {
        let isCurrent = app.player.current?.id == song.id
        HStack(spacing: 12) {
            if let number {
                Text("\(number)").font(.system(size: 15).monospacedDigit()).foregroundStyle(Color.subtle).frame(minWidth: 18)
            }
            if showCover {
                CoverView(id: song.coverArt ?? song.albumId, size: 120, corner: 2).frame(width: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.system(size: 16)).lineLimit(1).foregroundStyle(isCurrent ? Color.accent : .white)
                HStack(spacing: 5) {
                    if app.isFavorite(song) {
                        Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(Color.accent)
                            .accessibilityLabel("Favorite")
                    }
                    if app.downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accent)
                    } else if app.downloads.index.queued[song.id] != nil {
                        // Waiting its turn: a quiet arrow; loading: the filling ring
                        if let p = app.downloads.progress[song.id], p > 0 {
                            ProgressRing(value: p, lineWidth: 2).frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "arrow.down.circle").font(.system(size: 12)).foregroundStyle(Color.subtle)
                        }
                    }
                    if app.player.smartIds.contains(song.id) {
                        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Color.accent)
                            .accessibilityLabel("Added by Smart Shuffle")
                    }
                    if let artist = song.artist {
                        Text(artist).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            // Says "this one plays right now" – in a playlist, an album and in the search alike
            if isCurrent { PlayingBars(active: app.player.isPlaying).frame(width: 14, height: 12) }
            SongMenu(song: song) {
                Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 32, height: 40).contentShape(Rectangle())
            }
            .foregroundStyle(Color.subtle)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .modifier(HoldMenu(song: song, on: holdMenu))
        .modifier(SwipeActions(song: song, on: swipe))
    }
}

/// Swipe a song row like in other music apps: right plays it next, left opens the playlists to add it to.
/// The row follows the finger and shows the action in the gap; letting go far enough triggers it, otherwise it springs back.
/// Only on iOS 18 and newer: the sideways swipe needs UIKit's gesture, a SwiftUI drag on a row would stop the list from
/// scrolling when the finger starts on it. On iOS 17 the "…" menu and the long press still do the same.
private struct SwipeActions: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let song: Song
    let on: Bool

    func body(content: Content) -> some View {
        content.modifier(SwipeRow(on: on, rightIcon: "text.insert", leftIcon: "text.badge.plus", right: {
            let playing = app.player.current != nil
            app.player.playNext([song])
            if playing { app.notify(String(localized: "Plays next")) }
        }, left: { ui.addToPlaylist([song]) }))
    }
}

/// The row follows the finger and shows an icon in the gap; letting go far enough triggers the action, otherwise it springs back.
struct SwipeRow: ViewModifier {
    let on: Bool
    let rightIcon: String
    let leftIcon: String
    let right: () -> Void
    let left: () -> Void
    @State private var dx: CGFloat = 0
    @State private var armed = false

    private let trigger: CGFloat = 72

    func body(content: Content) -> some View {
        if on, #available(iOS 18.0, *) {
            content
                .offset(x: dx)
                .background(alignment: dx > 0 ? .leading : .trailing) {
                    Image(systemName: dx > 0 ? rightIcon : leftIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accent)
                        .frame(width: abs(dx))
                        .scaleEffect(armed ? 1.2 : 0.8)
                        .opacity(min(1, abs(dx) / 40))
                        .accessibilityHidden(true)
                }
                .gesture(SidewaysPan(
                    onMove: { w in
                        // A little resistance, so it feels like pulling something
                        dx = w > 0 ? min(w * 0.85, 130) : max(w * 0.85, -130)
                        let now = abs(dx) >= trigger
                        if now != armed {
                            armed = now
                            if now { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        }
                    },
                    onEnd: { finished in
                        let go = finished && abs(dx) >= trigger
                        let isRight = dx > 0
                        armed = false
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dx = 0 }
                        guard go else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if isRight { right() } else { left() }
                    }))
        } else {
            content
        }
    }
}

/// A pan that only starts when the finger moves sideways. Up and down it stays out of the way, so the list scrolls.
@available(iOS 18.0, *)
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let onMove: (CGFloat) -> Void
    let onEnd: (Bool) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return false }
            let v = p.velocity(in: p.view)
            return abs(v.x) > abs(v.y) * 1.4
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        switch g.state {
        case .changed: onMove(g.translation(in: g.view).x)
        case .ended: onEnd(true)
        case .cancelled, .failed: onEnd(false)
        default: break
        }
    }
}

/// The song menu on a long press – unless the long press is meant for something else.
private struct HoldMenu: ViewModifier {
    let song: Song
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.contextMenu { SongMenuItems(song: song) } } else { content }
    }
}

struct SongMenu<Label: View>: View {
    let song: Song
    @ViewBuilder let label: () -> Label
    var body: some View { Menu { SongMenuItems(song: song) } label: { label() } }
}

/// Actions for a single song (context menu and "…" button).
struct SongMenuItems: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let song: Song

    var body: some View {
        if let albumId = song.albumId {
            Button { ui.open(.album(albumId)) } label: { Label("Go to album", systemImage: "square.stack") }
        }
        if let artistId = song.artistId {
            Button { ui.open(.artist(artistId)) } label: { Label("Go to artist", systemImage: "music.mic") }
        }
        Button { app.player.playNext([song]) } label: { Label("Play next", systemImage: "text.insert") }
        Button { app.player.enqueue([song]) } label: { Label("Add to queue", systemImage: "text.append") }
        Button { ui.addToPlaylist([song]) } label: { Label("Add to playlist", systemImage: "text.badge.plus") }
        Button { startRadio() } label: { Label("Start song radio", systemImage: "dot.radiowaves.left.and.right") }
        if app.player.dj.ready {
            Button { app.player.dj.start(from: [song], name: song.title) } label: { Label("Start DJ from here", systemImage: "sparkles") }
        }
        if app.downloads.isDownloaded(song.id) {
            Button(role: .destructive) { app.downloads.remove([song.id]) } label: { Label("Remove download", systemImage: "trash") }
        } else if app.downloads.index.queued[song.id] != nil {
            Button(role: .destructive) { app.downloads.cancel([song.id]) } label: { Label("Cancel download", systemImage: "xmark.circle") }
        } else {
            Button { app.downloads.download([song]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        Button { toggleStar() } label: {
            app.isFavorite(song) ? Label("Remove from favorites", systemImage: "heart.slash") : Label("Add to favorites", systemImage: "heart")
        }
    }

    private func startRadio() {
        Task { await app.player.radio.start(String(localized: "\(song.title) radio"), seedId: song.id, first: song) }
    }

    /// The menu closes right away, so say what happened
    private func toggleStar() {
        let on = !app.isFavorite(song)
        Task {
            if await app.setFavorite(song, on) {
                app.notify(on ? String(localized: "Added to favorites") : String(localized: "Removed from favorites"))
            } else {
                app.notify(String(localized: "Couldn’t change favorites. Check your connection."))
            }
        }
    }
}

/// Shuffle icon plus the round play button, right-aligned like on album pages.
struct PlayButtons: View {
    var playing = false
    let play: () -> Void
    let shuffle: () -> Void
    /// Offered next to plain shuffle when there is one: a choice instead of a single button.
    var smartShuffle: (() -> Void)?
    var body: some View {
        HStack(spacing: 20) {
            Spacer()
            if let smartShuffle {
                Menu {
                    Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }
                    Button(action: smartShuffle) { Label("Smart Shuffle", systemImage: "sparkles") }
                } label: { Image(systemName: "shuffle").font(.system(size: 22)).foregroundStyle(Color.subtle) }
                    .accessibilityLabel("Shuffle")
            } else {
                Button(action: shuffle) { Image(systemName: "shuffle").font(.system(size: 22)).foregroundStyle(Color.subtle) }
                    .accessibilityLabel("Shuffle")
            }
            PlayCircle(playing: playing, action: play)
        }
    }
}

/// Shows a spinner while loading and the error text if something went wrong.
struct LoadState: View {
    let loading: Bool
    let error: String?
    var retry: (() async -> Void)?

    var body: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        } else if let error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let retry { Button("Try again") { Task { await retry() } }.buttonStyle(.bordered) }
            }
            .padding(30).frame(maxWidth: .infinity)
        }
    }
}

/// Gradient from the cover's average color into black, behind page headers.
struct CoverTint: View {
    @Environment(AppModel.self) private var app
    let coverId: String?
    var height: CGFloat = 520
    @State private var color = Color(white: 0.25)

    var body: some View {
        LinearGradient(colors: [Theme.shared.coverTint ? color : Color(white: 0.2), Color.canvas], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .task(id: coverId) {
                if let c = await loadCoverColor(app, coverId) { withAnimation(.easeOut(duration: 0.4)) { color = c } }
            }
    }
}

@MainActor func avatarColor(_ name: String) -> Color {
    let palette: [Color] = [.accent, .orange, .green, .pink, .purple, .red, .cyan, .yellow, .mint, .indigo]
    let h = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    return palette[h % palette.count]
}

/// Pull to refresh: the system's spinner is only shown while this runs, and a cached or local answer comes back
/// in milliseconds – then it would flash by unseen and look like nothing happened. Pages that draw under the
/// navigation bar (album, playlist) hide the system's spinner altogether, so the app shows its own as well.
@MainActor @Observable final class PullState {
    static let shared = PullState()
    var count = 0
    var active: Bool { count > 0 }
}

/// `ownSpinner`: for pages that draw under the navigation bar – the system's spinner is hidden there.
/// Everywhere else the system's own is shown, and a second one would only double it.
@MainActor func pulled(ownSpinner: Bool = false, _ work: () async -> Void) async {
    let pull = PullState.shared
    if ownSpinner { pull.count += 1 }
    defer { if ownSpinner { pull.count -= 1 } }
    let start = ContinuousClock.now
    await work()
    let rest = Duration.milliseconds(700) - (ContinuousClock.now - start)
    if rest > .zero { try? await Task.sleep(for: rest) }
}

struct PullSpinner: View {
    var body: some View {
        if PullState.shared.active {
            ProgressView()
                .padding(12)
                .background(.regularMaterial, in: Circle())
                .padding(.top, 70)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
        }
    }
}

/// The small level meter that says "this plays right now": the bars move while it plays and rest while it is paused.
/// Driven by the clock, not by a state change – so it keeps moving on its own, wherever it stands.
struct PlayingBars: View {
    var active: Bool
    /// How many bars (up to four) and how thick: the tiles on Home use three thin ones.
    var bars = 4
    var barWidth: CGFloat = 3.5
    var spacing: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let phase: [Double] = [0, 1.7, 3.1, 0.9], speed: [Double] = [5.2, 6.4, 4.6, 5.8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<min(bars, 4), id: \.self) { i in
                    let level = active && !reduceMotion ? 0.55 + 0.45 * sin(t * speed[i] + phase[i]) : [0.45, 0.8, 0.6, 0.35][i]
                    Capsule().fill(Color.accent)
                        .frame(width: barWidth)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .scaleEffect(y: max(0.18, level), anchor: .bottom)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
