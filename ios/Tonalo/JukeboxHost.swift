import CryptoKit
import Foundation
import Network
import Observation
import UIKit

/// This iPhone hosts a Jukebox – for the car, where there's no TV: guests nearby find it (directly phone to
/// phone, no Wi-Fi needed), join with a code shown here, see what plays, add songs and skip. Speaks the same
/// small protocol as the TV (tv/service/service.js). Only runs while switched on.
@MainActor
@Observable
final class JukeboxHost {
    struct Guest: Codable, Hashable {
        var keyId: String
        var key: String
        var name: String
    }

    /// A guest wants to join: the code to show on this phone.
    struct Request: Identifiable, Equatable {
        let name: String
        let code: String
        var id: String { code }
    }

    @ObservationIgnored weak var app: AppModel?
    private(set) var running = false
    private(set) var request: Request?
    /// Guests paired with the current account.
    private(set) var guests: [Guest] = []
    /// Guests connected right now, by name.
    private(set) var present: [String] = []
    /// Stable id of this phone's Jukebox – lets the phone skip itself in the list of devices nearby.
    let id: String = {
        if let id = UserDefaults.standard.string(forKey: "jukeboxId") { return id }
        let id = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        UserDefaults.standard.set(id, forKey: "jukeboxId")
        return id
    }()

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var streams: [(connection: LinkConnection, guest: Guest)] = []
    @ObservationIgnored private var pairing: (code: String, until: Date, tries: Int)?
    /// Wrong codes over all pairings – after 15, pairing is closed for 10 minutes, so guessing gets nowhere.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lockedUntil = Date.distantPast
    /// Requests already used: one recorded by someone else doesn't go through a second time.
    @ObservationIgnored private var nonces: [String: Date] = [:]
    @ObservationIgnored private var connections = 0
    @ObservationIgnored private var sync: Timer?
    @ObservationIgnored private var ticks = 0
    /// What the guests were told last, to notice a jump (seeking) between the regular updates.
    @ObservationIgnored private var told: (position: Double, at: Date, playing: Bool)?
    /// Counts up with every start, so an observation left from before a restart ends by itself.
    @ObservationIgnored private var generation = 0

    private var storageKey: String? { app?.current.map { "jukebox." + $0.id.uuidString } }
    /// What everyone nearby sees before pairing – no user name, that's for those who joined.
    let name = "Tonalo Jukebox"

    // MARK: Switching on and off

    func start() {
        guard !running else { return }
        guests = storageKey.flatMap { Keychain.load([Guest].self, key: $0) } ?? []
        guard let l = try? NWListener(using: LinkHTTP.parameters) else { return }
        l.service = NWListener.Service(name: name, type: LinkHTTP.serviceType, txtRecord: NWTXTRecord(["id": id, "kind": "phone"]))
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in await self?.handle(LinkConnection(c)) }
        }
        l.stateUpdateHandler = { [weak self] state in
            // No local network permission, or the system took the listener away: off, so the switch says so
            if case .failed = state { Task { @MainActor in self?.stop() } }
        }
        l.start(queue: .main)
        listener = l
        running = true
        generation += 1
        watchPlayer(generation)
        // The position counts on by itself on the guests' phones – it's only corrected now and then, or when it jumped
        sync = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sync?.invalidate()
        sync = nil
        streams.forEach { $0.connection.close() }
        streams = []
        present = []
        request = nil
        pairing = nil
        running = false
    }

    func accountChanged() {
        if running { stop() }
    }

    func remove(_ guest: Guest) {
        guests.removeAll { $0.keyId == guest.keyId }
        save()
        for s in streams where s.guest.keyId == guest.keyId { s.connection.close() }
    }

    func cancelRequest() {
        request = nil
        pairing = nil
    }

    private func save() {
        if let key = storageKey { Keychain.save(guests, key: key) }
    }

    // MARK: Requests

    private func handle(_ c: LinkConnection) async {
        // Someone nearby opening lots of connections that never send anything doesn't wear the phone out
        guard connections < 16 else { return c.close() }
        connections += 1
        defer { connections -= 1 }
        do {
            c.idle = 10
            try await c.open(timeout: 10)
            guard let req = try await read(c) else { c.close(); return }
            c.idle = nil
            await route(req, c)
        } catch {
            c.close()
        }
    }

    private struct Request_ {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func read(_ c: LinkConnection) async throws -> Request_? {
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let chunk = try await c.receive(), data.count < 3_000_000 else { return nil }
            data.append(chunk)
        }
        let split = data.range(of: Data("\r\n\r\n".utf8))!
        let lines = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[split.upperBound...])
        let length = min(Int(headers["content-length"] ?? "0") ?? 0, 3_000_000)
        while body.count < length, let chunk = try await c.receive() { body.append(chunk) }
        return Request_(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    private func route(_ r: Request_, _ c: LinkConnection) async {
        let p = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        switch (r.method, r.path) {
        case ("GET", "/info"):
            return await reply(c, 200, ["app": "tonalo", "id": id, "name": name])
        case ("POST", "/pair/start"):
            guard Date() > lockedUntil else { return await reply(c, 429, ["error": "too many tries"]) }
            // Only guests: this phone's own account plays here already
            let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
            pairing = (code, Date().addingTimeInterval(120), 0)
            request = Request(name: String((p["device"] as? String ?? "Guest").prefix(60)), code: code)
            return await reply(c, 200, ["ok": true])
        case ("POST", "/pair/finish"):
            guard let pairing, pairing.until > .now else { return await reply(c, 410, ["error": "expired"]) }
            // The code itself never comes over the network – only proof that the guest knows it (see LinkHTTP)
            guard let pub = (p["pub"] as? String).flatMap({ Data(hex: $0) }), let proof = (p["proof"] as? String).flatMap({ Data(hex: $0) }),
                  LinkHTTP.same(proof, LinkHTTP.proof(code: pairing.code, pub: pub)) else {
                self.pairing?.tries += 1
                failures += 1
                // Guessing doesn't pay off: after five wrong tries the code is gone, after 15 pairing closes for 10 minutes
                if failures >= 15 { failures = 0; lockedUntil = Date().addingTimeInterval(600); cancelRequest() }
                if (self.pairing?.tries ?? 0) >= 5 { cancelRequest() }
                return await reply(c, 403, ["error": "wrong code"])
            }
            let mine = P256.KeyAgreement.PrivateKey()
            guard let key = LinkHTTP.pairingKey(mine, other: pub, code: pairing.code) else { return await reply(c, 400, ["error": "bad key"]) }
            let guest = Guest(keyId: LinkHTTP.random(8).hex, key: key.hex, name: String((p["device"] as? String ?? "Guest").prefix(60)))
            // Pairing again replaces the old pairing of the same guest
            for old in guests where old.name == guest.name { remove(old) }
            guests.append(guest)
            save()
            cancelRequest()
            failures = 0
            app?.notify(String(localized: "\(guest.name) joined the Jukebox"))
            return await reply(c, 200, ["id": guest.keyId, "pub": mine.publicKey.x963Representation.hex, "tv": id, "name": name])
        default:
            break
        }
        let who = authorized(r)
        guard case .success(let guest) = who else {
            if case .failure(let why) = who { return await reply(c, 401, ["error": why.rawValue]) }
            return
        }
        switch (r.method, r.path) {
        case ("GET", "/events"):
            try? await c.send(Data("HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n".utf8))
            streams.append((c, guest))
            updatePresent()
            push()
            // Waits for the guest to go away
            while (try? await c.receive()) != nil {}
            streams.removeAll { $0.connection === c }
            updatePresent()
        case ("POST", "/command"):
            run(p, from: guest)
            await reply(c, 200, ["ok": true])
        default:
            await reply(c, 404, ["error": "not found"])
        }
    }

    enum Refusal: String, Error {
        case notPaired = "not paired"
        /// The signature is right, the time isn't – the guest stays paired.
        case clock
    }

    private func authorized(_ r: Request_) -> Result<Guest, Refusal> {
        let parts = (r.headers["authorization"] ?? "").replacingOccurrences(of: "Tonalo ", with: "").split(separator: ":").map(String.init)
        guard parts.count == 4, let time = Double(parts[1]), parts[2].count >= 16,
              let guest = guests.first(where: { $0.keyId == parts[0] }), let key = Data(hex: guest.key),
              let got = Data(hex: parts[3]), let want = Data(hex: LinkHTTP.signature(r.method, r.path, parts[1], parts[2], r.body, key)),
              LinkHTTP.same(got, want) else { return .failure(.notPaired) }
        guard abs(Date().timeIntervalSince1970 - time) < 120 else { return .failure(.clock) }
        let now = Date()
        nonces = nonces.filter { $0.value > now }
        guard nonces[parts[2]] == nil else { return .failure(.notPaired) }
        nonces[parts[2]] = now.addingTimeInterval(250)
        return .success(guest)
    }

    private func reply(_ c: LinkConnection, _ status: Int, _ body: [String: Any]) async {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let head = "HTTP/1.0 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
        try? await c.send(Data(head.utf8) + data)
        c.close()
    }

    // MARK: What guests may do

    private func run(_ c: [String: Any], from guest: Guest) {
        let player = app?.player
        // No more than 20 at once, whatever a guest's phone sends
        let songs = Array(((c["songs"] as? [Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode([Song].self, from: $0) } ?? []).prefix(20))
        switch c["cmd"] as? String {
        case "enqueue" where !songs.isEmpty:
            player?.enqueue(songs)
            app?.notify(added(songs, by: guest))
        case "playNext" where !songs.isEmpty:
            player?.playNext(songs)
            app?.notify(added(songs, by: guest))
        case "next":
            player?.next()
            app?.notify(String(localized: "\(guest.name) skipped"))
        default:
            break
        }
        push()
    }

    private func added(_ songs: [Song], by guest: Guest) -> String {
        songs.count == 1 ? String(localized: "\(guest.name) added “\(songs[0].title)”")
                         : String(localized: "\(guest.name) added \(songs.count) songs")
    }

    // MARK: State for the guests

    private func watchPlayer(_ generation: Int) {
        guard running, generation == self.generation, let p = app?.player else { return }
        withObservationTracking {
            _ = p.current?.id
            _ = p.isPlaying
            _ = p.queue.count
            _ = p.index
            _ = p.station
            _ = p.shuffle
            _ = p.repeatMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.push()
                self?.watchPlayer(generation)
            }
        }
    }

    private func updatePresent() {
        var names: [String] = []
        for s in streams where !names.contains(s.guest.name) { names.append(s.guest.name) }
        present = names
    }

    /// The same fields as Link.snapshot() on the TV – without the account name, guests don't need it.
    private func snapshot() -> [String: Any] {
        guard let app else { return ["active": false] }
        let p = app.player
        guard p.current != nil || p.station != nil else { return ["active": false] }
        let from = max(0, p.index - 20)
        let window = p.queue.isEmpty ? [] : Array(p.queue[from..<min(p.queue.count, p.index + 101)])
        var s: [String: Any] = [
            "active": true,
            "server": app.current?.serverURL ?? "",
            "playing": p.isPlaying,
            "position": p.position,
            "duration": p.duration,
            "at": Date().timeIntervalSince1970 * 1000,
            "queue": json(window),
            "index": p.index - from,
            "offset": from,
            "shuffle": p.shuffle,
            "repeat": p.repeatMode.rawValue,
            "guests": present,
        ]
        if let st = p.station { s["station"] = json(st) }
        if let ctx = p.context { s["context"] = ["kind": ctx.kind.rawValue, "name": ctx.name, "id": ctx.id as Any] }
        return s
    }

    /// Every 2 s: a ping now and then so guests notice when this phone is gone, the state every 10 s, and
    /// at once when the position jumped.
    private func tick() {
        ticks += 1
        guard !streams.isEmpty, let p = app?.player else { return }
        if let t = told {
            let expected = t.position + (t.playing ? Date().timeIntervalSince(t.at) : 0)
            if abs(p.position - expected) > 2 || ticks % 5 == 0 { return push() }
        } else if ticks % 5 == 0 { return push() }
        if ticks % 10 == 0 { for s in streams { Task { try? await s.connection.send(Data(": ping\n\n".utf8)) } } }
    }

    private func push() {
        if let p = app?.player { told = (p.position, Date(), p.isPlaying) }
        guard !streams.isEmpty, let data = try? JSONSerialization.data(withJSONObject: snapshot()) else { return }
        let line = Data("data: ".utf8) + data + Data("\n\n".utf8)
        for s in streams { Task { try? await s.connection.send(line) } }
    }

    private func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }
}
