// The demo server (tv/tools/mock_server.js) draws its covers as SVG, which iOS can't show.
// This renders them to PNG once, so the iPhone app in the simulator gets real pictures:
//   swift ios/tools/render_covers.swift http://localhost:4599 covers
//   MOCK_COVERS=covers node tv/tools/mock_server.js
import AppKit

let args = CommandLine.arguments
let server = args.count > 1 ? args[1] : "http://localhost:4599"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "covers")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func get(_ method: String, _ query: String = "") -> Data {
    let url = URL(string: "\(server)/rest/\(method)?u=demo&p=demo&v=1.16.1&c=covers&f=json\(query)")!
    return try! Data(contentsOf: url)
}

// Every id that can have a cover: albums and artists
let text = String(decoding: get("getAlbumList2", "&type=newest&size=1000") + get("getArtists"), as: UTF8.self)
let pattern = try NSRegularExpression(pattern: #""id":"(a[lr][0-9_]+)""#)
let ids = Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range(at: 1)) })

let size = 600
for id in ids.sorted() {
    guard let image = NSImage(data: get("getCoverArt", "&id=\(id)")) else { print("skipped \(id)"); continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(id).png"))
}
print("\(ids.count) covers in \(out.path)")
