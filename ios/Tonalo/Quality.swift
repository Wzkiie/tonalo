import AVFoundation

/// Volume leveling with ReplayGain: per song, or per album so quiet and loud tracks of one album keep their difference.
enum VolumeLeveling: String, CaseIterable, Identifiable {
    case off, track, album
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .track: String(localized: "Same volume for every song")
        case .album: String(localized: "Same volume for every album")
        }
    }

    /// Volume factor for a song (AVPlayer can only turn down, so louder than 1 isn't possible).
    func factor(for song: Song?) -> Float {
        guard self != .off, let rg = song?.replayGain else { return 1 }
        let gain = self == .album ? rg.albumGain.flatMap { $0 != 0 ? $0 : nil } ?? rg.trackGain : rg.trackGain ?? rg.albumGain
        let peak = self == .album ? rg.albumPeak ?? rg.trackPeak : rg.trackPeak ?? rg.albumPeak
        guard let gain, gain != 0 else { return 1 }
        var f = pow(10, gain / 20)
        if let peak, peak > 0 { f = min(f, 1 / peak) } // never clip
        return Float(min(max(f, 0.05), 1))
    }
}

/// Audio quality for streaming and downloads. "Original" sends the files as they are (FLAC stays FLAC);
/// everything else is converted by the server. Navidrome converts to AAC, Opus (in an OGG container) and MP3 –
/// any other format falls back to Opus, so lossless conversion isn't possible and only original files are lossless.
enum AudioQuality: String, CaseIterable, Identifiable, Codable {
    case lossless
    case aac256, aac192, aac128, aac96
    case opus192, opus128, opus96
    case mp3320, mp3192, mp3128

    var id: String { rawValue }

    enum Codec: String, CaseIterable, Identifiable {
        case original, aac, opus, mp3
        var id: String { rawValue }
        var name: String {
            switch self {
            case .original: String(localized: "Original")
            case .aac: "AAC"
            case .opus: "Opus"
            case .mp3: "MP3"
            }
        }
        /// Opus needs a newer iOS (OGG playback), asked at runtime.
        var available: Bool { self != .opus || AudioQuality.playable.contains("opus") }
        var levels: [AudioQuality] { AudioQuality.allCases.filter { $0.codec == self } }
    }

    var codec: Codec {
        switch self {
        case .lossless: .original
        case .aac256, .aac192, .aac128, .aac96: .aac
        case .opus192, .opus128, .opus96: .opus
        case .mp3320, .mp3192, .mp3128: .mp3
        }
    }

    /// Server format, nil = original file
    var format: String? { codec == .original ? nil : codec.rawValue }

    var bitRate: Int {
        switch self {
        case .lossless: 0
        case .aac256: 256
        case .aac192, .opus192, .mp3192: 192
        case .aac128, .opus128, .mp3128: 128
        case .aac96, .opus96: 96
        case .mp3320: 320
        }
    }

    /// "AAC 256 kbit/s" – what the settings show.
    var title: String { codec == .original ? codec.name : "\(codec.name) \(bitRate) kbit/s" }

    /// The bitrate on its own, for the rows under a codec heading.
    var rateTitle: String { codec == .original ? String(localized: "Original files") : "\(bitRate) kbit/s" }

    /// How good it sounds and how much data an hour of music takes.
    var detail: String {
        guard codec != .original else { return String(localized: "Lossless · FLAC stays FLAC, largest files") }
        // Opus sounds as good as AAC and MP3 at a lower bitrate
        let rate = codec == .opus ? bitRate * 3 / 2 : bitRate
        let level = switch rate {
        case 256...: String(localized: "Highest quality")
        case 192...: String(localized: "High quality")
        case 128...: String(localized: "Standard quality")
        default: String(localized: "Data saver")
        }
        let perHour = Int((Double(bitRate) * 3600 / 8 / 1000 / 5).rounded()) * 5
        return String(localized: "\(level) · about \(perHour) MB per hour")
    }

    /// Formats this iPhone plays itself; anything else (WMA, APE, WavPack, DSD …) is converted.
    /// Newer iOS versions also play Opus/OGG – asked at runtime, so older ones get AAC instead.
    static let playable: Set<String> = {
        var formats: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac", "alac", "flac", "wav", "aif", "aiff", "aifc", "caf"]
        if AVURLAsset.audiovisualMIMETypes().contains("audio/ogg") { formats.formUnion(["opus", "ogg", "oga"]) }
        return formats
    }()

    /// The quality actually used for a song: lossless only works for files the iPhone can play.
    func resolved(for song: Song) -> AudioQuality {
        if codec == .opus && !codec.available { return .aac192 }
        guard self == .lossless else { return self }
        return Self.playable.contains((song.suffix ?? "").lowercased()) ? .lossless : .aac256
    }

    /// File extension of the result, so iOS recognizes downloaded files.
    func fileExtension(for song: Song) -> String {
        codec == .opus ? "ogg" : format ?? (song.suffix?.lowercased() ?? "audio")
    }

    /// Short label for the player, e.g. "FLAC" or "AAC 256".
    func label(for song: Song) -> String {
        if codec != .original { return "\(codec.name.uppercased()) \(bitRate)" }
        let suffix = (song.suffix ?? "").uppercased()
        if let rate = song.bitRate, ["MP3", "M4A", "AAC", "MP4"].contains(suffix) { return "\(suffix) \(rate)" }
        return suffix.isEmpty ? String(localized: "Original") : suffix
    }

    /// Settings from before quality levels existed were plain bitrates (0 = original, otherwise MP3).
    static func migrated(_ bitRate: Int?) -> AudioQuality? {
        switch bitRate {
        case nil: nil
        case 0: .lossless
        case 320: .mp3320
        case 192: .mp3192
        case 128: .mp3128
        default: nil
        }
    }

    static func stored(_ key: String, legacy: String, default fallback: AudioQuality) -> AudioQuality {
        if let raw = UserDefaults.standard.string(forKey: key), let q = AudioQuality(rawValue: raw) { return q }
        return migrated(UserDefaults.standard.object(forKey: legacy) as? Int) ?? fallback
    }
}
