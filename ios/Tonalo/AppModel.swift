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

    var current: Account? { accounts.first { $0.id == currentId } }
    var client: SubsonicClient? { current.map { SubsonicClient(account: $0, atHome: atHome) } }

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
        if let s = UserDefaults.standard.string(forKey: "currentAccount"), let id = UUID(uuidString: s), accounts.contains(where: { $0.id == id }) {
            currentId = id
        } else {
            currentId = accounts.first?.id
        }
        player.app = self
        downloads.app = self
        downloads.reload()
        player.restore()
        #if DEBUG
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
        checkRoute() // also when switching between Wi-Fi networks
        if networkKnown, self.network != network {
            // After checkRoute, so cancelled requests are sent again to the right address
            ServerSession.shared.networkChanged()
            if player.isPlaying { player.preloadChanged() } // its download was among them
        }
        self.network = network
        networkKnown = true
        guard isOnline != online else { return }
        isOnline = online
        if online { await player.flushScrobbles() }
    }

    /// Checks the login, then stores the account. Replaces an existing one for the same server and user.
    func save(_ account: Account) async throws {
        try await SubsonicClient(account: account).ping()
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else if let i = accounts.firstIndex(where: { $0.serverURL == account.serverURL && $0.username == account.username }) {
            var a = account; a.id = accounts[i].id
            accounts[i] = a
        } else {
            accounts.append(account)
        }
        guard persist() else {
            accounts = Keychain.load([Account].self, key: "accounts") ?? []
            throw KeychainError.saveFailed
        }
        select(accounts.first { $0.serverURL == account.serverURL && $0.username == account.username }!.id)
        checkRoute() // the home address may have changed
    }

    /// Picks the home address or the normal one: the home address only on Wi-Fi, and only if it answers.
    func checkRoute() {
        routeCheck?.cancel()
        guard let account = current, account.localURL != nil, isOnline, !cellularOnly else { setAtHome(false); return }
        routeCheck = Task {
            let ok = await SubsonicClient(account: account, atHome: true).reachable()
            guard !Task.isCancelled, account.id == currentId else { return }
            setAtHome(ok)
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

    func select(_ id: UUID) {
        if id != currentId {
            player.detach()
            atHome = false
            favoriteChanges = [:]
            currentId = id
            UserDefaults.standard.set(id.uuidString, forKey: "currentAccount")
            downloads.reload()
            librarySync.show(id)
            player.restore()
            checkRoute()
        }
        showsAccountPicker = false
    }

    func remove(_ account: Account) {
        if account.id == currentId { player.detach() }
        accounts.removeAll { $0.id == account.id }
        UserDefaults.standard.removeObject(forKey: "queue." + account.id.uuidString)
        UserDefaults.standard.removeObject(forKey: "scrobbles." + account.id.uuidString)
        UserDefaults.standard.removeObject(forKey: "queue.dismissed." + account.id.uuidString)
        DownloadStore.deleteAccount(account.id)
        LibraryCache.deleteAccount(account.id)
        librarySync.forget(account.id)
        ImageLoader.clearDisk()
        persist()
        if account.id == currentId {
            currentId = accounts.first?.id
            UserDefaults.standard.set(currentId?.uuidString, forKey: "currentAccount")
            atHome = false
            downloads.reload()
            librarySync.show(currentId)
            player.restore()
            checkRoute()
        }
    }

    @discardableResult
    private func persist() -> Bool { Keychain.save(accounts, key: "accounts") }
}

enum KeychainError: LocalizedError {
    case saveFailed
    var errorDescription: String? { String(localized: "The login couldn't be saved securely on this device.") }
}
