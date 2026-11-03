import Foundation

/// **Plex wire types into the package's own types** (``Item``, ``MediaSource``,
/// ``MediaStream``, ``Segment``, ``Chapter``), so everything above the client stays as it is.
///
/// Choices that are not obvious, all repeated in `Notizen/Mehrserver/PLEX-KERN.md`:
/// - `Item.id` is the `ratingKey`.
/// - `MediaStream.index` is the **Plex stream id**, not a running number: it is unique
///   per item and exactly what `PUT /library/parts/{id}?audioStreamID=` takes.
/// - A *favourite* is a user rating of 10 (Plex has no favourite flag; a heart in the
///   Plex apps is a rating).
/// - `imageTags` hold the **relative image path** the server gave (`/library/metadata/1/thumb/17`),
///   which already contains the version stamp; ``PlexClient/imageURL(path:maxHeight:maxWidth:)``
///   turns it into an address.
public struct PlexMapper: Sendable {

    public init() {}

    // MARK: - Types

    /// The ``Item/type`` for a Plex `type`.
    public static func itemType(_ plexType: String) -> String {
        switch plexType {
        case "movie": "Movie"
        case "show": "Series"
        case "season": "Season"
        case "episode": "Episode"
        case "collection": "BoxSet"
        case "playlist": "Playlist"
        case "artist": "MusicArtist"
        case "album": "MusicAlbum"
        case "track": "Audio"
        default: "Video"
        }
    }

    /// The type number `/all?type=` takes.
    public static func plexTypeNumber(forItemType type: String) -> Int? {
        switch type {
        case "Movie": 1
        case "Series": 2
        case "Season": 3
        case "Episode": 4
        default: nil
        }
    }

    static func ticks(milliseconds: Int?) -> Int64? {
        milliseconds.map { Int64($0) * 10_000 }
    }

    static func isoDate(seconds: Int?) -> String? {
        seconds.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
    }

    // MARK: - Library

    /// A library as the home page's list of "views".
    public func view(_ section: PlexSection) -> Item {
        let kind: String
        switch section.type {
        case "movie": kind = "movies"
        case "show": kind = "tvshows"
        case "artist": kind = "music"
        default: kind = section.type
        }
        return Item(id: section.key, name: section.title, type: "CollectionFolder",
                    collectionType: kind)
    }

    // MARK: - Title

    public func item(_ m: PlexMetadata) -> Item {
        let type = Self.itemType(m.type)
        let isEpisode = m.type == "episode"
        let isSeason = m.type == "season"
        let isContainer = m.type == "show" || isSeason

        // A show or season is "watched" when every leaf is; a single title by its count.
        let played: Bool? = {
            if isContainer {
                guard let all = m.leafCount, all > 0 else { return nil }
                return (m.viewedLeafCount ?? 0) >= all
            }
            guard m.type != "collection", m.type != "playlist" else { return nil }
            return (m.viewCount ?? 0) > 0
        }()
        var percentage: Double?
        if let offset = m.viewOffset, offset > 0, let duration = m.duration, duration > 0 {
            percentage = min(100, Double(offset) / Double(duration) * 100)
        }
        let data = UserItemData(
            playbackPositionTicks: Self.ticks(milliseconds: m.viewOffset),
            played: played,
            isFavorite: (m.userRating ?? 0) >= 10,
            playedPercentage: percentage,
            unplayedItemCount: isContainer
                ? m.leafCount.map { max(0, $0 - (m.viewedLeafCount ?? 0)) } : nil,
            lastPlayedDate: Self.isoDate(seconds: m.lastViewedAt))

        var people: [Person] = []
        for tag in m.cast {
            people.append(Person(id: tag.id ?? tag.tag, name: tag.tag, role: tag.role,
                                 type: "Actor", primaryImageTag: tag.thumb))
        }
        for tag in m.directors {
            people.append(Person(id: tag.id ?? tag.tag, name: tag.tag, role: nil,
                                 type: "Director", primaryImageTag: tag.thumb))
        }
        for tag in m.writers {
            people.append(Person(id: tag.id ?? tag.tag, name: tag.tag, role: nil,
                                 type: "Writer", primaryImageTag: tag.thumb))
        }

        var images: [String: String] = [:]
        if let thumb = m.thumb { images["Primary"] = thumb }
        if let logo = m.clearLogo { images["Logo"] = logo }

        var providers: [String: String] = [:]
        for guid in m.guids {
            guard let range = guid.id.range(of: "://") else { continue }
            let scheme = String(guid.id[..<range.lowerBound]).lowercased()
            let value = String(guid.id[range.upperBound...])
            switch scheme {
            case "imdb": providers["Imdb"] = value
            case "tmdb": providers["Tmdb"] = value
            case "tvdb": providers["Tvdb"] = value
            default: break
            }
        }

        let sources = m.media.isEmpty ? nil : mediaSources(of: m)

        // Both ratings are 0-10 in Plex; the item has a 0-10 community and a 0-100 critic
        // rating.
        let community = m.audienceRating ?? m.rating
        let critic = m.audienceRating != nil ? m.rating.map { $0 * 10 } : nil

        let rating = m.contentRating.map { raw -> String in
            // Plex writes `de/12` or `gb/15`; the country prefix is of no use to the app.
            raw.split(separator: "/", maxSplits: 1).last.map(String.init) ?? raw
        }

        return Item(
            id: m.ratingKey, name: m.title, type: type,
            productionYear: m.year,
            overview: m.summary.flatMap { $0.isEmpty ? nil : $0 },
            runTimeTicks: Self.ticks(milliseconds: m.duration),
            seriesName: isEpisode ? m.grandparentTitle : (isSeason ? m.parentTitle : nil),
            indexNumber: m.index,
            parentIndexNumber: isEpisode ? m.parentIndex : nil,
            seriesId: isEpisode ? m.grandparentRatingKey : (isSeason ? m.parentRatingKey : nil),
            seasonId: isEpisode ? m.parentRatingKey : nil,
            genres: m.genres.isEmpty ? nil : m.genres.map(\.tag),
            officialRating: rating,
            communityRating: community,
            // A series' children are seasons, a season's are episodes.
            childCount: m.type == "show" ? m.childCount : (isSeason ? m.leafCount : nil),
            backdropImageTags: m.art.map { [$0] },
            seriesPrimaryImageTag: isEpisode ? m.grandparentThumb : (isSeason ? m.parentThumb : nil),
            people: people.isEmpty ? nil : people,
            studios: m.studio.map { [NameID(id: nil, name: $0)] },
            taglines: m.tagline.map { [$0] },
            criticRating: critic,
            imageTags: images.isEmpty ? nil : images,
            userData: data,
            mediaSources: sources,
            parentBackdropImageTags: isEpisode ? m.grandparentArt.map { [$0] } : nil,
            parentBackdropItemId: isEpisode ? m.grandparentRatingKey : nil,
            premiereDate: m.originallyAvailableAt.map { $0.count == 10 ? $0 + "T00:00:00Z" : $0 },
            productionLocations: m.countries.isEmpty ? nil : m.countries.map(\.tag),
            providerIds: providers.isEmpty ? nil : providers,
            originalLanguage: m.originalLanguage,
            mediaType: ["movie", "episode", "clip"].contains(m.type) ? "Video" : nil,
            sortName: (m.titleSort ?? m.title).lowercased(),
            // Seconds since 1970; as ISO 8601 like Jellyfin's `DateCreated`.
            dateCreated: m.addedAt.map {
                ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
            })
    }

    // MARK: - Files

    /// **Every file of a title as a media source.** A title has several ``PlexMedia``
    /// (versions: 4K next to 1080p) and each of those holds one or more ``PlexPart``
    /// (files; a title split over CD1/CD2 has two). Each file is one source, so the
    /// version choice offers all of them and the player opens one address per source.
    /// The ids come from ``PlexPlayback/files(of:)``.
    public func mediaSources(of m: PlexMetadata) -> [MediaSource] {
        PlexPlayback.files(of: m).map { mediaSource($0, duration: m.duration) }
    }

    /// One file as a media source.
    public func mediaSource(_ file: PlexFile, duration: Int?) -> MediaSource {
        let media = file.media, part = file.part
        let streams = part.streams.map(stream)
        var name = part.file.map { ($0 as NSString).lastPathComponent }
        // A later part without a file name still needs something to tell it apart.
        if (name ?? "").isEmpty, file.number > 1 {
            name = translated("Teil \(file.number)")
        }
        return MediaSource(
            id: file.sourceID, name: name, container: part.container ?? media.container,
            size: part.size, supportsDirectPlay: true, supportsDirectStream: false,
            supportsTranscoding: false, transcodingUrl: nil, mediaStreams: streams,
            defaultAudioStreamIndex: part.streams.first { $0.streamType == 2 && $0.selected }?.id,
            // Jellyfin says -1 for "none"; so do we, so the existing rule can read it.
            defaultSubtitleStreamIndex: part.streams.first { $0.streamType == 3 && $0.selected }?.id ?? -1,
            runTimeTicks: Self.ticks(milliseconds: part.duration ?? media.duration ?? duration))
    }

    public func stream(_ s: PlexStream) -> MediaStream {
        let type: String? = switch s.streamType {
        case 1: "Video"
        case 2: "Audio"
        case 3: "Subtitle"
        default: nil
        }
        let range = s.streamType == 1 ? colorRange(s) : nil
        return MediaStream(
            codec: s.codec, type: type, language: s.languageCode ?? s.language,
            displayTitle: s.displayTitle, channels: s.channels, isDefault: s.isDefault,
            index: s.id, height: s.height, width: s.width, realFrameRate: s.frameRate,
            averageFrameRate: s.frameRate, videoRangeType: range,
            colorTransfer: s.colorTrc, colorPrimaries: s.colorPrimaries,
            dvProfile: s.dolbyVisionPresent ? s.dolbyVisionProfile : nil,
            dvBlSignalCompatibilityId: s.dolbyVisionPresent ? s.dolbyVisionCompatibility : nil,
            isForced: s.forced, isExternal: s.streamType == 3 ? s.key != nil : nil,
            title: s.title,
            // The path only; the token is added by the client (see PlexClient.subtitleURL).
            deliveryUrl: s.streamType == 3 ? s.key : nil,
            isHearingImpaired: s.hearingImpaired)
    }

    /// Plex has no "range type"; derive it from transfer function and Dolby Vision.
    func colorRange(_ s: PlexStream) -> ColorRange {
        let trc = s.colorTrc?.lowercased()
        let base: ColorRange = switch trc {
        case "smpte2084": .hdr10
        case "arib-std-b67": .hlg
        case nil: .unknown
        default: .sdr
        }
        guard s.dolbyVisionPresent else { return base }
        switch base {
        case .hdr10: return .dolbyVisionHDR10
        case .hlg: return .dolbyVisionHLG
        case .sdr: return .dolbyVisionSDR
        default: return .dolbyVision
        }
    }

    // MARK: - Markers and chapters

    /// `intro` and `credits` as skip buttons; `commercial` as an ad. Milliseconds to
    /// seconds. A final credits marker may end past the file; the end is cut to the
    /// runtime when it is known.
    public func segments(_ markers: [PlexMarker], duration: Int?) -> [Segment] {
        markers.compactMap { marker in
            let art: Segment.Art
            switch marker.type {
            case "intro": art = .introSegment
            case "credits": art = .credits
            case "commercial": art = .ads
            default: return nil
            }
            var end = marker.end
            if let duration, duration > 0 { end = min(end, duration) }
            guard end > marker.start else { return nil }
            return Segment(art: art, from: Double(marker.start) / 1000,
                           until: Double(end) / 1000)
        }
        .sorted { $0.from < $1.from }
    }

    public func chapters(_ list: [PlexChapter]) -> [Chapter] {
        list.enumerated().map { index, chapter in
            let given = chapter.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = given.isEmpty ? translated("Kapitel \(index + 1)") : given
            return Chapter(name: name, from: Double(chapter.start) / 1000)
        }
    }
}
