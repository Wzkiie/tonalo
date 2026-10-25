import SwiftUI

struct AlbumCard: View {
    let album: Album
    var width: CGFloat? = 150

    var body: some View {
        NavigationLink(value: Route.album(album.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(id: album.coverArt ?? album.id)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([album.year.map(String.init), album.artist].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            VStack(spacing: 6) {
                CoverView(id: artist.coverArt ?? artist.id, round: true)
                Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .frame(width: 120)
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal row with a title and optional "Show all" link.
struct AlbumRow: View {
    let title: LocalizedStringKey
    let albums: [Album]
    var more: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                if let more { NavigationLink("Show all", value: more).font(.subheadline) }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { AlbumCard(album: $0) }
                }
                .padding(.horizontal)
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
            if showCover {
                CoverView(id: song.coverArt ?? song.albumId, size: 120, corner: 4).frame(width: 44)
            } else if let number {
                Text("\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1).foregroundStyle(isCurrent ? Color.accent : .primary)
                if let artist = song.artist { Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if app.downloads.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
            } else if app.downloads.index.queued[song.id] != nil {
                ProgressRing(value: app.downloads.progress[song.id] ?? 0, lineWidth: 2).frame(width: 13, height: 13)
            }
            if song.starred != nil { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.accent) }
            Text(formatTime(Double(song.duration ?? 0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            SongMenu(song: song) {
                Image(systemName: "ellipsis").frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
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
    let song: Song

    var body: some View {
        Button { app.player.playNext([song]) } label: { Label("Play next", systemImage: "text.insert") }
        Button { app.player.enqueue([song]) } label: { Label("Add to queue", systemImage: "text.append") }
        Button { startRadio() } label: { Label("Start song radio", systemImage: "dot.radiowaves.left.and.right") }
        if app.downloads.isDownloaded(song.id) {
            Button(role: .destructive) { app.downloads.remove([song.id]) } label: { Label("Remove download", systemImage: "trash") }
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

    private func toggleStar() {
        guard let client = app.client else { return }
        let on = song.starred == nil
        Task {
            try? await client.setStar(songId: song.id, on: on)
            app.player.setStarred(song, on)
        }
    }
}

/// Big round play button plus shuffle, used on album/playlist/artist pages.
struct PlayButtons: View {
    let play: () -> Void
    let shuffle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) { Label("Play", systemImage: "play.fill").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .foregroundStyle(.black)
        .tint(.accent)
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

/// Header background tinted with the cover's average color, like on the TV.
struct CoverTint: View {
    @Environment(AppModel.self) private var app
    let coverId: String?
    @State private var color = Color(white: 0.25)

    var body: some View {
        LinearGradient(colors: [Theme.shared.coverTint ? color : Color(white: 0.2), .black], startPoint: .top, endPoint: .bottom)
            .frame(height: 520)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .task(id: coverId) {
                guard let client = app.client, let url = client.coverURL(coverId, size: 120),
                      let img = await ImageLoader.shared.image(url, headers: client.account.httpHeaders) else { return }
                withAnimation(.easeOut(duration: 0.4)) { color = img.averageColor }
            }
    }
}

@MainActor func avatarColor(_ name: String) -> Color {
    let palette: [Color] = [.accent, .orange, .green, .pink, .purple, .red, .cyan, .yellow, .mint, .indigo]
    let h = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    return palette[h % palette.count]
}
