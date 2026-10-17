import Foundation

/// **In which quality a title is downloaded to the device.**
///
/// The default is the original, the same file that would be streamed. But
/// someone taking a whole season on a train ride has a problem at 35 GB that a
/// smaller version solves. Only the server can make it, and only if the
/// operator allows this account to transcode; so the choice is available only
/// then (``waehlbar(videoConvert:audioConvert:)``).
///
/// **Three levels, named after what you see.** "720p" answers the question
/// someone asks before downloading; the bitrate comes second, because it
/// explains the size. The numbers are the ones Jellyfin's own interface and
/// the other clients use for the same levels.
///
/// **Transcoding goes to H.264 and AAC in Matroska.** Every device Swiftly
/// runs on plays that, and no server needs a special library for it. Subtitles
/// are no longer inside a transcoded file; they travel alongside as separate files
/// (``Untertiteldatei/mitladen(stroeme:itemID:quelle:server:schluessel:umgewandelt:)``).
public enum DownloadQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case hd1080
    case hd720
    case sd480

    public var id: String { rawValue }

    /// The levels that transcode: everything except the original.
    public static let levels: [DownloadQuality] = [.hd1080, .hd720, .sd480]

    /// The container of a transcoded file. It appears in the file name, and VLC
    /// recognizes the demuxer by the extension.
    public static let container = "mkv"

    public var isOriginal: Bool { self == .original }

    /// Picture height of the level; `nil` for the original.
    public var height: Int? {
        switch self {
        case .original: nil
        case .hd1080: 1080
        case .hd720: 720
        case .sd480: 480
        }
    }

    /// Width for the height at 16:9. The server keeps the aspect ratio itself;
    /// the width only limits widescreen films whose height is below it anyway.
    public var width: Int? {
        switch self {
        case .original: nil
        case .hd1080: 1920
        case .hd720: 1280
        case .sd480: 854
        }
    }

    /// Bits per second for the picture.
    public var imageBitrate: Int? {
        switch self {
        case .original: nil
        case .hd1080: 8_000_000
        case .hd720: 4_000_000
        case .sd480: 1_500_000
        }
    }

    /// Bits per second for the audio. 5.1 is kept at 1080p and 720p; at 480p it
    /// becomes stereo, since whoever downloads that small listens on headphones.
    public var audioBitrate: Int? {
        switch self {
        case .original: nil
        case .hd1080: 384_000
        case .hd720: 256_000
        case .sd480: 128_000
        }
    }

    public var audioChannels: Int? {
        switch self {
        case .original: nil
        case .hd1080, .hd720: 6
        case .sd480: 2
        }
    }

    /// Picture and audio together, bit/s; the estimated size derives from it.
    public var totalBitrate: Int? {
        guard let b = imageBitrate, let t = audioBitrate else { return nil }
        return b + t
    }

    // MARK: What is offered

    /// **Whether a choice is allowed at all.** Transcoding means recomputing
    /// picture *and* audio; if either right is missing, the server refuses. As with
    /// ``DownloadPermission``, only an explicit `false` blocks; a silent server takes
    /// nothing away from anyone.
    public static func selectable(videoConvert: Bool?, audioConvert: Bool?) -> Bool {
        (videoConvert ?? true) && (audioConvert ?? true)
    }

    /// The levels for a selection, original first.
    ///
    /// **A level that does not make the file smaller is dropped.** Downloading a
    /// 720p series at 2 Mbit/s "as 1080p at 8 Mbit/s" would mean transcoding the
    /// file and making it bigger. The source bitrate comes from size and
    /// runtime; if unknown, all levels stay.
    public static func offered(selectable: Bool, sourceBitrateOf: Int?) -> [DownloadQuality] {
        guard selectable else { return [.original] }
        let matching = levels.filter { rung in
            guard let q = sourceBitrateOf, q > 0, let g = rung.totalBitrate else { return true }
            return g < q
        }
        return [.original] + matching
    }

    /// Bits per second of a file from size and runtime; `nil` if either is
    /// missing.
    public static func bitrate(bytes: Int64, runtimeTicks: Int64?) -> Int? {
        guard bytes > 0, let t = runtimeTicks, t > 0 else { return nil }
        let seconds = Double(t) / 10_000_000
        return Int(capped: Double(bytes) * 8 / seconds)
    }

    /// **The highest source bitrate of a selection**: the levels follow the best
    /// file in it. Otherwise 1080p would disappear as soon as a single episode
    /// exists in 720p.
    public static func sourceBitrateOf(_ files: [(bytes: Int64, runtimeTicks: Int64?)]) -> Int? {
        files.compactMap { bitrate(bytes: $0.bytes, runtimeTicks: $0.runtimeTicks) }.max()
    }

    // MARK: Size

    /// **Roughly how big the file will be.**
    ///
    /// The server only knows the size of a transcoded file once it is finished,
    /// and therefore sends no length. So we compute: bitrate times runtime, plus
    /// three percent for the container. For the original, the real size is shown.
    ///
    /// **Never larger than the original.** If the source is below the level, the
    /// server delivers at most its bitrate; an estimate above that would make the
    /// smaller choice look more expensive.
    public func estimatedBytes(original: Int64, runtimeTicks: Int64?) -> Int64 {
        guard let bitrate = totalBitrate else { return original }
        guard let t = runtimeTicks, t > 0 else { return 0 }
        let seconds = Double(t) / 10_000_000
        let schaetzung = Int64(seconds * Double(bitrate) / 8 * 1.03)
        return original > 0 ? min(schaetzung, original) : schaetzung
    }

    /// **What a series group shows in the download list:** the level, if all
    /// episodes carry the same smaller one; otherwise nothing. A group of original
    /// and 720p would have no label that is true for all.
    public static func gemeinsam(_ entries: [DownloadItem]) -> DownloadQuality? {
        guard let first = entries.first?.guete, !first.isOriginal,
              entries.allSatisfy({ $0.guete == first }) else { return nil }
        return first
    }

    // MARK: Wording

    /// "Original", "1080p", "720p", "480p".
    public var name: String {
        switch self {
        case .original: translated("Original")
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        }
    }

    /// The second label: "Direct Play" or the bitrate, "1,5 Mbit/s".
    public func addition(locale: Locale = .current) -> String {
        guard let b = imageBitrate else { return translated("Direct Play") }
        let mbit = (Double(b) / 1_000_000).formatted(
            .number.precision(.fractionLength(0...1)).locale(locale))
        return mbit + " Mbit/s"
    }

    /// What the badge shows: "Direct Play · Originalqualität" or
    /// "720p · 4 Mbit/s".
    public func badge(locale: Locale = .current) -> String {
        isOriginal ? translated("Direct Play · Originalqualität")
                    : name + " · " + addition(locale: locale)
    }
}
