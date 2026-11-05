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
        /// When the snapshot was taken (ms since 1970, the other side's clock) – the position counts on from there.
        var at: Double?
        /// When this line was sent, on the same clock as `at`: together they don't depend on both clocks being right.
        var sent: Double?
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
        /// This phone is only a guest there: on the TV someone with another account is signed in.
        var jukebox: Bool?
        /// The Audiobookshelf account signed in on the TV, if any – books can be sent there when it's this phone's.
        var abs: Audiobookshelf?
        /// An audiobook or podcast episode playing on the TV (then `active` stays false: no music).
        var book: Book?
    }

    struct Audiobookshelf: Decodable, Hashable {
        var server: String?
        var user: String?
        /// Library ids: the same server shows the same ones, whatever address each side knows it by.
        var libs: [String]?
    }

    struct Book: Decodable {
        var id: String?
        var episode: String?
        var title: String?
        var author: String?
        var chapter: String?
        var chapterIndex: Int?
        var position: Double?
        var duration: Double?
        var playing: Bool?
        var loading: Bool?
        var rate: Double?
        /// Sleep timer on the TV: milliseconds left, -1 at the end of the chapter, 0 off.
        var sleep: Double?
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        /// An iPhone hosting a Jukebox rather than a TV.
        let isPhone: Bool
        /// Tonalo for Windows: works like a TV, but it's a computer.
        let isPC: Bool
        var symbol: String { isPhone ? "iphone" : isPC ? "desktopcomputer" : "tv" }
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

    /// The own TV's name while it's connected and ready – music playing here can move over to it.
    private(set) var ownTV: String?
    /// The own TV is Tonalo on a computer – shown with a computer instead of a TV.
    private(set) var ownIsPC = false
    /// The own TV's name while it's signed in to this account's Audiobookshelf – books can move over to it.
    private(set) var ownBooks: String?
    /// Own TVs where someone with another account is signed in right now: this phone can join their Jukebox.
    private(set) var guestOnly: Set<String> = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var listening: (device: Device, pairing: Pairing)?
    /// Where commands go – kept while the app is in the background, so a pause on the lock screen still reaches the TV.
    @ObservationIgnored private var target: (device: Device, pairing: Pairing)?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Counts connections: an answer to an old one (a command that was slow) must not tear down the new one.
    @ObservationIgnored private var generation = 0
    /// When the other side last reported anything, and when the search began – see `checkGone`.
    @ObservationIgnored private var lastEvent: Date = .distantPast
    @ObservationIgnored private var startedAt: Date = .distantPast
    @ObservationIgnored private var goneCheck: Task<Void, Never>?
    /// TV and server ("id|address") where the server turned out to be this account's under another address –
    /// the TV knows it by its home IP, the phone by its domain. Checked once by asking for a song playing there.
    @ObservationIgnored private var sameServer: Set<String> = []
    @ObservationIgnored private var checking: Set<String> = []

    private var storageKey: String? { app?.current.map { "tv." + $0.id.uuidString } }

    // MARK: Finding

    func start() {
        loadPairings()
        if jukebox == nil, let saved = UserDefaults.standard.array(forKey: "jukebox.joined"), let id = saved.first as? String,
           let at = saved.last as? Double, Date().timeIntervalSince1970 - at < 6 * 3600, pairings.contains(where: { $0.tv == id }) {
            jukebox = id
        }
        startedAt = .now
        checkGone()
        guard browser == nil else { connect(); return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkHTTP.serviceType, domain: nil), using: LinkHTTP.parameters)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Device? in
                guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata, let id = txt["id"] else { return nil }
                return Device(id: id, name: name, endpoint: r.endpoint, isPhone: txt["kind"] == "phone", isPC: txt["kind"] == "pc")
            }
            Task { @MainActor in self?.found(found) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// The app came back and the player still shows a TV: if nothing has been heard from it since – it was switched
    /// off in the meantime, or isn't found any more – the player lets go of it, instead of showing it forever.
    private func checkGone() {
        goneCheck?.cancel()
        goneCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.app?.player.tvName != nil || self.app?.bookPlayer.tvName != nil, self.lastEvent < self.startedAt else { return }
            self.ownTV = nil
            self.ownBooks = nil
            self.app?.player.tvGone()
            self.app?.bookPlayer.tvGone()
        }
    }

    /// Going to the background: the connection ends, the player keeps showing the other side until it's back.
    func stop() {
        browser?.cancel()
        browser = nil
        checking = []
        goneCheck?.cancel()
        generation += 1
        listener?.cancel()
        listener = nil
        listening = nil
        ownTV = nil
        ownBooks = nil
        guestOnly = []
        retry?.cancel()
        devices = []
    }

    func accountChanged() {
        disconnect()
        jukebox = nil
        sameServer = []
        sameBooks = [:]
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
        let body = (try? JSONSerialization.data(withJSONObject: ["device": deviceName, "uid": installId, "guest": guest, "pub": pub.hex,
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

    /// Stays the same for this installation: a Jukebox tells two guests with the same name apart by it.
    private var installId: String {
        if let id = UserDefaults.standard.string(forKey: "link.install") { return id }
        let id = LinkHTTP.random(8).hex
        UserDefaults.standard.set(id, forKey: "link.install")
        return id
    }

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
        generation += 1
        checking = []
        listener?.cancel()
        listener = nil
        listening = nil
        target = nil
        ownTV = nil
        ownBooks = nil
        retry?.cancel()
        app?.player.tvGone()
        app?.bookPlayer.tvGone()
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
        generation += 1
        listener = Task { [weak self] in
            // A dropped connection gets a few more tries before the phone takes over again
            var misses = 0
            while misses < 3, !Task.isCancelled, let self, self.devices.contains(where: { $0.id == device.id }) {
                // The address can change (Wi-Fi switched, TV got a new IP): always the one Bonjour knows now
                let device = self.devices.first { $0.id == device.id } ?? device
                let got = await self.follow(device, pairing)
                misses = got ? 0 : misses + 1
                guard !Task.isCancelled else { break }
                // Connected but not a word came back: it accepts connections (or the router does) and nothing answers – gone too
                if !got { self.ownTV = nil; self.ownBooks = nil; self.app?.player.tvGone(); self.app?.bookPlayer.tvGone() }
                // The stream ended: unless the TV answers again right away it's gone – the player lets go of it now
                // instead of showing music that isn't playing until the last try has failed
                if !(await self.reachable(device)) { self.ownTV = nil; self.ownBooks = nil; self.app?.player.tvGone(); self.app?.bookPlayer.tvGone() }
                try? await Task.sleep(for: .seconds(2))
            }
            guard let self, !Task.isCancelled else { return }
            self.listener = nil
            self.listening = nil
            self.target = nil
            self.ownBooks = nil
            self.app?.player.tvGone()
            self.app?.bookPlayer.tvGone()
            // A Jukebox that dropped out (the host's phone locked for a moment) is joined again once it's back
            self.retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.browser != nil else { return }
                self.connect()
            }
        }
    }

    /// A quick check whether the other side still answers (a signed request would need the key; opening the connection is enough).
    private func reachable(_ device: Device) async -> Bool {
        let c = LinkConnection(device.endpoint)
        defer { c.close() }
        return (try? await c.open(timeout: 8)) != nil
    }

    /// The other side doesn't answer: let go of it at once and look again, instead of showing music that isn't playing.
    private func lost(_ gen: Int? = nil) {
        guard listener != nil, gen == nil || gen == generation else { return }
        generation += 1
        listener?.cancel()
        listener = nil
        listening = nil
        ownTV = nil
        ownBooks = nil
        app?.player.tvGone()
        app?.bookPlayer.tvGone()
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.browser != nil else { return }
            self.connect()
        }
    }

    /// True when anything came from the other side before the connection ended.
    private func follow(_ device: Device, _ pairing: Pairing) async -> Bool {
        guard let key = Data(hex: pairing.key) else { return false }
        listening = (device, pairing)
        target = (device, pairing)
        // Joined as a guest: a Jukebox – or the own TV while someone else is signed in there
        let guest = pairing.guest == true || jukebox == device.id
        var wasPlaying = false, first = true
        var wasBookPlaying = false, firstBook = true
        var latest: State? // the newest report – the server check below can take a moment, the old one would be stale
        let auth = LinkHTTP.authorization("GET", "/events", body: Data(), keyId: pairing.keyId, key: key, offset: clockOffset[pairing.tv] ?? 0)
        // What the other side reports, shown here – again once the server check below says it's the same server
        func apply(_ s: State) {
            self.lastEvent = .now
            if pairing.guest != true {
                if s.jukebox == true { self.guestOnly.insert(device.id) } else { self.guestOnly.remove(device.id) }
                // Joined as a guest, and now the TV is back on this account: it's the own TV again
                if guest, s.jukebox != true { Task { @MainActor in self.leave() }; return }
            }
            if !guest {
                // Someone else is signed in on the TV: nothing of theirs shows here until this phone joins
                guard s.jukebox != true else { self.ownTV = nil; self.ownBooks = nil; self.app?.player.tvGone(); self.app?.bookPlayer.tvGone(); first = false; return }
                self.ownTV = device.name
                self.ownIsPC = device.isPC
                // Audiobooks: the TV has the same Audiobookshelf account, so a book can go there and come back
                let booksSame = self.booksMatch(s, device: device.id) {
                    if !Task.isCancelled, self.listening?.device.id == device.id, let now = latest { firstBook = true; wasBookPlaying = false; apply(now) }
                }
                self.ownBooks = booksSame ? device.name : nil
                if booksSame, let b = s.book, b.id != nil {
                    let local = self.app?.bookPlayer.tvName == nil && self.app?.bookPlayer.isPlaying == true
                    let bookPlaying = b.playing == true
                    self.app?.bookPlayer.tvUpdate(s, book: b, name: device.name, started: bookPlaying && (firstBook ? !local : !wasBookPlaying))
                    wasBookPlaying = bookPlaying
                    firstBook = false
                    self.app?.player.tvGone() // the TV plays a book now, not the music this phone mirrored
                    wasPlaying = false
                    first = false
                    return
                } else {
                    if self.app?.bookPlayer.tvName != nil { self.app?.bookPlayer.tvGone() }
                    wasBookPlaying = false
                    firstBook = false
                }
            }
            let playing = s.active && s.playing == true
            let same = self.matches(s, guest: guest, device: device.id)
            if s.active, !same {
                // Once it turns out to be the same server (the TV knows it by its IP, the phone by its domain) this is like
                // connecting anew: the TV takes over if it plays – not only at its next pause and play
                self.checkServer(s, device: device.id) {
                    if !Task.isCancelled, self.listening?.device.id == device.id, let now = latest { first = true; wasPlaying = false; apply(now) }
                }
            }
            if guest {
                // A guest follows the Jukebox all the time, also before anything plays there – what it picks is the first song
                if !s.active || same { self.app?.player.tvUpdate(s, name: device.name, guest: true, started: true) }
            } else if s.active && same {
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
        let status = await LinkHTTP.stream(device.endpoint, "/events", headers: ["Authorization": auth]) { line in
            guard line.starts(with: Data("data: ".utf8)), let s = try? JSONDecoder().decode(State.self, from: Data(line.dropFirst(6))) else { return }
            guard !Task.isCancelled else { return }
            latest = s
            apply(s)
        }
        if !guest { ownTV = nil; ownBooks = nil }
        // The other side forgot this phone – but not when only its clock is off: then the next try uses its time
        if status?.status == 401 {
            if !learnClock(status?.body, pairing.tv) { unpair(pairing.tv) }
            return false
        }
        return !first
    }

    /// The own TV: same account on the same server – another person's music is none of this phone's business.
    /// A Jukebox: the same server, so the songs added are there too.
    private func matches(_ s: State, guest: Bool, device: String) -> Bool {
        guard let acc = app?.current, let server = s.server else { return false }
        if !guest && s.user != acc.username { return false }
        if sameServer.contains(device + "|" + server) { return true }
        func norm(_ url: String?) -> String? {
            guard let url, let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let host = u.host?.lowercased() else { return nil }
            return host + ":" + String(u.port ?? (u.scheme == "https" ? 443 : 80))
        }
        let other = norm(server)
        return other != nil && (other == norm(acc.serverURL) || other == norm(acc.localURL))
    }

    /// The TV is signed in to this account's Audiobookshelf: the same user, and the same server – by its libraries,
    /// which don't depend on the address, or else by the address itself. The libraries are asked for once; until the
    /// answer is there this says no, and `recheck` runs when it has come.
    private func booksMatch(_ s: State, device: String, recheck: @escaping () -> Void) -> Bool {
        guard let mine = app?.current?.audiobooks, let theirs = s.abs, let user = theirs.user,
              user.caseInsensitiveCompare(mine.username) == .orderedSame else { return false }
        func norm(_ url: String?) -> String? {
            guard let url, let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let host = u.host?.lowercased() else { return nil }
            return host + ":" + String(u.port ?? (u.scheme == "https" ? 443 : 80))
        }
        let other = norm(theirs.server)
        if other != nil, other == norm(mine.url) || other == norm(mine.localURL) { return true }
        guard let libs = theirs.libs, !libs.isEmpty else { return false }
        let key = device + "|" + libs.joined(separator: ",")
        if let known = sameBooks[key] { return known }
        if checkingBooks.insert(key).inserted {
            Task { @MainActor in
                let ids = await self.app?.books.libraryIds() ?? []
                // No answer (no connection): not remembered, the next report asks again
                if !ids.isEmpty { self.sameBooks[key] = !Set(ids).isDisjoint(with: libs) }
                self.checkingBooks.remove(key)
                if !ids.isEmpty { recheck() }
            }
        }
        return false
    }
    @ObservationIgnored private var sameBooks: [String: Bool] = [:]
    @ObservationIgnored private var checkingBooks: Set<String> = []

    /// The address differs: asks this account's server for a song playing over there. If it knows it, it's the same server.
    private func checkServer(_ s: State, device: String, then: @escaping () -> Void) {
        guard let server = s.server, let client = app?.client else { return }
        let key = device + "|" + server
        let songs = s.queue ?? []
        guard let song = songs.indices.contains(s.index ?? -1) ? songs[s.index ?? 0] : songs.first,
              !sameServer.contains(key), checking.insert(key).inserted else { return }
        Task {
            // Asked once per connection: an unknown song stays a different server until the phone connects again
            if (try? await client.call("getSong", ["id": song.id])) != nil { sameServer.insert(key); then() }
            else {
                // Not known – or the request failed: asked again after a while, not with every report
                try? await Task.sleep(for: .seconds(30))
                checking.remove(key)
            }
        }
    }

    // MARK: Commands

    /// Plays songs over there, like PlayerModel.play does here. Very long lists go as a window around the start.
    /// `at`: where in the first song to begin – for music moving over from this phone.
    func play(_ songs: [Song], from start: Int, shuffled: Bool, context: PlayerModel.Context?, at: Double = 0) {
        let from = max(0, min(start - 100, songs.count - 500))
        let window = Array(songs[from..<min(songs.count, from + 500)])
        var cmd: [String: Any] = ["cmd": "play", "songs": json(window), "index": start - from, "shuffle": shuffled, "position": at]
        if let context { cmd["context"] = ["kind": context.kind.rawValue, "name": context.name, "id": context.id as Any] }
        command(cmd)
    }

    func play(_ station: Station, in list: [Station]) {
        command(["cmd": "station", "station": json(station), "list": json(list)])
    }

    /// Starts an audiobook or episode over there, `position` seconds into it.
    func playBook(item: String, episode: String?, position: Double?) {
        var cmd: [String: Any] = ["cmd": "bookPlay", "itemId": item, "user": app?.current?.audiobooks?.username ?? ""]
        if let episode { cmd["episodeId"] = episode }
        if let position { cmd["position"] = position }
        command(cmd)
    }

    func command(_ name: String, _ extra: [String: Any] = [:]) {
        command(extra.merging(["cmd": name]) { $1 })
    }

    func add(_ songs: [Song], next: Bool) {
        command(next ? "playNext" : "enqueue", ["songs": json(Array(songs.prefix(200)))])
    }

    private func command(_ cmd: [String: Any]) {
        guard let (found, pairing) = listening ?? target, let key = Data(hex: pairing.key),
              let body = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        let device = devices.first { $0.id == found.id } ?? found
        let gen = generation
        Task {
            var answer: LinkHTTP.Response?
            // Twice at most: the second time with the other side's clock, if only that was off
            for _ in 0..<2 {
                let auth = LinkHTTP.authorization("POST", "/command", body: body, keyId: pairing.keyId, key: key, offset: clockOffset[pairing.tv] ?? 0)
                answer = try? await LinkHTTP.request(device.endpoint, "POST", "/command", body: body, headers: ["Authorization": auth])
                guard answer?.status == 401, learnClock(answer?.body, pairing.tv) else { break }
            }
            guard answer?.status != 200 else { return }
            app?.player.lastError = String(localized: "\(device.name) isn't answering.")
            guard gen == generation, listening?.device.id == device.id else { return }
            if answer == nil, !(await reachable(device)) { lost(gen); return } // nothing came back and it doesn't open: off or away
            // What the phone showed in advance (paused, moved on) didn't happen over there: look at the real state again
            generation += 1
            listener?.cancel()
            listener = nil
            listening = nil
            connect()
        }
    }

    /// How far each TV's or computer's clock is off from this phone's – learned when it turns a request down for the time.
    @ObservationIgnored private var clockOffset: [String: TimeInterval] = [:]

    /// True when the other side only turned the request down for the time; from now on its time is used.
    private func learnClock(_ body: Data?, _ tv: String) -> Bool {
        guard let body, let p = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], p["error"] as? String == "clock" else { return false }
        if let now = p["now"] as? Double { clockOffset[tv] = now - Date().timeIntervalSince1970 }
        return true
    }

    private func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }
}
