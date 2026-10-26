import SwiftUI
import UIKit
import CoreImage

/// Loads cover art with the account's custom headers (AsyncImage can't send headers) and keeps a memory cache.
actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var running: [URL: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 400 }

    func image(_ url: URL, headers: [String: String]) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = running[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, _) = try? await ServerSession.shared.session.data(for: req) else { return nil }
            return UIImage(data: data)
        }
        running[url] = task
        let img = await task.value
        running[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
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
