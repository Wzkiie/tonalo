import Foundation
import Network
import Observation

/// Accounts, the active server connection and app settings.
@MainActor
@Observable
final class AppModel {
    /// One instance for the app and for actions run from outside it (lock screen button, Siri)
    static let shared = AppModel()

    private(set) var accounts: [Account] = []
    private(set) var currentId: UUID?
    var showsAccountPicker = false

    /// Streaming quality on Wi-Fi and on mobile data, like the big streaming apps offer it.
    var wifiQuality = AudioQuality.stored("quality.wifi", legacy: "maxBitRate", default: .lossless) {
        didSet { UserDefaults.standard.set(wifiQuality.rawValue, forKey: "quality.wifi") }
    }
    var cellularQuality = AudioQuality.stored("quality.cellular", legacy: "maxBitRate", default: .aac256) {
        didSet { UserDefaults.standard.set(cellularQuality.rawValue, forKey: "quality.cellular") }
    }
    var streamingQuality: AudioQuality { cellularOnly ? cellularQuality : wifiQuality }
    /// Seconds the end of a song overlaps with the start of the next one (0 = off).
    var crossfade: Int = UserDefaults.standard.integer(forKey: "crossfade") {
        didSet { UserDefaults.standard.set(crossfade, forKey: "crossfade") }
    }
    /// Evens out loudness between songs with the ReplayGain tags of the files.
    var volumeLeveling = VolumeLeveling(rawValue: UserDefaults.standard.string(forKey: "volumeLeveling") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(volumeLeveling.rawValue, forKey: "volumeLeveling"); player.levelingChanged() }
    }
    var scrobble: Bool = UserDefaults.standard.object(forKey: "scrobble") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scrobble, forKey: "scrobble") }
    }
    /// When the queue ends, similar songs keep playing (like a radio).
    var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    /// How many of the next songs in the queue are loaded ahead (0 = off).
    var preloadCount: Int = UserDefaults.standard.object(forKey: "preload") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(preloadCount, forKey: "preload"); player.preloadChanged() }
    }

    /// Songs whose heart was changed in this session, by song id – see `isFavorite`.
    var favoriteChanges: [String: Bool] = [:]

    /// Short confirmation shown above the player bar, e.g. "Added to Road trip".
    private(set) var notice: String?

    /// Goes up whenever a playlist is created, changed or deleted here, so lists showing playlists reload.
    private(set) var playlistsVersion = 0
    func playlistsChanged() { playlistsVersion += 1 }

    func notify(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }

    let player = PlayerModel()
    let books = AudiobookLibrary()
    let bookPlayer = BookPlayer()
    /// The TV in the home network that can play for this phone.
    let tv = TVLink()
    /// This phone hosting a Jukebox (in the car, where there's no TV).
    let jukeboxHost = JukeboxHost()
    let downloads = DownloadStore.shared
    let librarySync = LibrarySync()
    /// False when the device has no network – the app then falls back to downloaded music.
    private(set) var isOnline = true
    /// Online, but only over mobile data – downloads wait for Wi-Fi unless cellular is allowed.
    private(set) var cellularOnly = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Wi-Fi, cellular, other or nil when offline – to notice a switch between networks.
    @ObservationIgnored private var network: NWInterface.InterfaceType?
    @ObservationIgnored private var networkKnown = false

    /// On Wi-Fi at home with a home address set and answering: requests go there directly.
    private(set) var atHome = false
    @ObservationIgnored private var routeCheck: Task<Void, Never>?
    /// The network (see LocalNetwork.fingerprint) in which the home address was last confirmed.
    @ObservationIgnored private var homeNetwork: String?
    @ObservationIgnored private var bookHomeNetwork: String?
    @ObservationIgnored private var bookRouteCheck: Task<Void, Never>?

    var current: Account? { accounts.first { $0.id == currentId } }
    var client: SubsonicClient? { current.flatMap { $0.hasMusic ? SubsonicClient(account: $0, atHome: atHome) : nil } }

    init() {
        accounts = Keychain.load([Account].self, key: "accounts") ?? []
        #if DEBUG
        // Test hook for the simulator: launch with -demoAccount to sign in to the public Navidrome demo server,
        // or add -demoServer <url> to use another one (tv/tools/mock_server.js for the README screenshots).
        // Compiled out of release builds.
        // -demoHome <url> and -demoHeader <name=value> set the home address and a custom header (for testing both routes).
        let args = ProcessInfo.processInfo.arguments
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        if args.contains("-demoAccount") {
            let t = SubsonicClient.makeToken(password: "demo")
            var acc = accounts.first ?? Account(serverURL: "https://demo.navidrome.org", username: "demo", salt: t.salt, token: t.token)
            if let server = arg("-demoServer") { acc.serverURL = server }
            acc.localURL = arg("-demoHome")
            if let h = arg("-demoHeader")?.split(separator: "=", maxSplits: 1), h.count == 2 {
                acc.headers = [HeaderField(name: String(h[0]), value: String(h[1]))]
            }
            accounts = [acc]
            persist()
        }
        #endif
        mergeAudiobookAccounts()
        if let s = UserDefaults.standard.string(forKey: "currentAccount"), let id = UUID(uuidString: s), accounts.contains(where: { $0.id == id }) {
            currentId = id
        } else {
            currentId = accounts.first?.id
        }
        player.app = self
        books.app = self
        bookPlayer.app = self
        tv.app = self
        jukeboxHost.app = self
        downloads.app = self
        defer { books.restore() } // finished background downloads may report in before any page opens
        downloads.reload()
        player.restore()
        #if DEBUG
        // Test hook: -demoRadio <genre> starts a genre radio, -demoRadio song one from a random song
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-demoRadio"), i + 1 < ProcessInfo.processInfo.arguments.count, let client {
            let what = ProcessInfo.processInfo.arguments[i + 1]
            Task {
                if what == "song", let song = try? await client.randomSongs(1).first {
                    await player.radio.start("Demo radio", seedId: song.id, first: song)
                } else if what == "end" {
                    // Two songs, the last one almost over: autoplay should take over
                    if let songs = try? await client.randomSongs(2) {
                        player.play(songs, from: 1, context: .init(kind: .mix, name: "Demo"))
                        try? await Task.sleep(for: .seconds(2))
                        player.seek(to: Double(songs[1].duration ?? 180) - 4)
                    }
                    return
                } else {
                    await player.radio.start("Demo radio", genre: what)
                }
                // -demoRadioLow: jump near the end of the radio, so it has to top up the queue
                if ProcessInfo.processInfo.arguments.contains("-demoRadioLow") { player.jump(to: player.queue.count - 3) }
            }
        }
        // Test hook: -demoDJ <ollama address> sets the DJ up against tools/dj_mock.js and starts it;
        // -demoDJChange more|mood|<wish> steers it a few seconds later. Debug builds only – never a key.
        if let address = arg("-demoDJ") {
            let dj = player.dj
            dj.provider = .ollama
            dj.ollamaAddress = address
            dj.model = "mock:latest"
            dj.setEnabled(true)
            Task {
                if args.contains("-demoDJTake"), let songs = try? await client?.randomSongs(6) {
                    // -demoDJTake: something else plays, then the DJ takes over as the symbol in the player does
                    player.play(songs, context: .init(kind: .mix, name: "Demo"))
                    try? await Task.sleep(for: .seconds(2))
                    let problem = await dj.takeOver()
                    NSLog("DJ take: %@ – current kept %d, queue %ld, context %@", problem ?? "ok", player.current?.id == songs[0].id ? 1 : 0, player.queue.count, player.context?.kind.rawValue ?? "-")
                    return
                }
                if args.contains("-demoDJFrom"), let album = try? await client?.albumList("random", size: 1).first, let full = try? await client?.album(album.id) {
                    // -demoDJFrom: start from a random album instead, as the album menu does
                    dj.start(from: full.song ?? [], name: full.name)
                    try? await Task.sleep(for: .seconds(6))
                    NSLog("DJ from %@: queue %ld, first %@, line %@", full.name, player.queue.count, player.queue.first?.title ?? "-", dj.line ?? "-")
                    return
                }
                if let problem = await dj.start(wish: arg("-demoDJWish")) { notify(problem); NSLog("DJ: %@", problem) }
                // -demoDJLow: jump near the end of the set, so the DJ has to ask for the next one
                if args.contains("-demoDJLow") {
                    player.jump(to: player.queue.count - 3)
                    try? await Task.sleep(for: .seconds(5))
                    NSLog("DJ low: queue %ld, context %@", player.queue.count, player.context?.kind.rawValue ?? "-")
                }
                if let how = arg("-demoDJChange") {
                    try? await Task.sleep(for: .seconds(4))
                    let problem = await dj.change(how == "more" ? .more : how == "mood" ? .mood : .wish(how))
                    NSLog("DJ change: %@ upNext %ld line %@", problem ?? "ok", player.upNext.count, dj.line ?? "-")
                }
            }
        }
        // Test hook: -demoPairDJ <url> pairs with the first computer found (the url answers with the code its screen shows)
        // and shares a DJ set up against tools/dj_mock.js with it – the whole way a key would take, without one.
        if let helper = arg("-demoPairDJ"), let url = URL(string: helper) {
            let dj = player.dj
            dj.provider = .ollama
            dj.ollamaAddress = "localhost:11435"
            dj.model = "mock:latest"
            dj.setEnabled(true)
            dj.shareWithDevices = true
            Task {
                for _ in 0..<30 {
                    try? await Task.sleep(for: .seconds(1))
                    guard let pc = tv.devices.first(where: { $0.isPC }) else { continue }
                    if tv.pairing(for: pc) == nil {
                        let started = await tv.startPairing(pc, guest: false)
                        try? await Task.sleep(for: .seconds(1.5))
                        let code = (try? await URLSession.shared.data(from: url)).map { String(decoding: $0.0, as: UTF8.self) } ?? ""
                        let result = await tv.finishPairing(pc, code: code, guest: false)
                        NSLog("DJ pair: start %ld, result %@", started, String(describing: result))
                    } else { NSLog("DJ pair: already paired with %@", pc.name) }
                    return
                }
                NSLog("DJ pair: no computer found")
            }
        }
        // Test hook: -demoQueue fills an empty queue with a few songs, paused – for testing the watch silently
        if ProcessInfo.processInfo.arguments.contains("-demoQueue"), player.current == nil, let client {
            Task { if let songs = try? await client.randomSongs(8) { player.cue(songs, context: .init(kind: .mix, name: "Demo")) } }
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellular = online && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            let network: NWInterface.InterfaceType? = online ? path.availableInterfaces.first?.type ?? .other : nil
            Task { @MainActor in await self?.pathChanged(online: online, cellular: cellular, network: network) }
        }
        #if DEBUG
        // Test hook: the simulator can't switch to mobile data – `notifyutil -p io.github.wzkiie.tonalo.cellular` pretends to
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let app = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in await app.pathChanged(online: true, cellular: true, network: .cellular) }
        }, "io.github.wzkiie.tonalo.cellular" as CFString, nil, .deliverImmediately)
        #endif
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
        // Several accounts: ask who is listening on start, like the TV app
        showsAccountPicker = accounts.count > 1
        librarySync.show(currentId)
    }

    private func pathChanged(online: Bool, cellular: Bool, network: NWInterface.InterfaceType?) async {
        if cellularOnly != cellular { cellularOnly = cellular }
        let cameOnline = online && !isOnline
        if isOnline != online { isOnline = online } // before checkRoute, which only looks for home while online
        checkRoute() // also when switching between Wi-Fi networks
        if networkKnown, self.network != network {
            // After checkRoute, so cancelled requests are sent again to the right address
            ServerSession.shared.networkChanged()
            if player.isPlaying { player.preloadChanged() } // its download was among them
        }
        self.network = network
        networkKnown = true
        if cameOnline { await player.flushScrobbles() }
    }

    /// Checks the login, then stores the account. Replaces an existing one for the same server and user.
    func save(_ account: Account) async throws {
        if account.hasMusic { try await SubsonicClient(account: account).ping() }
        // The same login signed in again stays one account, and keeps what only it knows
        func same(_ a: Account) -> Bool {
            if account.hasMusic { return a.serverURL == account.serverURL && a.username == account.username }
            return !a.hasMusic && a.audiobooks?.url == account.audiobooks?.url && a.username == account.username
        }
        var saved = account
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else if let i = accounts.firstIndex(where: same) {
            saved.id = accounts[i].id
            if saved.audiobooks == nil { saved.audiobooks = accounts[i].audiobooks }
            accounts[i] = saved
        } else {
            accounts.append(account)
        }
        guard persist() else {
            accounts = Keychain.load([Account].self, key: "accounts") ?? []
            throw KeychainError.saveFailed
        }
        select(saved.id)
        checkRoute() // the home address may have changed
    }

    /// Picks the home address or the normal one: the home address only on Wi-Fi, and only if the same server answers there.
    /// Fails closed: in another network than the one home was confirmed in, the outside address is used at once,
    /// and home only again after the check – a plain-http home address must never get the login in a stranger's network.
    func checkRoute() {
        checkBookRoute()
        routeCheck?.cancel()
        let network = LocalNetwork.fingerprint(monitor.currentPath)
        if atHome, network != homeNetwork {
            setAtHome(false)
            ServerSession.shared.networkChanged() // running requests to the home address go outside instead
        }
        guard let account = current, let local = account.localURL, isOnline, !cellularOnly,
              let host = URL(string: local)?.host, SubsonicClient.isLocal(local),
              LocalNetwork.sameSubnet(host) != false else { setAtHome(false); return }
        routeCheck = Task {
            // Asked without the login on both sides: the home address only counts if the same server answers there
            async let home = SubsonicClient(account: account, atHome: true).identity()
            async let outside = SubsonicClient(account: account).identity()
            let key = "server." + account.id.uuidString
            var ok = false
            if let found = await home, !found.hasPrefix("|") {
                if let known = await outside, !known.hasPrefix("|") { UserDefaults.standard.set(known, forKey: key) }
                // Outside not reachable from inside (no hairpin NAT): the last answer from there.
                // Never seen the server from outside yet: no trust – anything could answer at a private address.
                ok = UserDefaults.standard.string(forKey: key) == found
            }
            guard !Task.isCancelled, account.id == currentId else { return }
            // The network mustn't have changed while asking
            ok = ok && LocalNetwork.fingerprint(monitor.currentPath) == network
            homeNetwork = ok ? network : nil
            setAtHome(ok)
        }
    }

    /// The same for Audiobookshelf, which has its own addresses. Fails closed the same way.
    private func checkBookRoute() {
        bookRouteCheck?.cancel()
        let network = LocalNetwork.fingerprint(monitor.currentPath)
        if books.atHome, network != bookHomeNetwork {
            books.setAtHome(false)
            ServerSession.shared.networkChanged()
        }
        guard let id = currentId, let server = current?.audiobooks, let local = server.localURL, isOnline, !cellularOnly,
              let host = URL(string: local)?.host, SubsonicClient.isLocal(local),
              LocalNetwork.sameSubnet(host) != false else { books.setAtHome(false); return }
        bookRouteCheck = Task {
            async let home = AudiobookLibrary.identity(server.route(atHome: true))
            async let outside = AudiobookLibrary.identity(server)
            let key = "bookServer." + id.uuidString
            var ok = false
            if let found = await home {
                if let known = await outside { UserDefaults.standard.set(known, forKey: key) }
                ok = UserDefaults.standard.string(forKey: key) == found
            }
            guard !Task.isCancelled, id == currentId else { return }
            ok = ok && LocalNetwork.fingerprint(monitor.currentPath) == network
            bookHomeNetwork = ok ? network : nil
            books.setAtHome(ok)
        }
    }

    private func setAtHome(_ value: Bool) {
        // Away from home: downloads started at home (maybe before the app was even opened) can't finish there
        if !value, let home = current?.localURL.flatMap({ URL(string: $0)?.host }), home != current?.host {
            downloads.restartTasks(onHost: home)
        }
        guard value != atHome else { return }
        atHome = value
        // Leaving home: a stream from the home address breaks – continue it from the outside one.
        // Arriving home needs nothing: the outside address keeps working, new requests go home anyway.
        if !value { player.addressChanged() }
    }

    /// Music and audiobooks belong in one account: one that only has audiobooks moves into a music account that has none.
    private func mergeAudiobookAccounts() {
        for books in accounts where !books.hasMusic {
            guard let i = accounts.firstIndex(where: { $0.hasMusic && $0.audiobooks == nil }) else { return }
            accounts[i].audiobooks = books.audiobooks
            if UserDefaults.standard.string(forKey: "currentAccount") == books.id.uuidString {
                UserDefaults.standard.set(accounts[i].id.uuidString, forKey: "currentAccount")
            }
            accounts.removeAll { $0.id == books.id }
            persist()
        }
    }

    /// Takes the music server out of the current account; its audiobooks stay.
    func disconnectMusic() {
        guard let i = accounts.firstIndex(where: { $0.id == currentId }), let books = accounts[i].audiobooks else { return }
        let id = accounts[i].id
        player.detach()
        accounts[i].serverURL = ""; accounts[i].localURL = nil; accounts[i].headers = []
        accounts[i].salt = ""; accounts[i].token = ""
        accounts[i].username = books.username
        forgetMusicData(of: id)
        persist()
        downloads.reload()
        librarySync.show(id)
        tv.accountChanged()
        jukeboxHost.accountChanged()
        checkRoute()
    }

    func setAudiobooks(_ server: AudiobookServer?) throws {
        guard let i = accounts.firstIndex(where: { $0.id == currentId }) else { throw AudiobookError.notConnected }
        let old = accounts[i].audiobooks
        accounts[i].audiobooks = server
        if !persist() {
            accounts[i].audiobooks = old
            throw KeychainError.saveFailed
        }
    }

    func select(_ id: UUID) {
        if id != currentId {
            books.accountChanged()
            player.detach()
            ServerSession.shared.networkChanged() // drops the old account's proxy cookies
            atHome = false
            favoriteChanges = [:]
            currentId = id
            UserDefaults.standard.set(id.uuidString, forKey: "currentAccount")
            downloads.reload()
            librarySync.show(id)
            player.restore()
            tv.accountChanged()
            jukeboxHost.accountChanged()
            checkRoute()
        }
        showsAccountPicker = false
    }

    func remove(_ account: Account) {
        if let server = account.audiobooks { books.logout(server) }
        AudiobookFiles.deleteAccount(account.id)
        if account.id == currentId { books.accountChanged(); jukeboxHost.accountChanged(); player.detach() }
        accounts.removeAll { $0.id == account.id }
        forgetMusicData(of: account.id)
        persist()
        if account.id == currentId {
            currentId = accounts.first?.id
            UserDefaults.standard.set(currentId?.uuidString, forKey: "currentAccount")
            atHome = false
            downloads.reload()
            librarySync.show(currentId)
            player.restore()
            tv.accountChanged()
            checkRoute()
        }
    }

    @discardableResult
    private func forgetMusicData(of id: UUID) {
        UserDefaults.standard.removeObject(forKey: "queue." + id.uuidString)
        UserDefaults.standard.removeObject(forKey: "scrobbles." + id.uuidString)
        UserDefaults.standard.removeObject(forKey: "queue.dismissed." + id.uuidString)
        UserDefaults.standard.removeObject(forKey: "server." + id.uuidString)
        Keychain.save([TVLink.Pairing](), key: "tv." + id.uuidString)
        Keychain.save([JukeboxHost.Guest](), key: "jukebox." + id.uuidString)
        ServerSession.shared.networkChanged()
        DownloadStore.deleteAccount(id)
        PlayHistory.forget(id)
        LibraryCache.deleteAccount(id)
        librarySync.forget(id)
        ImageLoader.clearDisk()
    }

    private func persist() -> Bool { Keychain.save(accounts, key: "accounts") }
}

enum KeychainError: LocalizedError {
    case saveFailed
    var errorDescription: String? { String(localized: "The login couldn't be saved securely on this device.") }
}
