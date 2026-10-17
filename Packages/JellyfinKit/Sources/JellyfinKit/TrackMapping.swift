import Foundation

/// An audio or subtitle track as the player lists it.
///
/// **Not a VLC object, only its data**, so the mapping lives in the package,
/// is testable without a player and Android, Linux and Windows get it without a
/// copy. libVLC 4 delivers the same fields everywhere.
public struct PlayerTrack: Sendable, Equatable {
    /// libVLC's track ID (`trackId`): `audio/1`, `spu/3`, for a sideloaded file
    /// `<md5 of the address>/spu/0`.
    public let identifier: String
    public let name: String
    /// As libVLC reports it: `ger`, `German` or empty.
    public let language: String?
    /// In the spelling of ``Technikangaben/codecname(_:)``, otherwise `nil`.
    public let codec: String?
    public let channels: Int?

    public init(identifier: String, name: String, language: String?, codec: String?, channels: Int?) {
        self.identifier = identifier; self.name = name; self.language = language
        self.codec = codec; self.channels = channels
    }

    /// Does the track come from a sideloaded file? libVLC then puts the MD5 of the
    /// address before the type (`src/input/es_out.c`, `EsOutCreateStrId`;
    /// `input.c`, `InputSourceNew`). Tracks of the file itself have no prefix.
    public var additionId: String? {
        guard let firstOne = identifier.split(separator: "/").first, firstOne.count == 32,
              firstOne.allSatisfy(\.isHexDigit) else { return nil }
        return String(firstOne)
    }

    /// Subtitles libVLC extracts from a video track (`.../cc/...`). The server does
    /// not know them.
    var isSubtitleOutImage: Bool { identifier.contains("/cc/") }
}

/// A subtitle file next to the film that the player loads separately.
public struct SubtitleFile: Sendable, Equatable {
    /// Jellyfin's `Index` of the `MediaStream`.
    public let index: Int
    public let address: URL
    /// MD5 of `address.absoluteString` as lowercase hex, which is how the track is
    /// recognized in the player. `nil` if the platform cannot compute an MD5;
    /// order counts then.
    public let attribute: String?

    public init(index: Int, address: URL, attribute: String?) {
        self.index = index; self.address = address; self.attribute = attribute
    }

    /// The external subtitles of a source with a full address.
    ///
    /// `DeliveryUrl` is server-relative and carries no key; it is appended as for
    /// the playback address (`ApiKey`).
    public static func from(streams: [MediaStream], server: URL, key: String?,
                           attribute: (URL) -> String? = { _ in nil }) -> [SubtitleFile] {
        streams.compactMap { feed in
            guard feed.type == "Subtitle", feed.isExternal == true,
                  let index = feed.index, let path = feed.deliveryUrl, !path.isEmpty,
                  let whole = AppModelURLNormalizer.serverRelative(path, base: server),
                  var parts = URLComponents(url: whole, resolvingAgainstBaseURL: false)
            else { return nil }
            let available = parts.queryItems ?? []
            if let key, !available.contains(where: { ["apikey", "api_key"].contains($0.name.lowercased()) }) {
                parts.queryItems = available + [URLQueryItem(name: "ApiKey", value: key)]
            }
            guard let address = parts.url else { return nil }
            return SubtitleFile(index: index, address: address, attribute: attribute(address))
        }
    }

    /// **Which subtitles travel with a download.**
    ///
    /// For the original only the external ones: embedded ones are in the file. A
    /// **converted** file carries only picture and sound, so the embedded text
    /// subtitles are added, extracted by the server as their own file
    /// (`/Videos/{id}/{quelle}/Subtitles/{index}/0/Stream.srt`). Image-based ones
    /// (PGS, VobSub, DVB) cannot be extracted as text and are missing; burning in
    /// would mean always showing them.
    public static func withLoad(streams: [MediaStream], itemID: String, source: String?,
                                server: URL, key: String?,
                                converted: Bool) -> [SubtitleFile] {
        var files = from(streams: streams, server: server, key: key)
        guard converted, let source, !source.isEmpty else { return files }
        let already = Set(files.map(\.index))
        for feed in streams where feed.type == "Subtitle" && feed.isExternal != true {
            guard let index = feed.index, !already.contains(index),
                  let suffix = textSuffix(feed.codec) else { continue }
            var parts = URLComponents(
                url: server.appendingPathComponent("Videos/\(itemID)/\(source)/Subtitles/\(index)/0/Stream.\(suffix)"),
                resolvingAgainstBaseURL: false)
            if let key { parts?.queryItems = [URLQueryItem(name: "ApiKey", value: key)] }
            guard let address = parts?.url else { continue }
            files.append(SubtitleFile(index: index, address: address, attribute: nil))
        }
        return files.sorted { $0.index < $1.index }
    }

    /// The file extension in which the server outputs an embedded text subtitle,
    /// `nil` for image subtitles. ASS stays ASS so font and position are kept;
    /// everything else becomes SRT.
    static func textSuffix(_ codec: String?) -> String? {
        switch codec?.lowercased() {
        case "ass", "ssa": "ass"
        case "subrip", "srt", "webvtt", "vtt", "mov_text", "text", "tx3g", "microdvd", "sami", "smi":
            "srt"
        default: nil
        }
    }
}

/// Which track in the player is which `MediaStream` of the server.
///
/// **By order per type, with a cross-check.** Server and libVLC both list the
/// tracks of a file in file order. If count, language and codec match pairwise,
/// the position counts. If the count differs (libVLC drops tracks it cannot
/// read), only what language or codec can confirm is assigned; the rest stays
/// `nil` instead of guessed.
///
/// Sideloaded subtitle files count separately: they are recognized by the MD5 of
/// their address (as in Swiftfin), otherwise by order.
///
/// Matching by track name alone does not work: two tracks named "Deutsch"
/// cannot be told apart.
public struct TrackMapping: Sendable, Equatable {
    /// Jellyfin index per position in the player's audio track list.
    public let audio: [Int?]
    /// Jellyfin index per position in the player's subtitle list.
    public let subtitle: [Int?]

    public init(audio: [Int?] = [], subtitle: [Int?] = []) {
        self.audio = audio; self.subtitle = subtitle
    }

    public static func compose(audio: [PlayerTrack], subtitle: [PlayerTrack],
                              streams: [MediaStream], files: [SubtitleFile]) -> TrackMapping {
        let audioStreams = streams.filter { $0.type == "Audio" && $0.isExternal != true }
        let audioIndices = arrange(audio, audioStreams)

        var utIndices = [Int?](repeating: nil, count: subtitle.count)
        // Sideloaded first: they must not count when counting the embedded ones.
        var opened = files
        var withoutRememberTimes: [Int] = []
        for (position, track) in subtitle.enumerated() {
            guard let addition = track.additionId else { continue }
            if let hit = opened.firstIndex(where: { $0.attribute?.lowercased() == addition.lowercased() }) {
                utIndices[position] = opened.remove(at: hit).index
            } else {
                withoutRememberTimes.append(position)
            }
        }
        // Without attributes only if it adds up: a file that was not loaded would
        // otherwise shift all following ones.
        if !withoutRememberTimes.isEmpty, withoutRememberTimes.count == opened.count {
            for (position, file) in zip(withoutRememberTimes, opened) { utIndices[position] = file.index }
        }

        let embeddedPositions = subtitle.indices.filter {
            subtitle[$0].additionId == nil && !subtitle[$0].isSubtitleOutImage
        }
        let utStreams = streams.filter { $0.type == "Subtitle" && $0.isExternal != true }
        let embedded = arrange(embeddedPositions.map { subtitle[$0] }, utStreams)
        for (i, position) in embeddedPositions.enumerated() { utIndices[position] = embedded[i] }

        return TrackMapping(audio: audioIndices, subtitle: utIndices)
    }

    /// **The wanted tracks as a position per type, before opening.**
    ///
    /// libVLC takes `:audio-track=N` and `:sub-track=N` as the Nth track of its type
    /// in the order the demuxer creates them, the same file order the server
    /// counts in (see above). Setting the track this way at open starts with it
    /// right away; before, VLC's own choice started first and was switched after
    /// the first frame, with a new audio decoder and a rebuilt audio output.
    ///
    /// `nil` means: not to be set at open. Subtitle files are excluded, they attach
    /// to the stream only after opening. Whether the position is right is checked
    /// later by ``bilden(audio:subtitle:stroeme:dateien:)``; only what differs is
    /// then set.
    public static func startPositions(streams: [MediaStream], audio: Int?,
                                       subtitle: TrackRule.Subtitle) -> (audio: Int?, subtitle: Int?) {
        let audioStreams = streams.filter { $0.type == "Audio" && $0.isExternal != true }
        let utStreams = streams.filter { $0.type == "Subtitle" && $0.isExternal != true }
        let audioPosition = audio.flatMap { index in audioStreams.firstIndex { $0.index == index } }
        var utPosition: Int?
        if case .feed(let index) = subtitle {
            utPosition = utStreams.firstIndex { $0.index == index }
        }
        return (audioPosition, utPosition)
    }

    public func audioPositionValue(index: Int) -> Int? { audio.firstIndex(of: index) }
    public func subtitlePosition(index: Int) -> Int? { subtitle.firstIndex(of: index) }

    /// A list of one type: position if everything fits together, otherwise only
    /// what can be confirmed.
    static func arrange(_ tracks: [PlayerTrack], _ streams: [MediaStream]) -> [Int?] {
        if tracks.count == streams.count,
           zip(tracks, streams).allSatisfy({ compatibleWith($0, $1) }) {
            return streams.map(\.index)
        }
        var since = 0
        return tracks.map { track in
            guard let hit = streams.indices.dropFirst(since).first(where: {
                compatibleWith(track, streams[$0]) && used(track, streams[$0])
            }) else { return nil }
            since = hit + 1
            return streams[hit].index
        }
    }

    /// Nothing speaks against it: language and codec do not contradict where both
    /// sides know them.
    static func compatibleWith(_ track: PlayerTrack, _ feed: MediaStream) -> Bool {
        if let a = language(track.language), let b = language(feed.language), a != b { return false }
        if let a = track.codec, let b = TechDetails.codecNameValue(feed.codec), a != b { return false }
        return true
    }

    /// Something speaks for it: the same language or the same codec.
    static func used(_ track: PlayerTrack, _ feed: MediaStream) -> Bool {
        if let a = language(track.language), a == language(feed.language) { return true }
        if let a = track.codec, a == TechDetails.codecNameValue(feed.codec) { return true }
        return false
    }

    /// Only languages that can be recognized reliably count as a contradiction;
    /// otherwise "pol" against "Polish" would be one.
    static func language(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return Language.detected(in: raw)
    }
}

/// What the next episode should recognize about a track.
///
/// **Similarity instead of name** (like jellyfin-web and Streamyfin): the
/// language must match, then title, forced, codec, position and channels
/// decide. So "German full" in the next episode does not hit "German forced",
/// even if both have the same name.
public struct TrackImprint: Codable, Sendable, Equatable {
    enum CodingKeys: String, CodingKey {
        case language = "sprache"
        case codec
        case title = "titel"
        case forced = "erzwungen"
        case channels = "kanaele"
        case position
        case extern
        case name
        case hearingImpaired = "hoergeschaedigt"
    }
    public var language: String?
    public var codec: String?
    public var title: String?
    public var forced: Bool
    public var channels: Int?
    /// Position among the tracks of the same type at the server.
    public var position: Int?
    public var extern: Bool
    /// Track name in the player, for information only.
    public var name: String?
    /// For the hearing impaired (SDH). Optional because older snapshots do not
    /// carry it; it does not count there.
    public var hearingImpaired: Bool?

    public init(language: String?, codec: String?, title: String?, forced: Bool,
                channels: Int?, position: Int?, extern: Bool, name: String?,
                hearingImpaired: Bool? = nil) {
        self.language = language; self.codec = codec; self.title = title
        self.forced = forced; self.channels = channels; self.position = position
        self.extern = extern; self.name = name; self.hearingImpaired = hearingImpaired
    }

    /// From a server stream.
    public init(feed: MediaStream, in streams: [MediaStream], name: String? = nil) {
        let art = streams.filter { $0.type == feed.type }
        self.init(language: feed.language, codec: feed.codec, title: feed.title,
                  forced: feed.isForced == true,
                  channels: feed.type == "Audio" ? feed.channels : nil,
                  position: art.firstIndex(of: feed), extern: feed.isExternal == true,
                  name: name,
                  hearingImpaired: feed.type == "Subtitle" ? feed.isHearingImpaired == true : nil)
    }

    /// From a player track that could not be assigned to a stream.
    public init(track: PlayerTrack) {
        self.init(language: track.language, codec: nil, title: nil,
                  forced: Language.soundsForced(track.name),
                  channels: track.channels, position: nil, extern: track.additionId != nil,
                  name: track.name)
    }

    /// The stream closest to the snapshot, or `nil`.
    ///
    /// If a language is remembered, it must match: English is no substitute for
    /// German, even if codec and position fit.
    public func bester(under streams: [MediaStream], art: String) -> MediaStream? {
        let candidates = streams.filter { $0.type == art }
        let rememberedLanguage = Self.languageKey(language)
        var bester: (feed: MediaStream, points: Int)?
        for (position, feed) in candidates.enumerated() {
            if let rememberedLanguage, Self.languageKey(feed.language) != rememberedLanguage { continue }
            var points = rememberedLanguage == nil ? 0 : 3
            if let title, !title.isEmpty, title == feed.title { points += 2 }
            if forced == (feed.isForced == true) { points += 2 }
            if let hearingImpaired, hearingImpaired == (feed.isHearingImpaired == true) { points += 2 }
            if let codec, TechDetails.codecNameValue(codec) == TechDetails.codecNameValue(feed.codec) { points += 1 }
            if position == self.position { points += 1 }
            if let channels, channels == feed.channels { points += 1 }
            if extern == (feed.isExternal == true) { points += 1 }
            if bester == nil || points > bester!.points { bester = (feed, points) }
        }
        // Without a language a chance coincidence is not enough.
        guard let bester, bester.points >= 3 else { return nil }
        return bester.feed
    }

    /// `ger`, `deu` and "German" are the same language.
    static func languageKey(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !["und", "unknown", "mis", "zxx"].contains(raw.lowercased())
        else { return nil }
        return Language.detected(in: raw) ?? raw.lowercased()
    }
}
