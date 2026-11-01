import Foundation

// The answers of a Plex server as they arrive on the wire (`Accept: application/json`).
//
// **Every field is optional and read leniently.** Plex writes the same field once as a
// number and once as a string depending on version and route (`"forced": 1`, `true`,
// `"1"`), and a field that fails to decode would take the whole list down with it.
// So nothing here throws for a single odd value; see ``Lenient`` for the same idea on
// the Jellyfin side.

extension KeyedDecodingContainer {
    func looseString(_ key: Key) -> String? {
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return text }
        if let number = (try? decodeIfPresent(Int64.self, forKey: key)) ?? nil { return String(number) }
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return String(number) }
        return nil
    }
    func looseDouble(_ key: Key) -> Double? {
        if let number = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return number }
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(text) }
        return nil
    }
    func looseInt(_ key: Key) -> Int? {
        if let number = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return number }
        if let number = looseDouble(key), number.isFinite, abs(number) < 9e15 { return Int(number) }
        return nil
    }
    func looseInt64(_ key: Key) -> Int64? { looseInt(key).map(Int64.init) }
    func looseBool(_ key: Key) -> Bool? {
        if let flag = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil { return flag }
        if let number = looseInt(key) { return number != 0 }
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            return ["1", "true", "yes"].contains(text.lowercased())
        }
        return nil
    }
    func looseList<T: Decodable>(_ key: Key, of: T.Type = T.self) -> [T]? {
        (try? decodeIfPresent(Lenient<T>.self, forKey: key))??.values
    }
}

/// Every Plex answer wraps its content in `MediaContainer`.
struct PlexEnvelope<Content: Decodable>: Decodable {
    let container: Content
    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

/// A tag on a title: genre, country, studio, person.
public struct PlexTag: Sendable, Equatable, Decodable {
    public let id: String?
    public let tag: String
    /// For a person the part played; for a director empty.
    public let role: String?
    /// For a person an absolute address (plex.tv metadata), otherwise `nil`.
    public let thumb: String?
    /// The ready-made query for `/all`, e.g. `genre=20`.
    public let filter: String?

    enum CodingKeys: String, CodingKey { case id, tag, role, thumb, filter }

    public init(id: String? = nil, tag: String, role: String? = nil,
                thumb: String? = nil, filter: String? = nil) {
        self.id = id; self.tag = tag; self.role = role; self.thumb = thumb; self.filter = filter
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let tag = c.looseString(.tag) else {
            throw DecodingError.keyNotFound(CodingKeys.tag, .init(codingPath: c.codingPath,
                                                                  debugDescription: "tag"))
        }
        self.tag = tag
        id = c.looseString(.id)
        role = c.looseString(.role)
        thumb = c.looseString(.thumb)
        filter = c.looseString(.filter)
    }
}

/// One entry in `Guid`: `imdb://tt0133093`, `tmdb://603`, `tvdb://78804`.
struct PlexGuid: Sendable, Equatable, Decodable {
    let id: String
}

public struct PlexStream: Sendable, Equatable, Decodable {
    public let id: Int
    /// 1 video, 2 audio, 3 subtitle.
    public let streamType: Int
    public let codec: String?
    public let index: Int?
    public let language: String?
    public let languageCode: String?
    public let displayTitle: String?
    public let title: String?
    public let selected: Bool
    public let isDefault: Bool
    public let forced: Bool
    public let hearingImpaired: Bool
    public let channels: Int?
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let bitDepth: Int?
    public let profile: String?
    public let colorTrc: String?
    public let colorPrimaries: String?
    public let dolbyVisionPresent: Bool
    public let dolbyVisionProfile: Int?
    public let dolbyVisionCompatibility: Int?
    /// Only for a subtitle **next to** the file (`/library/streams/{id}`); a track inside
    /// the container has none.
    public let key: String?
    /// Subtitle format (`srt`, `ass`), only for external ones.
    public let format: String?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, index, language, languageCode, displayTitle, title
        case selected, forced, channels, width, height, frameRate, bitDepth, profile
        case colorTrc, colorPrimaries, key, format
        case isDefault = "default"
        case hearingImpaired
        case dolbyVisionPresent = "DOVIPresent"
        case dolbyVisionProfile = "DOVIProfile"
        case dolbyVisionCompatibility = "DOVIBLCompatID"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.looseInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "id"))
        }
        self.id = id
        streamType = c.looseInt(.streamType) ?? 0
        codec = c.looseString(.codec)?.lowercased()
        index = c.looseInt(.index)
        language = c.looseString(.language)
        languageCode = c.looseString(.languageCode)
        displayTitle = c.looseString(.displayTitle)
        title = c.looseString(.title)
        selected = c.looseBool(.selected) ?? false
        isDefault = c.looseBool(.isDefault) ?? false
        forced = c.looseBool(.forced) ?? false
        hearingImpaired = c.looseBool(.hearingImpaired) ?? false
        channels = c.looseInt(.channels)
        width = c.looseInt(.width)
        height = c.looseInt(.height)
        frameRate = c.looseDouble(.frameRate)
        bitDepth = c.looseInt(.bitDepth)
        profile = c.looseString(.profile)
        colorTrc = c.looseString(.colorTrc)
        colorPrimaries = c.looseString(.colorPrimaries)
        dolbyVisionPresent = c.looseBool(.dolbyVisionPresent) ?? false
        dolbyVisionProfile = c.looseInt(.dolbyVisionProfile)
        dolbyVisionCompatibility = c.looseInt(.dolbyVisionCompatibility)
        key = c.looseString(.key)
        format = c.looseString(.format)
    }
}

public struct PlexPart: Sendable, Equatable, Decodable {
    public let id: Int
    /// `/library/parts/{id}/{changestamp}/file.mkv`: the original file.
    public let key: String
    public let duration: Int?
    public let size: Int64?
    public let container: String?
    public let file: String?
    /// `sd` when the server has made preview pictures (BIF).
    public let indexes: String?
    public let streams: [PlexStream]

    enum CodingKeys: String, CodingKey {
        case id, key, duration, size, container, file, indexes
        case streams = "Stream"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.looseInt(.id), let key = c.looseString(.key) else {
            throw DecodingError.keyNotFound(CodingKeys.key, .init(codingPath: c.codingPath,
                                                                  debugDescription: "key"))
        }
        self.id = id; self.key = key
        duration = c.looseInt(.duration)
        size = c.looseInt64(.size)
        container = c.looseString(.container)
        file = c.looseString(.file)
        indexes = c.looseString(.indexes)
        streams = c.looseList(.streams) ?? []
    }
}

/// One **version** of a title (`Media`): resolution, container, bitrate; holds the files.
public struct PlexMedia: Sendable, Equatable, Decodable {
    public let id: Int
    public let duration: Int?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let container: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let videoResolution: String?
    public let videoProfile: String?
    public let parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, width, height, container, videoCodec, audioCodec
        case videoResolution, videoProfile
        case parts = "Part"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.looseInt(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "id"))
        }
        self.id = id
        duration = c.looseInt(.duration)
        bitrate = c.looseInt(.bitrate)
        width = c.looseInt(.width)
        height = c.looseInt(.height)
        container = c.looseString(.container)
        videoCodec = c.looseString(.videoCodec)
        audioCodec = c.looseString(.audioCodec)
        videoResolution = c.looseString(.videoResolution)
        videoProfile = c.looseString(.videoProfile)
        parts = c.looseList(.parts) ?? []
    }
}

/// `type` is `intro`, `credits` or `commercial`; offsets in milliseconds.
public struct PlexMarker: Sendable, Equatable, Decodable {
    public let type: String
    public let start: Int
    public let end: Int
    /// The last credits marker: after it nothing follows.
    public let final: Bool

    enum CodingKeys: String, CodingKey {
        case type, final
        case start = "startTimeOffset"
        case end = "endTimeOffset"
    }

    public init(type: String, start: Int, end: Int, final: Bool = false) {
        self.type = type; self.start = start; self.end = end; self.final = final
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = c.looseString(.type), let start = c.looseInt(.start),
              let end = c.looseInt(.end) else {
            throw DecodingError.keyNotFound(CodingKeys.type, .init(codingPath: c.codingPath,
                                                                   debugDescription: "marker"))
        }
        self.type = type; self.start = start; self.end = end
        final = c.looseBool(.final) ?? false
    }
}

public struct PlexChapter: Sendable, Equatable, Decodable {
    public let tag: String?
    public let start: Int
    public let end: Int?
    public let thumb: String?

    enum CodingKeys: String, CodingKey {
        case tag, thumb
        case start = "startTimeOffset"
        case end = "endTimeOffset"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = c.looseInt(.start) else {
            throw DecodingError.keyNotFound(CodingKeys.start, .init(codingPath: c.codingPath,
                                                                    debugDescription: "start"))
        }
        self.start = start
        end = c.looseInt(.end)
        tag = c.looseString(.tag)
        thumb = c.looseString(.thumb)
    }
}

/// An entry of a list: title, season, episode, collection, playlist.
public struct PlexMetadata: Sendable, Equatable, Decodable {
    public let ratingKey: String
    public let type: String
    public let title: String
    public let titleSort: String?
    public let originalTitle: String?
    public let summary: String?
    public let tagline: String?
    public let year: Int?
    public let contentRating: String?
    public let studio: String?
    /// Audience rating 0–10.
    public let audienceRating: Double?
    /// Critic rating 0–10.
    public let rating: Double?
    public let userRating: Double?
    /// Milliseconds.
    public let duration: Int?
    public let originallyAvailableAt: String?
    public let addedAt: Int?
    public let lastViewedAt: Int?
    /// Milliseconds.
    public let viewOffset: Int?
    public let viewCount: Int?
    public let leafCount: Int?
    public let viewedLeafCount: Int?
    public let childCount: Int?
    public let index: Int?
    public let parentIndex: Int?
    public let parentRatingKey: String?
    public let grandparentRatingKey: String?
    public let parentTitle: String?
    public let grandparentTitle: String?
    public let thumb: String?
    public let art: String?
    public let parentThumb: String?
    public let grandparentThumb: String?
    public let grandparentArt: String?
    public let clearLogo: String?
    public let updatedAt: Int?
    public let librarySectionID: String?
    public let smart: Bool
    public let playlistType: String?
    public let subtype: String?
    public let originalLanguage: String?
    public let media: [PlexMedia]
    public let genres: [PlexTag]
    public let countries: [PlexTag]
    public let cast: [PlexTag]
    public let directors: [PlexTag]
    public let writers: [PlexTag]
    public let collections: [PlexTag]
    public let markers: [PlexMarker]
    public let chapters: [PlexChapter]
    let guids: [PlexGuid]

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, titleSort, originalTitle, summary, tagline, year
        case contentRating, studio, audienceRating, rating, userRating, duration
        case originallyAvailableAt, addedAt, lastViewedAt, viewOffset, viewCount, leafCount
        case viewedLeafCount, childCount, index, parentIndex, parentRatingKey
        case grandparentRatingKey, parentTitle, grandparentTitle, thumb, art, parentThumb
        case grandparentThumb, grandparentArt, updatedAt, librarySectionID, smart
        case playlistType, subtype, composite
        case media = "Media", genres = "Genre", countries = "Country", cast = "Role"
        case directors = "Director", writers = "Writer", collections = "Collection"
        case markers = "Marker", chapters = "Chapter", guids = "Guid", images = "Image"
        case originalLanguage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.looseString(.ratingKey), let title = c.looseString(.title) else {
            throw DecodingError.keyNotFound(CodingKeys.ratingKey, .init(
                codingPath: c.codingPath, debugDescription: "ratingKey"))
        }
        ratingKey = key; self.title = title
        type = c.looseString(.type) ?? "unknown"
        titleSort = c.looseString(.titleSort)
        originalTitle = c.looseString(.originalTitle)
        summary = c.looseString(.summary)
        tagline = c.looseString(.tagline)
        year = c.looseInt(.year)
        contentRating = c.looseString(.contentRating)
        studio = c.looseString(.studio)
        audienceRating = c.looseDouble(.audienceRating)
        rating = c.looseDouble(.rating)
        userRating = c.looseDouble(.userRating)
        duration = c.looseInt(.duration)
        originallyAvailableAt = c.looseString(.originallyAvailableAt)
        addedAt = c.looseInt(.addedAt)
        lastViewedAt = c.looseInt(.lastViewedAt)
        viewOffset = c.looseInt(.viewOffset)
        viewCount = c.looseInt(.viewCount)
        leafCount = c.looseInt(.leafCount)
        viewedLeafCount = c.looseInt(.viewedLeafCount)
        childCount = c.looseInt(.childCount)
        index = c.looseInt(.index)
        parentIndex = c.looseInt(.parentIndex)
        parentRatingKey = c.looseString(.parentRatingKey)
        grandparentRatingKey = c.looseString(.grandparentRatingKey)
        parentTitle = c.looseString(.parentTitle)
        grandparentTitle = c.looseString(.grandparentTitle)
        // A playlist carries its collage in `composite` instead of `thumb`.
        thumb = c.looseString(.thumb) ?? c.looseString(.composite)
        art = c.looseString(.art)
        parentThumb = c.looseString(.parentThumb)
        grandparentThumb = c.looseString(.grandparentThumb)
        grandparentArt = c.looseString(.grandparentArt)
        clearLogo = (c.looseList(.images, of: PlexImage.self) ?? [])
            .first { $0.type == "clearLogo" }?.url
        updatedAt = c.looseInt(.updatedAt)
        librarySectionID = c.looseString(.librarySectionID)
        smart = c.looseBool(.smart) ?? false
        playlistType = c.looseString(.playlistType)
        subtype = c.looseString(.subtype)
        originalLanguage = c.looseString(.originalLanguage)
        media = c.looseList(.media) ?? []
        genres = c.looseList(.genres) ?? []
        countries = c.looseList(.countries) ?? []
        cast = c.looseList(.cast) ?? []
        directors = c.looseList(.directors) ?? []
        writers = c.looseList(.writers) ?? []
        collections = c.looseList(.collections) ?? []
        markers = c.looseList(.markers) ?? []
        chapters = c.looseList(.chapters) ?? []
        guids = c.looseList(.guids) ?? []
    }

    struct PlexImage: Decodable {
        let type: String?
        let url: String?
    }
}

/// A library (`/library/sections`).
public struct PlexSection: Sendable, Equatable, Decodable {
    public let key: String
    /// `movie`, `show`, `artist`, `photo`.
    public let type: String
    public let title: String
    public let uuid: String?
    public let updatedAt: Int?

    enum CodingKeys: String, CodingKey { case key, type, title, uuid, updatedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.looseString(.key), let title = c.looseString(.title) else {
            throw DecodingError.keyNotFound(CodingKeys.key, .init(codingPath: c.codingPath,
                                                                  debugDescription: "key"))
        }
        self.key = key; self.title = title
        type = c.looseString(.type) ?? "unknown"
        uuid = c.looseString(.uuid)
        updatedAt = c.looseInt(.updatedAt)
    }
}

/// A shelf the server composes itself: "Continue Watching", "Recently Added" …
public struct PlexHub: Sendable, Equatable, Decodable {
    public let identifier: String
    public let title: String
    /// `movie`, `show`, `episode` … what the shelf mostly holds.
    public let type: String?
    public let more: Bool
    public let items: [PlexMetadata]

    enum CodingKeys: String, CodingKey {
        case title, type, more
        case identifier = "hubIdentifier"
        case items = "Metadata"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.looseString(.title) ?? ""
        identifier = c.looseString(.identifier) ?? title
        type = c.looseString(.type)
        more = c.looseBool(.more) ?? false
        items = c.looseList(.items) ?? []
    }
}

/// Everything a list answer can carry; each route fills a part.
struct PlexListing: Decodable {
    let size: Int
    let totalSize: Int?
    let offset: Int?
    let metadata: [PlexMetadata]
    let directories: [PlexSection]
    let hubs: [PlexHub]
    let machineIdentifier: String?
    let version: String?
    let claimed: Bool?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, machineIdentifier, version, claimed
        case metadata = "Metadata", directories = "Directory", hubs = "Hub"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = c.looseList(.metadata) ?? []
        directories = c.looseList(.directories) ?? []
        hubs = c.looseList(.hubs) ?? []
        size = c.looseInt(.size) ?? metadata.count
        totalSize = c.looseInt(.totalSize)
        offset = c.looseInt(.offset)
        machineIdentifier = c.looseString(.machineIdentifier)
        version = c.looseString(.version)
        claimed = c.looseBool(.claimed)
    }
}
