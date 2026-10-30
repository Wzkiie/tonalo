import CryptoKit
import Foundation
import Network
import Observation
import UIKit

/// A TV running Tonalo in the home network. While it plays, the player here shows what plays there, and
/// music picked on the phone plays on the TV. Found with Bonjour, paired once with a code from the TV
/// screen; every request is signed with the key from the pairing, so nobody else in the network can see
/// or send anything. Works only inside the home network – nothing goes through the internet.
@MainActor
@Observable
final class TVLink {
    /// What the TV reports – the fields of Link.snapshot() in tv/app/js/link.js.
    struct State: Decodable {
        struct Source: Decodable { var kind: String?; var id: String?; var name: String? }
        var active: Bool
        var user: String?
        var server: String?
        var playing: Bool?
        var position: Double?
        var duration: Double?
        /// When the TV took this snapshot (ms since 1970) – the position counts on from there.
        var at: Double?
        var station: Station?
        var queue: [Song]?
        var index: Int?
        /// Where `queue` starts in the TV's whole queue (only a window around the current song is sent).
        var offset: Int?
        var shuffle: Bool?
        var `repeat`: String?
        var context: Source?
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    struct Pairing: Codable, Hashable {
        var tv: String
        var name: String
        var keyId: String
        var key: String
    }

    enum PairResult { case ok, wrongCode, expired, failed }

    @ObservationIgnored weak var app: AppModel?
    /// TVs with Tonalo found in this network right now.
    private(set) var devices: [Device] = []
    /// TVs paired with the current account.
    private(set) var pairings: [Pairing] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var listening: (tv: String, base: URL, pairing: Pairing)?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private var storageKey: String? { app?.current.map { "tv." + $0.id.uuidString } }

    // MARK: Finding TVs

    func start() {
        loadPairings()
        guard browser == nil else { connect(); return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_tonalo._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Device? in
                guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata, let id = txt["id"] else { return nil }
                return Device(id: id, name: name, endpoint: r.endpoint)
            }
            Task { @MainActor in self?.found(found) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Going to the background: the connection ends, the player keeps showing the TV until it's back.
    func stop() {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        listening = nil
        devices = []
    }

    func accountChanged() {
        listener?.cancel()
        listener = nil
        listening = nil
        loadPairings()
        connect()
    }

    private func found(_ list: [Device]) {
        devices = list
        connect()
    }

    // MARK: Pairing

    func isPaired(_ device: Device) -> Bool { pairings.contains { $0.tv == device.id } }

    /// Asks the TV to show a code.
    func startPairing(_ device: Device) async -> Bool {
        guard let base = await address(of: device.endpoint) else { return false }
        return (try? await send(base, "POST", "/pair/start", body: Data("{}".utf8))).map { $0.0 == 200 } ?? false
    }

    func finishPairing(_ device: Device, code: String) async -> PairResult {
        guard let base = await address(of: device.endpoint) else { return .failed }
        let body = try? JSONSerialization.data(withJSONObject: ["code": code, "device": UIDevice.current.name])
        guard let (status, data) = try? await send(base, "POST", "/pair/finish", body: body ?? Data()) else { return .failed }
        switch status {
        case 200:
            struct Answer: Decodable { var id: String; var key: String; var tv: String; var name: String }
            guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { return .failed }
            pairings.removeAll { $0.tv == a.tv }
            pairings.append(Pairing(tv: a.tv, name: a.name, keyId: a.id, key: a.key))
            savePairings()
            connect()
            return .ok
        case 403: return .wrongCode
        case 410: return .expired
        default: return .failed
        }
    }

    func unpair(_ tv: String) {
        pairings.removeAll { $0.tv == tv }
        savePairings()
        if listening?.tv == tv {
            listener?.cancel()
            listener = nil
            listening = nil
            app?.player.tvGone()
        }
    }

    private func loadPairings() {
        pairings = storageKey.flatMap { Keychain.load([Pairing].self, key: $0) } ?? []
    }

    private func savePairings() {
        if let key = storageKey { Keychain.save(pairings, key: key) }
    }

    // MARK: Live

    /// Follows the first paired TV in the network: its state comes in as long as the connection lasts.
    private func connect() {
        guard listener == nil, let device = devices.first(where: isPaired),
              let pairing = pairings.first(where: { $0.tv == device.id }) else { return }
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
            self.app?.player.tvGone()
        }
    }

    /// True when anything came from the TV before the connection ended.
    private func follow(_ device: Device, _ pairing: Pairing) async -> Bool {
        guard let base = await address(of: device.endpoint), !Task.isCancelled else { return false }
        listening = (device.id, base, pairing)
        var request = signed(URLRequest(url: base.appending(path: "events")), "GET", "/events", body: nil, pairing)
        request.timeoutInterval = 60 // the TV sends a sign of life every 20 seconds
        guard let (bytes, response) = try? await session.bytes(for: request) else { return false }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            unpair(pairing.tv) // the TV forgot this phone (disconnected in its settings)
            return false
        }
        var wasPlaying = false, first = true
        // Read line by line by hand: `bytes.lines` holds a line back until the next one starts,
        // so every change would only show up with the one after it
        var buffer = Data()
        do {
            for try await byte in bytes {
                guard byte == UInt8(ascii: "\n") else { buffer.append(byte); continue }
                let line = buffer
                buffer.removeAll(keepingCapacity: true)
                guard line.starts(with: Data("data: ".utf8)), let s = try? JSONDecoder().decode(State.self, from: Data(line.dropFirst(6))) else { continue }
                let playing = s.active && s.playing == true && matches(s)
                if s.active && matches(s) {
                    // Only a TV that starts playing takes over – one that just sits there paused doesn't
                    app?.player.tvUpdate(s, name: pairing.name, started: playing && (first || !wasPlaying))
                } else {
                    app?.player.tvGone()
                }
                wasPlaying = playing
                first = false
            }
        } catch {}
        return !first
    }

    /// Same account on the same server – another person's music on the TV is none of this phone's business.
    private func matches(_ s: State) -> Bool {
        guard let acc = app?.current, s.user == acc.username, let server = s.server else { return false }
        func norm(_ url: String?) -> String? {
            guard let url, let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let host = u.host?.lowercased() else { return nil }
            return host + ":" + String(u.port ?? (u.scheme == "https" ? 443 : 80))
        }
        let tv = norm(server)
        return tv != nil && (tv == norm(acc.serverURL) || tv == norm(acc.localURL))
    }

    // MARK: Commands

    /// Plays songs on the TV, like PlayerModel.play does here. Very long lists go as a window around the start.
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

    private func command(_ cmd: [String: Any]) {
        guard let (_, base, pairing) = listening, let body = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        Task {
            if (try? await send(base, "POST", "/command", body: body, pairing))?.0 != 200 {
                app?.player.lastError = String(localized: "The TV isn't answering.")
            }
        }
    }

    private func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
    }

    // MARK: Requests

    private func send(_ base: URL, _ method: String, _ path: String, body: Data, _ pairing: Pairing? = nil) async throws -> (Int, Data) {
        var r = URLRequest(url: base.appending(path: String(path.dropFirst())), timeoutInterval: 8)
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r = signed(r, method, path, body: body, pairing)
        let (data, response) = try await session.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// HMAC over method, path, time and body with the key from the pairing – checked by tv/service/service.js.
    private func signed(_ request: URLRequest, _ method: String, _ path: String, body: Data?, _ pairing: Pairing?) -> URLRequest {
        var r = request
        r.httpMethod = method
        guard let pairing, let key = Data(hex: pairing.key) else { return r }
        let time = String(Int(Date().timeIntervalSince1970))
        var message = Data("\(method)\n\(path)\n\(time)\n".utf8)
        message.append(body ?? Data())
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        r.setValue("Tonalo \(pairing.keyId):\(time):\(mac.map { String(format: "%02x", $0) }.joined())", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Bonjour names a service, URLSession needs an address: a short connection tells which one.
    private func address(of endpoint: NWEndpoint) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let once = Once(done)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var url: URL?
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
                        if h.contains(":") { h = "[\(h)]" }
                        url = URL(string: "http://\(h):\(port.rawValue)")
                    }
                    once.finish(url)
                    connection.cancel()
                case .failed, .cancelled:
                    once.finish(nil)
                default: break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.finish(nil); connection.cancel() }
        }
    }
}

/// Resumes a continuation only the first time, whichever callback comes first.
private final class Once: @unchecked Sendable {
    private var continuation: CheckedContinuation<URL?, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<URL?, Never>) { continuation = c }
    func finish(_ url: URL?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: url)
    }
}

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}
