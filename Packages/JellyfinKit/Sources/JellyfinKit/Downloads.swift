import Foundation

// **What lives here and what does not.**
//
// This file holds the decisions that can be checked without a simulator: who
// loads next, whether space is enough, what is expendable, how a list is
// grouped. The actual download (background `URLSession`, resuming, storage on
// disk) lives in `Sources/Shared/DownloadManager.swift`, because it needs a
// file system and a running process.
//
// The split is not a matter of taste. `TimeAssumption`, `EpisodeEnd` and
// `DisplayRules` are in the package for the same reason: they are rules that
// drift apart between platforms as soon as nobody checks them.

/// What a download is doing right now.
///
/// **Progress is deliberately not in here.** A `loads(0.37)` would be
/// convenient, but the state is written to disk and progress changes several
/// times a second; every change would be a write. How far along it is comes
/// from `DownloadItem.loaded` against `.bytes`, which sits alongside and is
/// only persisted on pause.
public enum DownloadState: String, Codable, Sendable, Equatable, CaseIterable {
    /// In the queue. Only one loads at a time.
    case waits = "wartet"
    /// This one is up.
    case loads = "laedt"
    /// Paused by hand, or paused by missing Wi-Fi.
    case halted = "angehalten"
    case done = "fertig"
    case error = "fehler"
}

/// A title on the device: downloaded, downloading or waiting.
///
/// **`account` is not optional decoration.** Storage hangs on the `userID`, not on
/// the item ID alone. Two accounts on one server carry the same IDs, and with
/// them one account's progress would land on the other's title, exactly the
/// damage `SeriesCache` once had, there in `userData` rather than in the
/// titles.
public struct DownloadItem: Codable, Sendable, Equatable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id
        case account = "konto"
        case art
        case title = "titel"
        case series = "serie"
        case seriesIdentifier = "serienId"
        case season = "staffel"
        case episode = "folge"
        case runtimeTicks = "laufzeitTicks"
        case container
        case source = "quelle"
        case bytes
        case quality = "qualitaet"
        case loaded = "geladen"
        case state = "stand"
        case reason = "grund"
        case watched = "gesehen"
        case created = "angelegt"
        case stillOnTheServer = "nochAufDemServer"
        case sections = "abschnitte"
        case pointTicks = "stelleTicks"
        case recent = "zuletzt"
        case videoCodec = "bildcodec"
        case audioIndex = "tonIndex"
        case audioLanguage = "tonSprache"
        case replaces = "ersetzt"
        case nextPending = "naechsteOffen"
    }

    public enum Art: String, Codable, Sendable, Equatable {
        case film, episode = "folge"
    }

    /// The server's item ID.
    public let id: String
    /// The `userID` this download belongs to.
    public let account: String
    public let art: Art
    public let title: String
    /// For an episode the series name, otherwise `nil`.
    public let series: String?
    public let seriesIdentifier: String?
    public let season: Int?
    public let episode: Int?
    public let runtimeTicks: Int64?
    public let container: String?
    /// `mediaSourceId`: the same source the player would have taken.
    public let source: String?
    /// What the server states as size. 0 if it states none.
    ///
    /// **An estimate for a converted file** until it is finished; then this holds
    /// what is on disk. Hence `var`.
    public var bytes: Int64
    /// The quality it loads in. `nil` means original, as in every list from before
    /// 1.0.5, so those stay readable.
    public let quality: DownloadQuality?

    /// How much of it is already on disk.
    public var loaded: Int64
    public var state: DownloadState
    /// Only set when `state == .error`.
    public var reason: String?
    /// Only watched items count as expendable.
    public var watched: Bool
    public var created: Date
    /// Falls to `false` when the server no longer knows the title; the file stays,
    /// playable, with a quiet note next to it.
    public var stillOnTheServer: Bool

    // MARK: Offline
    //
    // All three optional and at the end: a list from before this still reads, and
    // whatever is missing is fetched by ``DownloadRules`` on the next contact with
    // the server.

    /// Intro, recap, credits, taken along when downloading so "Skip intro" and the
    /// "Next episode" card also work without a server. `nil`: never asked; empty:
    /// the server knows none.
    public var sections: [Segment]?
    /// Where playback last stopped, in ticks. `nil` means from the start.
    public var pointTicks: Int64?
    /// When last played, on this device or per the server.
    public var recent: Date?
    /// Codec of the video track of the downloaded file (``MediaSource/bildcodec``).
    /// Offline there is no source from which the player recognizes XviD
    /// (``Erstbild/softwareFromStart(bildcodec:methode:)``). `nil`: downloaded or
    /// converted before this field existed; free choice applies then.
    public var videoCodec: String?

    // MARK: Audio and the next episode
    //
    // Also optional and at the end, for the same reason as above: older lists decode
    // them as `nil`, which means "all audio tracks, nothing pending".

    /// The one audio track the file holds (the server's stream index). `nil`: the
    /// original file with all tracks.
    public var audioIndex: Int?
    /// The language the audio track was chosen by, for a series: the next episode is
    /// loaded with the same language, its index may differ. See ``DownloadAudio``.
    public var audioLanguage: String?
    /// The ID of the watched episode this one was loaded to follow. Once this
    /// episode is on the device, that one is removed. See ``DownloadRules/replacedOne(by:in:)``.
    public var replaces: String?
    /// Set when this episode was watched to the end and its successor could not be
    /// looked up yet (no server). The next contact with the server does it.
    public var nextPending: Bool?

    public init(id: String, account: String, art: Art, title: String,
                series: String? = nil, seriesIdentifier: String? = nil,
                season: Int? = nil, episode: Int? = nil,
                runtimeTicks: Int64? = nil, container: String? = nil,
                source: String? = nil, bytes: Int64,
                quality: DownloadQuality? = nil,
                loaded: Int64 = 0, state: DownloadState = .waits,
                reason: String? = nil, watched: Bool = false,
                created: Date = Date(), stillOnTheServer: Bool = true,
                sections: [Segment]? = nil, pointTicks: Int64? = nil,
                recent: Date? = nil, videoCodec: String? = nil,
                audioIndex: Int? = nil, audioLanguage: String? = nil,
                replaces: String? = nil, nextPending: Bool? = nil) {
        self.id = id; self.account = account; self.art = art; self.title = title
        self.series = series; self.seriesIdentifier = seriesIdentifier
        self.season = season; self.episode = episode
        self.runtimeTicks = runtimeTicks; self.container = container
        self.source = source; self.bytes = bytes
        self.quality = quality == .original ? nil : quality
        self.loaded = loaded; self.state = state; self.reason = reason
        self.watched = watched; self.created = created
        self.stillOnTheServer = stillOnTheServer
        self.sections = sections; self.pointTicks = pointTicks
        self.recent = recent
        // A converted file has the server's video codec, not the original's.
        self.videoCodec = self.quality == nil ? videoCodec : nil
        self.audioIndex = audioIndex; self.audioLanguage = audioLanguage
        self.replaces = replaces; self.nextPending = nextPending
    }

    /// **A title's watch state as the server knows it**, passed along when creating
    /// a download so the list shows it without network.
    public init(id: String, account: String, art: Art, title: String,
                series: String? = nil, seriesIdentifier: String? = nil,
                season: Int? = nil, episode: Int? = nil,
                runtimeTicks: Int64? = nil, container: String? = nil,
                source: String? = nil, bytes: Int64,
                watchState: UserItemData?, videoCodec: String? = nil) {
        self.init(id: id, account: account, art: art, title: title, series: series,
                  seriesIdentifier: seriesIdentifier, season: season, episode: episode,
                  runtimeTicks: runtimeTicks, container: container, source: source,
                  bytes: bytes, watched: watchState?.played ?? false,
                  pointTicks: watchState?.playbackPositionTicks.flatMap { $0 > 0 ? $0 : nil },
                  recent: watchState?.lastPlay, videoCodec: videoCodec)
    }

    /// Between 0 and 1. `nil` if the server stated no size; then there is no bar
    /// and the ring only shows that it is running.
    public var share: Double? {
        guard bytes > 0 else { return nil }
        let value = min(1, max(0, Double(loaded) / Double(bytes)))
        // **An estimate never quite reaches the end.** If the converted file ends up
        // larger than calculated, the ring would otherwise sit full for a long time
        // while still loading.
        return streamed && state != .done ? min(value, 0.99) : value
    }

    /// Is the file converted by the server? Then ``bytes`` is estimated until the
    /// end.
    public var converted: Bool { quality.map { !$0.isOriginal } ?? false }

    /// **Is the file built by the server while it is loaded?** Converted, or cut down
    /// to one audio track. Either way there is no length up front and no resuming
    /// (`Accept-Ranges: none`), ``bytes`` is an estimate until the end, and
    /// subtitles come as separate files because the built file carries none.
    public var streamed: Bool { converted || audioIndex != nil }

    /// The chosen quality; `nil` counts as original.
    public var guete: DownloadQuality { quality ?? .original }

    /// **The same item in another quality.** Container and size change with it: a
    /// converted file is Matroska, and its size is estimated
    /// (``Downloadqualitaet/estimatedBytes(original:laufzeitTicks:)``). For the
    /// original everything stays as the server names it.
    ///
    /// It is called on the item as the catalog describes it, i.e. with original
    /// size and container; the estimate is computed from there.
    public func inQuality(_ q: DownloadQuality) -> DownloadItem {
        DownloadItem(
            id: id, account: account, art: art, title: title, series: series, seriesIdentifier: seriesIdentifier,
            season: season, episode: episode, runtimeTicks: runtimeTicks,
            container: q.isOriginal && audioIndex == nil ? container : DownloadQuality.container,
            source: source,
            bytes: q.estimatedBytes(original: bytes, runtimeTicks: runtimeTicks),
            quality: q, loaded: loaded, state: state, reason: reason, watched: watched,
            created: created, stillOnTheServer: stillOnTheServer,
            sections: sections, pointTicks: pointTicks, recent: recent,
            videoCodec: videoCodec, audioIndex: audioIndex, audioLanguage: audioLanguage,
            replaces: replaces, nextPending: nextPending)
    }

    /// An `Item` from what is stored here, **for playback without network.**
    ///
    /// The player needs an `Item`, and offline there is no server to deliver one.
    /// Everything needed is in the entry anyway: ID, title, runtime, and for an
    /// episode series, season and number.
    ///
    /// **Explicitly no substitute for the server** once one is there: plot, cast
    /// and progress are missing. Playing from the download list does not need them.
    public var asItem: Item {
        Item(id: id, name: title,
             type: art == .episode ? "Episode" : "Movie",
             runTimeTicks: runtimeTicks,
             seriesName: series, indexNumber: episode,
             parentIndexNumber: season, seriesId: seriesIdentifier)
    }

    /// Where the download list starts playback: the remembered position, otherwise
    /// from the start. Watched items start over, like "Watch again" online.
    public var resumeFrom: Double {
        guard !watched, let t = pointTicks, t > 0 else { return 0 }
        return Double(t) / 10_000_000
    }

    /// **Record a playback on this device**, with or without network.
    ///
    /// Same thresholds as the server (`MinResumePct` 5, `MaxResumePct` 90, Jellyfin's
    /// defaults): below 5% nothing counts as a position, above 90% the title counts
    /// as watched and the position is dropped. In between "watched" stays as it
    /// was, which the server also does. So the list shows offline what it will hear
    /// from the server after reconnecting.
    public func postPlayback(ticks: Int64, moment: Date) -> DownloadItem {
        var p = self
        p.recent = moment
        guard let runtime = runtimeTicks, runtime > 0 else {
            p.pointTicks = ticks > 0 ? ticks : nil
            return p
        }
        let share = Double(ticks) / Double(runtime)
        if share >= DownloadRules.watchedOff {
            p.watched = true
            p.pointTicks = nil
        } else if share < DownloadRules.pointOff {
            p.pointTicks = nil
        } else {
            p.pointTicks = ticks
        }
        return p
    }

    /// The file name on disk. Account and ID so two accounts do not collide, and
    /// the container's extension so VLC guesses the demuxer; for Matroska
    /// `:demux=mkv_trusted` hangs on that, see `VLCPlayer.play`.
    ///
    /// All three parts come from the server and pass through ``PathPart``, so a
    /// malicious server cannot get a path out of the folder.
    public var fileName: String {
        let suffix = PathPart.suffix(container).map { "." + $0 } ?? ""
        return "\(PathPart.safe(account))-\(PathPart.safe(id))\(suffix)"
    }

    /// The name of the image on disk, next to the file.
    public static func imageName(account: String, identifier: String) -> String {
        "\(PathPart.safe(account))-\(PathPart.safe(identifier)).jpg"
    }
}

/// **A piece of a file name from server data**, never a way out of the folder.
///
/// IDs (Jellyfin GUIDs) and extensions stay as they are; everything else is
/// defused so no `/`, `\`, `..` or control character lands in the file name.
/// Real values do not change, so existing downloads are still found.
public enum PathPart {
    /// Letters, digits, `-` and `_` stay; every other character becomes `_`. Empty
    /// becomes `_`.
    public static func safe(_ part: String) -> String {
        let allowed = part.unicodeScalars.map { z -> Character in
            switch z {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": Character(z)
            default: "_"
            }
        }
        return allowed.isEmpty ? "_" : String(allowed)
    }

    /// Does this look like a Jellyfin ID (GUID, with or without hyphens)? For IDs
    /// that come from outside, such as a `swiftly://titel/<id>` link, before they
    /// go into a server address: a `..%2F..` in it would otherwise hit another
    /// endpoint.
    public static func isId(_ text: String) -> Bool {
        (1...64).contains(text.count)
            && text.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || ("0"..."9").contains($0) || $0 == "-"
            }
    }

    /// The extension from the server's container: `[a-z0-9]{1,8}`, otherwise `nil`
    /// (then no extension, as with a missing container). A list like `mov,mp4,m4a`
    /// stays allowed as long as every member fits: that is how already downloaded
    /// files are named, and a comma leads nowhere.
    public static func suffix(_ container: String?) -> String? {
        guard let c = container?.lowercased(), !c.isEmpty else { return nil }
        let elements = c.split(separator: ",", omittingEmptySubsequences: false)
        let fits = elements.allSatisfy { g in
            (1...8).contains(g.count)
                && g.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
        return fits ? c : nil
    }
}

/// A row in the download list. A series is **one** row.
public enum DownloadGroup: Sendable, Equatable, Identifiable {
    case single(DownloadItem)
    case series(id: String, title: String, episodes: [DownloadItem])

    public var id: String {
        switch self {
        case let .single(p): p.id
        case let .series(id, _, _): "serie-" + id
        }
    }

    public var title: String {
        switch self {
        case let .single(p): p.title
        case let .series(_, title, _): title
        }
    }

    public var bytes: Int64 {
        switch self {
        case let .single(p): p.bytes
        case let .series(_, _, f): f.reduce(0) { $0 + $1.bytes }
        }
    }

    /// The group's most recent addition, which sorting uses.
    public var created: Date {
        switch self {
        case let .single(p): p.created
        case let .series(_, _, f): f.map(\.created).max() ?? .distantPast
        }
    }
}

/// The decisions around downloads, all verifiable.
public enum DownloadRules {

    /// How much space on the device stays untouched: **one gigabyte.**
    ///
    /// A full disk is not cosmetic: iOS can then no longer unpack an update and the
    /// camera records nothing. Someone loading 40 GB should not stall the phone
    /// with it.
    public static let padding: Int64 = 1_073_741_824

    // MARK: One after the other

    /// Which item should run next, or `nil`.
    ///
    /// `nil` means one of three: one is already running, none is waiting, or Wi-Fi
    /// is missing and `onlyOverWLAN` applies. The three are deliberately not
    /// distinguished: the caller does the same in all three, namely nothing.
    public static func nextOne(from entries: [DownloadItem],
                                 wLAN: Bool, onlyOverWLAN: Bool) -> DownloadItem? {
        guard !entries.contains(where: { $0.state == .loads }) else { return nil }
        guard mayLoad(wLAN: wLAN, onlyOverWLAN: onlyOverWLAN) else { return nil }
        // Oldest first: whoever started the download first gets it first. On equal
        // times the ID decides so the order does not depend on the caller's sorting.
        return entries
            .filter { $0.state == .waits }
            .min { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    // MARK: Cellular

    /// May anything be loaded at all?
    ///
    /// Deliberately its own function and not a `&&` at the call site: the question
    /// is asked in three places (on start, on network change and on app launch)
    /// and should give the same answer all three times.
    public static func mayLoad(wLAN: Bool, onlyOverWLAN: Bool) -> Bool {
        wLAN || !onlyOverWLAN
    }

    /// What the tick does with the network.
    public enum NetworkVerdict: Sendable, Equatable {
        /// Loading may begin or continue.
        case load
        /// What is running goes back into the queue; it waits for Wi-Fi.
        case putBack
        /// Do nothing yet: the network is not known.
        case waitFor
    }

    /// **While the network is unknown, nothing starts.**
    ///
    /// The path observer's first report only arrives after the first tick. Assuming
    /// Wi-Fi until then meant: on a cellular start a waiting download began and was
    /// stopped again milliseconds later, which crashed the app on Android. Without
    /// "Wi-Fi only" the network does not matter, and `load` applies.
    ///
    /// `putBack` is not a pause: the title waits afterwards so the next tick
    /// on Wi-Fi resumes it by itself.
    public static func networkVerdict(wLAN: Bool?, onlyOverWLAN: Bool) -> NetworkVerdict {
        guard onlyOverWLAN else { return .load }
        guard let wLAN else { return .waitFor }
        return wLAN ? .load : .putBack
    }

    // MARK: Space

    /// What a download would cost and what options there are.
    public struct SpaceInfo: Sendable, Equatable {
        /// Does it fit without clearing, with ``luft`` as reserve?
        public let suffices: Bool
        /// What would be free after the download. Can be negative.
        public let freeAfter: Int64
        /// Watched downloads, largest first. Empty if there are none.
        public let dispensable: [DownloadItem]
        /// How much they take up together.
        public let dispensableBytes: Int64

        /// Is it enough once everything expendable is gone?
        public var sufficesToCleanUp: Bool {
            suffices || freeAfter + dispensableBytes >= 0
        }
    }

    public static func slot(for bytes: Int64, free: Int64,
                             available: [DownloadItem]) -> SpaceInfo {
        let leftover = free - bytes - padding
        let distance = dispensable(from: available)
        return SpaceInfo(suffices: leftover >= 0,
                             freeAfter: leftover,
                             dispensable: distance,
                             dispensableBytes: distance.reduce(0) { $0 + $1.bytes })
    }

    /// What the footer of a download picker says on the right, **before** pressing.
    public enum FootSpace: Sendable, Equatable {
        /// This much stays free after loading.
        case free(Int64)
        /// This much is missing for it to fit, reserve included.
        case few(Int64)
    }

    /// **The footer says the same as the sheet after it.**
    ///
    /// Whether it fits is decided by ``platz(fuer:free:available:)`` with ``luft``
    /// as reserve. If the footer computed without it, it would say "0.4 GB free
    /// afterwards" and the button would still lead to the "Not enough space" sheet.
    /// So the reserve counts in the shortfall; if it fits, the plain difference
    /// is shown, since that is what the device shows afterwards.
    ///
    /// Without a selection nothing is missing: it shows what is free now, even if
    public static func footSpace(for bytes: Int64, free: Int64) -> FootSpace {
        guard bytes > 0 else { return .free(max(free, 0)) }
        let leftover = free - bytes - padding
        return leftover >= 0 ? .free(free - bytes) : .few(-leftover)
    }

    /// What the app may suggest removing: **fully downloaded and watched**, largest
    /// first.
    ///
    /// Partial downloads are deliberately not included even though they take space:
    /// clearing them to make room for another would be a trade nobody asked for.
    public static func dispensable(from entries: [DownloadItem]) -> [DownloadItem] {
        entries
            .filter { $0.state == .done && $0.watched }
            .sorted { ($0.bytes, $0.id) > ($1.bytes, $1.id) }
    }

    // MARK: One series is one row

    /// Movies stay single, episodes of the same series become a group. Newest
    /// first; within a series by season and episode.
    public static func grouped(_ entries: [DownloadItem]) -> [DownloadGroup] {
        var groups: [DownloadGroup] = []
        var seriesList: [String: [DownloadItem]] = [:]
        var railsEpisode: [String] = []

        for p in entries {
            // An episode without `seriesIdentifier` cannot be grouped and so stands alone: better
            // one row too many than a group under the name `nil`.
            guard p.art == .episode, let sid = p.seriesIdentifier else {
                groups.append(.single(p))
                continue
            }
            if seriesList[sid] == nil { railsEpisode.append(sid) }
            seriesList[sid, default: []].append(p)
        }

        for sid in railsEpisode {
            let episodes = (seriesList[sid] ?? []).sorted {
                ($0.season ?? 0, $0.episode ?? 0, $0.id) < ($1.season ?? 0, $1.episode ?? 0, $1.id)
            }
            let title = episodes.first?.series ?? episodes.first?.title ?? ""
            groups.append(.series(id: sid, title: title, episodes: episodes))
        }

        return groups.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    // MARK: Numbers in words

    /// "18,6 GB" in German, "18.6 GB" in English.
    ///
    /// **Thousands steps, not powers of two** (`.file`): that is how Finder and the
    /// iOS settings compute, and our number sits next to theirs. An app that says
    /// 17.3 GiB where Settings shows 18.6 GB looks wrong even when it is right.
    ///
    /// ``Dateiangaben/groesse(_:)`` in the file summary computes via this; a file
    /// must not be measured differently in the download list than on the detail
    /// page.
    public static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(sizeLocale(.current)))
    }

    /// **Units stay Latin: "18,6 GB", not "18,6 ГБ".**
    ///
    /// Next to the size stand codec names, Mbit/s and fps, all Latin; a Cyrillic
    /// unit between them reads as a different kind of number. German formatting
    /// gives the same decimal comma Russian uses, with Latin units.
    static func sizeLocale(_ current: Locale) -> Locale {
        ["ru", "uk", "be"].contains(String(current.identifier.prefix(2)))
            ? Locale(identifier: "de_DE") : current
    }

    /// **When progress is shown: at most once per second.**
    ///
    /// `URLSession` reports at the rhythm of packets. The half-percent limit alone
    /// let five or more new numbers per second through on a fast line, so the
    /// subline trembled instead of counting. Always let through: the first report,
    /// a restart (less than before) and the end.
    public static func progressShow(loaded: Int64, total: Int64,
                                         before: Int64?, elapsed: TimeInterval?) -> Bool {
        guard let before, let elapsed else { return true }
        if loaded < before { return true }
        if total > 0, loaded >= total { return loaded != before }
        let step = max(Int64(1), total / 200)
        return loaded - before >= step && elapsed >= 1
    }

    /// "0,84 von 2,31 GB": **both numbers in the same unit, with fixed decimals.**
    ///
    /// ``size(_:)`` adapts unit and decimals to the value: "845 MB" becomes
    /// "1 GB", then "1,01 GB", then "1,1 GB". For a figure that stands still that
    /// is right; for one that counts it means comma and width keep changing. Here
    /// the total size sets the unit and the decimals stay: GB with two, MB with
    /// none.
    public static func progress(loaded: Int64, from total: Int64,
                                   locale: Locale = .current) -> (loaded: String, total: String) {
        let (divider, unit, set): (Double, String, Int) =
            total >= 1_000_000_000 ? (1e9, "GB", 2)
            : total >= 1_000_000 ? (1e6, "MB", 0) : (1e3, "KB", 0)
        func figure(_ b: Int64) -> String {
            (Double(max(b, 0)) / divider).formatted(
                .number.precision(.fractionLength(set)).locale(locale))
        }
        return (figure(min(loaded, max(total, loaded))), figure(total) + " " + unit)
    }

    /// **Which downloaded episode the play button takes.** The first finished one
    /// not yet watched, by season and episode; if all are watched, the first, like
    /// "from the start". Running and waiting ones do not count: they cannot be
    /// played yet.
    public static func nextEpisode(from entries: [DownloadItem]) -> DownloadItem? {
        let done = entries.filter { $0.state == .done }.sorted {
            ($0.season ?? 0, $0.episode ?? 0, $0.id) < ($1.season ?? 0, $1.episode ?? 0, $1.id)
        }
        return done.first { !$0.watched } ?? done.first
    }

    // MARK: Offline

    /// From this fraction a title counts as watched: Jellyfin's `MaxResumePct`.
    public static let watchedOff = 0.9
    /// Below this no position is remembered: Jellyfin's `MinResumePct`.
    public static let pointOff = 0.05

    /// **The next downloaded episode after this one**, for "Next episode" when no
    /// server answers.
    ///
    /// By season and episode, only finished downloads of the same account and the
    /// same series. Specials (season 0) come first and so never come up after a
    /// regular episode. **A gap is skipped**: if episode 4 is missing, 5 is the next
    /// downloaded; offline there is no other, and "none" would end the evening.
    /// Without an episode number nothing can be ordered; then there is none.
    public static func episodePost(_ id: String, from entries: [DownloadItem]) -> DownloadItem? {
        guard let now = entries.first(where: { $0.id == id }), now.art == .episode,
              let series = now.seriesIdentifier, let number = now.episode else { return nil }
        let here = (now.season ?? 0, number)
        return entries
            .filter {
                $0.state == .done && $0.account == now.account && $0.seriesIdentifier == series
                    && $0.id != id && $0.episode != nil
                    && ($0.season ?? 0, $0.episode ?? 0) > here
            }
            .min { ($0.season ?? 0, $0.episode ?? 0, $0.id) < ($1.season ?? 0, $1.episode ?? 0, $1.id) }
    }

    // MARK: Next episode

    /// **Has this playback reached the end?** The same line as ``postPlayback``: from
    /// 90 % a title counts as watched.
    public static func reachedEnd(ticks: Int64, runtimeTicks: Int64?) -> Bool {
        guard let runtime = runtimeTicks, runtime > 0 else { return false }
        return Double(ticks) / Double(runtime) >= watchedOff
    }

    /// Does this entry have a successor to look for: a finished episode with a series
    /// and a number?
    public static func hasSuccessor(_ item: DownloadItem) -> Bool {
        item.state == .done && item.art == .episode
            && item.seriesIdentifier != nil && item.episode != nil
    }

    /// **The episode after this one in the series**, from the server's list: by season
    /// and number, specials (season 0) before everything, so a regular episode never
    /// leads to one. `nil` after the last episode.
    public static func followingEpisode(after item: DownloadItem, in episodes: [Item]) -> Item? {
        guard let number = item.episode else { return nil }
        let here = (item.season ?? 0, number)
        return episodes
            .filter { $0.id != item.id && $0.indexNumber != nil
                && ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) > here }
            .min { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.id)
                < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.id) }
    }

    /// **The download that follows a watched one**: same series and account, **same
    /// quality and same audio language**, and the link back that removes the watched
    /// one once this is on the device (``replacedOne(by:in:)``).
    ///
    /// If the next episode lacks the language, it is loaded with every track; the
    /// language is still carried along, so the episode after it can use it again.
    public static func followUp(to watched: DownloadItem, next: Item) -> DownloadItem {
        let source = next.mediaSources?.first
        var follower = DownloadItem(
            id: next.id, account: watched.account, art: .episode, title: next.name,
            series: watched.series, seriesIdentifier: watched.seriesIdentifier,
            season: next.parentIndexNumber ?? watched.season, episode: next.indexNumber,
            runtimeTicks: next.runTimeTicks, container: source?.container,
            source: source?.id, bytes: source?.size ?? 0,
            watchState: next.userData, videoCodec: source?.videoCodec)
            .inQuality(watched.guete)
        if let language = watched.audioLanguage {
            follower = follower.withAudio(.language(language), streams: source?.mediaStreams ?? [])
            follower.audioLanguage = language
        }
        follower.replaces = watched.id
        return follower
    }

    /// **Which watched episode to remove now that this one is finished**, if any: the
    /// one it was loaded to follow, as long as it is still on the device, finished and
    /// watched. Anything else (removed by hand, started over, not watched after all)
    /// stays.
    public static func replacedOne(by item: DownloadItem, in entries: [DownloadItem]) -> String? {
        guard item.state == .done, let old = item.replaces,
              let entry = entries.first(where: { $0.id == old && $0.account == item.account }),
              entry.state == .done, entry.watched else { return nil }
        return old
    }

    /// **The segments of a title, stored ones first.**
    ///
    /// If some were stored at download, they apply immediately without a request:
    /// they came from the same server, and without network (or on the road, where
    /// the home server does not answer) a request would only be answered after its
    /// timeout and the "Skip intro" button would come too late. Otherwise
    /// ``server`` is asked; empty there means "none" or "unreachable", and both mean
    /// no button.
    public static func sections(stored: [Segment]?,
                                  server: @Sendable () async -> [Segment]) async -> [Segment] {
        if let stored, !stored.isEmpty { return stored }
        return await server()
    }

    /// **"Next episode": online as before, without a server the next downloaded
    /// one** (``episodePost(_:aus:)``).
    ///
    /// Without network it is not even asked. With network ``server`` is asked; if
    /// the request fails (home server unreachable), the downloaded one applies. If
    /// the server answers "none", that stands; it knows better than the list on the
    /// device.
    public static func episodePost(_ item: Item, from entries: [DownloadItem], withoutNetwork: Bool,
                                 server: @Sendable () async throws -> Item?) async -> Item? {
        let loaded = episodePost(item.id, from: entries)?.asItem
        if withoutNetwork { return loaded }
        do { return try await server() } catch { return loaded }
    }

    /// **What the server says about a downloaded title, into the entry.**
    ///
    /// Watched, position and time come from the server, **unless** the entry carries
    /// a newer state from here that is not yet reported (`recent` newer than the
    /// server's value). Then it stays; the late report brings it over and the next
    /// query confirms it.
    public static func follow(_ p: DownloadItem, watchState: UserItemData?) -> DownloadItem {
        guard let watchState else { return p }
        // One second of slack: the late report writes exactly this time to the server,
        // and what comes back may be rounded.
        if let here = p.recent,
           here.timeIntervalSince(watchState.lastPlay ?? .distantPast) > 1 { return p }
        var q = p
        q.watched = watchState.played ?? false
        q.pointTicks = watchState.playbackPositionTicks.flatMap { $0 > 0 ? $0 : nil }
        q.recent = watchState.lastPlay ?? p.recent
        return q
    }

    /// "3 of 12 titles" nobody needs, but "12 titles · 42.8 GB" yes.
    public static func allocation(_ entries: [DownloadItem]) -> (count: Int, bytes: Int64) {
        let done = entries.filter { $0.state == .done }
        return (done.count, done.reduce(0) { $0 + $1.bytes })
    }
}

/// **Keep counting between two reports, never backwards.**
///
/// Reports come at most once per second
/// (``Downloadregeln/progressShow(geladen:gesamt:vorher:vergangen:)``).
/// Showing only the reports makes the number jump in steps; stores do not do
/// that: App Store and Music keep counting in between at the pace of the last
/// seconds. This estimator computes exactly that, and bar, ring and number all
/// read the same value so none runs ahead of another.
///
/// Four rules: (1) the pace is smoothed, a single fast packet does not push it
/// up; (2) at most one and a half seconds past the last report, then the
/// number stands until something comes again; (3) never less than last shown;
/// only a restart (less than the previous report) resets; (4) **paused means
/// standing.** Pause, waiting, error, no network: ``halt()`` freezes the
/// number, and on resume it measures the pace anew instead of calculating
/// across the pause; the number stands until the real one catches up and does
public struct ProgressEstimator: Sendable {
    private var reported: Int64?
    private var reportTime: Date?
    private var total: Int64 = 0
    private var running = false
    /// Bytes per second, smoothed.
    public private(set) var tempo: Double = 0
    private var shown: Int64 = 0

    public init() {}

    public mutating func report(_ loaded: Int64, total: Int64, um time: Date) {
        self.total = total
        if let g = reported, loaded < g {
            // Restart: what stood before no longer applies.
            tempo = 0
            shown = loaded
        } else if running, let g = reported, let mz = reportTime {
            let dt = time.timeIntervalSince(mz)
            if dt > 0.05 {
                let new = Double(loaded - g) / dt
                tempo = tempo == 0 ? new : tempo * 0.7 + new * 0.3
            }
        }
        reported = loaded
        reportTime = time
        running = true
    }

    /// No bytes come anymore: the number stays where it is.
    public mutating func halt() {
        running = false
        tempo = 0
    }

    public mutating func value(um time: Date) -> Int64 {
        guard let g = reported, let mz = reportTime else { return shown }
        var schaetzung = g
        if running {
            let dt = min(max(time.timeIntervalSince(mz), 0), 1.5)
            schaetzung += Int64(tempo * dt)
        }
        if total > 0 { schaetzung = min(schaetzung, total) }
        shown = max(shown, schaetzung)
        return shown
    }
}
