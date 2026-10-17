import Foundation

/// How the file behind a title is described.
///
/// The summary is the evidence for the app's promise: container, codec, audio
/// tracks, subtitles show **why** Direct Play works. It belongs on all
/// platforms, and the wording must not drift apart.
///
/// Lives in the package because the Linux version cannot reach
/// `Sources/Shared`; without this the summary was missing there entirely.
///
/// Translated via ``translated(_:)`` with the package's bundle.
public enum FileDetails {

    /// Resolution plus codec, e.g. "2160p · HEVC".
    public static func video(_ feed: MediaStream, _ source: MediaSource) -> String {
        var parts: [String] = []
        if let height = source.height { parts.append("\(height)p") }
        if let codec = feed.codec { parts.append(MediaStream.readable(codec)) }
        return parts.isEmpty ? feed.short : parts.joined(separator: " · ")
    }

    /// At most three languages, then "+ n".
    public static func subtitle(_ streams: [MediaStream]) -> String {
        guard !streams.isEmpty else { return translated("Keine") }
        let languages = streams.compactMap(\.languageName)
        let unique = NSOrderedSet(array: languages).array as? [String] ?? []
        let visible = unique.prefix(3).joined(separator: " · ")
        let rest = unique.count - min(unique.count, 3)
        return rest > 0 ? visible + " + \(rest)" : (visible.isEmpty ? "\(streams.count)" : visible)
    }

    /// The file size: "10,3 GB" in German, "10.3 GB" in English.
    ///
    /// Uses ``Downloadregeln/groesse(_:)`` so the summary and the download list do
    /// not show two different numbers for the same file. Why `.file` and not
    /// powers of two is explained there.
    ///
    /// **Two bugs lived here before.** `String(format: "%.1f GB")` with a
    /// hard-coded comma was wrong in English, and the unit was always GB: a
    /// 112 kB audio track showed as "0,0 GB".
    /// Without a size from the server the line stays empty, not "0 bytes".
    public static func size(_ source: MediaSource) -> String {
        guard let bytes = source.size else { return "" }
        return DownloadRules.size(bytes)
    }

    /// Container with size, e.g. "MKV · 10,3 GB"; without a size just "MKV".
    ///
    /// The separator lives here and not in ``size(_:)``: there it was a trap,
    /// because Mac and Linux also show the size alone, leaving a dot before
    /// nothing.
    public static func container(_ source: MediaSource) -> String? {
        guard let container = source.container else { return nil }
        let sizeInfo = size(source)
        return sizeInfo.isEmpty ? container.uppercased() : container.uppercased() + " · " + sizeInfo
    }

    public static func audioTracks(_ source: MediaSource) -> [MediaStream] {
        (source.mediaStreams ?? []).filter { $0.type == "Audio" }
    }

    public static func subtitleTracks(_ source: MediaSource) -> [MediaStream] {
        (source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
    }

    public static func videoTrack(_ source: MediaSource) -> MediaStream? {
        (source.mediaStreams ?? []).first { $0.type == "Video" }
    }
}

public extension MediaSource {
    /// Codec of the first video track per the server (`h264`, `mpeg4` ...), `nil` without a video track.
    var videoCodec: String? { FileDetails.videoTrack(self)?.codec }
}
