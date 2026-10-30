import CryptoKit
import Foundation
import Network

/// The small HTTP the TV, the iPhone and their guests speak with each other. Built on Network instead of
/// URLSession, because only Network reaches another iPhone directly (peer to peer, like AirDrop) – in a car
/// there's no Wi-Fi both phones are in. HTTP/1.0: every answer ends when the other side closes.
enum LinkHTTP {
    static let serviceType = "_tonalo._tcp"

    static var parameters: NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }

    struct Response {
        var status: Int
        var body: Data
    }

    /// One request, the whole answer.
    static func request(_ endpoint: NWEndpoint, _ method: String, _ path: String, body: Data = Data(),
                        headers: [String: String] = [:], timeout: TimeInterval = 8) async throws -> Response {
        let c = LinkConnection(endpoint)
        defer { c.close() }
        return try await withTaskCancellationHandler {
            try await c.open(timeout: timeout)
            try await c.send(head(method, path, body: body, headers: headers) + body)
            var data = Data()
            while let chunk = try await c.receive() { data.append(chunk) }
            guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { throw URLError(.badServerResponse) }
            return Response(status: status(data[..<split.lowerBound]), body: Data(data[split.upperBound...]))
        } onCancel: { c.close() }
    }

    /// A stream of server-sent events: `line` gets every line of the body as it comes.
    /// Returns the status, once the connection has ended.
    @MainActor
    static func stream(_ endpoint: NWEndpoint, _ path: String, headers: [String: String], line: (Data) -> Void) async -> Int? {
        let c = LinkConnection(endpoint)
        defer { c.close() }
        return await withTaskCancellationHandler {
            do {
                try await c.open(timeout: 8)
                try await c.send(head("GET", path, body: Data(), headers: headers))
                var buffer = Data()
                var code: Int?
                while let chunk = try await c.receive() {
                    buffer.append(chunk)
                    if code == nil {
                        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
                        code = status(buffer[..<split.lowerBound])
                        buffer = Data(buffer[split.upperBound...])
                        if code != 200 { return code }
                    }
                    while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        line(Data(buffer[buffer.startIndex..<nl]))
                        buffer = Data(buffer[buffer.index(after: nl)...])
                    }
                }
                return code
            } catch {
                return nil
            }
        } onCancel: { c.close() }
    }

    private static func head(_ method: String, _ path: String, body: Data, headers: [String: String]) -> Data {
        var text = "\(method) \(path) HTTP/1.0\r\nHost: tonalo\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private static func status(_ head: Data) -> Int {
        let first = String(decoding: head.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self).split(separator: " ")
        return first.count > 1 ? Int(first[1]) ?? 0 : 0
    }

    // MARK: Signing

    /// HMAC over method, path, time and body with the key from the pairing – the same as tv/service/service.js.
    static func authorization(_ method: String, _ path: String, body: Data, keyId: String, key: Data) -> String {
        let time = String(Int(Date().timeIntervalSince1970))
        return "Tonalo \(keyId):\(time):\(signature(method, path, time, body, key))"
    }

    static func signature(_ method: String, _ path: String, _ time: String, _ body: Data, _ key: Data) -> String {
        var message = Data("\(method)\n\(path)\n\(time)\n".utf8)
        message.append(body)
        return HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An NWConnection with async send and receive.
final class LinkConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "tonalo.link")

    init(_ endpoint: NWEndpoint) { connection = NWConnection(to: endpoint, using: LinkHTTP.parameters) }
    init(_ connection: NWConnection) { self.connection = connection }

    func open(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = OnceThrowing(done)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(nil)
                case .failed(let e): once.finish(e)
                case .cancelled: once.finish(CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.finish(URLError(.timedOut)) }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    /// The next piece of data, or nil once the other side has closed.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data, !data.isEmpty { done.resume(returning: data) }
                else if let error { done.resume(throwing: error) }
                else if complete { done.resume(returning: nil) }
                else { done.resume(returning: Data()) }
            }
        }
    }

    func close() { connection.cancel() }
}

/// Resumes a continuation only the first time, whichever callback comes first.
private final class OnceThrowing: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
    func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}

extension Data {
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

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
