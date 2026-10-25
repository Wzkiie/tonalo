import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Playback, queue, lock screen controls and scrobbling. The queue is saved per account.
@MainActor
@Observable
final class PlayerModel {
    enum RepeatMode: String, Codable { case off, all, one }

    @ObservationIgnored weak var app: AppModel?

    private(set) var queue: [Song] = []
    private(set) var index = -1
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    var lastError: String?

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [Song] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var original: [Song]?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var artwork: UIImage?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var errorStreak = 0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.next(auto: true)
            }
        }
        setupRemoteCommands()
    }

    // MARK: Queue

    func play(_ songs: [Song], from start: Int = 0, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
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
        if index < queue.count - 1 { index += 1 }
        else if repeatMode == .all || !auto { index = 0 }
        else { player.pause(); return }
        load(autoplay: true)
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
        if isPlaying { player.pause() } else { activateSession(); player.play() }
    }

    func seek(to seconds: Double) {
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []; index = -1; position = 0; duration = 0; original = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private struct Saved: Codable { var queue: [Song]; var index: Int; var position: Double; var repeatMode: RepeatMode; var shuffle: Bool }

    private var storageKey: String? { app?.current.map { "queue." + $0.id.uuidString } }

    func restore() {
        guard let key = storageKey, let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        queue = s.queue
        index = queue.indices.contains(s.index) ? s.index : (queue.isEmpty ? -1 : 0)
        position = s.position
        repeatMode = s.repeatMode
        shuffle = s.shuffle
        duration = Double(current?.duration ?? 0)
    }

    private func persist() {
        guard let key = storageKey else { return }
        let s = Saved(queue: Array(queue.prefix(1000)), index: index, position: position, repeatMode: repeatMode, shuffle: shuffle)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
    }

    // MARK: Loading

    private func load(autoplay: Bool, startAt: Double = 0) {
        guard let song = current, let client = app?.client else { return }
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
        artwork = nil
        updateNowPlaying()
        loadArtwork(for: song, client: client)
        persist()
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
