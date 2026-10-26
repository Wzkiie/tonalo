import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Playback, queue, lock screen controls and scrobbling. The queue is saved per account.
@MainActor
@Observable
final class PlayerModel {
    enum RepeatMode: String, Codable { case off, all, one }

    /// Where the queue came from, shown as "Playing from …" in the player.
    struct Context: Codable, Hashable {
        enum Kind: String, Codable { case album, playlist, artist, favorites, search, mix, downloads }
        var kind: Kind
        var id: String?
        var name: String
    }

    @ObservationIgnored weak var app: AppModel?

    private(set) var queue: [Song] = []
    private(set) var index = -1
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var context: Context?
    var lastError: String?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    @ObservationIgnored private var player = AVPlayer()
    /// The previous song's player while it fades out during a crossfade.
    @ObservationIgnored private var fading: AVPlayer?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var original: [Song]?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var artwork: UIImage?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var errorStreak = 0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        observe(player)
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.next(auto: true)
            }
        }
        setupRemoteCommands()
    }

    /// Time and play state always come from the player of the current song.
    private func observe(_ p: AVPlayer) {
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        statusObservation = p.observe(\.timeControlStatus) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, p === self.player else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }
    }

    // MARK: Queue

    func play(_ songs: [Song], from start: Int = 0, shuffled: Bool = false, context: Context? = nil) {
        guard !songs.isEmpty else { return }
        self.context = context
        if shuffled {
            original = songs
            queue = songs.shuffled()
            index = 0
        } else {
            original = nil
            queue = songs
            index = min(max(start, 0), songs.count - 1)
        }
        shuffle = shuffled
        errorStreak = 0
        load(autoplay: true)
    }

    /// Puts songs in the queue without starting playback.
    func cue(_ songs: [Song], context: Context? = nil) {
        guard !songs.isEmpty else { return }
        queue = songs; index = 0; position = 0; original = nil; shuffle = false
        self.context = context
        duration = Double(songs[0].duration ?? 0)
        persist()
    }

    /// True while this album/playlist/… is what the queue was started from.
    func isPlaying(from kind: Context.Kind, id: String?) -> Bool {
        isPlaying && context?.kind == kind && context?.id == id
    }

    func playNext(_ songs: [Song]) {
        guard !queue.isEmpty else { return play(songs) }
        queue.insert(contentsOf: songs, at: index + 1)
        original?.append(contentsOf: songs)
        persist()
    }

    func enqueue(_ songs: [Song]) {
        guard !queue.isEmpty else { return play(songs) }
        queue.append(contentsOf: songs)
        original?.append(contentsOf: songs)
        persist()
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        load(autoplay: true)
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
        persist()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto && repeatMode == .one { seek(to: 0); player.play(); return }
        guard let i = nextIndex(auto: auto) else { player.pause(); return }
        index = i
        load(autoplay: true)
    }

    /// The song that follows the current one, or nil at the end of the queue.
    private func nextIndex(auto: Bool) -> Int? {
        if index < queue.count - 1 { return index + 1 }
        return repeatMode == .all || !auto ? 0 : nil
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if position > 3 { seek(to: 0); return }
        index = index > 0 ? index - 1 : (repeatMode == .all ? queue.count - 1 : 0)
        load(autoplay: true)
    }

    func toggle() {
        guard current != nil else { return }
        if player.currentItem == nil { load(autoplay: true, startAt: position); return }
        if isPlaying { endFade(); player.pause() } else { activateSession(); player.play() }
    }

    func seek(to seconds: Double) {
        endFade()
        position = max(0, seconds)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        updateNowPlaying()
    }

    func toggleShuffle() {
        guard let cur = current else { return }
        if shuffle, let original {
            queue = original
            index = queue.firstIndex(of: cur) ?? 0
            self.original = nil
        } else {
            original = queue
            var rest = queue; rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        }
        shuffle.toggle()
        persist()
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        persist()
    }

    func setStarred(_ song: Song, _ on: Bool) {
        for i in queue.indices where queue[i].id == song.id { queue[i].starred = on ? "1" : nil }
        persist()
    }

    // MARK: Account switching

    /// Saves the current queue and empties the player, without touching the saved queue.
    func detach() {
        persist()
        endFade()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []; index = -1; position = 0; duration = 0; original = nil; context = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private struct Saved: Codable { var queue: [Song]; var index: Int; var position: Double; var repeatMode: RepeatMode; var shuffle: Bool; var context: Context? }

    private var storageKey: String? { app?.current.map { "queue." + $0.id.uuidString } }

    func restore() {
        guard let key = storageKey, let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        queue = s.queue
        index = queue.indices.contains(s.index) ? s.index : (queue.isEmpty ? -1 : 0)
        position = s.position
        repeatMode = s.repeatMode
        shuffle = s.shuffle
        context = s.context
        duration = Double(current?.duration ?? 0)
    }

    private func persist() {
        guard let key = storageKey else { return }
        let s = Saved(queue: Array(queue.prefix(1000)), index: index, position: position, repeatMode: repeatMode, shuffle: shuffle, context: context)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
    }

    // MARK: Loading

    private func load(autoplay: Bool, startAt: Double = 0, fadeIn: Double = 0) {
        guard let song = current, let client = app?.client else { return }
        endFade()
        let asset: AVURLAsset
        if let local = app?.downloads.localURL(song.id) {
            asset = AVURLAsset(url: local) // downloaded: plays without network
        } else {
            guard let url = client.streamURL(song.id, maxBitRate: app?.maxBitRate ?? 0) else { return }
            // Custom headers (e.g. Cloudflare Access) also have to reach the audio stream itself
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.account.httpHeaders])
        }
        let item = AVPlayerItem(asset: asset)
        itemObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.handleFailure(message) }
        }
        if fadeIn > 0 {
            // The old player keeps playing the end of the last song while the new one fades in
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            fading = player
            player = AVPlayer()
            player.volume = 0
            observe(player)
        }
        player.replaceCurrentItem(with: item)
        duration = Double(song.duration ?? 0)
        position = startAt
        if startAt > 1 { player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
        scrobbled = false
        if autoplay {
            activateSession()
            player.play()
            if app?.scrobble == true { Task { await client.scrobble(song.id, submission: false) } }
        }
        if fadeIn > 0 { startFade(over: fadeIn) }
        artwork = nil
        updateNowPlaying()
        loadArtwork(for: song, client: client)
        persist()
    }

    // MARK: Crossfade

    private func startCrossfade() {
        guard let i = nextIndex(auto: true) else { return }
        index = i
        errorStreak = 0
        load(autoplay: true, fadeIn: Double(app?.crossfade ?? 0))
    }

    private func startFade(over seconds: Double) {
        let start = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(Date().timeIntervalSince(start) / seconds, 1)
                // Equal-power curve, so the volume doesn't dip in the middle
                self.player.volume = Float(sin(t * .pi / 2))
                self.fading?.volume = Float(cos(t * .pi / 2))
                if t >= 1 { self.endFade() }
            }
        }
    }

    /// Stops a running crossfade at once: the old song stops, the new one plays at full volume.
    private func endFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fading?.pause()
        fading?.replaceCurrentItem(with: nil)
        fading = nil
        player.volume = 1
    }

    private func handleFailure(_ message: String?) {
        errorStreak += 1
        lastError = message ?? String(localized: "This song can't be played.")
        if errorStreak < 3 && queue.count > 1 { next(auto: true) }
    }

    private func activateSession() { try? AVAudioSession.sharedInstance().setActive(true) }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, player.currentItem != nil else { return }
        position = seconds
        if duration <= 0, let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        if isPlaying { errorStreak = 0 }
        if let song = current, !scrobbled, app?.scrobble == true, duration > 0, seconds > duration / 2 || seconds > 240 {
            scrobbled = true
            if let client = app?.client {
                let playedAt = Date()
                Task { if !(await client.scrobble(song.id, submission: true, time: playedAt)) { queueScrobble(song.id, at: playedAt) } }
            }
        }
        if Int(seconds) % 10 == 0 { persist() }
        let fade = Double(app?.crossfade ?? 0)
        if fade > 0, fading == nil, isPlaying, repeatMode != .one, duration > fade * 2, seconds >= duration - fade {
            startCrossfade()
        }
    }

    // MARK: Offline scrobbles

    private struct PendingScrobble: Codable { var id: String; var time: Date }
    private var scrobbleKey: String? { app?.current.map { "scrobbles." + $0.id.uuidString } }

    private func pendingScrobbles() -> [PendingScrobble] {
        guard let key = scrobbleKey, let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingScrobble].self, from: data)) ?? []
    }

    private func savePending(_ list: [PendingScrobble]) {
        guard let key = scrobbleKey else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.suffix(500))), forKey: key)
    }

    /// Played without network: remember it and send it with the original time once the server is reachable.
    private func queueScrobble(_ id: String, at time: Date) {
        savePending(pendingScrobbles() + [PendingScrobble(id: id, time: time)])
    }

    func flushScrobbles() async {
        guard let client = app?.client else { return }
        var left: [PendingScrobble] = []
        for p in pendingScrobbles() where !(await client.scrobble(p.id, submission: true, time: p.time)) { left.append(p) }
        savePending(left)
    }

    // MARK: Lock screen / Control Center

    private func loadArtwork(for song: Song, client: SubsonicClient) {
        let coverId = song.coverArt ?? song.albumId
        let local = app?.downloads.localCover(coverId)
        guard local != nil || client.coverURL(coverId, size: 600) != nil else { return }
        Task {
            var img: UIImage?
            if let local { img = UIImage(contentsOfFile: local.path) }
            if img == nil, let url = client.coverURL(coverId, size: 600) {
                img = await ImageLoader.shared.image(url, headers: client.account.httpHeaders)
            }
            guard current?.id == song.id else { return }
            artwork = img
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let song = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.isPlaying == false { self?.toggle() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.isPlaying == true { self?.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }
}
