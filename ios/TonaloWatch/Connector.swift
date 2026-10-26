import Observation
import SwiftUI
import WatchConnectivity

/// The watch end of the connection: receives the phone's player state and sends commands to it.
@MainActor
@Observable
final class Connector: NSObject {
    static let shared = Connector()

    private(set) var now: WatchNowPlaying?
    private(set) var error: String?
    /// Page of the main screen (0 = player, 1 = library) and the library's navigation, so starting
    /// a song can jump straight back to the player.
    var page = 0
    var path = NavigationPath()

    @ObservationIgnored private var covers: [String: Data] = [:]

    var accent: Color { now.flatMap { Color(hex: $0.accentHex) } ?? Color(hex: "#5B9DFF")! }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Commands

    /// Sends a player command; the phone answers with its new state.
    func send(_ command: String, _ extra: [String: Any] = [:]) {
        // Feels instant: show the expected result before the phone confirms it
        if var n = now {
            switch command {
            case "toggle": n.isPlaying.toggle(); n.position = position(at: .now); n.sentAt = .now
            case "favorite": n.starred.toggle()
            case "shuffle": n.shuffle.toggle()
            default: break
            }
            now = n
        }
        Task {
            if let reply = await request([Watch.command: command].merging(extra) { $1 }),
               let state = Watch.decode(WatchNowPlaying.self, reply[Watch.data]) {
                apply(state)
            }
        }
    }

    func play(_ item: WatchItem, index: Int = 0, shuffled: Bool = false) {
        send("play", [Watch.kind: item.kind.rawValue, Watch.id: item.id, Watch.index: index, Watch.shuffle: shuffled])
        path = NavigationPath()
        page = 0
    }

    func list(_ item: WatchItem? = nil) async -> [WatchSection]? {
        var message: [String: Any] = [Watch.command: "list"]
        if let item { message[Watch.kind] = item.kind.rawValue; message[Watch.id] = item.id }
        guard let reply = await request(message) else { return nil }
        return Watch.decode([WatchSection].self, reply[Watch.data])
    }

    func cover(_ id: String) async -> Data? {
        if let hit = covers[id] { return hit }
        guard let data = await request([Watch.command: "cover", Watch.id: id])?[Watch.data] as? Data else { return nil }
        covers[id] = data
        return data
    }

    /// The position right now, counted on from when the phone sent its state.
    func position(at date: Date) -> Double {
        guard let n = now else { return 0 }
        let p = n.isPlaying ? n.position + date.timeIntervalSince(n.sentAt) : n.position
        return min(max(p, 0), max(n.duration, 0))
    }

    private func request(_ message: [String: Any]) async -> [String: Any]? {
        // Right after launch the session may still be connecting – give it a moment
        for _ in 0..<30 where WCSession.default.activationState != .activated || !WCSession.default.isReachable {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard WCSession.default.activationState == .activated else { error = String(localized: "Not connected to your iPhone."); return nil }
        nonisolated(unsafe) let message = message
        return await withCheckedContinuation { (done: CheckedContinuation<[String: Any]?, Never>) in
            WCSession.default.sendMessage(message) { reply in
                nonisolated(unsafe) let reply = reply
                Task { @MainActor in self.error = nil; done.resume(returning: reply) }
            } errorHandler: { _ in
                Task { @MainActor in
                    self.error = String(localized: "Your iPhone can’t be reached. Open Tonalo on it.")
                    done.resume(returning: nil)
                }
            }
        }
    }

    private func apply(_ state: WatchNowPlaying) {
        var s = state
        if s.cover == nil, s.songId == now?.songId { s.cover = now?.cover } // keep the cover we already have
        now = s
    }
}

extension Connector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext[Watch.data] as? Data
        Task { @MainActor in
            if let state = Watch.decode(WatchNowPlaying.self, context) { self.apply(state) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[Watch.data] as? Data
        Task { @MainActor in
            if let state = Watch.decode(WatchNowPlaying.self, data) { self.apply(state) }
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
