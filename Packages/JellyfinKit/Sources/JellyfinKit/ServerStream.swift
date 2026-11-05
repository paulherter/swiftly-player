import Foundation

/// **Someone playing something on the server right now** (`GET /Sessions`, only sessions with
/// a `NowPlayingItem`), and everything the card on the administrator's page says about it.
///
/// The card reads top to bottom: what (poster, title, year, who), in which form (resolution, range,
/// codecs as badges), on what (device, app, address), how far (progress, time), and how the
/// server delivers it and at what rate (Direct Play, Direct Stream, transcoding). All the
/// wording is decided here so iPhone and Android say the same.
public struct ServerStream: Sendable, Equatable, Identifiable, Decodable {
    /// **Session and title together.** The card is rebuilt (poster, badges) only when this
    /// changes: a new session, or the same one moving on to the next episode. Position and
    /// pause change every second under the same id.
    public var id: String { sessionID + "/" + item.id }
    public let sessionID: String
    public let userID: String?
    public let userName: String
    public let userImageTag: String?
    public let client: String
    public let device: String
    public let address: String?
    let item: Playing
    let state: PlayState
    let transcoding: Transcoding?

    enum CodingKeys: String, CodingKey {
        case sessionID = "Id", userID = "UserId", userName = "UserName", userImageTag = "UserPrimaryImageTag"
        case client = "Client", device = "DeviceName", address = "RemoteEndPoint"
        case item = "NowPlayingItem", state = "PlayState", transcoding = "TranscodingInfo"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        userID = try? c.decodeIfPresent(String.self, forKey: .userID)
        userName = (try? c.decode(String.self, forKey: .userName)) ?? ""
        userImageTag = try? c.decodeIfPresent(String.self, forKey: .userImageTag)
        client = (try? c.decode(String.self, forKey: .client)) ?? ""
        device = (try? c.decode(String.self, forKey: .device)) ?? ""
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        item = try c.decode(Playing.self, forKey: .item)
        state = (try? c.decode(PlayState.self, forKey: .state)) ?? PlayState()
        transcoding = try? c.decodeIfPresent(Transcoding.self, forKey: .transcoding)
    }

    /// Only sessions that play something; the others are open apps.
    public static func playing(_ data: Data, decoder: JSONDecoder) throws -> [ServerStream] {
        struct Loose: Decodable {
            let stream: ServerStream?
            init(from decoder: Decoder) throws { stream = try? ServerStream(from: decoder) }
        }
        return try decoder.decode([Loose].self, from: data).compactMap(\.stream)
    }

    // MARK: What

    /// The film, the series, the song.
    public var title: String {
        switch item.type {
        case "Episode": item.seriesName ?? item.name
        default: item.name
        }
    }

    /// After the title, quieter: the year of a film, "S1 · E3" of an episode, the artist of a song.
    public var titleAddition: String? {
        switch item.type {
        case "Episode":
            guard let s = item.season, let e = item.episode else { return nil }
            return translated("S\(s) · F\(e)")
        case "Audio":
            return item.albumArtist ?? item.artists?.first
        default:
            return item.year.map(String.init)
        }
    }

    /// The episode's own name under the series; nothing for the rest.
    public var subtitle: String? {
        item.type == "Episode" && item.seriesName != nil ? item.name : nil
    }

    /// Whose image is the poster: the series for an episode, the album for a song.
    public var posterID: String {
        switch item.type {
        case "Episode" where item.seriesID != nil && item.seriesImageTag != nil: item.seriesID!
        case "Audio" where item.albumID != nil && item.albumImageTag != nil: item.albumID!
        default: item.id
        }
    }
    public var posterTag: String? {
        switch item.type {
        case "Episode" where item.seriesID != nil && item.seriesImageTag != nil: item.seriesImageTag
        case "Audio" where item.albumID != nil && item.albumImageTag != nil: item.albumImageTag
        default: item.primaryTag
        }
    }
    /// Music has square covers, everything else portrait posters.
    public var squarePoster: Bool { item.type == "Audio" || item.type == "MusicAlbum" }
    public var isAudio: Bool { item.mediaType == "Audio" || item.type == "Audio" }

    // MARK: In which form

    /// One badge on the card. The kind decides the colour, on every platform the same.
    public struct Badge: Sendable, Equatable {
        public enum Kind: String, Sendable { case resolution, range, video, audio }
        public let kind: Kind
        public let text: String
    }

    var videoTrack: Track? { item.streams.first { $0.type == "Video" } }
    var audioTrack: Track? {
        let audio = item.streams.filter { $0.type == "Audio" }
        if let i = state.audioIndex, let chosen = audio.first(where: { $0.index == i }) { return chosen }
        return audio.first { $0.isDefault == true } ?? audio.first
    }

    /// Resolution, range, video codec, audio codec with channels, as far as known.
    ///
    /// **The file, not the output.** What the server makes of it is in ``deliveryLine``; the
    /// badges say what lies on the disk, so a transcoded 4K HEVC stays recognisable as one.
    public var badges: [Badge] {
        var list: [Badge] = []
        if let v = videoTrack {
            if let r = Self.resolution(width: v.width, height: v.height) { list.append(.init(kind: .resolution, text: r)) }
            if let r = Self.range(v.rangeType) { list.append(.init(kind: .range, text: r)) }
            if let c = TechDetails.codecNameValue(v.codec) { list.append(.init(kind: .video, text: c)) }
        }
        if let a = audioTrack, let c = TechDetails.codecNameValue(a.codec) {
            let channels = Self.channels(a.channels)
            list.append(.init(kind: .audio, text: channels.map { "\(c) \($0)" } ?? c))
        }
        return list
    }

    /// What goes over the line: the transcoder's rate, else the file's tracks together.
    var bitrate: Double? {
        if let t = transcoding?.bitrate, t > 0 { return Double(t) }
        let sum = item.streams.filter { $0.type == "Video" || $0.type == "Audio" }
            .compactMap(\.bitRate).reduce(0, +)
        return sum > 0 ? Double(sum) : nil
    }

    /// "8K", "4K", "1080p", "720p", "SD". Width first: a scope film is 3840×1600 and still 4K.
    /// The same buckets as the Jelly Twiggy plugin, so the badge and the library counts agree.
    public static func resolution(width: Int?, height: Int?) -> String? {
        let w = width ?? 0, h = height ?? 0
        if w <= 0 && h <= 0 { return nil }
        if w >= 7000 || h >= 4000 { return "8K" }
        if w >= 3200 || h >= 2000 { return "4K" }
        if w >= 1800 || h >= 1000 { return "1080p" }
        if w >= 1200 || h >= 700 { return "720p" }
        return "SD"
    }

    /// "DV", "HDR10+", "HDR10", "HLG"; nothing for SDR, which is the normal case.
    public static func range(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix("DOVI"), raw != "DOVIInvalid" { return "DV" }
        switch raw {
        case "HDR10Plus": return "HDR10+"
        case "HDR10": return "HDR10"
        case "HLG": return "HLG"
        default: return nil
        }
    }

    /// "2.0", "5.1", "7.1" next to an audio codec, where "Stereo" would be a word among codes.
    static func channels(_ count: Int?) -> String? {
        switch count {
        case .some(1): "1.0"
        case .some(2): "2.0"
        case .some(6): "5.1"
        case .some(8): "7.1"
        case .some(let n) where n > 0: "\(n)ch"
        default: nil
        }
    }

    // MARK: On what

    /// "iPhone · Swiftly Player · 192.168.1.20": device, app, address.
    public var deviceLine: String {
        [device, client, address ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: How far

    public var position: Double { Double(state.positionTicks ?? 0) / 10_000_000 }
    public var runtime: Double? { item.runtimeTicks.map { Double($0) / 10_000_000 }.flatMap { $0 > 0 ? $0 : nil } }
    public var paused: Bool { state.paused ?? false }
    /// 0...1 for the bar.
    public var share: Double {
        guard let r = runtime else { return 0 }
        return min(max(position / r, 0), 1)
    }
    /// "0:42 / 2:05:33"; without a runtime only the position.
    public var timeLine: String {
        let now = Self.clock(position, long: (runtime ?? position) >= 3600)
        guard let r = runtime else { return now }
        return "\(now) / \(Self.clock(r, long: r >= 3600))"
    }

    /// "4:07" or "1:04:07". Hours only when the whole runs that long, so both sides match.
    static func clock(_ seconds: Double, long: Bool) -> String {
        let t = max(Int(capped: seconds), 0)
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return long ? "\(h):\(two(m)):\(two(s))" : "\(t / 60):\(two(s))"
    }

    // MARK: How

    /// The server's `PlayMethod`. A transcoding session whose picture and sound both pass
    /// unchanged is only a new container: that is Direct Stream, not the expensive case.
    public var delivery: DeliveryMethod {
        switch state.playMethod {
        case "DirectPlay": return .directPlay
        case "DirectStream": return .directStream
        case "Transcode":
            if let t = transcoding, t.videoDirect == true, t.audioDirect == true { return .directStream }
            return .transcode
        default:
            return transcoding == nil ? .directPlay : .transcode
        }
    }

    /// The word for ``delivery`` ("Direct Play", "Transkodiert"); its colour by `TechDetails.weight`.
    public var deliveryText: String { TechDetails.delivery(delivery) }

    /// **How and how fast, in one pill**: "Direct Play · 26 Mb/s". The rate sits with the
    /// method because together they answer the administrator's question (does this cost the
    /// server, does it fit the line); short units so the pill fits beside the time on a phone.
    public var deliveryLine: String {
        guard let rate = Self.shortRate(bitrate) else { return deliveryText }
        return "\(deliveryText) · \(rate)"
    }

    /// "26 Mb/s" from 10 Mbit up, "4.5 Mb/s" below, "320 kb/s" under one megabit. Latin units
    /// like every other technical value next to it (see `DownloadRules.sizeLocale`).
    static func shortRate(_ bitPerSecond: Double?) -> String? {
        guard let b = bitPerSecond, b > 0 else { return nil }
        if b >= 10_000_000 { return "\(Int((b / 1_000_000).rounded())) Mb/s" }
        if b >= 1_000_000 { return String(format: "%.1f Mb/s", b / 1_000_000) }
        return "\(Int((b / 1_000).rounded())) kb/s"
    }

    // MARK: Wire

    struct Track: Decodable, Equatable, Sendable {
        let type: String?
        let codec: String?
        let width: Int?
        let height: Int?
        let rangeType: String?
        let channels: Int?
        let bitRate: Int?
        let index: Int?
        let isDefault: Bool?
        enum CodingKeys: String, CodingKey {
            case type = "Type", codec = "Codec", width = "Width", height = "Height"
            case rangeType = "VideoRangeType", channels = "Channels", bitRate = "BitRate"
            case index = "Index", isDefault = "IsDefault"
        }
    }

    struct Playing: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let type: String?
        let mediaType: String?
        let year: Int?
        let seriesName: String?
        let seriesID: String?
        let seriesImageTag: String?
        let season: Int?
        let episode: Int?
        let albumID: String?
        let albumImageTag: String?
        let albumArtist: String?
        let artists: [String]?
        let runtimeTicks: Int64?
        let primaryTag: String?
        let streams: [Track]

        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type", mediaType = "MediaType", year = "ProductionYear"
            case seriesName = "SeriesName", seriesID = "SeriesId", seriesImageTag = "SeriesPrimaryImageTag"
            case season = "ParentIndexNumber", episode = "IndexNumber"
            case albumID = "AlbumId", albumImageTag = "AlbumPrimaryImageTag", albumArtist = "AlbumArtist"
            case artists = "Artists", runtimeTicks = "RunTimeTicks", imageTags = "ImageTags", streams = "MediaStreams"
        }
        enum ImageKeys: String, CodingKey { case primary = "Primary" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            mediaType = try? c.decodeIfPresent(String.self, forKey: .mediaType)
            year = try? c.decodeIfPresent(Int.self, forKey: .year)
            seriesName = try? c.decodeIfPresent(String.self, forKey: .seriesName)
            seriesID = try? c.decodeIfPresent(String.self, forKey: .seriesID)
            seriesImageTag = try? c.decodeIfPresent(String.self, forKey: .seriesImageTag)
            season = try? c.decodeIfPresent(Int.self, forKey: .season)
            episode = try? c.decodeIfPresent(Int.self, forKey: .episode)
            albumID = try? c.decodeIfPresent(String.self, forKey: .albumID)
            albumImageTag = try? c.decodeIfPresent(String.self, forKey: .albumImageTag)
            albumArtist = try? c.decodeIfPresent(String.self, forKey: .albumArtist)
            artists = try? c.decodeIfPresent([String].self, forKey: .artists)
            runtimeTicks = try? c.decodeIfPresent(Int64.self, forKey: .runtimeTicks)
            let images = try? c.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageTags)
            primaryTag = try? images?.decodeIfPresent(String.self, forKey: .primary)
            streams = (try? c.decode([Track].self, forKey: .streams)) ?? []
        }
    }

    struct PlayState: Decodable, Equatable, Sendable {
        var positionTicks: Int64? = nil
        var paused: Bool? = nil
        var playMethod: String? = nil
        var audioIndex: Int? = nil
        enum CodingKeys: String, CodingKey {
            case positionTicks = "PositionTicks", paused = "IsPaused", playMethod = "PlayMethod"
            case audioIndex = "AudioStreamIndex"
        }
    }

    struct Transcoding: Decodable, Equatable, Sendable {
        let videoDirect: Bool?
        let audioDirect: Bool?
        let bitrate: Int?
        enum CodingKeys: String, CodingKey {
            case videoDirect = "IsVideoDirect", audioDirect = "IsAudioDirect", bitrate = "Bitrate"
        }
    }
}
