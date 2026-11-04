// Draws made-up book and podcast covers for the audiobook demo server (ios/tools/abs_mock.js with MOCK_EN=1):
//   swift ios/tools/render_book_covers.swift covers-books
//   MOCK_EN=1 MOCK_BOOK_COVERS=covers-books node ios/tools/abs_mock.js
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "covers-books")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Cover { let id, title, author: String; let top, bottom: NSColor; let shape: Int }
func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor { NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
let covers = [
    Cover(id: "book-1", title: "The Last\nLighthouse", author: "NORA VALE", top: c(244, 162, 97), bottom: c(38, 70, 83), shape: 0),
    Cover(id: "book-2", title: "Paper\nCities", author: "ELLIS MOOR", top: c(233, 196, 106), bottom: c(142, 68, 73), shape: 1),
    Cover(id: "book-3", title: "Salt and\nStatic", author: "SAFFRON LANE", top: c(100, 180, 220), bottom: c(25, 30, 80), shape: 2),
    Cover(id: "book-4", title: "A Field Guide\nto Quiet", author: "GLASS HARBOR", top: c(168, 213, 186), bottom: c(40, 90, 80), shape: 1),
    Cover(id: "book-5", title: "Midnight\nOrchard", author: "RAVI KADE", top: c(190, 140, 220), bottom: c(30, 20, 60), shape: 0),
    Cover(id: "pod-1", title: "The Quiet\nHour", author: "ECHO PARK SOCIAL", top: c(250, 130, 120), bottom: c(70, 30, 90), shape: 2),
]

for cv in covers {
    let size = 600
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    NSGradient(starting: cv.top, ending: cv.bottom)!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)
    NSColor.white.withAlphaComponent(0.16).setFill()
    switch cv.shape {
    case 0: NSBezierPath(ovalIn: NSRect(x: 280, y: 250, width: 360, height: 360)).fill()
            NSColor.black.withAlphaComponent(0.18).setFill(); NSBezierPath(ovalIn: NSRect(x: 60, y: -120, width: 320, height: 320)).fill()
    case 1: for i in 0..<6 { NSBezierPath(rect: NSRect(x: 0, y: 70 + i * 62, width: size, height: 10 + i * 4)).fill() }
    default: for i in 0..<5 { let r = 120.0 + Double(i) * 60; let p = NSBezierPath(ovalIn: NSRect(x: 300 - r, y: 380 - r, width: r * 2, height: r * 2)); p.lineWidth = 6; NSColor.white.withAlphaComponent(0.22).setStroke(); p.stroke() }
    }
    let para = NSMutableParagraphStyle(); para.lineSpacing = 4
    (cv.title as NSString).draw(in: NSRect(x: 44, y: 330, width: 520, height: 230), withAttributes: [
        .font: NSFont.systemFont(ofSize: 66, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para])
    (cv.author as NSString).draw(at: NSPoint(x: 46, y: 46), withAttributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .kern: 4])
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(cv.id + ".png"))
}
print("covers in", out.path)
