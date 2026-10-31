import CryptoKit
import Foundation
import Network
import Observation
import UIKit

/// Tonalo on another device nearby: a TV, or an iPhone hosting a Jukebox.
/// - Your own TV (same account): while it plays, the player here shows what plays there, and music picked
///   on the phone plays on the TV.
/// - A Jukebox (someone else's TV or iPhone, same server): you see what plays, add songs and skip.
/// Found with Bonjour, in the home network or directly phone to phone. Paired once with a code from the
/// other screen; both sides work out a key that never goes over the network (see LinkHTTP), and every request
/// is signed with it, so nobody else nearby can send anything. Nothing goes through the internet.
/// What plays isn't encrypted – someone in the same Wi-Fi who listens in could see song titles, not more.
@MainActor
@Observable
final class TVLink {
    /// What the other side reports – the fields of Link.snapshot() in tv/app/js/link.js and JukeboxHost.snapshot().
    struct State: Decodable {
        struct Source: Decodable { var kind: String?; var id: String?; var name: String? }
        var active: Bool
        var user: String?
        var server: String?
        var playing: Bool?
        var position: Double?
        var duration: Double?
        /// When the snapshot was taken (ms since 1970) – the position counts on from there.
        var at: Double?
        var station: Station?
        var queue: [Song]?
        var index: Int?
        /// Where `queue` starts in the whole queue (only a window around the current song is sent).
        var offset: Int?
        var shuffle: Bool?
        var `repeat`: String?
        var context: Source?
        /// Guests of a Jukebox, by name.
        var guests: [String]?
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        /// An iPhone hosting a Jukebox rather than a TV.
        let isPhone: Bool
    }

    struct Pairing: Codable, Hashable {
        var tv: String
        var name: String
        var keyId: String
        var key: String
        /// Paired as a Jukebox guest: may add songs and skip, nothing more.
        var guest: Bool?
    }

    enum PairResult { case ok, wrongCode, expired, failed }

    @ObservationIgnored weak var app: AppModel?
    /// Devices with Tonalo found nearby right now – this phone's own Jukebox not among them.
    private(set) var devices: [Device] = []
    /// Devices paired with the current account.
    private(set) var pairings: [Pairing] = []
    /// The Jukebox this phone has joined as a guest (its device id), until it leaves. Kept for a few hours,
    /// so a guest whose app was closed on a long drive is back in by itself.
    private(set) var jukebox: String? {
        didSet {
            if let jukebox { UserDefaults.standard.set([jukebox, Date().timeIntervalSince1970], forKey: "jukebox.joined") }
            else { UserDefaults.standard.removeObject(forKey: "jukebox.joined") }
        }
    }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var listening: (device: Device, pairing: Pairing)?
    /// Where commands go – kept while the app is in the background, so a pause on the lock screen still reaches the TV.
    @ObservationIgnored private var target: (device: Device, pairing: Pairing)?
    @ObservationIgnored private var retry: Task<Void, Never>?

    private var storageKey: String? { app?.current.map { "tv." + $0.id.uuidString } }

    // MARK: Finding

    func start() {
        loadPairings()
        if jukebox == nil, let saved = UserDefaults.standard.array(forKey: "jukebox.joined"), let id = saved.first as? String,
           let at = saved.last as? Double, Date().timeIntervalSince1970 - at < 6 * 3600, pairings.contains(where: { $0.tv == id }) {
            jukebox = id
        }
        guard browser == nil else { connect(); return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkHTTP.serviceType, domain: nil), using: LinkHTTP.parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Device? in
                guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata, let id = txt["id"] else { return nil }
                return Device(id: id, name: name, endpoint: r.endpoint, isPhone: txt["kind"] == "phone")
            }
            Task { @MainActor in self?.found(found) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Going to the background: the connection ends, the player keeps showing the other side until it's back.
    func stop() {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        listening = nil
        retry?.cancel()
        devices = []
    }

    func accountChanged() {
        disconnect()
        jukebox = nil
        loadPairings()
        connect()
    }

    private func found(_ list: [Device]) {
        // A device in the network more than one way (Wi-Fi and cable, or peer to peer) shows up once
        var seen = Set<String>()
        devices = list.filter { $0.id != app?.jukeboxHost.id && seen.insert($0.id).inserted }
        connect()
    }

    // MARK: Pairing

    func pairing(for device: Device) -> Pairing? { pairings.first { $0.tv == device.id } }

    /// Asks the other side to show a code. The answer's status: 200 shows the code, 503 means Tonalo on the TV
    /// isn't ready yet (no one chosen there), 0 means no answer.
    func startPairing(_ device: Device, guest: Bool) async -> Int {
        let body = (try? JSONSerialization.data(withJSONObject: ["guest": guest, "device": deviceName])) ?? Data()
        return (try? await LinkHTTP.request(device.endpoint, "POST", "/pair/start", body: body))?.status ?? 0
    }

    func finishPairing(_ device: Device, code: String, guest: Bool) async -> PairResult {
        let mine = P256.KeyAgreement.PrivateKey()
        let pub = mine.publicKey.x963Representation
        let body = (try? JSONSerialization.data(withJSONObject: ["device": deviceName, "guest": guest, "pub": pub.hex,
                                                                 "proof": LinkHTTP.proof(code: code, pub: pub).hex])) ?? Data()
        guard let r = try? await LinkHTTP.request(device.endpoint, "POST", "/pair/finish", body: body) else { return .failed }
        switch r.status {
        case 200:
            struct Answer: Decodable { var id: String; var pub: String; var tv: String; var name: String }
            guard let a = try? JSONDecoder().decode(Answer.self, from: r.body), let other = Data(hex: a.pub),
                  let key = LinkHTTP.pairingKey(mine, other: other, code: code) else { return .failed }
            pairings.removeAll { $0.tv == a.tv }
            pairings.append(Pairing(tv: a.tv, name: a.name, keyId: a.id, key: key.hex, guest: guest))
            savePairings()
            if guest { join(device) } else { connect() }
            return .ok
        case 403: return .wrongCode
        case 410, 429: return .expired
        default: return .failed
        }
    }

    func unpair(_ tv: String) {
        pairings.removeAll { $0.tv == tv }
        savePairings()
        if jukebox == tv { jukebox = nil }
        if listening?.pairing.tv == tv { disconnect() }
        if target?.pairing.tv == tv { target = nil }
    }

    /// The name others see when this phone pairs or adds songs: the account's user name, which they know anyway.
    private var deviceName: String { app?.current?.username ?? UIDevice.current.name }

    private func loadPairings() {
        pairings = storageKey.flatMap { Keychain.load([Pairing].self, key: $0) } ?? []
    }

    private func savePairings() {
        if let key = storageKey { Keychain.save(pairings, key: key) }
    }

    // MARK: Jukebox as a guest

    /// Joins a Jukebox this phone is paired with as a guest: from now on the player here shows it.
    func join(_ device: Device) {
        disconnect()
        jukebox = device.id
        connect()
    }

    func leave() {
        jukebox = nil
        disconnect()
        connect()
    }

    // MARK: Live

    private func disconnect() {
        listener?.cancel()
        listener = nil
        listening = nil
        target = nil
        retry?.cancel()
        app?.player.tvGone()
    }

    /// Follows the joined Jukebox, or else the first own TV nearby: its state comes in as long as the connection lasts.
    private func connect() {
        guard listener == nil else { return }
        let target: (Device, Pairing)?
        if let jukebox {
            target = devices.first { $0.id == jukebox }.flatMap { d in pairing(for: d).map { (d, $0) } }
        } else {
            target = devices.lazy.compactMap { d in self.pairing(for: d).flatMap { $0.guest == true ? nil : (d, $0) } }.first
        }
        guard let (device, pairing) = target else { return }
        listener = Task { [weak self] in
            // A dropped connection gets a few more tries before the phone takes over again
            var misses = 0
            while misses < 3, !Task.isCancelled, let self, self.devices.contains(where: { $0.id == device.id }) {
                misses = await self.follow(device, pairing) ? 0 : misses + 1
                try? await Task.sleep(for: .seconds(2))
            }
            guard let self, !Task.isCancelled else { return }
            self.listener = nil
            self.listening = nil
            self.target = nil
            self.app?.player.tvGone()
            // A Jukebox that dropped out (the host's phone locked for a moment) is joined again once it's back
            self.retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.browser != nil else { return }
                self.connect()
            }
        }
    }

    /// True when anything came from the other side before the connection ended.
    private func follow(_ device: Device, _ pairing: Pairing) async -> Bool {
        guard let key = Data(hex: pairing.key) else { return false }
        listening = (device, pairing)
        target = (device, pairing)
        let guest = pairing.guest == true
        var wasPlaying = false, first = true
        let auth = LinkHTTP.authorization("GET", "/events", body: Data(), keyId: pairing.keyId, key: key)
        let status = await LinkHTTP.stream(device.endpoint, "/events", headers: ["Authorization": auth]) { line in
            guard line.starts(with: Data("data: ".utf8)), let s = try? JSONDecoder().decode(State.self, from: Data(line.dropFirst(6))) else { return }
            guard !Task.isCancelled else { return }
            let playing = s.active && s.playing == true
            if guest {
                // A guest follows the Jukebox all the time, also before anything plays there – what it picks is the first song
                if !s.active || self.matches(s, guest: true) { self.app?.player.tvUpdate(s, name: device.name, guest: true, started: true) }
            } else if s.active && self.matches(s, guest: false) {
                // The own TV takes over when it starts playing – or, right after connecting, when it plays and this
                // phone doesn't: music playing here isn't cut off just because the app came back to the front
                let local = self.app?.player.tvName == nil && self.app?.player.isPlaying == true
                self.app?.player.tvUpdate(s, name: device.name, guest: false, started: playing && (first ? !local : !wasPlaying))
            } else {
                self.app?.player.tvGone()
            }
            wasPlaying = playing
            first = false
        }
        // The other side forgot this phone – but not when only its clock is off
        if status?.status == 401, !String(decoding: status?.body ?? Data(), as: UTF8.self).contains("clock") { unpair(pairing.tv) }
        return !first
    }

    /// The own TV: same account on the same server – another person's music is none of this phone's business.
    /// A Jukebox: the same server, so the songs added are there too.
    private func matches(_ s: State, guest: Bool) -> Bool {
        guard let acc = app?.current, let server = s.server else { return false }
        if !guest && s.user != acc.username { return false }
        func norm(_ url: String?) -> String? {
            guard let url, let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let host = u.host?.lowercased() else { return nil }
            return host + ":" + String(u.port ?? (u.scheme == "https" ? 443 : 80))
        }
        let other = norm(server)
        return other != nil && (other == norm(acc.serverURL) || other == norm(acc.localURL))
    }

    // MARK: Commands

    /// Plays songs over there, like PlayerModel.play does here. Very long lists go as a window around the start.
    func play(_ songs: [Song], from start: Int, shuffled: Bool, context: PlayerModel.Context?) {
        let from = max(0, min(start - 100, songs.count - 500))
        let window = Array(songs[from..<min(songs.count, from + 500)])
        var cmd: [String: Any] = ["cmd": "play", "songs": json(window), "index": start - from, "shuffle": shuffled]
        if let context { cmd["context"] = ["kind": context.kind.rawValue, "name": context.name, "id": context.id as Any] }
        command(cmd)
    }

    func play(_ station: Station, in list: [Station]) {
        command(["cmd": "station", "station": json(station), "list": json(list)])
    }

    func command(_ name: String, _ extra: [String: Any] = [:]) {
        command(extra.merging(["cmd": name]) { $1 })
    }

    func add(_ songs: [Song], next: Bool) {
        command(next ? "playNext" : "enqueue", ["songs": json(Array(songs.prefix(200)))])
    }

    private func command(_ cmd: [String: Any]) {
        guard let (device, pairing) = listening ?? target, let key = Data(hex: pairing.key),
              let body = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        let auth = LinkHTTP.authorization("POST", "/command", body: body, keyId: pairing.keyId, key: key)
        Task {
            let status = (try? await LinkHTTP.request(device.endpoint, "POST", "/command", body: body, headers: ["Authorization": auth]))?.status
            if status != 200 { app?.player.lastError = String(localized: "\(device.name) isn't answering.") }
        }
    }

    private func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }
}
