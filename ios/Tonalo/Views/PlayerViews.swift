import SwiftUI

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openNowPlaying) private var openNowPlaying

    var body: some View {
        let p = app.player
        if let song = p.current {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverView(id: song.coverArt ?? song.albumId, size: 120, corner: 4).frame(width: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { p.toggle() } label: {
                        Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 40)
                    }
                    Button { p.next() } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 40, height: 40) }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                GeometryReader { g in
                    Capsule().fill(Color.white.opacity(0.15))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.white).frame(width: p.duration > 0 ? g.size.width * min(1, p.position / p.duration) : 0)
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { openNowPlaying() }
        }
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var showLyrics = Theme.shared.lyricsFirst
    @State private var showQueue = false
    @State private var lyrics: Lyrics?

    var body: some View {
        let p = app.player
        VStack(spacing: 20) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
            if let song = p.current {
                Group {
                    if showLyrics { LyricsView(lyrics: lyrics, position: p.position) }
                    else {
                        CoverView(id: song.coverArt ?? song.albumId, size: 800, corner: 10)
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(maxHeight: .infinity)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.title2.bold()).lineLimit(1)
                        Text(song.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { toggleStar(song) } label: {
                        Image(systemName: song.starred == nil ? "heart" : "heart.fill").font(.title2)
                    }
                }

                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? p.position }, set: { scrub = $0 }),
                           in: 0...max(p.duration, 1)) { editing in
                        if !editing, let s = scrub { p.seek(to: s); scrub = nil }
                    }
                    HStack {
                        Text(formatTime(scrub ?? p.position))
                        Spacer()
                        Text(formatTime(p.duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                HStack {
                    Button { p.toggleShuffle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(p.shuffle ? Color.accent : .secondary)
                    Spacer()
                    Button { p.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                    Spacer()
                    Button { p.toggle() } label: {
                        Image(systemName: p.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72))
                    }
                    Spacer()
                    Button { p.next() } label: { Image(systemName: "forward.fill").font(.title) }
                    Spacer()
                    Button { p.cycleRepeat() } label: { Image(systemName: p.repeatMode == .one ? "repeat.1" : "repeat") }
                        .foregroundStyle(p.repeatMode == .off ? .secondary : Color.accent)
                }
                .font(.title3)
                .foregroundStyle(.primary)

                HStack {
                    Button { showLyrics.toggle() } label: { Image(systemName: "quote.bubble") }
                        .foregroundStyle(showLyrics ? Color.accent : .secondary)
                    Spacer()
                    Button { showQueue = true } label: { Image(systemName: "list.bullet") }.foregroundStyle(.secondary)
                }
                .font(.title3)
                .padding(.bottom, 8)
            } else {
                Spacer()
                Text("Nothing playing").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .background(CoverTint(coverId: p.current?.coverArt ?? p.current?.albumId))
        .sheet(isPresented: $showQueue) { QueueView() }
        .task(id: p.current?.id) {
            lyrics = nil
            if let id = p.current?.id { lyrics = await app.client?.lyrics(id) }
        }
        .alert("Playback error", isPresented: Binding(get: { app.player.lastError != nil }, set: { if !$0 { app.player.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.player.lastError ?? "") }
    }

    private func toggleStar(_ song: Song) {
        guard let client = app.client else { return }
        let on = song.starred == nil
        Task { try? await client.setStar(songId: song.id, on: on); app.player.setStarred(song, on) }
    }
}

struct LyricsView: View {
    let lyrics: Lyrics?
    let position: Double

    var body: some View {
        if let lyrics {
            let active = lyrics.synced ? lyrics.lines.lastIndex { Double($0.start ?? 0) / 1000 <= position + 0.3 } : nil
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.value.isEmpty ? "♪" : line.value)
                                .font(.title2.bold())
                                .foregroundStyle(!lyrics.synced || i == active ? Color.white : Color.white.opacity(i < (active ?? 0) ? 0.5 : 0.3))
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 120)
                }
                .onChange(of: active) { _, new in
                    if let new { withAnimation(.easeInOut) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
        } else {
            Text("No lyrics for this song.").foregroundStyle(.secondary)
        }
    }
}

struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let p = app.player
        NavigationStack {
            List {
                if let cur = p.current {
                    Section("Now playing") {
                        SongRow(song: cur, showCover: true) { p.toggle() }
                    }
                }
                Section("Up next") {
                    ForEach(Array(p.upNext.enumerated()), id: \.offset) { i, s in
                        SongRow(song: s, showCover: true) { p.jump(to: p.index + 1 + i) }
                    }
                    .onDelete { set in set.sorted(by: >).forEach { p.remove(at: p.index + 1 + $0) } }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
