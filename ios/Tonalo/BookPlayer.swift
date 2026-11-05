import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

/// Plays one audiobook or podcast episode from Audiobookshelf. While it plays, it owns the lock screen; the music queue
/// waits untouched in PlayerModel – nothing of this reaches Navidrome (no scrobbles, no saved queue).
@MainActor
@Observable
final class BookPlayer {
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5]

    @ObservationIgnored weak var app: AppModel?
    private(set) var item: ABSItem?
    private(set) var episode: ABSEpisode?
    private(set) var session: ABSSession?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var position: Double = 0
    /// Decoded ahead of time, see `prepareCover`.
    private(set) var cover: UIImage?
    private(set) var coverTint: Color?
    @ObservationIgnored private var coverFor: String?
    var lastError: String?
    var rate = UserDefaults.standard.object(forKey: "book.rate") as? Float ?? 1 {
        didSet {
            if applyingRemote { return }
            // Playing on the TV: the speed is the TV's, and this phone's own stays as it was
            if tvName != nil { app?.tv.command("bookRate", ["rate": Double(rate)]); return }
            UserDefaults.standard.set(rate, forKey: "book.rate")
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }
    /// How far the skip buttons jump, in seconds.
    var skipBack = BookPlayer.storedSkip("book.skipBack", default: 15) {
        didSet { UserDefaults.standard.set(skipBack, forKey: "book.skipBack"); MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)] }
    }
    var skipForward = BookPlayer.storedSkip("book.skipForward", default: 30) {
        didSet { UserDefaults.standard.set(skipForward, forKey: "book.skipForward"); MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)] }
    }
    /// Each of these has its own symbol with the number in it.
    static let skipChoices = [10, 15, 30, 45, 60]
    private static func storedSkip(_ key: String, default fallback: Int) -> Int {
        let saved = UserDefaults.standard.integer(forKey: key)
        return skipChoices.contains(saved) ? saved : fallback
    }
    /// Sleep timer: when it stops, or at the end of the chapter.
    private(set) var sleepAt: Date?
    private(set) var sleepAtChapterEnd = false

    /// The TV that plays this book instead of this phone (its name): the player here shows and controls what plays there.
    private(set) var tvName: String?
    @ObservationIgnored private var tvBook: TVLink.Book?
    /// When the TV's last report counts from (ms since 1970, this phone's clock).
    @ObservationIgnored private var tvAt: Double = 0
    @ObservationIgnored private var tvClock: Timer?
    @ObservationIgnored private var tvLoad: Task<Void, Never>?
    @ObservationIgnored private var handoff: Task<Void, Never>?
    @ObservationIgnored private var applyingRemote = false

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var trackIndex = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var listened: Double = 0
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var lastSync = Date()
    @ObservationIgnored private var lastNowPlaying = Date.distantPast
    @ObservationIgnored private var artwork: UIImage?
    @ObservationIgnored private var retriedSession = false
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// A downloaded book plays from its files. With a connection the server also gets a session, for its listening stats.
    @ObservationIgnored private var serverSession: String?

    private var library: AudiobookLibrary? { app?.books }
    var isActive: Bool { session != nil || isLoading }
    var duration: Double { session?.duration ?? 0 }
    var title: String { episode?.title ?? session?.displayTitle ?? item?.title ?? "" }
    var creator: String { item?.title != title ? (item?.title ?? "") : (session?.displayAuthor ?? item?.creator ?? "") }
    var chapters: [ABSChapter] { session?.chapters ?? [] }
    var chapterIndex: Int? { chapters.lastIndex { $0.start <= position + 0.5 } }
    var chapter: ABSChapter? { chapterIndex.map { chapters[$0] } }

    init() {
        #if DEBUG
        // Test hook: -demoSilent plays without sound
        if ProcessInfo.processInfo.arguments.contains("-demoSilent") { player.isMuted = true }
        #endif
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.playStateChanged(playing) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.trackEnded()
            }
        }
        // The app may not get another chance to report where it stopped
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        setupRemoteCommands()
    }

    // MARK: Start and stop

    /// Continues where the server says it stopped, or at `at` (a chapter).
    func play(_ item: ABSItem, episode: ABSEpisode? = nil, at: Double? = nil) {
        if app?.jukeboxHost.running == true {
            app?.notify(String(localized: "Stop the Jukebox to listen to an audiobook."))
            return
        }
        let episode = episode ?? item.recentEpisode
        // The TV is where books play right now: it gets this one, from the server's position unless a spot was given
        if tvName != nil, let tv = app?.tv {
            if self.item?.id == item.id, self.episode?.id == episode?.id {
                if let at { seek(to: at) }
                if !isPlaying { toggle() }
            } else {
                tv.playBook(item: item.id, episode: episode?.id, position: at)
            }
            return
        }
        if self.item?.id == item.id, self.episode?.id == episode?.id, session != nil {
            if let at { seek(to: at) }
            if !isPlaying { toggle() }
            return
        }
        close()
        app?.player.pauseForBook()
        self.item = item
        self.episode = episode
        isLoading = true
        lastError = nil
        retriedSession = false
        artwork = nil
        starting = Task { [weak self] in await self?.open(item: item.id, episode: episode?.id, at: at, autoplay: true) }
    }

    private func open(item: String, episode: String?, at: Double?, autoplay: Bool) async {
        guard let library else { return }
        let saved = library.progress[ABSProgress.key(item, episode)]?.currentTime ?? 0
        if let local = library.downloads.localSession(item: item, episode: episode, position: saved) {
            begin(local, itemId: item, at: at, autoplay: autoplay)
            attachServerSession(item: item, episode: episode, local: local.id)
            return
        }
        do {
            let new = try await library.startSession(item: item, episode: episode)
            guard !Task.isCancelled, self.item?.id == item else {
                try? await library.syncSession(new.id, currentTime: new.currentTime, timeListened: 0, duration: new.duration, close: true)
                return
            }
            begin(new, itemId: item, at: at, autoplay: autoplay)
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            lastError = error.userMessage
            if let message = error.userMessage { app?.notify(message) }
            self.item = nil
            self.episode = nil
        }
    }

    private func begin(_ new: ABSSession, itemId: String, at: Double?, autoplay: Bool) {
        session = new
        isLoading = false
        var start = at ?? new.currentTime
        // Finished earlier: starting it again means from the beginning
        if start >= new.duration - 5 { start = 0 }
        position = start
        lastSync = Date()
        if let item, let library { library.noteListening(item, episode: episode, currentTime: start, duration: new.duration) } // shows up at once
        try? AVAudioSession.sharedInstance().setActive(true)
        configureCommands(active: true)
        loadArtwork(itemId)
        loadTrack(containing: start, autoplay: autoplay)
    }

    private func attachServerSession(item: String, episode: String?, local: String) {
        guard let library else { return }
        Task { [weak self] in
            guard let new = try? await library.startSession(item: item, episode: episode) else { return }
            if self?.session?.id == local { self?.serverSession = new.id }
            else { try? await library.syncSession(new.id, currentTime: new.currentTime, timeListened: 0, duration: new.duration, close: true) }
        }
    }

    /// Stops and reports the final position. Also when music starts playing.
    func close() {
        // The TV keeps playing; this phone only lets go of it (the stop button asks the TV to stop: see `stop`)
        if tvName != nil { endRemote(); return }
        starting?.cancel()
        starting = nil
        let wasActive = session != nil
        if let s = session { report(s, close: true) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        session = nil
        serverSession = nil
        item = nil
        episode = nil
        isLoading = false
        isPlaying = false
        position = 0
        lastTick = nil
        listened = 0
        cancelSleep()
        if wasActive {
            configureCommands(active: false)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            app?.player.bookEnded()
        }
    }

    /// The stop button: ends the book wherever it plays.
    func stop() {
        if tvName != nil { app?.tv.command("bookStop") }
        close()
    }

    // MARK: Files

    /// A book can be many files; all times here count from the start of the whole book.
    private func loadTrack(containing time: Double, autoplay: Bool) {
        guard let s = session else { return }
        let tracks = s.audioTracks
        guard let i = tracks.lastIndex(where: { $0.startOffset <= time + 0.01 }) ?? tracks.indices.first else { return }
        let asset: AVURLAsset
        if s.isLocal {
            guard let file = library?.downloads.localFile(item: s.libraryItemId, episode: s.episodeId, index: tracks[i].index) else { return }
            asset = AVURLAsset(url: file)
        } else {
            guard let server = library?.server, let url = URL(string: "\(server.url)/public/session/\(s.id)/track/\(tracks[i].index)") else { return }
            // The session id in the address is the permission, so no login token ends up in it.
            // Custom headers (e.g. Cloudflare Access) also have to reach the audio itself.
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": server.httpHeaders])
        }
        trackIndex = i
        let new = AVPlayerItem(asset: asset)
        new.audioTimePitchAlgorithm = .timeDomain // speech at another speed keeps its pitch
        itemObservation = new.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.failed(message) }
        }
        player.replaceCurrentItem(with: new)
        let offset = time - tracks[i].startOffset
        if offset > 0.5 { player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        player.defaultRate = rate
        if autoplay { player.play() }
        updateNowPlaying()
    }

    /// Gets the big cover and its color ready while the small player is showing: decoding them only
    /// when the big player opens would make it stutter on the way up.
    func prepareCover() async {
        guard let id = item?.id, coverFor != id, let library else { return }
        coverFor = id
        cover = nil
        coverTint = nil
        guard let image = await library.coverImage(id, width: 900) else { coverFor = nil; return }
        let ready = await image.byPreparingForDisplay() ?? image
        let tint = await Task.detached { ready.averageColor }.value
        guard item?.id == id else { return }
        cover = ready
        coverTint = tint
    }

    /// The address of the server changed: go on from the new one. A book on this iPhone doesn't care.
    func addressChanged() {
        guard let s = session, !s.isLocal, player.currentItem != nil else { return }
        loadTrack(containing: position, autoplay: isPlaying)
    }

    /// The server forgets a session after a while (long pause, restart): ask for a new one and continue.
    private func failed(_ message: String?) {
        guard let s = session, let item else { return }
        if retriedSession {
            player.pause()
            lastError = message
            app?.notify(message ?? String(localized: "This can't be played right now."))
            return
        }
        retriedSession = true
        session = nil
        isLoading = true
        let at = position, episodeId = s.episodeId
        starting = Task { [weak self] in await self?.open(item: item.id, episode: episodeId, at: at, autoplay: true) }
    }

    private func trackEnded() {
        guard let s = session else { return }
        if trackIndex + 1 < s.audioTracks.count {
            let next = s.audioTracks[trackIndex + 1]
            position = next.startOffset
            loadTrack(containing: next.startOffset, autoplay: true)
        } else {
            position = s.duration
            close()
            Task { await library?.load(force: true) }
        }
    }

    // MARK: Controls

    func toggle() {
        guard session != nil else { return }
        if tvName != nil {
            // Shown at once, the TV's report follows
            let now = Date().timeIntervalSince1970 * 1000
            tvBook?.position = position
            tvAt = now
            tvBook?.playing = !isPlaying
            isPlaying.toggle()
            app?.tv.command("bookPlayPause", ["playing": isPlaying])
            return
        }
        if isPlaying {
            player.pause()
            sync()
        } else {
            app?.player.pauseForBook()
            try? AVAudioSession.sharedInstance().setActive(true)
            if player.currentItem == nil || player.currentItem?.status == .failed {
                retriedSession = false
                loadTrack(containing: position, autoplay: true)
            } else {
                player.play()
            }
        }
    }

    func seek(to time: Double) {
        guard let s = session else { return }
        let target = max(0, min(time, s.duration - 1))
        if tvName != nil {
            tvBook?.position = target
            tvAt = Date().timeIntervalSince1970 * 1000
            position = target
            app?.tv.command("bookSeek", ["position": target])
            return
        }
        position = target
        let track = s.audioTracks[trackIndex]
        if target >= track.startOffset, target < track.startOffset + track.duration, player.currentItem != nil {
            player.seek(to: CMTime(seconds: target - track.startOffset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            loadTrack(containing: target, autoplay: isPlaying)
        }
        updateNowPlaying()
    }

    func skip(_ seconds: Double) { seek(to: position + seconds) }

    func nextChapter() {
        guard let i = chapterIndex, i + 1 < chapters.count else { return }
        seek(to: chapters[i + 1].start)
    }

    /// Back to the start of this chapter; right after its start, to the one before.
    func previousChapter() {
        guard let i = chapterIndex else { return seek(to: 0) }
        seek(to: position - chapters[i].start > 5 || i == 0 ? chapters[i].start : chapters[i - 1].start)
    }

    func setSleep(minutes: Int) {
        if tvName != nil { app?.tv.command("bookSleep", ["minutes": minutes]) }
        sleepAt = Date().addingTimeInterval(Double(minutes) * 60); sleepAtChapterEnd = false
    }
    func setSleepAtChapterEnd() {
        if tvName != nil { app?.tv.command("bookSleep", ["mode": "chapter"]) }
        sleepAtChapterEnd = true; sleepAt = nil
    }
    func cancelSleep() {
        if tvName != nil { app?.tv.command("bookSleep", ["minutes": 0]) }
        sleepAt = nil; sleepAtChapterEnd = false
    }

    // MARK: Clock

    private func playStateChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        lastTick = playing ? Date() : nil
        updateNowPlaying()
    }

    private func tick(_ seconds: Double) {
        guard let s = session, player.currentItem != nil, seconds.isFinite, !isLoading else { return }
        let now = Date()
        if player.timeControlStatus == .playing {
            if let lastTick { listened += now.timeIntervalSince(lastTick) }
            lastTick = now
            position = s.audioTracks[trackIndex].startOffset + seconds
            if listened > 0, now.timeIntervalSince(lastSync) >= 15 { sync() }
            if now.timeIntervalSince(lastNowPlaying) >= 5 { updateNowPlaying() }
        } else {
            lastTick = nil
        }
        if let sleepAt, now >= sleepAt { sleepFired() }
        if sleepAtChapterEnd, isPlaying, let chapter, position >= chapter.end - 0.6 { sleepFired() }
    }

    private func sleepFired() {
        cancelSleep()
        player.pause()
        sync()
    }

    func sync() {
        if tvName != nil { return } // the TV reports to the server
        if let session { report(session, close: false) }
    }

    /// Sends the position; what couldn't be sent is added to the next report. Allowed to finish in the background.
    private func report(_ s: ABSSession, close: Bool) {
        guard let library else { return }
        let amount = listened
        let at = position
        listened = 0
        lastSync = Date()
        if let item { library.noteListening(item, episode: episode, currentTime: at, duration: s.duration) }
        if s.isLocal, serverSession == nil {
            library.saveProgress(item: s.libraryItemId, episode: s.episodeId, currentTime: at, duration: s.duration)
            return
        }
        let id = serverSession ?? s.id
        let local = s.isLocal
        let background = UIApplication.shared.beginBackgroundTask(withName: "Audiobook progress")
        Task { [weak self] in
            do {
                try await library.syncSession(id, currentTime: at, timeListened: amount, duration: s.duration, close: close)
            } catch {
                if local { library.saveProgress(item: s.libraryItemId, episode: s.episodeId, currentTime: at, duration: s.duration) }
                if !close { self?.listened += amount }
            }
            // "Continue listening" and the progress bars show the new position
            if close { await library.load(force: true) }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    // MARK: On the TV

    /// News from the TV about a book playing there. `started`: it just began – then it takes over and this phone goes quiet.
    func tvUpdate(_ s: TVLink.State, book b: TVLink.Book, name: String, started: Bool) {
        guard let id = b.id else { return }
        if tvName == nil {
            guard started else { return }
            // The TV has the sound now: a book here would only keep the lock screen, music here would play over it
            if session != nil { close() }
            app?.player.pauseForBook()
            handoff?.cancel()
            tvName = name
            lastError = nil
            tvClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tvTick() }
            }
            configureCommands(active: true)
        }
        tvBook = b
        // From here on the report is on this phone's clock: the TV's or computer's clock may be off
        let now = Date().timeIntervalSince1970 * 1000
        tvAt = now - (s.sent.flatMap { sent in s.at.map { max(0, sent - $0) } } ?? 0)
        if let r = b.rate, Float(r) != rate { applyingRemote = true; rate = Float(r); applyingRemote = false }
        if let left = b.sleep {
            sleepAtChapterEnd = left < 0
            sleepAt = left > 0 ? Date().addingTimeInterval(left / 1000) : nil
        }
        let different = item?.id != id || episode?.id != b.episode
        if different { showRemote(id: id, b) }
        else if let old = session, old.duration != (b.duration ?? old.duration) || old.displayTitle != b.title {
            session = Self.remoteSession(id: id, b, chapters: old.chapters ?? [])
        }
        tvTick()
        if let item { library?.noteListening(item, episode: episode, currentTime: position, duration: duration) }
    }

    /// A stand-in until the real item arrives from the server (with the chapters).
    private func showRemote(id: String, _ b: TVLink.Book) {
        let podcast = b.episode != nil
        let stub: [String: Any] = ["id": id, "mediaType": podcast ? "podcast" : "book",
                                   "media": ["metadata": ["title": podcast ? (b.author ?? "") : (b.title ?? ""), "authorName": podcast ? "" : (b.author ?? "")],
                                             "duration": b.duration ?? 0]]
        item = (try? JSONSerialization.data(withJSONObject: stub)).flatMap { try? JSONDecoder().decode(ABSItem.self, from: $0) }
        episode = nil
        session = Self.remoteSession(id: id, b, chapters: [])
        isLoading = false
        cover = nil
        coverTint = nil
        coverFor = nil
        artwork = nil
        loadArtwork(id)
        tvLoad?.cancel()
        tvLoad = Task { [weak self] in
            guard let full = try? await self?.library?.item(id), !Task.isCancelled, let self, self.tvName != nil, self.item?.id == id,
                  let b = self.tvBook else { return }
            self.item = full
            self.episode = b.episode.flatMap { e in full.media.episodes?.first { $0.id == e } }
            self.session = Self.remoteSession(id: id, b, chapters: full.media.chapters ?? [])
            self.updateNowPlaying()
        }
    }

    private static func remoteSession(id: String, _ b: TVLink.Book, chapters: [ABSChapter]) -> ABSSession {
        ABSSession(id: "tv-" + id, libraryItemId: id, episodeId: b.episode, displayTitle: b.title, displayAuthor: b.author,
                   duration: b.duration ?? 0, currentTime: b.position ?? 0, chapters: chapters, audioTracks: [])
    }

    /// The position counts on from the TV's last report, like a clock – the TV only reports now and then.
    private func tvTick() {
        guard let b = tvBook else { return }
        let since = b.playing == true ? max(0, (Date().timeIntervalSince1970 * 1000 - tvAt) / 1000) * (b.rate ?? 1) : 0
        let p = (b.position ?? 0) + since
        let total = session?.duration ?? 0
        position = total > 0 ? min(p, total) : p
        isPlaying = b.playing == true
        isLoading = b.loading == true
        if Date().timeIntervalSince(lastNowPlaying) >= 5 { updateNowPlaying() }
    }

    /// The TV went away (switched off, app closed): nothing of the book is left here – the server has where it stopped.
    func tvGone() {
        guard tvName != nil else { return }
        endRemote()
    }

    private func endRemote() {
        tvClock?.invalidate()
        tvClock = nil
        tvLoad?.cancel()
        tvName = nil
        tvBook = nil
        applyingRemote = true
        rate = UserDefaults.standard.object(forKey: "book.rate") as? Float ?? 1
        applyingRemote = false
        sleepAt = nil
        sleepAtChapterEnd = false
        session = nil
        item = nil
        episode = nil
        isPlaying = false
        isLoading = false
        position = 0
        configureCommands(active: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        app?.player.bookEnded()
    }

    /// "Play on iPhone": the TV stops, the book goes on here from the same spot.
    func continueHere() {
        guard tvName != nil, let item else { return }
        let ep = episode, at = position
        app?.tv.command("bookStop")
        endRemote()
        play(item, episode: ep, at: at)
    }

    /// The other way round: the book playing here goes on on the own TV, from the same spot. The TV takes over once it
    /// reports playing; if it never does, this phone goes on by itself instead of sitting there silent.
    func playOnTV() {
        guard tvName == nil, let tv = app?.tv, let name = tv.ownBooks, let item, session != nil else { return }
        let at = position
        tv.playBook(item: item.id, episode: episode?.id, position: at)
        guard isPlaying else { return }
        player.pause()
        sync()
        handoff?.cancel()
        handoff = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.tvName == nil, self.session != nil, !self.isPlaying else { return }
            self.app?.notify(String(localized: "\(name) didn't start the audiobook – playing here again."))
            self.toggle()
        }
    }

    // MARK: Lock screen

    private func loadArtwork(_ itemId: String) {
        guard let library, let url = library.coverURL(itemId, width: 600), let server = library.server else { return }
        let headers = server.authorized
        Task { [weak self] in
            let image = await ImageLoader.shared.image(url, headers: headers)
            guard let self, self.item?.id == itemId else { return }
            self.artwork = image
            self.updateNowPlaying()
        }
    }

    func updateNowPlaying() {
        guard session != nil else { return }
        lastNowPlaying = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter?.title ?? title,
            MPMediaItemPropertyArtist: chapter != nil ? title : creator,
            MPMediaItemPropertyAlbumTitle: creator,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: (tvName != nil ? isPlaying : player.timeControlStatus == .playing) ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Play, pause and the position bar come in through PlayerModel, which hands them over while a book runs.
    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBack)]
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
        c.changePlaybackRateCommand.isEnabled = false
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if let self { self.skip(Double(self.skipForward)) } }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if let self { self.skip(-Double(self.skipBack)) } }; return .success }
        c.changePlaybackRateCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.rate = e.playbackRate }
            return .success
        }
    }

    /// A book has skip buttons and a speed; shuffle, repeat, the heart and next song only make sense for music.
    private func configureCommands(active: Bool) {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.isEnabled = active
        c.skipBackwardCommand.isEnabled = active
        c.changePlaybackRateCommand.isEnabled = active
        c.nextTrackCommand.isEnabled = !active
        c.previousTrackCommand.isEnabled = !active
        c.changeShuffleModeCommand.isEnabled = !active
        c.changeRepeatModeCommand.isEnabled = !active
        c.likeCommand.isEnabled = !active
    }
}
