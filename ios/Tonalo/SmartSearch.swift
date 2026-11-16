import Foundation

/// Matching that forgives typos, accents and half-typed words. It runs when the server finds little, on what the
/// servers send back for a few looser questions (single words, the first letters of a word).
enum SmartMatch {
    /// Lower case, no accents, no punctuation, single spaces.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init) }

    /// Edit distance where two letters the wrong way round cost one, not two.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var older = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], older[j - 2] + 1) }
            }
            older = prev
            prev = cur
        }
        return prev[b.count]
    }

    /// Words that say little on their own: "the", "die". They don't carry a match, they only count when nothing else was typed.
    private static let filler: Set<String> = ["the", "a", "an", "der", "die", "das", "ein", "eine", "und", "and", "of", "le", "la", "les"]

    /// How well the typed words fit a name, 0 to 1: every typed word is compared with the words of the name, a word that
    /// starts the same counts fully, a typo costs a little. Also tried with the spaces left out ("acdc" for "AC/DC").
    static func score(query: String, text: String) -> Double {
        let q = tokens(query), t = tokens(text)
        // Also as it sounds: "kolega" for "Kollegah"
        return max(rawScore(q, t), rawScore(q.map(sound), t.map(sound)))
    }

    /// Double letters count once, "ph" is "f", an "h" that is only a breath (not after c, s, p, t, g) is dropped.
    static func sound(_ w: String) -> String {
        var out: [Character] = []
        for ch in w.replacingOccurrences(of: "ph", with: "f") {
            if let last = out.last, last == ch { continue }
            if ch == "h", let last = out.last, !"cspltg".contains(last) { continue }
            out.append(ch)
        }
        return String(out)
    }

    private static func rawScore(_ all: [String], _ t: [String]) -> Double {
        guard !all.isEmpty, !t.isEmpty else { return 0 }
        let meaningful = all.filter { !filler.contains($0) }
        let q = meaningful.isEmpty ? all : meaningful
        var total = 0.0
        for w in q {
            var best = 0.0
            let wc = Array(w)
            for u in t {
                if u == w || (wc.count >= 2 && u.hasPrefix(w)) { best = 1; break }
                // A single letter only fits itself
                guard wc.count >= 2 else { continue }
                let uc = Array(u)
                let d = min(distance(wc, Array(uc.prefix(wc.count))), distance(wc, uc))
                best = max(best, max(0, 1 - Double(d) / Double(max(wc.count, 3))))
            }
            total += best
        }
        let byWords = total / Double(q.count)
        let qc = Array(all.joined()), tc = Array(t.joined())
        guard qc.count >= 3 else { return byWords }
        let compact = tc.starts(with: qc) ? 1 : max(0, 1 - Double(distance(qc, tc)) / Double(max(qc.count, 3)))
        return max(byWords, compact)
    }

    /// Looser questions for the servers, four at most: several words → the longer ones alone and the first letters of
    /// the longest; one word → letters swapped near the start ("nroa" for "nora") and its first letters.
    static func variants(for query: String) -> [String] {
        let toks = tokens(query)
        let whole = normalize(query)
        var out: [String] = []
        func add(_ s: String) { if s.count >= 3, s != whole, !out.contains(s) { out.append(s) } }
        if toks.count > 1 {
            let words = toks.filter { $0.count >= 3 && !filler.contains($0) }
            for w in words { add(w) }
            if let longest = words.max(by: { $0.count < $1.count }), longest.count >= 5 { add(String(longest.prefix(3))) }
        } else if let w = toks.first {
            let c = Array(w)
            for i in 0..<min(2, max(0, c.count - 1)) where c[i] != c[i + 1] {
                var d = c; d.swapAt(i, i + 1)
                add(String(d))
            }
            if c.count >= 4 { add(String(w.prefix(3))) }
        }
        return Array(out.prefix(4))
    }
}

/// Something opened from the search (or a search sent with the keyboard's search key). Shown again when the search
/// opens, with its cover, so it can be opened right away instead of searching again.
struct RecentItem: Codable, Identifiable {
    enum Kind: String, Codable { case query, artist, album, song, book, author, series, narrator }
    var kind: Kind
    /// The id on the server – the typed text for a search.
    var key: String
    var title: String
    /// Artist of an album or song, author of a book.
    var detail: String?
    /// What the cover is looked up with: a cover id for music.
    var cover: String?
    var podcast: Bool?
    /// A song is played right from here, so the whole song is kept.
    var song: Song?
    var id: String { kind.rawValue + ":" + key }
}

enum RecentStore {
    /// Only the last few, so the list stays something to glance at.
    static let limit = 5

    /// One broken entry (say, after a change to `Song`) must not take the others with it.
    private struct Lossy: Decodable {
        let item: RecentItem?
        init(from decoder: Decoder) throws { item = try? RecentItem(from: decoder) }
    }

    /// `legacy` is the key of the older list of plain texts: taken over once, then removed.
    static func load(_ key: String, legacy: String? = nil) -> [RecentItem] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([Lossy].self, from: data) {
            return Array(list.compactMap(\.item).prefix(limit))
        }
        guard let legacy else { return [] }
        let old = (defaults.stringArray(forKey: legacy) ?? []).prefix(limit).map { RecentItem(kind: .query, key: $0, title: $0) }
        defaults.removeObject(forKey: legacy)
        if !old.isEmpty { save(Array(old), key: key) }
        return Array(old)
    }

    static func save(_ list: [RecentItem], key: String) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func forget(account id: UUID) {
        UserDefaults.standard.removeObject(forKey: "search.recent2." + id.uuidString)
        UserDefaults.standard.removeObject(forKey: "search.recent." + id.uuidString)
    }

    /// New at the top, the same thing before is dropped (a text search without regard to case and accents).
    static func adding(_ item: RecentItem, to list: [RecentItem]) -> [RecentItem] {
        var out = list
        let text = SmartMatch.normalize(item.key)
        out.removeAll { $0.id == item.id || ($0.kind == .query && item.kind == .query && SmartMatch.normalize($0.key) == text) }
        out.insert(item, at: 0)
        return Array(out.prefix(limit))
    }
}
