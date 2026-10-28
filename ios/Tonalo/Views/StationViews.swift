import SwiftUI

/// Stations have no cover on the server: a gradient in a color of their own with the name on it.
struct StationArt: View {
    let station: Station
    var big = false

    /// The name's hash picks the color, so a station always keeps its own.
    private var hue: Double {
        let seed = station.name.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return Double((seed ^ seed >> 16) % 360) / 360
    }

    var body: some View {
        GeometryReader { g in
            let small = g.size.width < 80
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.75), Color(hue: hue + 0.06, saturation: 0.7, brightness: 0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: small ? .center : .topTrailing) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: small ? g.size.width * 0.4 : big ? 28 : 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(small ? 0.9 : 0.75)).padding(big ? 18 : 6)
                }
                .overlay(alignment: .bottomLeading) {
                    if !small {
                        Text(station.name).font(.system(size: big ? 30 : 14, weight: .heavy)).foregroundStyle(.white)
                            .lineLimit(big ? 3 : 2).minimumScaleFactor(0.6).padding(big ? 20 : 8)
                    }
                }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A station on the home page: tap to play, tap again to pause.
struct StationCard: View {
    @Environment(AppModel.self) private var app
    let station: Station
    let all: [Station]

    var body: some View {
        let p = app.player
        let live = p.station == station
        Button { live ? p.toggle() : p.play(station, in: all) } label: {
            VStack(alignment: .leading, spacing: 6) {
                StationArt(station: station)
                    .overlay(alignment: .topLeading) {
                        if live { LiveBadge(playing: p.isPlaying).padding(8) }
                    }
                    .frame(width: 130, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(live ? p.stationTitle ?? String(localized: "Live radio") : String(localized: "Live radio"))
                    .font(.system(size: 13)).foregroundStyle(live ? Color.accent : Color.subtle).lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(station.name)
    }
}

/// Small "LIVE" tag, with a pulsing dot while it plays.
struct LiveBadge: View {
    let playing: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6).opacity(playing && pulse ? 0.3 : 1)
            Text("LIVE").font(.system(size: 9, weight: .heavy)).tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

/// All stations set up on the server.
struct StationsView: View {
    @Environment(AppModel.self) private var app
    @State private var stations: [Station] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if loaded, error == nil, stations.isEmpty {
                Text("No radio stations yet. They are added on the server, in Navidrome under Radio.")
                    .foregroundStyle(Color.subtle).multilineTextAlignment(.center).padding(32)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(stations) { s in
                    Button { app.player.station == s ? app.player.toggle() : app.player.play(s, in: stations) } label: {
                        StationArt(station: s)
                            .overlay(alignment: .topLeading) {
                                if app.player.station == s { LiveBadge(playing: app.player.isPlaying).padding(8) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(s.name)
                }
            }
            .padding(16)
        }
        .overlay { LoadState(loading: !loaded, error: error) }
        .navigationTitle("Radio")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { stations = try await app.client?.stations() ?? [] } catch { self.error = error.userMessage }
        loaded = true
    }
}

/// The mini player while a station plays.
struct StationMiniBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.ui) private var ui
    let station: Station

    var body: some View {
        let p = app.player
        let parts = p.stationTitle.map(PlayerModel.split)
        HStack(spacing: 10) {
            StationArt(station: station).frame(width: 40).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(parts?.title ?? station.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text(parts?.artist ?? station.name).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { p.toggle() } label: {
                Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 36, height: 36)
            }
            .accessibilityLabel(p.isPlaying ? Text("Pause") : Text("Play"))
        }
        .foregroundStyle(.white)
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
        .contentShape(Rectangle())
        .onTapGesture { ui.nowPlaying() }
        .gesture(DragGesture(minimumDistance: 15).onEnded { v in
            if v.translation.width < -60 { p.next() }
            else if v.translation.width > 60 { p.previous() }
            else if v.translation.height < -40 { ui.nowPlaying() }
        })
    }
}

/// The full player while a station plays: what's on now, other stations with the skip buttons,
/// and the song in your own library when the station plays one you have.
struct StationPage: View {
    @Environment(AppModel.self) private var app
    let station: Station
    let close: () -> Void
    @State private var inLibrary: Song?

    var body: some View {
        let p = app.player
        let parts = p.stationTitle.map(PlayerModel.split)
        VStack(spacing: 0) {
            HStack {
                Button(action: close) { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 40, height: 40) }
                    .accessibilityLabel("Close")
                Spacer()
                VStack(spacing: 2) {
                    Text("PLAYING RADIO").font(.system(size: 11, weight: .medium)).tracking(1).foregroundStyle(.white.opacity(0.75))
                    Text(station.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                Spacer()
                Menu {
                    if let home = station.homePageUrl.flatMap(URL.init(string:)), home.scheme?.hasPrefix("http") == true {
                        Link(destination: home) { Label("Station website", systemImage: "safari") }
                    }
                    if p.current != nil {
                        Button { p.stopStation() } label: { Label("Back to queue", systemImage: "list.bullet") }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 40, height: 40)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 16)
            StationArt(station: station, big: true)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(parts?.title ?? station.name).font(.system(size: 22, weight: .bold)).lineLimit(2)
                Text(parts?.artist ?? String(localized: "Live radio")).font(.system(size: 16)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
            HStack {
                LiveBadge(playing: p.isPlaying)
                Spacer()
                if p.isPlaying { Text(formatTime(p.position)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6)) }
            }
            .padding(.bottom, 18)
            HStack {
                Spacer()
                Button { p.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 30)) }
                    .accessibilityLabel("Previous station")
                Spacer()
                PlayCircle(playing: p.isPlaying, size: 66, color: .white) { p.toggle() }
                Spacer()
                Button { p.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 30)) }
                    .accessibilityLabel("Next station")
                Spacer()
            }
            .padding(.bottom, 20)
            // Room for it is always kept, so the page doesn't jump when it shows up
            ZStack {
                if let song = inLibrary {
                    Button { app.player.play([song]) } label: {
                        HStack(spacing: 10) {
                            CoverView(id: song.coverArt ?? song.albumId, size: 120, corner: 4).frame(width: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("In your library").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accent)
                                Text(song.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.fill")
                        }
                        .padding(8)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .frame(height: 52)
            HStack {
                Spacer()
                SleepTimerButton()
                Spacer()
            }
            .font(.system(size: 20))
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
        .task(id: p.stationTitle) { await findInLibrary() }
    }

    /// Looks up the song on air in the own library – one search per title, nothing leaves the server.
    private func findInLibrary() async {
        withAnimation { inLibrary = nil }
        guard let text = app.player.stationTitle, let client = app.client else { return }
        let parts = PlayerModel.split(text)
        guard let artist = parts.artist else { return }
        try? await Task.sleep(for: .seconds(1)) // titles sometimes change twice in a row
        guard !Task.isCancelled, let found = try? await client.search(parts.title).song else { return }
        let match = found.first {
            $0.title.localizedCaseInsensitiveCompare(parts.title) == .orderedSame
                && ($0.artist ?? "").localizedCaseInsensitiveContains(artist)
        }
        guard !Task.isCancelled else { return }
        withAnimation { inLibrary = match }
    }
}
