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

/// Audio quality for streaming and downloads. "Lossless" sends the files as they are (FLAC stays FLAC);
/// everything else is converted by the server. Navidrome converts to MP3 and AAC – for any other
/// format it falls back to Opus in an OGG container, which older iOS versions can't play, so only those two are used.
enum AudioQuality: String, CaseIterable, Identifiable, Codable {
    case lossless
    case aac256, aac192, aac128, aac96
    case mp3320, mp3192, mp3128

    var id: String { rawValue }

    /// Server format, nil = original file
    var format: String? {
        switch self {
        case .lossless: nil
        case .aac256, .aac192, .aac128, .aac96: "aac"
        case .mp3320, .mp3192, .mp3128: "mp3"
        }
    }

    var bitRate: Int {
        switch self {
        case .lossless: 0
        case .aac256: 256
        case .aac192: 192
        case .aac128: 128
        case .aac96: 96
        case .mp3320: 320
        case .mp3192: 192
        case .mp3128: 128
        }
    }

    var title: String {
        switch self {
        case .lossless: String(localized: "Lossless (original files)")
        case .aac256: String(localized: "Very high · AAC 256 kbit/s")
        case .aac192: String(localized: "High · AAC 192 kbit/s")
        case .aac128: String(localized: "Normal · AAC 128 kbit/s")
        case .aac96: String(localized: "Data saver · AAC 96 kbit/s")
        case .mp3320: "MP3 320 kbit/s"
        case .mp3192: "MP3 192 kbit/s"
        case .mp3128: "MP3 128 kbit/s"
        }
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
        guard self == .lossless else { return self }
        return Self.playable.contains((song.suffix ?? "").lowercased()) ? .lossless : .aac256
    }

    /// File extension of the result, so iOS recognizes downloaded files.
    func fileExtension(for song: Song) -> String {
        format ?? (song.suffix?.lowercased() ?? "audio")
    }

    /// Short label for the player, e.g. "FLAC" or "AAC 256".
    func label(for song: Song) -> String {
        if let format { return "\(format.uppercased()) \(bitRate)" }
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
