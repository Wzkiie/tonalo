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

    /// Streaming quality in kbit/s, 0 = original file.
    var maxBitRate: Int = UserDefaults.standard.integer(forKey: "maxBitRate") {
        didSet { UserDefaults.standard.set(maxBitRate, forKey: "maxBitRate") }
    }
    /// Seconds the end of a song overlaps with the start of the next one (0 = off).
    var crossfade: Int = UserDefaults.standard.integer(forKey: "crossfade") {
        didSet { UserDefaults.standard.set(crossfade, forKey: "crossfade") }
    }
    var scrobble: Bool = UserDefaults.standard.object(forKey: "scrobble") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scrobble, forKey: "scrobble") }
    }

    let player = PlayerModel()
    let downloads = DownloadStore.shared
    /// False when the device has no network – the app then falls back to downloaded music.
    private(set) var isOnline = true
    /// Online, but only over mobile data – downloads wait for Wi-Fi unless cellular is allowed.
    private(set) var cellularOnly = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    var current: Account? { accounts.first { $0.id == currentId } }
    var client: SubsonicClient? { current.map(SubsonicClient.init) }

    init() {
        accounts = Keychain.load([Account].self, key: "accounts") ?? []
        #if DEBUG
        // Test hook for the simulator: launch with -demoAccount to sign in to the public Navidrome demo server.
        // Compiled out of release builds.
        if ProcessInfo.processInfo.arguments.contains("-demoAccount"), accounts.isEmpty {
            let t = SubsonicClient.makeToken(password: "demo")
            accounts = [Account(serverURL: "https://demo.navidrome.org", username: "demo", salt: t.salt, token: t.token)]
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
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellular = online && path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                if self.cellularOnly != cellular { self.cellularOnly = cellular }
                guard self.isOnline != online else { return }
                self.isOnline = online
                if online { await self.player.flushScrobbles() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
        // Several accounts: ask who is listening on start, like the TV app
        showsAccountPicker = accounts.count > 1
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
    }

    func select(_ id: UUID) {
        if id != currentId {
            player.detach()
            currentId = id
            UserDefaults.standard.set(id.uuidString, forKey: "currentAccount")
            downloads.reload()
            player.restore()
        }
        showsAccountPicker = false
    }

    func remove(_ account: Account) {
        if account.id == currentId { player.detach() }
        accounts.removeAll { $0.id == account.id }
        UserDefaults.standard.removeObject(forKey: "queue." + account.id.uuidString)
        UserDefaults.standard.removeObject(forKey: "scrobbles." + account.id.uuidString)
        DownloadStore.deleteAccount(account.id)
        persist()
        if account.id == currentId {
            currentId = accounts.first?.id
            UserDefaults.standard.set(currentId?.uuidString, forKey: "currentAccount")
            downloads.reload()
            player.restore()
        }
    }

    @discardableResult
    private func persist() -> Bool { Keychain.save(accounts, key: "accounts") }
}

enum KeychainError: LocalizedError {
    case saveFailed
    var errorDescription: String? { String(localized: "The login couldn't be saved securely on this device.") }
}
