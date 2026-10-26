import SwiftUI

/// Songs on their way into a playlist – what the "Add to playlist" sheet works on.
struct SongBatch: Identifiable {
    let id = UUID()
    var songs: [Song]
}

extension Playlist {
    /// Only the owner can change a playlist; other users' public playlists are read-only.
    @MainActor func isOwned(by app: AppModel) -> Bool { owner == nil || owner == app.current?.username }
}

/// Pick one of your playlists – or make a new one – for one or more songs.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let songs: [Song]
    @State private var playlists: [Playlist]?
    @State private var error: String?
    @State private var naming = false
    @State private var newName = ""
    @State private var busy = false
    @State private var duplicates: Duplicates?

    /// Some of the songs are already in the chosen playlist.
    struct Duplicates {
        var playlist: Playlist
        var fresh: [Song]
    }

    var body: some View {
        NavigationStack {
            List {
                Button { newName = ""; naming = true } label: {
                    Label("New playlist", systemImage: "plus").foregroundStyle(Color.accent)
                }
                if let playlists {
                    Section {
                        ForEach(playlists) { p in
                            Button { Task { await add(to: p) } } label: {
                                HStack(spacing: 12) {
                                    CoverView(id: p.coverArt ?? p.id, size: 120, corner: 4).frame(width: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundStyle(.white).lineLimit(1)
                                        Text("\(p.songCount ?? 0) songs").font(.caption).foregroundStyle(Color.subtle)
                                    }
                                }
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .overlay { if playlists == nil && error == nil { ProgressView() } }
            .disabled(busy)
            .navigationTitle(songs.count == 1 ? Text("Add to playlist") : Text("Add \(songs.count) songs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New playlist", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(duplicateTitle, isPresented: Binding(get: { duplicates != nil }, set: { if !$0 { duplicates = nil } }),
                                titleVisibility: .visible, presenting: duplicates) { d in
                Button("Add anyway") { Task { await commit(d.playlist, songs) } }
                if !d.fresh.isEmpty && d.fresh.count < songs.count {
                    Button("Add new ones only") { Task { await commit(d.playlist, d.fresh) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { d in
                songs.count == 1 ? Text("This song is already in the playlist.")
                    : Text("\(songs.count - d.fresh.count) of these songs are already in the playlist.")
            }
        }
        .task { await load() }
    }

    private var duplicateTitle: String {
        duplicates.map { String(localized: "Already in “\($0.playlist.name)”") } ?? ""
    }

    private func load() async {
        do {
            playlists = (try await app.client?.playlists() ?? []).filter { $0.isOwned(by: app) }
        } catch {
            self.error = error.userMessage
        }
    }

    /// Checks for songs that are already in the playlist first, like the big apps do.
    private func add(to p: Playlist) async {
        guard let client = app.client else { return }
        busy = true
        defer { busy = false }
        let existing = Set(((try? await client.playlist(p.id))?.entry ?? []).map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        if fresh.count == songs.count {
            await commit(p, songs)
        } else {
            duplicates = Duplicates(playlist: p, fresh: fresh)
        }
    }

    private func commit(_ p: Playlist, _ list: [Song]) async {
        guard let client = app.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.updatePlaylist(p.id, add: list.map(\.id))
            app.playlistsChanged()
            app.notify(String(localized: "Added to \(p.name)"))
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = app.client else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.createPlaylist(name: name, songIds: songs.map(\.id))
            app.playlistsChanged()
            app.notify(String(localized: "Added to \(name)"))
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}

/// Remove and reorder the songs of a playlist. Saved in one go when tapping Done.
struct PlaylistEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    let saved: () -> Void
    @State private var entries: [Entry]
    @State private var moved = false
    @State private var busy = false
    @State private var error: String?

    /// A song with its place in the playlist as the server knows it – removal works by those places.
    struct Entry: Identifiable {
        let id = UUID()
        let index: Int
        let song: Song
    }

    init(playlist: Playlist, saved: @escaping () -> Void) {
        self.playlist = playlist
        self.saved = saved
        _entries = State(initialValue: (playlist.entry ?? []).enumerated().map { Entry(index: $0.offset, song: $0.element) })
    }

    private var changed: Bool { moved || entries.count != (playlist.entry ?? []).count }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(entries) { e in
                    HStack(spacing: 12) {
                        CoverView(id: e.song.coverArt ?? e.song.albumId, size: 120, corner: 2).frame(width: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.song.title).lineLimit(1)
                            Text(e.song.artist ?? "").font(.caption).foregroundStyle(Color.subtle).lineLimit(1)
                        }
                    }
                }
                .onDelete { entries.remove(atOffsets: $0) }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1); moved = true }
            }
            .environment(\.editMode, .constant(.active))
            .disabled(busy)
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await save() } }.bold().disabled(!changed || busy)
                }
            }
        }
    }

    private func save() async {
        guard let client = app.client else { return }
        busy = true
        defer { busy = false }
        do {
            if moved {
                // The API can only remove and append – a new order means replacing the list
                try await client.replacePlaylistSongs(playlist.id, songIds: entries.map(\.song.id))
            } else {
                let kept = Set(entries.map(\.index))
                let removed = (playlist.entry ?? []).indices.filter { !kept.contains($0) }
                try await client.updatePlaylist(playlist.id, removeIndexes: removed)
            }
            app.playlistsChanged()
            saved()
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}
