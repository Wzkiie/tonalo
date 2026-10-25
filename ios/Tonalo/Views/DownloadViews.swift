import SwiftUI

/// Filling ring for download progress (iOS only draws an indeterminate spinner for circular ProgressViews).
struct ProgressRing: View {
    let value: Double
    var lineWidth: CGFloat = 2.5
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.03, min(value, 1)))
                .stroke(Color.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: value)
        }
    }
}

/// Download button for an album or playlist: arrow → progress ring → checkmark. Tapping a finished one offers removal.
struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    let songs: [Song]
    let download: () -> Void
    let remove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        let state = app.downloads.state(songs)
        Button {
            switch state {
            case .complete: confirmRemove = true
            case .downloading: break
            default: download()
            }
        } label: {
            switch state {
            case .none: Image(systemName: "arrow.down.circle")
            case .partial: Image(systemName: "arrow.down.circle.dotted")
            case .complete: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accent)
            case .downloading(let done, let total):
                // Finished songs plus the progress of the ones still loading
                let partial = songs.compactMap { app.downloads.progress[$0.id] }.reduce(0, +)
                ProgressRing(value: (Double(done) + partial) / Double(max(total, 1)), lineWidth: 3).frame(width: 22, height: 22)
            }
        }
        .accessibilityLabel(state == .complete ? Text("Remove download") : Text("Download"))
        .confirmationDialog("Remove download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove download", role: .destructive, action: remove)
        }
    }
}

/// Everything saved for offline listening.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmDeleteAll = false

    var body: some View {
        let store = app.downloads
        let songs = store.downloadedSongs
        let albums = store.index.albums.values.sorted { $0.name < $1.name }
        let playlists = store.index.playlists.values.sorted { $0.name < $1.name }
        let active = store.index.queued.values.sorted { $0.title < $1.title }

        List {
            Section {
                LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
                LabeledContent("Songs", value: "\(songs.count)")
                if !songs.isEmpty {
                    PlayButtons(playing: app.player.isPlaying(from: .downloads, id: nil),
                                play: { app.player.play(songs, context: .init(kind: .downloads, name: String(localized: "Downloads"))) },
                                shuffle: { app.player.play(songs, shuffled: true, context: .init(kind: .downloads, name: String(localized: "Downloads"))) })
                        .listRowBackground(Color.clear)
                }
            }

            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active) { s in
                        HStack {
                            Text(s.title).lineLimit(1)
                            Spacer()
                            ProgressView(value: store.progress[s.id] ?? 0).frame(width: 80).tint(.accent)
                        }
                    }
                }
            }

            if !store.failed.isEmpty {
                Section {
                    Text("\(store.failed.count) downloads failed. Open the album or playlist and tap the download button to retry.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { p in
                        NavigationLink(value: Route.playlist(p.id)) {
                            HStack(spacing: 12) {
                                CoverView(id: p.coverArt ?? p.id, size: 120, corner: 4).frame(width: 44)
                                Text(p.name)
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { playlists[$0].id }.forEach(store.removePlaylist) }
                }
            }

            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { a in
                        NavigationLink(value: Route.album(a.id)) {
                            HStack(spacing: 12) {
                                CoverView(id: a.coverArt ?? a.id, size: 120, corner: 4).frame(width: 44)
                                VStack(alignment: .leading) {
                                    Text(a.name).lineLimit(1)
                                    Text(a.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { albums[$0].id }.forEach(store.removeAlbum) }
                }
            }

            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        SongRow(song: s, showCover: true) { app.player.play(songs, from: i) }
                    }
                    .onDelete { offsets in store.remove(offsets.map { songs[$0].id }) }
                }
                Section {
                    Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
                }
            }

            if songs.isEmpty && active.isEmpty {
                Section {
                    Text("Nothing downloaded yet. Use the download button on an album or playlist, or “Download” in a song’s menu.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all downloads", role: .destructive) { store.removeAll() }
        }
    }
}

/// Shown at the top of the home screen when there is no network.
struct OfflineBanner: View {
    var body: some View {
        NavigationLink(value: Route.downloads) {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You’re offline").font(.subheadline.bold())
                    Text("Your downloads still work.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}
