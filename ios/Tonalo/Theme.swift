import SwiftUI
import Observation
import UIKit

/// User-adjustable look and feel. Views that read these values update immediately when they change.
@MainActor
@Observable
final class Theme {
    static let shared = Theme()
    private let defaults = UserDefaults.standard

    static let defaultAccent = "#5B9DFF"
    static let presets: [(hex: String, name: LocalizedStringKey)] = [
        ("#5B9DFF", "Blue"), ("#9B7BFF", "Purple"), ("#FF6FB5", "Pink"), ("#FF5A5F", "Red"),
        ("#FF9F43", "Orange"), ("#FFD24A", "Yellow"), ("#3DDC97", "Green"), ("#2EC4C9", "Teal"),
    ]
    static let homeRows: [(id: String, name: LocalizedStringKey)] = [
        ("recent", "Recently played"), ("newest", "Recently added"), ("frequent", "Most played"),
        ("random", "Discover"), ("starred", "Favorite albums"),
    ]

    /// How light the background is. Cards and tiles keep their distance from it, whatever is chosen.
    enum Backdrop: String, CaseIterable {
        case gray, black
        var lift: Double { self == .gray ? 0.07 : 0 }
        var title: LocalizedStringKey { self == .gray ? "Dark gray" : "Black" }
    }
    /// Corners of covers and cards: the shapes in the code are the standard, these scale them.
    enum CardShape: String, CaseIterable {
        case sharp, standard, round
        var scale: CGFloat { switch self { case .sharp: 0; case .standard: 1; case .round: 2.5 } }
        var title: LocalizedStringKey { switch self { case .sharp: "Sharp"; case .standard: "Standard"; case .round: "Rounded" } }
    }
    /// Size of the covers in the shelves on the home page.
    enum CoverSize: String, CaseIterable {
        case small, standard, large
        var scale: CGFloat { switch self { case .small: 0.85; case .standard: 1; case .large: 1.2 } }
        var title: LocalizedStringKey { switch self { case .small: "Small"; case .standard: "Standard"; case .large: "Large" } }
    }

    var backdrop: Backdrop { didSet { defaults.set(backdrop.rawValue, forKey: "backdrop") } }
    var cardShape: CardShape { didSet { defaults.set(cardShape.rawValue, forKey: "cardShape") } }
    var coverSize: CoverSize { didSet { defaults.set(coverSize.rawValue, forKey: "coverSize") } }
    var accentHex: String { didSet { defaults.set(accentHex, forKey: "accentHex") } }
    var coverTint: Bool { didSet { defaults.set(coverTint, forKey: "coverTint") } }
    var lyricsFirst: Bool { didSet { defaults.set(lyricsFirst, forKey: "lyricsFirst") } }
    var startTab: Int { didSet { defaults.set(startTab, forKey: "startTab") } }
    var hiddenHomeRows: Set<String> { didSet { defaults.set(Array(hiddenHomeRows), forKey: "hiddenHomeRows") } }

    var accent: Color { Color(hex: accentHex) ?? Color(hex: Self.defaultAccent)! }

    private init() {
        backdrop = Backdrop(rawValue: defaults.string(forKey: "backdrop") ?? "") ?? .gray
        cardShape = CardShape(rawValue: defaults.string(forKey: "cardShape") ?? "") ?? .standard
        coverSize = CoverSize(rawValue: defaults.string(forKey: "coverSize") ?? "") ?? .standard
        accentHex = defaults.string(forKey: "accentHex") ?? Self.defaultAccent
        coverTint = defaults.object(forKey: "coverTint") as? Bool ?? true
        lyricsFirst = defaults.bool(forKey: "lyricsFirst")
        startTab = defaults.integer(forKey: "startTab")
        hiddenHomeRows = Set(defaults.stringArray(forKey: "hiddenHomeRows") ?? [])
    }
}

extension Color {
    @MainActor static var accent: Color { Theme.shared.accent }
    /// The page background, and the surfaces on it that keep their distance from it.
    @MainActor static var canvas: Color { Color(white: Theme.shared.backdrop.lift) }
    @MainActor static var elevated: Color { lifted(0.16) }   // tiles, chips, cards
    @MainActor static var panel: Color { lifted(0.11) }
    /// A gray that follows the background: `base` is how light it is on a black one.
    @MainActor static func lifted(_ base: Double) -> Color { Color(white: base + Theme.shared.backdrop.lift) }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (x: CGFloat) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// Alternate home screen icons. `id` nil is the default icon; the others are asset catalog icon sets.
struct AppIconChoice: Identifiable {
    let id: String?
    let name: LocalizedStringKey
    let background: Color
    let bars: Color

    static let all: [AppIconChoice] = [
        AppIconChoice(id: nil, name: "Blue", background: Color(hex: "#5B9DFF")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Purple", name: "Purple", background: Color(hex: "#9B7BFF")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Pink", name: "Pink", background: Color(hex: "#FF6FB5")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Red", name: "Red", background: Color(hex: "#FF5A5F")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Orange", name: "Orange", background: Color(hex: "#FF9F43")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Yellow", name: "Yellow", background: Color(hex: "#FFD24A")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Green", name: "Green", background: Color(hex: "#3DDC97")!, bars: Color(hex: "#121212")!),
        AppIconChoice(id: "AppIcon-Dark", name: "Dark", background: Color(hex: "#121212")!, bars: Color(hex: "#5B9DFF")!),
        AppIconChoice(id: "AppIcon-Light", name: "Light", background: Color(hex: "#F2F2F2")!, bars: Color(hex: "#121212")!),
    ]
}

/// The Tonalo waveform, drawn in SwiftUI for icon previews. Same proportions as tv/tools/make_icons.py.
struct WaveformShape: Shape {
    func path(in rect: CGRect) -> Path {
        let bars: [(x: CGFloat, h: CGFloat)] = [(0.27, 0.21), (0.385, 0.375), (0.5, 0.54), (0.615, 0.335), (0.73, 0.19)]
        let w = 0.07 * rect.width
        var p = Path()
        for b in bars {
            let h = b.h * rect.height
            p.addRoundedRect(in: CGRect(x: rect.minX + b.x * rect.width - w / 2, y: rect.midY - h / 2, width: w, height: h),
                             cornerSize: CGSize(width: w / 2, height: w / 2))
        }
        return p
    }
}

struct IconPreview: View {
    let choice: AppIconChoice
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(choice.background)
            WaveformShape().fill(choice.bars)
        }
        .frame(width: 68, height: 68)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12)))
    }
}
