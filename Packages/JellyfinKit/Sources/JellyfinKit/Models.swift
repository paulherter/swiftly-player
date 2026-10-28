import Foundation

// MARK: - Server

public struct PublicSystemInfo: Codable, Sendable, Equatable {
    public let serverName: String?
    public let version: String?
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

// MARK: - Auth

public struct AuthenticationResult: Codable, Sendable {
    public let accessToken: String
    public let serverId: String?
    public let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverId = "ServerId"
        case user = "User"
    }
}

public struct User: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

// MARK: - Items

public struct ItemsResponse: Codable, Sendable {
    public let items: [Item]
    public let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(items: [Item], totalRecordCount: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }

    /// Decodes leniently.
    ///
    /// Two hardenings against failures that used to topple a whole response:
    /// a single entry without `Name` made the **entire** list fail, leaving the
    /// screen empty without a word, and `TotalRecordCount` is missing entirely
    /// on some endpoints.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent(Lenient<Item>.self, forKey: .items)?
            .values ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount)
            ?? items.count
    }
}

/// Decodes a field and skips what cannot be read.
///
/// A server that returns one broken entry should not make a list unusable.
/// The rest comes through.
struct Lenient<Amount: Decodable>: Decodable {
    let values: [Amount]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var collected: [Amount] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Amount.self) {
                collected.append(value)
            } else {
                // Consume it, otherwise the pointer stays put and the loop runs forever.
                _ = try? container.decode(Skipped.self)
            }
        }
        values = collected
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

public struct Item: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let type: String?
    public let collectionType: String?
    public let productionYear: Int?
    public let overview: String?
    public let runTimeTicks: Int64?
    /// Series context, for the line under the title in the player.
    public let seriesName: String?
    public let indexNumber: Int?          // episode
    public let parentIndexNumber: Int?    // season
    public let seriesId: String?
    /// Season an episode belongs to, so the series page opens the right season
    /// right away.
    public let seasonId: String?
    public let genres: [String]?
    public let officialRating: String?
    public let communityRating: Double?
    public let childCount: Int?
    /// Trailers stored as a file on the server.
    public let localTrailerCount: Int?
    public let backdropImageTags: [String]?
    /// Poster of the series. Episodes carry only a 16:9 thumbnail of their own,
    /// which is useless in a portrait tile.
    public let seriesPrimaryImageTag: String?
    public let people: [Person]?
    public let studios: [NameID]?
    public let taglines: [String]?
    public let criticRating: Double?
    public let remoteTrailers: [MediaURL]?
    public let imageTags: [String: String]?
    public let userData: UserItemData?
    public let mediaSources: [MediaSource]?
    /// The backdrop of the **series**, delivered with every episode.
    ///
    /// An episode never has its own: `BackdropImageTags` is always empty for it,
    /// as verified against the server. Whoever wants an episode's backdrop must
    /// look here. It was not read at all before.
    public let parentBackdropImageTags: [String]?
    /// Which title the backdrop above belongs to.
    public let parentBackdropItemId: String?
    /// The landscape thumbnail of a title, if one is stored. Often maintained for
    /// series, rarely for episodes.
    public let parentThumbImageTag: String?
    /// The logo of the series, delivered with every episode.
    public let parentLogoImageTag: String?
    public let parentThumbItemId: String?
    /// For a person the birthday, otherwise the premiere date.
    public let premiereDate: String?
    /// For a person the birthplace.
    public let productionLocations: [String]?
    /// `Tmdb`, `Imdb` … Seerr finds a person via the TMDB id.
    public let providerIds: [String: String]?
    /// Kind of an extra (`Clip`, `BehindTheScenes`, `Interview`, `Trailer` …);
    /// set only on entries from `SpecialFeatures`.
    public let extraType: String?
    /// `Video`, `Audio` … Tells a video playlist from a music one.
    public let mediaType: String?
    /// **The name the server sorts by**: lowercased, leading articles dropped ("adam
    /// project" for "The Adam Project"). The alphabet index reads its letters from it so
    /// they match the order of an A–Z list (``AlphabetIndex``).
    public let sortName: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case productionYear = "ProductionYear"
        case overview = "Overview"
        case runTimeTicks = "RunTimeTicks"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case genres = "Genres"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case childCount = "ChildCount"
        case localTrailerCount = "LocalTrailerCount"
        case backdropImageTags = "BackdropImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case people = "People"
        case studios = "Studios"
        case taglines = "Taglines"
        case criticRating = "CriticRating"
        case remoteTrailers = "RemoteTrailers"
        case imageTags = "ImageTags"
        case userData = "UserData"
        case mediaSources = "MediaSources"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentLogoImageTag = "ParentLogoImageTag"
        case parentThumbItemId = "ParentThumbItemId"
        case premiereDate = "PremiereDate"
        case productionLocations = "ProductionLocations"
        case providerIds = "ProviderIds"
        case extraType = "ExtraType"
        case mediaType = "MediaType"
        case sortName = "SortName"
    }

    /// Names of the directors, for the line under the description.
    public var direction: [String] {
        (people ?? []).filter { $0.type == "Director" }.map(\.name)
    }

    /// Cast in order, without crew.
    public var actors: [Person] {
        (people ?? []).filter(\.isCast)
    }

    /// Series, season or collection; has no media file of its own.
    public var isContainer: Bool {
        ["Series", "Season", "BoxSet", "Folder", "CollectionFolder"].contains(type ?? "")
    }

    /// "S1 • F3" in German, "S1 • E3" in English; short, for button labels.
    ///
    /// **The letter is translated, not hard-wired.** It used to be a fixed "E",
    /// which is wrong in German: Netflix DE and the Apple TV app show "F" for
    /// "Folge"; "E" belongs only to "Episode". The tiles showed "F6, F7" while the
    /// play button showed "E7": the same value, two languages in one place.
    public var episodeCode: String? {
        guard let season = parentIndexNumber, let episode = indexNumber else { return nil }
        return translated("S\(season) • F\(episode)")
    }

    /// Fraction already watched, 0 to 1, for the progress bars.
    ///
    /// **Lifted here from `Sources/Shared/TitleDetails.swift`.** There it was
    /// unreachable for Linux, although nothing about it depends on UI or
    /// translation.
    public var watchedShare: Double? {
        guard let percent = userData?.playedPercentage, percent > 0 else { return nil }
        return percent / 100
    }

    public var isWatched: Bool { userData?.played ?? false }

    /// Second line for "Recently added": *what* was added.
    ///
    /// Jellyfin groups new episodes: if a whole season was added, the server
    /// returns a season, for single episodes the episode. The line must tell them
    /// apart, otherwise only the title shows everywhere.
    public var newArrivalsRow: String? {
        switch type {
        case "Episode":
            // The season, not the episode: in the row, a series stands for everything
            // that was added lately. "Season 3" answers "where does it continue"; a
            // single episode number does not.
            if let season = parentIndexNumber { return translated("Staffel \(season)") }
            if let episode = indexNumber { return translated("Folge \(episode)") }
            return nil
        case "Season":
            // Without a number the name carries the meaning, e.g. "Specials".
            if let number = indexNumber { return translated("Staffel \(number)") }
            return name
        case "Series":
            // `ChildCount` here is **not** the number of seasons.
            //
            // `Items/Latest` groups new episodes under their series, and the number
            // belongs to that group: this many episodes are new. Labeled as seasons, a
            // series with two seasons read "8 Staffeln" because eight episodes had
            // been added.
            //
            // The server does not say in this response which season it was.
            guard let count = childCount, count > 0 else {
                return productionYear.map(String.init)
            }
            return translated("\(count) neue Folgen")
        default:
            return productionYear.map(String.init)
        }
    }

    /// "S1 • F3 • 21 Jump Street" in German, "S1 • E3 • 21 Jump Street" in
    /// English; for a film the year.
    ///
    /// **The year for films.** Under "Continue watching", films showed only the
    /// remaining time although the year is shown everywhere else. One place for
    /// all platforms.
    public var contextLine: String? {
        var parts: [String] = []
        if let season = parentIndexNumber { parts.append(translated("S\(season)")) }
        if let episode = indexNumber { parts.append(translated("F\(episode)")) }
        if let series = seriesName { parts.append(series) }
        if parts.isEmpty, type == "Movie", let year = productionYear { parts.append(String(year)) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    /// Runtime in seconds. Jellyfin counts in 100-nanosecond ticks.
    public var runtimeSeconds: Double? {
        runTimeTicks.map { Double($0) / 10_000_000 }
    }
    /// A **provisional series** built from what an episode carries anyway.
    ///
    /// A list entry of an episode knows `seriesId` and `seriesName`, which is all a
    /// series page needs to open: the id for all further calls, the name for the
    /// heading, the genre for the branches. The backdrop is the same anyway;
    /// `landscapeImageURL` builds it from `seriesId ?? id`. Everything else (description,
    /// rating, season count) the page fetches itself and writes over it.
    ///
    /// **Why this is here and not in a view.** It is a statement about our data
    /// model, not about a UI, and here it can be tested without a simulator. `Item`
    /// has no public initializer, which is why other code had to build the same
    /// thing through a JSON detour.
    ///
    /// Returns `nil` if the episode names no series: then there is nothing to
    /// anticipate.
    public static func preCommonSeries(toward episode: Item) -> Item? {
        guard let id = episode.seriesId, let name = episode.seriesName else { return nil }
        return Item(id: id, name: name, type: "Series")
    }

    /// An entry made of the bare minimum. Everything else comes from the server.
    public init(id: String, name: String, type: String? = nil,
                collectionType: String? = nil, productionYear: Int? = nil,
                overview: String? = nil, runTimeTicks: Int64? = nil,
                seriesName: String? = nil, indexNumber: Int? = nil,
                parentIndexNumber: Int? = nil, seriesId: String? = nil,
                seasonId: String? = nil, genres: [String]? = nil,
                officialRating: String? = nil, communityRating: Double? = nil,
                childCount: Int? = nil, localTrailerCount: Int? = nil,
                backdropImageTags: [String]? = nil,
                seriesPrimaryImageTag: String? = nil, people: [Person]? = nil,
                studios: [NameID]? = nil, taglines: [String]? = nil,
                criticRating: Double? = nil, remoteTrailers: [MediaURL]? = nil,
                imageTags: [String: String]? = nil, userData: UserItemData? = nil,
                mediaSources: [MediaSource]? = nil,
                parentBackdropImageTags: [String]? = nil,
                parentBackdropItemId: String? = nil,
                parentThumbImageTag: String? = nil,
                parentLogoImageTag: String? = nil,
                parentThumbItemId: String? = nil,
                premiereDate: String? = nil,
                productionLocations: [String]? = nil,
                providerIds: [String: String]? = nil,
                extraType: String? = nil,
                mediaType: String? = nil,
                sortName: String? = nil) {
        self.id = id; self.name = name; self.type = type
        self.collectionType = collectionType; self.productionYear = productionYear
        self.overview = overview; self.runTimeTicks = runTimeTicks
        self.seriesName = seriesName; self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber; self.seriesId = seriesId
        self.seasonId = seasonId; self.genres = genres
        self.officialRating = officialRating; self.communityRating = communityRating
        self.childCount = childCount; self.localTrailerCount = localTrailerCount
        self.backdropImageTags = backdropImageTags
        self.seriesPrimaryImageTag = seriesPrimaryImageTag; self.people = people
        self.studios = studios; self.taglines = taglines
        self.criticRating = criticRating; self.remoteTrailers = remoteTrailers
        self.imageTags = imageTags; self.userData = userData
        self.mediaSources = mediaSources
        self.parentBackdropImageTags = parentBackdropImageTags
        self.parentBackdropItemId = parentBackdropItemId
        self.parentThumbImageTag = parentThumbImageTag
        self.parentLogoImageTag = parentLogoImageTag
        self.parentThumbItemId = parentThumbItemId
        self.premiereDate = premiereDate
        self.productionLocations = productionLocations
        self.providerIds = providerIds
        self.extraType = extraType
        self.mediaType = mediaType
        self.sortName = sortName
    }

}

// For NavigationLink(value:). The id is enough: it is unique across the
// server, and the other fields are partly not hashable.
extension Item: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct UserItemData: Codable, Sendable, Equatable {
    public let playbackPositionTicks: Int64?
    public let played: Bool?
    public let isFavorite: Bool?
    public let playedPercentage: Double?
    /// How many episodes of a series are still unwatched.
    ///
    /// **The server has always sent it; we never read it.** That is why a series
    /// tile could say nothing: the progress bar shows the state of the started
    /// *episode*, not of the series.
    public let unplayedItemCount: Int?
    /// `LastPlayedDate` **as the server sends it**, as text.
    ///
    /// Not as `Date`: `Item` is decoded in two places with the plain `JSONDecoder`
    /// (the tvOS top shelf, the Android core), which reads a date as a number. A
    /// `Date` field would have made the whole title unreadable there. It is read
    /// through ``lastPlay``.
    public let lastPlayedDate: String?

    public init(playbackPositionTicks: Int64? = nil, played: Bool? = nil,
                isFavorite: Bool? = nil, playedPercentage: Double? = nil,
                unplayedItemCount: Int? = nil, lastPlayedDate: String? = nil) {
        self.playbackPositionTicks = playbackPositionTicks
        self.played = played
        self.isFavorite = isFavorite
        self.playedPercentage = playedPercentage
        self.unplayedItemCount = unplayedItemCount
        self.lastPlayedDate = lastPlayedDate
    }

    /// When last played, for "newer state wins" (late report).
    public var lastPlay: Date? {
        guard let text = lastPlayedDate else { return nil }
        return TimestampFormat.read(text)
    }

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case isFavorite = "IsFavorite"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
        case lastPlayedDate = "LastPlayedDate"
    }
}

extension UserItemData {
    /// **The fraction is limited to 0 to 100 on decoding.**
    ///
    /// The tiles write it as an integer into the accessibility text
    /// (`Int(share * 100)`), and `Int` traps as soon as the value does not fit. A
    /// server with a broken runtime (one tick long, with a position at one hour)
    /// delivers exactly such a value. Reproduced in the tvOS simulator: the library
    /// crashed on the first draw of the tile. Limiting once here covers every place.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playbackPositionTicks = try c.decodeIfPresent(Int64.self, forKey: .playbackPositionTicks)
        played = try c.decodeIfPresent(Bool.self, forKey: .played)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite)
        playedPercentage = try c.decodeIfPresent(Double.self, forKey: .playedPercentage)
            .flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
        unplayedItemCount = try c.decodeIfPresent(Int.self, forKey: .unplayedItemCount)
        lastPlayedDate = try c.decodeIfPresent(String.self, forKey: .lastPlayedDate)
    }
}

/// A contributor. `role` is the role in the film, `type` the function
/// (Actor, Director, Writer …).
public struct Person: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let role: String?
    public let type: String?
    public let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }

    public var isCast: Bool { type == "Actor" }
}

public struct NameID: Codable, Sendable, Identifiable, Hashable {
    public let id: String?
    public let name: String?
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
}

public struct MediaURL: Codable, Sendable, Hashable {
    public let url: String?
    public let name: String?
    enum CodingKeys: String, CodingKey { case url = "Url", name = "Name" }
}

// MARK: - Playback

public struct PlaybackInfoResponse: Codable, Sendable {
    public let mediaSources: [MediaSource]
    public let playSessionId: String?
    /// Why the server names no version: `NotAllowed`, `NoCompatibleStream`,
    /// `RateLimitExceeded`. Comes only together with an empty source list; see
    /// ``JellyfinError/wiedergabeAbgelehnt(_:)``.
    public let errorCode: String?

    public init(mediaSources: [MediaSource], playSessionId: String?, errorCode: String? = nil) {
        self.mediaSources = mediaSources; self.playSessionId = playSessionId; self.errorCode = errorCode
    }

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }

    /// A refusal often carries no source list at all; without `decodeIfPresent`
    /// this became "Die Antwort des Servers war unverständlich" instead of the
    /// reason.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaSources = try c.decodeIfPresent([MediaSource].self, forKey: .mediaSources) ?? []
        playSessionId = try c.decodeIfPresent(String.self, forKey: .playSessionId)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

public struct MediaSource: Codable, Sendable, Identifiable, Equatable {
    public let id: String?
    public let name: String?
    public let container: String?
    public let size: Int64?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let supportsTranscoding: Bool?
    public let transcodingUrl: String?
    public let mediaStreams: [MediaStream]?
    /// Which audio and subtitle track the server would choose according to the
    /// user profile (audio language, subtitle mode, subtitle language). Subtitle
    /// `-1` means "none". See ``Spurregel``.
    public var defaultAudioStreamIndex: Int?
    public var defaultSubtitleStreamIndex: Int?
    /// The runtime of the file in ticks (hundred nanoseconds).
    public var runTimeTicks: Int64?

    /// The runtime in seconds, if the server knows it.
    ///
    /// **Why.** libVLC 4 reports no length for MPEG-TS over HTTP: `media.length`
    /// stays 0, while the same file locally has 60.6 s. Without a length there was
    /// no progress bar and no progress report to the server. TV recordings are TS.
    public var runtimeSeconds: Double? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        return Double(runTimeTicks) / 10_000_000
    }

    /// Picture height of the video track, for "2160p".
    public var height: Int? {
        mediaStreams?.first { $0.type == "Video" }?.height
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case size = "Size"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case runTimeTicks = "RunTimeTicks"
    }

    /// How the server would deliver this source. This is the number Swiftly cares
    /// about: everything except `.transcode` is a success.
    public var deliveryMethod: DeliveryMethod {
        if supportsDirectPlay == true { return .directPlay }
        if supportsDirectStream == true { return .directStream }
        return .transcode
    }
}

public enum DeliveryMethod: String, Sendable, Equatable {
    case directPlay = "Direct Play"
    case directStream = "Direct Stream"
    case transcode = "Transcode"

    public var isLossless: Bool { self != .transcode }

    /// The spelling Jellyfin expects in playback reports.
    /// Not identical to `rawValue`, which is for the UI.
    public var wireName: String {
        switch self {
        case .directPlay:   "DirectPlay"
        case .directStream: "DirectStream"
        case .transcode:    "Transcode"
        }
    }
}

/// **A number that cannot topple the response.**
///
/// A `Double?` with a synthesized decoder throws as soon as something other
/// than a number is there, and a throw during unwrapping takes not just the
/// field but **the whole response**. A detail that is only decoration must
/// never decide over playback.
///
/// That is exactly what is at stake: `RealFrameRate` is a floating-point number
/// in the data sheet, but depending on the source Jellyfin also writes numeric
/// fields as a string or not at all. A title whose value deviates would not be
/// playable at all, and nobody would guess the frame rate is the cause.
public struct NumberValue: Codable, Sendable, Equatable {
    public let value: Double?

    public init(_ value: Double?) { self.value = value }

    public init(from decoder: Decoder) throws {
        let space = try decoder.singleValueContainer()
        if let figure = try? space.decode(Double.self) { value = figure }
        else if let text = try? space.decode(String.self) { value = Double(text) }
        else { value = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var space = encoder.singleValueContainer()
        if let value { try space.encode(value) } else { try space.encodeNil() }
    }
}

public struct MediaStream: Codable, Sendable, Equatable {
    public init(codec: String?, type: String?, language: String?, displayTitle: String?,
                channels: Int?, isDefault: Bool?, index: Int?, height: Int?, width: Int?,
                realFrameRate: Double? = nil, averageFrameRate: Double? = nil,
                videoRangeType: ColorRange? = nil,
                colorTransfer: String? = nil, colorPrimaries: String? = nil,
                dvProfile: Int? = nil, dvBlSignalCompatibilityId: Int? = nil,
                isForced: Bool? = nil, isExternal: Bool? = nil,
                title: String? = nil, deliveryUrl: String? = nil,
                isHearingImpaired: Bool? = nil, aspectRatio: String? = nil) {
        self.title = title; self.deliveryUrl = deliveryUrl
        self.isHearingImpaired = isHearingImpaired; self.aspectRatio = aspectRatio
        self.codec = codec; self.type = type; self.language = language
        self.displayTitle = displayTitle; self.channels = channels
        self.isDefault = isDefault; self.index = index
        self.isForced = isForced; self.isExternal = isExternal
        self.height = height; self.width = width
        self.videoRankTypeRaw = videoRangeType?.rawValue
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.dvProfileRaw = dvProfile.map { NumberValue(Double($0)) }
        self.dvCompatibleRaw = dvBlSignalCompatibilityId.map { NumberValue(Double($0)) }
        self.realFrameRateRaw = NumberValue(realFrameRate)
        self.averageFrameRateRaw = NumberValue(averageFrameRate)
    }

    public let codec: String?
    public let type: String?          // Video | Audio | Subtitle
    public let language: String?
    public let displayTitle: String?
    public let channels: Int?
    public let isDefault: Bool?
    /// Forced subtitles: only the parts that are in a foreign language in the
    /// audio. Only the server knows this: VLC has no such attribute on the track.
    /// See ``Untertitelwahl``.
    public let isForced: Bool?
    /// A subtitle file next to the film instead of a track inside it. The player
    /// does not see it with Direct Play, so it must not count when enumerating.
    public let isExternal: Bool?
    /// Subtitles for the hearing impaired (SDH/CC): with sounds and speaker names.
    /// The file carries its own flag for this, which VLC does not show; without
    /// this field "Deutsch" and "Deutsch" stand side by side, and automatic
    /// selection took whichever came first.
    public let isHearingImpaired: Bool?
    /// The aspect ratio in which the picture is **displayed** ("16:9"); for
    /// anamorphic material not width to height of the pixels.
    public let aspectRatio: String?
    /// The track title from the file ("Forced", "SDH", "Kommentar"), unlike
    /// `DisplayTitle` without words added by the server.
    public let title: String?
    /// Where the server delivers an external subtitle file, relative to the server.
    /// Comes only if the device profile reports `External` for the format.
    public let deliveryUrl: String?
    public let index: Int?
    public let height: Int?
    public let width: Int?
    /// Dynamic range, transfer curve and primaries, see ``ColorRange``.
    ///
    /// They were not decoded at first, although the server always sends them. That
    /// is why Apple TV never switched into HDR mode.
    ///
    /// **Stored as a string, not as an enumeration, for a reason.**
    /// An unknown value makes a `String` enumeration throw, and because throwing
    /// makes the **whole** track unreadable, a new Jellyfin version with a new range
    /// type would have left every file without codec, channels and language. In the
    /// test this was not visible at first: `try?` let it pass even when nothing
    /// arrived.
    private let videoRankTypeRaw: String?

    public var videoRangeType: ColorRange? {
        videoRankTypeRaw.flatMap(ColorRange.init(rawValue:))
    }
    public let colorTransfer: String?
    public let colorPrimaries: String?

    /// The Dolby Vision profile (5, 7, 8 …) and the compatibility of the base
    /// layer (for profile 8: 1 = HDR10, 2 = SDR, 4 = HLG), together "8.1". Only
    /// for the tech badge; ``Technikangaben/dynamik(_:)``.
    ///
    /// Decoded as ``Zahlwert`` like the frame rates: a value that arrives as a
    /// string once should not make the whole track unreadable.
    private let dvProfileRaw: NumberValue?
    private let dvCompatibleRaw: NumberValue?

    public var dvProfile: Int? { dvProfileRaw?.value.flatMap { Int(exactly: $0) } }
    public var dvBlSignalCompatibilityId: Int? { dvCompatibleRaw?.value.flatMap { Int(exactly: $0) } }

    /// The frame rate of the track.
    ///
    /// **Why.** Apple TV can set its output to the frame rate of the film; without
    /// that, 23.976 is distributed unevenly over 60 Hz and the motion judders even
    /// though no frame is missing. Measured: butter smooth with matching, juddery
    /// without, at 4 late frames out of 4888.
    ///
    /// **Why it is here and not in the player.** VLC knows it only once the stream
    /// is open. The switch costs the TV a few seconds of black picture, and those
    /// should lie behind the loading screen, not stick out behind it. The server
    /// knows beforehand.
    ///
    /// `RealFrameRate` is the exact value, `AverageFrameRate` the averaged one;
    /// with a variable frame rate they differ.
    private let realFrameRateRaw: NumberValue?
    private let averageFrameRateRaw: NumberValue?

    public var realFrameRate: Double? { realFrameRateRaw?.value }
    public var averageFrameRate: Double? { averageFrameRateRaw?.value }

    /// The more reliable of the two, or `nil` if it cannot be trusted.
    ///
    /// **If the two differ clearly, the frame rate fluctuates.** Then there is no
    /// rate an output could be set to: whichever is taken, it fits only some of the
    /// time. Switching would be a black picture for nothing, so in that case this
    /// answer prefers to say nothing.
    public var frameRate: Double? {
        let plausibel = { (value: Double?) -> Double? in
            guard let value, value > 1, value < 250 else { return nil }
            return value
        }
        guard let real = plausibel(realFrameRate) else { return plausibel(averageFrameRate) }
        if let medium = plausibel(averageFrameRate), abs(real - medium) > 0.5 { return nil }
        return real
    }

    enum CodingKeys: String, CodingKey {
        case height = "Height"
        case videoRankTypeRaw = "VideoRangeType"
        case colorTransfer = "ColorTransfer"
        case colorPrimaries = "ColorPrimaries"
        case dvProfileRaw = "DvProfile"
        case dvCompatibleRaw = "DvBlSignalCompatibilityId"
        case width = "Width"
        case codec = "Codec"
        case type = "Type"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case channels = "Channels"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case isHearingImpaired = "IsHearingImpaired"
        case aspectRatio = "AspectRatio"
        case title = "Title"
        case deliveryUrl = "DeliveryUrl"
        case index = "Index"
        case realFrameRateRaw = "RealFrameRate"
        case averageFrameRateRaw = "AverageFrameRate"
    }

    /// Short, readable label, "Deutsch · DTS-HD MA 5.1".
    ///
    /// Jellyfin's `DisplayTitle` is unusable for one line; it contains things like
    /// "German Forced - Hörgeschädigt - Standard - Erzwungen - ASS".
    /// Here it is composed from language, codec and channels.
    public var short: String {
        var parts: [String] = []
        if let language = languageName { parts.append(language) }
        if let codec { parts.append(codecName(codec)) }
        // Below one channel the value is broken and is omitted.
        if let channels = channels, channels > 0, type == "Audio" {
            parts.append(channels == 2 ? translated("Stereo")
                       : channels == 1 ? translated("Mono")
                                      : "\(channels - 1).1")
        }
        return parts.isEmpty ? (displayTitle ?? "—") : parts.joined(separator: " · ")
    }

    /// Language in the interface's language, from the three-letter code; the rule is
    /// ``TrackLabel/language(_:locale:)``, so the details page and the player agree.
    public var languageName: String? {
        TrackLabel.language(language)
    }

    /// Also usable from outside.
    public static func readable(_ codec: String) -> String {
        MediaStream(codec: nil, type: nil, language: nil, displayTitle: nil,
                    channels: nil, isDefault: nil, index: nil, height: nil, width: nil)
            .codecName(codec)
    }

    private func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "dca", "dts":        "DTS"
        case "dtshd", "dts-hd":   "DTS-HD"
        case "truehd":            "TrueHD"
        case "eac3":              "Dolby Digital+"
        case "ac3":               "Dolby Digital"
        case "aac":               "AAC"
        case "flac":              "FLAC"
        case "opus":              "Opus"
        case "pgssub", "pgs":     "PGS"
        case "subrip", "srt":     "SRT"
        case "ass", "ssa":        "ASS"
        case "dvdsub", "vobsub":  "VOBSUB"
        case "hevc", "h265":      "HEVC"
        case "h264", "avc":       "H.264"
        case "av1":               "AV1"
        default:                  codec.uppercased()
        }
    }
}
