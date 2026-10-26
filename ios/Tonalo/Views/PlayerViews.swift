import SwiftUI

/// Floating bar above the tabs, tinted with the cover color. Swipe sideways to skip, tap to open the player.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    @State private var tint = Color(white: 0.2)
    @State private var swipe: CGFloat = 0

    var body: some View {
        let p = app.player
        if let song = p.current {
            HStack(spacing: 10) {
                CoverView(id: song.coverArt ?? song.albumId, size: 120, corner: 4).frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(song.artist ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .offset(x: swipe)
                Spacer(minLength: 8)
                Button { app.toggleStar(song) } label: {
                    Image(systemName: song.starred == nil ? "heart" : "heart.fill").font(.system(size: 20))
                        .foregroundStyle(song.starred == nil ? Color.white : Color.accent)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(song.starred == nil ? Text("Add to favorites") : Text("Remove from favorites"))
                Button { p.toggle() } label: {
                    Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 36, height: 36)
                }
                .accessibilityLabel(p.isPlaying ? Text("Pause") : Text("Play"))
            }
            .foregroundStyle(.white)
            .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(Color.white.opacity(0.25))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.white).frame(width: p.duration > 0 ? g.size.width * min(1, p.position / p.duration) : 0)
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(tint).overlay(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))))
            .contentShape(Rectangle())
            .onTapGesture { ui.nowPlaying() }
            .gesture(DragGesture(minimumDistance: 15)
                .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { swipe = v.translation.width / 3 } }
                .onEnded { v in
                    if v.translation.width < -60 { p.next() }
                    else if v.translation.width > 60 { p.previous() }
                    else if v.translation.height < -40 { ui.nowPlaying() }
                    withAnimation(.spring(duration: 0.25)) { swipe = 0 }
                })
            .task(id: song.coverArt ?? song.albumId) {
                if let c = await loadCoverColor(app, song.coverArt ?? song.albumId) { withAnimation { tint = c } }
            }
        }
    }
}

/// Full-screen player. Lyrics sit in a card below and can be opened full screen.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let close: () -> Void
    @State private var tint = Color(white: 0.25)
    @State private var drag: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var closing = false
    @State private var height: CGFloat = 900
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyrics: Lyrics?

    var body: some View {
        let p = app.player
        ZStack {
            background
            if let song = p.current {
                if showLyrics {
                    lyricsScreen(song)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            page(song).containerRelativeFrame(.vertical)
                            if let lyrics, !lyrics.lines.isEmpty { lyricsCard(lyrics) }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                    }
                }
            } else {
                Text("Nothing playing").foregroundStyle(Color.subtle)
            }
        }
        .offset(y: drag)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onAppear { if Theme.shared.lyricsFirst { showLyrics = true } }
        .sheet(isPresented: $showQueue) { QueueView() }
        .task(id: p.current?.id) {
            lyrics = nil
            if let id = p.current?.id { lyrics = await app.client?.lyrics(id) }
        }
        .task(id: p.current?.coverArt ?? p.current?.albumId) {
            if let c = await loadCoverColor(app, p.current?.coverArt ?? p.current?.albumId) { withAnimation(.easeOut(duration: 0.5)) { tint = c } }
        }
        .alert("Playback error", isPresented: Binding(get: { app.player.lastError != nil }, set: { if !$0 { app.player.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.player.lastError ?? "") }
    }

    private var background: some View {
        ZStack {
            Color.black
            (Theme.shared.coverTint ? tint : Color(white: 0.22))
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    /// Pull down on the top part or the cover to close; on the cover, a sideways swipe skips songs instead.
    /// Measured on screen, not in the player itself – the player moves with the finger, so its own
    /// coordinates would shift under the gesture and make it stutter.
    private func dismissDrag(skips: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { v in
                guard !closing else { return }
                if dragAxis == nil {
                    dragAxis = skips && abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .vertical else { return }
                drag = max(0, v.translation.height)
            }
            .onEnded { v in
                defer { dragAxis = nil }
                guard !closing else { return }
                if dragAxis == .horizontal {
                    if v.translation.width < -60 { app.player.next() } else if v.translation.width > 60 { app.player.previous() }
                    return
                }
                let speed = v.velocity.height
                if drag > 0, v.translation.height > height * 0.25 || speed > 700 {
                    // Keep moving at the finger's speed until it's off screen, then close
                    closing = true
                    let duration = min(0.35, max(0.15, (height - drag) / max(speed, 1800)))
                    withAnimation(.easeOut(duration: duration)) { drag = height } completion: { close() }
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 300, damping: 30, initialVelocity: min(10, max(-10, Double(-speed / max(drag, 20)))))) { drag = 0 }
                }
            }
    }

    private func page(_ song: Song) -> some View {
        let p = app.player
        return VStack(spacing: 0) {
            topBar(song)
            Spacer(minLength: 16)
            CoverView(id: song.coverArt ?? song.albumId, size: 800, corner: 8)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                .gesture(dismissDrag(skips: true))
            Spacer(minLength: 16)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    Button { if let id = song.artistId { ui.open(.artist(id)) } } label: {
                        Text(song.artist ?? "").font(.system(size: 16)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { app.toggleStar(song) } label: {
                    Image(systemName: song.starred == nil ? "heart" : "heart.fill").font(.system(size: 26))
                        .foregroundStyle(song.starred == nil ? Color.white : Color.accent)
                }
                .accessibilityLabel(song.starred == nil ? Text("Add to favorites") : Text("Remove from favorites"))
            }
            .padding(.bottom, 18)
            ProgressBar()
                .overlay(alignment: .bottom) { qualityBadge.offset(y: 2) }
                .padding(.bottom, 14)
            controls
                .padding(.bottom, 20)
            HStack {
                Button { showLyrics = true } label: { Image(systemName: "quote.bubble") }
                    .disabled(lyrics == nil)
                    .accessibilityLabel("Lyrics")
                Spacer()
                Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Queue")
            }
            .font(.system(size: 20))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.bottom, 12)
        }
    }

    /// "FLAC" / "AAC 256", centered between the times under the seek bar.
    @ViewBuilder private var qualityBadge: some View {
        if let label = app.player.qualityLabel {
            HStack(spacing: 3) {
                if app.player.playingDownload { Image(systemName: "arrow.down.circle.fill") }
                Text(label)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
        }
    }

    private func topBar(_ song: Song) -> some View {
        HStack {
            Button(action: close) { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 40, height: 40) }
                .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                Text(contextLabel).font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(.white.opacity(0.75))
                Text(app.player.context?.name ?? song.album ?? "").font(.system(size: 13, weight: .bold)).lineLimit(1)
            }
            .onTapGesture { openContext() }
            Spacer()
            Menu { SongMenuItems(song: song) } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .gesture(dismissDrag())
    }

    private var contextLabel: String {
        switch app.player.context?.kind {
        case .playlist: String(localized: "PLAYING FROM PLAYLIST")
        case .artist: String(localized: "PLAYING FROM ARTIST")
        case .search: String(localized: "PLAYING FROM SEARCH")
        case .favorites: String(localized: "PLAYING FROM FAVORITES")
        case .downloads: String(localized: "PLAYING FROM DOWNLOADS")
        case .mix: String(localized: "PLAYING MIX")
        default: String(localized: "PLAYING FROM ALBUM")
        }
    }

    private func openContext() {
        guard let c = app.player.context else {
            if let id = app.player.current?.albumId { ui.open(.album(id)) }
            return
        }
        switch c.kind {
        case .album: if let id = c.id { ui.open(.album(id)) }
        case .playlist: if let id = c.id { ui.open(.playlist(id)) }
        case .artist: if let id = c.id { ui.open(.artist(id)) }
        case .favorites: ui.open(.favorites)
        case .downloads: ui.open(.downloads)
        default: break
        }
    }

    private var controls: some View {
        let p = app.player
        return HStack {
            Button { p.toggleShuffle() } label: { toggleIcon("shuffle", on: p.shuffle) }
                .accessibilityLabel("Shuffle")
            Spacer()
            Button { p.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 30)) }
                .accessibilityLabel("Previous")
            Spacer()
            PlayCircle(playing: p.isPlaying, size: 66, color: .white) { p.toggle() }
            Spacer()
            Button { p.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 30)) }
                .accessibilityLabel("Next")
            Spacer()
            Button { p.cycleRepeat() } label: { toggleIcon(p.repeatMode == .one ? "repeat.1" : "repeat", on: p.repeatMode != .off) }
                .accessibilityLabel("Repeat")
        }
        .foregroundStyle(.white)
    }

    /// Shuffle/repeat icon: accent colored with a small dot underneath while on.
    private func toggleIcon(_ name: String, on: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: name).font(.system(size: 22))
            Circle().frame(width: 4, height: 4).opacity(on ? 1 : 0)
        }
        .foregroundStyle(on ? Color.accent : .white)
        .offset(y: 3)
    }

    private func lyricsCard(_ lyrics: Lyrics) -> some View {
        Button { showLyrics = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Lyrics").font(.system(size: 16, weight: .bold))
                LyricsView(lyrics: lyrics, position: app.player.position, compact: true)
                    .frame(height: 300)
                    .allowsHitTesting(false)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint).brightness(0.08))
        }
        .buttonStyle(.plain)
    }

    private func lyricsScreen(_ song: Song) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button { showLyrics = false } label: { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 40, height: 40) }
                    .accessibilityLabel("Close")
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(song.artist ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
            }
            .padding(.top, 8)
            LyricsView(lyrics: lyrics, position: app.player.position)
            ProgressBar()
            HStack(spacing: 40) {
                PlayCircle(playing: app.player.isPlaying, size: 56, color: .white) { app.player.toggle() }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .foregroundStyle(.white)
    }
}

/// Thin seek bar with a knob that only shows while dragging, plus times underneath.
struct ProgressBar: View {
    @Environment(AppModel.self) private var app
    @State private var scrub: Double?

    var body: some View {
        let p = app.player
        let total = max(p.duration, 1)
        let value = scrub ?? p.position
        VStack(spacing: 6) {
            GeometryReader { g in
                let x = g.size.width * min(1, max(0, value / total))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Color.white).frame(width: x, height: 4)
                    Circle().fill(Color.white).frame(width: scrub == nil ? 12 : 16).offset(x: x - (scrub == nil ? 6 : 8))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(total, max(0, v.location.x / g.size.width * total)) }
                    .onEnded { _ in if let s = scrub { p.seek(to: s) }; scrub = nil })
            }
            .frame(height: 20)
            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(0, p.duration - value)))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(formatTime(value))
    }
}

/// Synced lyrics scroll along; lines already sung are white, the rest stay dark like on a lyrics card.
struct LyricsView: View {
    let lyrics: Lyrics?
    let position: Double
    var compact = false

    var body: some View {
        if let lyrics {
            let active = lyrics.synced ? lyrics.lines.lastIndex { Double($0.start ?? 0) / 1000 <= position + 0.3 } : nil
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.value.isEmpty ? "♪" : line.value)
                                .font(.system(size: compact ? 20 : 26, weight: .bold))
                                .foregroundStyle(!lyrics.synced || i <= (active ?? -1) ? Color.white : Color.black.opacity(0.55))
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, compact ? 8 : 100)
                }
                .onChange(of: active) { _, new in
                    if let new { withAnimation(.easeInOut) { proxy.scrollTo(new, anchor: compact ? .top : .center) } }
                }
            }
        } else {
            Text("No lyrics for this song.").foregroundStyle(.white.opacity(0.7)).frame(maxHeight: .infinity)
        }
    }
}

/// Now playing plus what comes next, on a dark sheet.
struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.player
        NavigationStack {
            List {
                if let cur = p.current {
                    Section {
                        SongRow(song: cur, showCover: true) { p.toggle() }
                    } header: { header("Now playing") }
                }
                Section {
                    ForEach(Array(p.upNext.enumerated()), id: \.offset) { i, s in
                        SongRow(song: s, showCover: true) { p.jump(to: p.index + 1 + i) }
                    }
                    .onDelete { set in set.sorted(by: >).forEach { p.remove(at: p.index + 1 + $0) } }
                } header: { header(p.context.map { "Next from: \($0.name)" } ?? "Next in queue") }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowBackground(Color.clear)
            .background(Color(white: 0.07))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(white: 0.07))
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).textCase(nil)
    }
}
