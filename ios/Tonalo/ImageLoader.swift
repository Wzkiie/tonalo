import SwiftUI
import UIKit
import CoreImage
import CryptoKit

/// Loads cover art with the account's custom headers (AsyncImage can't send headers).
/// Keeps covers in memory and on disk, so pages look complete right away and without a connection.
/// The disk copy is named after user, cover and size – never after the address, which holds the login token.
actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var running: [URL: Task<UIImage?, Never>] = [:]
    nonisolated static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// Upper limit for the covers on disk; the oldest go first.
    private static let diskLimit = 300 * 1024 * 1024

    init() { cache.countLimit = 400 }

    private static func diskFile(for url: URL) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        guard !value("id").isEmpty else { return nil }
        let key = [value("u"), value("id"), value("size")].joined(separator: "|")
        return folder.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    func image(_ url: URL, headers: [String: String]) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = running[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            let file = Self.diskFile(for: url)
            if let file, let data = try? Data(contentsOf: file), let img = UIImage(data: data) { return img }
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, resp) = try? await ServerSession.shared.session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
            if let file { try? data.write(to: file, options: .atomic) }
            return img
        }
        running[url] = task
        let img = await task.value
        running[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    /// Removes all covers on disk (when an account is removed – they're named by user, not by account).
    nonisolated static func clearDisk() {
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Keeps the disk cache under its limit. Run once at launch, in the background.
    nonisolated static func trimDisk() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        for (url, _, size) in entries where total > diskLimit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

/// Square cover with placeholder. `round` is used for artists.
struct CoverView: View {
    @Environment(AppModel.self) private var app
    let id: String?
    var size: Int = 300
    var round = false
    var corner: CGFloat = 6
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.16))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: round ? "person.fill" : "music.note")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner)))
        .task(id: id) {
            image = nil
            // Downloaded covers first, so offline music keeps its artwork
            if let local = app.downloads.localCover(id), let img = UIImage(contentsOfFile: local.path) { image = img; return }
            guard let client = app.client, let url = client.coverURL(id, size: size) else { return }
            image = await ImageLoader.shared.image(url, headers: client.headers)
        }
    }
}

extension UIImage {
    /// Average color, toned down like the TV app does for header backgrounds.
    var averageColor: Color {
        guard let input = CIImage(image: self) else { return Color(white: 0.3) }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)])
        guard let out = filter?.outputImage else { return Color(white: 0.3) }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: kCFNull as Any]).render(out, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(s, 0.6), brightness: max(0.3, min(b, 0.55)))
    }
}
