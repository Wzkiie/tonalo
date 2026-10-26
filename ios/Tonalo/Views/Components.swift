import SwiftUI

struct AlbumCard: View {
    let album: Album
    var width: CGFloat? = 150

    var body: some View {
        NavigationLink(value: Route.album(album.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(id: album.coverArt ?? album.id, corner: 4)
                Text(album.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([album.year.map(String.init), album.artist].compactMap { $0 }.joined(separator: " • "))
                    .font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
            }
            .frame(width: width)
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
            .frame(width: 140)
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
                    if app.downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accent)
                    } else if app.downloads.index.queued[song.id] != nil {
                        ProgressRing(value: app.downloads.progress[song.id] ?? 0, lineWidth: 2).frame(width: 11, height: 11)
                    }
                    if let artist = song.artist {
                        Text(artist).font(.system(size: 13)).foregroundStyle(Color.subtle).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            SongMenu(song: song) {
                Image(systemName: "ellipsis").font(.system(size: 16)).frame(width: 32, height: 40).contentShape(Rectangle())
            }
            .foregroundStyle(Color.subtle)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { SongMenuItems(song: song) }
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
        Button { startRadio() } label: { Label("Start song radio", systemImage: "dot.radiowaves.left.and.right") }
        if app.downloads.isDownloaded(song.id) {
            Button(role: .destructive) { app.downloads.remove([song.id]) } label: { Label("Remove download", systemImage: "trash") }
        } else if app.downloads.index.queued[song.id] != nil {
            Button(role: .destructive) { app.downloads.cancel([song.id]) } label: { Label("Cancel download", systemImage: "xmark.circle") }
        } else {
            Button { app.downloads.download([song]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        Button { toggleStar() } label: {
            song.starred == nil ? Label("Add to favorites", systemImage: "heart") : Label("Remove from favorites", systemImage: "heart.slash")
        }
    }

    private func startRadio() {
        guard let client = app.client else { return }
        Task {
            let similar = await client.similarSongs(song.id)
            app.player.play([song] + similar.filter { $0.id != song.id })
        }
    }

    private func toggleStar() { app.toggleStar(song) }
}

/// Shuffle icon plus the round play button, right-aligned like on album pages.
struct PlayButtons: View {
    var playing = false
    let play: () -> Void
    let shuffle: () -> Void
    var body: some View {
        HStack(spacing: 20) {
            Spacer()
            Button(action: shuffle) { Image(systemName: "shuffle").font(.system(size: 22)).foregroundStyle(Color.subtle) }
                .accessibilityLabel("Shuffle")
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
        LinearGradient(colors: [Theme.shared.coverTint ? color : Color(white: 0.2), .black], startPoint: .top, endPoint: .bottom)
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
