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
    /// ReplayGain volume of the current song and of the one fading out.
    @ObservationIgnored private var gain: Float = 1
    @ObservationIgnored private var fadingGain: Float = 1
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
    /// Converted streams start at `timeOffset` when seeking (the server cuts them); the player's own clock starts at 0.
    @ObservationIgnored private var timeOffset: Double = 0
    @ObservationIgnored private var streamQuality: AudioQuality?
    /// What is playing, e.g. "FLAC" or "AAC 256" – shown small in the player.
    private(set) var qualityLabel: String?
    private(set) var playingDownload = false
    /// Playing a song that was loaded ahead: a file on the device, so a new server address doesn't matter.
    @ObservationIgnored private var playingPreloaded = false
    @ObservationIgnored private let prefetcher = Prefetcher()

    /// A queue another device (the TV, for example) left on the server, offered as "Continue listening".
    struct RemoteQueue: Equatable {
        var songs: [Song]
        var index: Int
        var position: Double
        var source: String
        var changed: String
        var changedDate: Date
        var song: Song { songs[index] }
    }
    private(set) var remoteOffer: RemoteQueue?

    /// Sleep timer: playback stops at this time, or at the end of the current song.
    private(set) var sleepAt: Date?
    private(set) var sleepAfterSong = false
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// The sleep timer is turning the volume down – no crossfade into the next song now.
    @ObservationIgnored private var fadingOut = false
    /// When this device last changed the queue or position – compared with the server's copy.
    @ObservationIgnored private var localChange = Date.distantPast
    @ObservationIgnored private var remoteSignature = ""
    @ObservationIgnored private var remoteSavedAt = Date.distantPast
    @ObservationIgnored private var remoteSave: Task<Void, Never>?
    /// A change (usually just the position) that was held back and hasn't reached the server yet.
    @ObservationIgnored private var unsynced = false

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
        if isPlaying { preload() }
    }

    func enqueue(_ songs: [Song]) {
        guard !queue.isEmpty else { return play(songs) }
        queue.append(contentsOf: songs)
        original?.append(contentsOf: songs)
        persist()
        if isPlaying { preload() }
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
        if isPlaying { preload() }
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if auto && sleepAfterSong { sleepAfterSong = false; player.pause(); persist(); syncToServer(force: true); return }
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
        if isPlaying { endFade(); player.pause(); persist(); syncToServer(force: true) } else { remoteOffer = nil; activateSession(); player.play(); preload() }
    }

    func seek(to seconds: Double) {
        endFade()
        position = max(0, seconds)
        if streamQuality?.format != nil {
            // A converted stream has no file to jump around in: ask the server to start there instead
            load(autoplay: isPlaying, startAt: position)
            return
        }
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
        persist(sync: false) // not a change to the queue – mustn't replace what another device saved
        updateNowPlaying() // the heart on the lock screen
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepAt = end
        sleepTask = Task {
            try? await Task.sleep(until: .now + .seconds(end.timeIntervalSinceNow), clock: .continuous)
            guard !Task.isCancelled else { return }
            sleepAt = nil
            fadeOutAndPause()
        }
    }

    func sleepAtEndOfSong() {
        cancelSleepTimer()
        sleepAfterSong = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAt = nil
        sleepAfterSong = false
    }

    /// Turns the volume down over a few seconds instead of stopping abruptly – nicer when falling asleep.
    private func fadeOutAndPause() {
        guard isPlaying else { return }
        endFade()
        fadingOut = true
        let start = Date(), from = gain
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(Date().timeIntervalSince(start) / 6, 1)
                self.player.volume = from * Float(1 - t)
                if t >= 1 {
                    timer.invalidate()
                    self.fadeTimer = nil
                    self.fadingOut = false
                    self.player.pause()
                    self.player.volume = self.gain
                    self.persist()
                    self.syncToServer(force: true)
                }
            }
        }
    }

    // MARK: Account switching

    /// Saves the current queue and empties the player, without touching the saved queue.
    func detach() {
        persist()
        endFade()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []; index = -1; position = 0; duration = 0; original = nil; context = nil
        remoteOffer = nil; remoteSave?.cancel(); remoteSignature = ""; localChange = .distantPast; unsynced = false
        cancelSleepTimer()
        prefetcher.clear()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private struct Saved: Codable {
        var queue: [Song]; var index: Int; var position: Double; var repeatMode: RepeatMode; var shuffle: Bool; var context: Context?
        var changed: Date?
    }

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
        localChange = s.changed ?? .distantPast
    }

    /// Saves the queue on the device, and on the server so other devices can continue from here.
    private func persist(sync: Bool = true) {
        guard let key = storageKey else { return }
        if sync { localChange = .now }
        let s = Saved(queue: Array(queue.prefix(1000)), index: index, position: position, repeatMode: repeatMode, shuffle: shuffle,
                      context: context, changed: localChange)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
        if sync { syncToServer() }
    }

    // MARK: Continue on another device

    /// Sends the queue to the server: right away when the songs or the current song changed,
    /// otherwise (only the position moved) at most every 30 seconds.
    func syncToServer(force: Bool = false) {
        guard let song = current, let client = app?.client, app?.isOnline != false else { return }
        // A window around the current song keeps the request small for huge queues
        let start = max(0, index - 100)
        let ids = queue[start..<min(queue.count, start + 500)].map(\.id)
        let signature = ids.joined(separator: ",") + "|" + song.id
        guard force || signature != remoteSignature || Date().timeIntervalSince(remoteSavedAt) > 30 else { unsynced = true; return }
        unsynced = false
        remoteSignature = signature
        remoteSavedAt = .now
        let position = position
        remoteSave?.cancel()
        remoteSave = Task {
            if !force { try? await Task.sleep(for: .seconds(2)) } // several quick skips send only once
            guard !Task.isCancelled else { return }
            await client.savePlayQueue(ids, current: song.id, position: position)
        }
    }

    /// Going to the background: only send what hasn't reached the server yet (the position while playing).
    /// A device that just sat there must not overwrite what another one saved in the meantime.
    func syncBeforeLeaving() {
        if isPlaying || unsynced { syncToServer(force: true) }
    }

    private var dismissedKey: String? { app?.current.map { "queue.dismissed." + $0.id.uuidString } }

    /// Looks for a newer queue from another device. With nothing queued here it is taken over quietly
    /// (paused); otherwise it's offered, as long as nothing plays on this device.
    func checkServerQueue() async {
        guard !isPlaying, let client = app?.client, let remote = await client.playQueue(), !isPlaying,
              let by = remote.changedBy, by != SubsonicClient.clientName,
              let changed = remote.changedDate, changed > localChange.addingTimeInterval(10),
              let songs = remote.entry, !songs.isEmpty, let stamp = remote.changed,
              stamp != dismissedKey.flatMap({ UserDefaults.standard.string(forKey: $0) }) else { return }
        let i = songs.firstIndex { $0.id == remote.current } ?? 0
        let offer = RemoteQueue(songs: songs, index: i, position: Double(remote.position ?? 0) / 1000,
                                source: by == "Tonalo" ? String(localized: "your TV") : by, changed: stamp, changedDate: changed)
        if queue.isEmpty {
            take(offer, play: false)
        } else if current?.id != offer.song.id || abs(position - offer.position) > 15 {
            remoteOffer = offer
        }
    }

    func acceptRemoteOffer() {
        guard let offer = remoteOffer else { return }
        take(offer, play: true)
    }

    func dismissRemoteOffer() {
        if let key = dismissedKey, let offer = remoteOffer { UserDefaults.standard.set(offer.changed, forKey: key) }
        remoteOffer = nil
    }

    private func take(_ offer: RemoteQueue, play: Bool) {
        remoteOffer = nil
        queue = offer.songs; index = offer.index; original = nil; shuffle = false; context = nil
        errorStreak = 0
        if play {
            load(autoplay: true, startAt: offer.position)
        } else {
            endFade(); player.pause(); player.replaceCurrentItem(with: nil)
            position = offer.position
            duration = Double(offer.song.duration ?? 0)
            localChange = offer.changedDate
            persist(sync: false) // the server already has this queue
        }
    }

    // MARK: Loading

    private func load(autoplay: Bool, startAt: Double = 0, fadeIn: Double = 0) {
        guard let song = current, let client = app?.client else { return }
        endFade()
        let asset: AVURLAsset
        timeOffset = 0
        playingPreloaded = false
        let streaming = (app?.streamingQuality ?? .lossless).resolved(for: song)
        if let local = app?.downloads.localURL(song.id) {
            asset = AVURLAsset(url: local) // downloaded: plays without network
            streamQuality = nil
            qualityLabel = app?.downloads.qualityLabel(song)
            playingDownload = true
        } else if let file = prefetcher.localFile(account: client.account.id, song: song, quality: streaming) {
            asset = AVURLAsset(url: file) // loaded ahead: a whole file, so seeking works without asking the server
            streamQuality = nil
            qualityLabel = streaming.label(for: song)
            playingDownload = false
            playingPreloaded = true
        } else {
            let quality = (app?.streamingQuality ?? .lossless).resolved(for: song)
            let offset = quality.format != nil && startAt > 1 ? Int(startAt) : 0
            guard let url = client.streamURL(song, quality: quality, offset: offset) else { return }
            timeOffset = Double(offset)
            streamQuality = quality
            qualityLabel = quality.label(for: song)
            playingDownload = false
            // Custom headers (e.g. Cloudflare Access) also have to reach the audio stream itself
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.headers])
        }
        remoteOffer = nil
        let item = AVPlayerItem(asset: asset)
        itemObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.handleFailure(message) }
        }
        let newGain = app?.volumeLeveling.factor(for: song) ?? 1
        if fadeIn > 0 {
            // The old player keeps playing the end of the last song while the new one fades in
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            fading = player
            fadingGain = gain
            player = AVPlayer()
            player.volume = 0
            observe(player)
        } else {
            player.volume = newGain
        }
        gain = newGain
        player.replaceCurrentItem(with: item)
        duration = Double(song.duration ?? 0)
        position = startAt
        if startAt > 1 && timeOffset == 0 { player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
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
        if autoplay { preload() } // not for a queue restored on start that may never be played
    }

    // MARK: Loading ahead

    /// Loads the next songs of the queue in the background (downloaded ones don't need it).
    private func preload() {
        guard let app, let client = app.client else { return }
        let count = app.preloadCount
        let upcoming = count == 0 || index < 0 ? [] : queue.dropFirst(index + 1).prefix(count).filter { app.downloads.localURL($0.id) == nil }
        prefetcher.update(current: current, upcoming: Array(upcoming), client: client, quality: app.streamingQuality)
    }

    func preloadChanged() { if current != nil { preload() } }

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
                self.player.volume = Float(sin(t * .pi / 2)) * self.gain
                self.fading?.volume = Float(cos(t * .pi / 2)) * self.fadingGain
                if t >= 1 { self.endFade() }
            }
        }
    }

    /// Stops a running crossfade at once: the old song stops, the new one plays at full volume.
    private func endFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadingOut = false
        fading?.pause()
        fading?.replaceCurrentItem(with: nil)
        fading = nil
        player.volume = gain
    }

    /// The leveling setting changed: apply it to the song that's playing right away.
    func levelingChanged() {
        gain = app?.volumeLeveling.factor(for: current) ?? 1
        if fading == nil { player.volume = gain }
    }

    /// The server address changed (arriving home or leaving): a stream continues from the new one at the same spot.
    func addressChanged() {
        prefetcher.stop() // playing again below starts it anew, from the new address
        guard current != nil, player.currentItem != nil, !playingDownload, !playingPreloaded else { return }
        if isPlaying {
            load(autoplay: true, startAt: position)
        } else {
            // Paused: just drop the old stream, Play loads it from the new address (no change to report to other devices)
            endFade()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func handleFailure(_ message: String?) {
        errorStreak += 1
        lastError = message ?? String(localized: "This song can't be played.")
        if errorStreak < 3 && queue.count > 1 { next(auto: true) }
    }

    private func activateSession() { try? AVAudioSession.sharedInstance().setActive(true) }

    private func tick(_ clock: Double) {
        guard clock.isFinite, player.currentItem != nil else { return }
        let seconds = clock + timeOffset
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
        if fade > 0, fading == nil, !sleepAfterSong, !fadingOut, isPlaying, repeatMode != .one, duration > fade * 2, seconds >= duration - fade {
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
                img = await ImageLoader.shared.image(url, headers: client.headers)
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
        MPRemoteCommandCenter.shared().likeCommand.isActive = song.starred != nil
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.isPlaying == false { self?.toggle() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.isPlaying == true { self?.toggle() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        // Heart in the lock screen player and Control Center (where iOS shows it): adds to / removes from favorites
        c.likeCommand.localizedTitle = String(localized: "Add to favorites")
        c.likeCommand.localizedShortTitle = String(localized: "Favorite")
        c.likeCommand.isEnabled = true
        c.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let song = self.current, let app = self.app else { return }
                Task { await app.setFavorite(song, song.starred == nil) }
            }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }
}
