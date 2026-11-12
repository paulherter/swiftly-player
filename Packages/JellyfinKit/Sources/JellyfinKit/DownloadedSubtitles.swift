import Foundation

/// One subtitle's facts, as stored next to a download in `<file>.untertitel/info.json`.
///
/// The shape is the one the Rust UIs write (`swiftly_vm::subtitle_sidecar::SubtitleMeta`, snake_case keys), so a stored title
/// reads the same on every platform. `embedded` is an addition of this side: the track lives inside the stored file (there is
/// no `<index>.<ext>` file for it); the Rust readers skip entries without a file.
public struct SubtitleSidecar: Codable, Equatable, Sendable {
    /// The server's numbering of the stream (the file's name; for an embedded track the number the engine knows it under).
    public var index: Int
    public var language: String?
    public var title: String?
    /// The server's codec name (`subrip`, `ass`, `hdmv_pgs_subtitle`).
    public var codec: String?
    public var forced: Bool
    public var hearingImpaired: Bool
    /// `true` for a track inside the stored file; absent for a file in the folder.
    public var embedded: Bool?

    public init(index: Int, language: String? = nil, title: String? = nil, codec: String? = nil, forced: Bool = false,
                hearingImpaired: Bool = false, embedded: Bool? = nil) {
        self.index = index; self.language = language; self.title = title; self.codec = codec
        self.forced = forced; self.hearingImpaired = hearingImpaired; self.embedded = embedded
    }

    enum CodingKeys: String, CodingKey {
        case index, language, title, codec, forced, embedded
        case hearingImpaired = "hearing_impaired"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        forced = try c.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        hearingImpaired = try c.decodeIfPresent(Bool.self, forKey: .hearingImpaired) ?? false
        embedded = try c.decodeIfPresent(Bool.self, forKey: .embedded)
    }
}

/// **The subtitles of a stored title.** A download keeps what the track list needs (language, title, format, forced) next to the
/// files, never an address or a key; the player rebuilds the list from it, so a title opened offline offers the same tracks, with
/// the same names, as online: the files that came along and the tracks that stay inside the stored file.
public enum DownloadedSubtitles {
    /// The facts' file name; it has no numeric stem, so the readers of the folder skip it.
    public static let sidecarName = "info.json"

    /// The facts to store after a download. `fetched` are the indexes of the files that arrived in the folder;
    /// `embeddedStay` is `true` for an original file (its subtitle tracks stay in the container) and `false` for a built
    /// one (its text tracks come as files, the container holds only picture and sound).
    public static func facts(streams: [MediaStream], fetched: Set<Int>, embeddedStay: Bool) -> [SubtitleSidecar] {
        streams.compactMap { feed -> SubtitleSidecar? in
            guard feed.type == "Subtitle", let index = feed.index else { return nil }
            func fact(_ number: Int, embedded: Bool?) -> SubtitleSidecar {
                SubtitleSidecar(index: number, language: feed.language, title: feed.title, codec: feed.codec,
                                forced: feed.isForced == true, hearingImpaired: feed.isHearingImpaired == true,
                                embedded: embedded)
            }
            if fetched.contains(index) { return fact(index, embedded: nil) }
            // A track that is not a file stays in the container of an original download.
            guard embeddedStay, !feed.isDeliveredFile, let inside = feed.engineIndex else { return nil }
            return fact(inside, embedded: true)
        }
        .sorted { $0.index < $1.index }
    }

    /// Stores `facts` in `folder` (after the files are there). Nothing to say writes nothing.
    public static func write(_ facts: [SubtitleSidecar], to folder: URL) {
        guard !facts.isEmpty, let data = try? JSONEncoder().encode(facts) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(sidecarName), options: .atomic)
    }

    private static func read(_ folder: URL) -> [SubtitleSidecar] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(sidecarName)) else { return [] }
        return (try? JSONDecoder().decode([SubtitleSidecar].self, from: data)) ?? []
    }

    /// The subtitle streams of a stored title, sorted by index: every file in `folder` (the facts' values where there are
    /// some, otherwise only the format from the ending, for a download made before the facts were stored) and the embedded
    /// tracks the facts name. Empty without a folder.
    public static func streams(in folder: URL) -> [MediaStream] {
        let facts = read(folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var rows: [MediaStream] = []
        var filed = Set<Int>()
        for name in names {
            guard let index = Int(name.split(separator: ".").first ?? ""), !filed.contains(index) else { continue }
            filed.insert(index)
            let ending = name.split(separator: ".").last.map { $0.lowercased() } ?? "srt"
            let fact = facts.first { $0.index == index && $0.embedded != true }
            let format: String =
                switch ending {
                case "srt": "subrip"
                case "vtt": "webvtt"
                default: ending
                }
            rows.append(stream(fact ?? SubtitleSidecar(index: index, codec: format), external: true))
        }
        for fact in facts where fact.embedded == true && !filed.contains(fact.index) {
            filed.insert(fact.index)
            rows.append(stream(fact, external: false))
        }
        return rows.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    private static func stream(_ fact: SubtitleSidecar, external: Bool) -> MediaStream {
        // Without a language or a title the label rule has nothing to say: the row is still named by what it is.
        let named = (fact.language ?? "").isEmpty && (fact.title ?? "").isEmpty
        let name = named
            ? [TechDetails.codecNameValue(fact.codec), external ? translated("Datei") : nil].compactMap { $0 }.joined(separator: " · ")
            : nil
        return MediaStream(
            codec: fact.codec, type: "Subtitle", language: fact.language, displayTitle: name?.isEmpty == false ? name : nil,
            channels: nil, isDefault: nil, index: fact.index, height: nil, width: nil, isForced: fact.forced,
            isExternal: external, title: fact.title, isHearingImpaired: fact.hearingImpaired)
    }

    /// The description of a file on the device for the player: the stored runtime (a built download has no duration in its
    /// header, so the engine could not plan segments) and the subtitle streams of ``streams(in:)``. `nil` when there is neither.
    public static func source(runtimeTicks: Int64?, folder: URL) -> MediaSource? {
        struct Shape: Encodable {
            let runTimeTicks: Int64?
            let mediaStreams: [MediaStream]
            enum CodingKeys: String, CodingKey { case runTimeTicks = "RunTimeTicks", mediaStreams = "MediaStreams" }
        }
        let ticks = runtimeTicks.flatMap { $0 > 0 ? $0 : nil }
        let rows = streams(in: folder)
        guard ticks != nil || !rows.isEmpty,
              let data = try? JSONEncoder().encode(Shape(runTimeTicks: ticks, mediaStreams: rows)) else { return nil }
        return try? JSONDecoder().decode(MediaSource.self, from: data)
    }
}
