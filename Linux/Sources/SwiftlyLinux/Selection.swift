import Foundation
import JellyfinKit

/// The user's settings, as they live in `AppModel` on the Apple versions (there in
/// `@AppStorage`, here as JSON next to the session).
///
/// **The defaults match the Mac:** Direct Play forced, unlimited bitrate, next episode
/// automatic, 10 s back and 30 s forward. Which values are selectable is defined in
/// `JellyfinKit.Bitrate`, `.Span` and `.LanguageSelection`, not here, otherwise the platforms
/// would offer different lists.
/// Direct Play and bitrate limit of one server, keyed by `serverURL.absoluteString`.
/// As with `AppModel.serverKey` on Apple: one server may transcode and another not,
/// so the choice belongs to the server, not the device.
struct PlaybackJeServer: Codable {
    enum CodingKeys: String, CodingKey {
        case alwaysDirectPlay = "immerDirectPlay"
        case bitratesLimit = "bitratenGrenze"
    }
    var alwaysDirectPlay: Bool
    var bitratesLimit: Int
}

struct Choices: Codable {
    /// The device-wide choice, used while no server has its own (field `playbackPerServer`,
    /// below). New users still see only the two simple fields, so the names and defaults stay.
    private var alwaysDirectPlayDevice = true
    private var bitratesLimitDevice = 0
    /// Direct Play and bitrate limit per server, as on Apple (`AppModel`) and Android. Not
    /// driven by `CodingKeys` over the old field names, so a file from before this change
    /// still reads.
    var playbackPerServer: [String: PlaybackJeServer] = [:]
    /// Which server is current. Comes from the session (`App.bundle`) and is not saved:
    /// `App` sets it fresh at every start, before the player or settings page needs it.
    var activeServer: String = ""

    /// **Per server.** One server may transcode and another not.
    var alwaysDirectPlay: Bool {
        get { playbackPerServer[activeServer]?.alwaysDirectPlay ?? alwaysDirectPlayDevice }
        set {
            guard !activeServer.isEmpty else { alwaysDirectPlayDevice = newValue; return }
            var w = playbackPerServer[activeServer]
                ?? PlaybackJeServer(alwaysDirectPlay: alwaysDirectPlayDevice, bitratesLimit: bitratesLimitDevice)
            w.alwaysDirectPlay = newValue
            playbackPerServer[activeServer] = w
        }
    }
    /// **Per server.** Applies only when Direct Play is not forced for this server.
    var bitratesLimit: Int {
        get { playbackPerServer[activeServer]?.bitratesLimit ?? bitratesLimitDevice }
        set {
            guard !activeServer.isEmpty else { bitratesLimitDevice = newValue; return }
            var w = playbackPerServer[activeServer]
                ?? PlaybackJeServer(alwaysDirectPlay: alwaysDirectPlayDevice, bitratesLimit: bitratesLimitDevice)
            w.bitratesLimit = newValue
            playbackPerServer[activeServer] = w
        }
    }
    var audioLanguage = ""
    var subtitleLanguage = ""
    var subtitleAutomatic = false
    /// **New movies and new series in separate rows** instead of one.
    /// `HomeModel` evaluates it; the row was missing on Linux entirely.
    var newArrivalsDisconnected = true

    /// **What is reported to the server as the limit.** The calculation lives in the package
    /// (``Bitratengrenze``). It used to exist here and in `AppModel` verbatim; the app's
    /// promise depends on it, and two copies are guaranteed to drift apart.
    var profileBitrate: Int {
        BitratesLimit.of(alwaysDirectPlay: alwaysDirectPlay, megabit: bitratesLimit)
    }
    /// **Set only when the user has toggled "Next episode automatically".** Otherwise the
    /// Jellyfin account's setting applies (rule in `Weiterschalten`); read via
    /// ``App/naechsteAutomatisch``.
    ///
    /// A separate key, because the old `naechsteAutomatisch` was written on **every** save,
    /// so a `true` in it does not mean anyone chose it. A `false` does, since the default
    /// was `true`.
    var nextAutomaticSelected: Bool?
    var backSeconds = 10
    var forwardSeconds = 30
    var progressOnTiles = true
    /// **The watchlist can be switched off**: sidebar row, filter and the button on detail
    /// pages. Same as `AppModel.watchlistShown`, default on.
    var watchlistShown = true
    /// **The letter strip beside "By name" grids**. Same as `AppModel.alphabetShown`,
    /// default on.
    var alphabetShown = true
    /// **Title as logo** on movie and series pages, when the server has one
    /// (Apple: `@AppStorage("titelAlsLogo")`, default off).
    var titleAsLogo = false
    /// **Fill the frame instead of showing the whole picture.**
    ///
    /// The same choice as the pinch gesture on iPhone and iPad and the row in the playback
    /// menu on Mac and TV: two states, no third, since that would only be a stretch. On the
    /// Apple versions it is in `@AppStorage("bildfuellend")`; here it lives in the same file
    /// as the other choices.
    var fillFrame = false
    /// **Remaining time or end time** in the player: "-12:34" or "Endet um 22:41". A click
    /// toggles, the choice persists (iOS `@AppStorage("restzeitAlsEnde")`).
    var remainingTimeAsEnd = false
    /// **Player volume**, 0 to 1, applies across titles (Mac: `@AppStorage("playerLautstaerke")`).
    /// `volumePrior` remembers the value for "sound on" after muting.
    var volume = 1.0
    var volumePrior = 1.0
    /// **The technical info badge: the information that stays.**
    ///
    /// Stutter is noticed *while* watching. So the switch belongs in the player, not in
    /// settings; that is how the Apple versions do it.
    var techBadge = false
    /// **Skip intro and outro automatically** (Apple: `@AppStorage("introAbspannAuto")`, default off).
    var skipAutomatic = false

    /// **off until switched on.**
    ///
    /// Without this switch there is neither the row in the sidebar nor the button on the
    /// detail page. As with Seerr: whoever does not want it sees nothing of it apart from the
    /// one row in settings. Same as `AppModel.downloadsAn`.
    var downloadsAn = false
    /// **Downloads wait on mobile data**. Also selectable on a desktop: a laptop can
    /// well be on a metered connection.
    var onlyOverWLAN = true

    /// **How much buffer the player keeps**, the level from the package.
    ///
    /// For users watching without a fixed line. The calculation is in `JellyfinKit.BufferLevel`;
    /// this only stores which level is chosen, as the `rawValue`, so a file from disk does not
    /// need to know the type.
    ///
    /// **And once more further down in the decoder.** That one is written by hand because a
    /// missing key would otherwise reset *all* settings; adding a field here and forgetting it
    /// there yields a choice that forgets itself on every restart.
    /// **Show on Discord what is playing: off until switched on.**
    ///
    /// The only setting in this app that gives something to the **outside**: enabling it tells
    /// everyone in the user's Discord servers which movie they are watching. A default of "on"
    /// would be a publication nobody asked for, not a convenience.
    var discordShow = false

    var bufferLevel = BufferLevel.normal.rawValue

    /// **"Recent searches", raw as on disk.** The list itself is computed by ``SearchHistory``
    /// in the package: at most eight, newest first, no duplicates. Only the string is stored
    /// here, so the format exists in one place and not in three views.
    var searchHistory = ""
    /// **Per account** (`SearchHistory.key(account:)` in the package): switching account does
    /// not show the previous account's searches. The old shared entry above is assigned to the
    /// active account on first read.
    var searchHistoryPerAccount: [String: String] = [:]

    /// **Finished titles, counted on this machine only**, for the Discord notice after the
    /// fifth (`Community.kickoff`). None of it leaves the machine.
    var doneWatch = 0
    /// Has the notice appeared yet? Once per installation.
    var discordHintShown = false

    /// **Which kind the watchlist shows**: "Filme & Serien", "Filme" or "Serien". It was a
    /// plain in-memory value and so reset to `all` on every start; on the Mac it is in
    /// `UserDefaults`, on the grounds that a sort order is a setting, not an action
    /// (`Sources/Shared/WatchlistModel.swift`).
    var savedGenre = ""

    // MARK: Home

    /// The order of the home rows, as `rawValue` of ``StartRail``. Empty means the package's
    /// default order.
    var startRails: [String] = []
    /// Which rows are hidden.
    var startOut: [String] = []
    /// The chosen genres, as separate rows below or as chips on top.
    var startGenres: [String] = []
    /// **Two forms of the same selection, not two sets.** The switch changes *how* the chosen
    /// genres appear, not *which*. An earlier attempt on Apple suddenly showed all of the
    /// server's genres as chips, and nobody understood why.
    var genreChips = false
    /// **The chosen libraries and collections per server**, as the package's JSON
    /// (`StartLibraries`); IDs are valid only on their server. Stored as text so that a
    /// corrupt entry does not discard the whole file: reading is tolerant and never throws.
    var startLibrariesPerServer: [String: String] = [:]
    /// The active server's choice, in home-page order.
    var startLibraries: [StartLibrary] {
        get {
            StartLibraries.read(startLibrariesPerServer[activeServer]?.data(using: .utf8))
        }
        set {
            guard !activeServer.isEmpty else { return }
            let clean = StartLibraries.clean(newValue)
            if clean.isEmpty { startLibrariesPerServer[activeServer] = nil; return }
            startLibrariesPerServer[activeServer] =
                StartLibraries.data(clean).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    // MARK: What is remembered per place

    /// **Sorting and filters survive a restart**.
    ///
    /// A user's feedback: "I sort by recent because it is practical. When I leave the app and
    /// come back, I am back at the default." They are right, and it is not minor: a sort order
    /// is not an action but a setting; it is chosen once and expected to be there afterwards.
    ///
    /// **Per place, not global.** Movies by year and series by recently added is a sensible
    /// combination; a shared value would play them against each other. The key is the
    /// section ID.
    var sortingPerPlace: [String: String] = [:]
    var filterPerPlace: [String: String] = [:]
    /// Which library a section shows when there are several.
    var libraryPerGenre: [String: String] = [:]
    /// **The window as it was when closed** (GNOME HIG: windows should keep their size).
    /// 0 means never remembered; the default applies.
    var windowWidth = 0
    var windowHeight = 0
    var windowMaximized = false
    /// **UI size**, 0.8 to 1.5, multiplied with what the system already gives (``Skalierung``).
    /// 1 means as the system.
    var surface = 1.0

    var buffer: BufferLevel { BufferLevel(rawValue: bufferLevel) ?? .normal }

    // MARK: Reading that survives an older file

    /// **A missing key must not reset everything.**
    ///
    /// The file on disk came from a version before `fillFrame` and `techBadge`. Swift's
    /// generated decoder requires every key; one was missing, `decode` threw, and `read()`
    /// silently returned fresh defaults: **all** settings gone, not just the new one. Quality,
    /// languages, skip lengths, home layout: everything was back at the start, and nobody
    /// noticed because an app with default values looks perfectly normal.
    ///
    /// This recurs with **every** new setting. So each value is read individually and keeps its
    /// default if missing. That is why what Swift would generate is written by hand here.
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        func w<T: Decodable>(_ s: CodingKeys, _ guideline: T) -> T {
            (try? k.decodeIfPresent(T.self, forKey: s)) .flatMap { $0 } ?? guideline
        }
        alwaysDirectPlayDevice  = w(.alwaysDirectPlayDevice, true)
        bitratesLimitDevice   = w(.bitratesLimitDevice, 0)
        playbackPerServer     = w(.playbackPerServer, [:])
        activeServer          = ""
        audioLanguage             = w(.audioLanguage, "")
        subtitleLanguage      = w(.subtitleLanguage, "")
        subtitleAutomatic  = w(.subtitleAutomatic, false)
        // `true`, as on the Mac (`Sources/Shared/AppModel.swift`). It stayed `false` here, so a
        // fresh install looked different from there.
        newArrivalsDisconnected    = w(.newArrivalsDisconnected, true)
        let alt = (try? decoder.container(keyedBy: OldKey.self)
                       .decodeIfPresent(Bool.self, forKey: .nextAutomatic)) ?? nil
        nextAutomaticSelected = w(.nextAutomaticSelected, Bool?.none)
            ?? (alt == false ? false : nil)
        backSeconds        = w(.backSeconds, 10)
        forwardSeconds            = w(.forwardSeconds, 30)
        progressOnTiles  = w(.progressOnTiles, true)
        watchlistShown   = w(.watchlistShown, true)
        alphabetShown    = w(.alphabetShown, true)
        titleAsLogo           = w(.titleAsLogo, false)
        fillFrame           = w(.fillFrame, false)
        remainingTimeAsEnd        = w(.remainingTimeAsEnd, false)
        volume            = min(max(w(.volume, 1.0), 0), 1)
        volumePrior       = min(max(w(.volumePrior, 1.0), 0), 1)
        techBadge          = w(.techBadge, false)
        skipAutomatic      = w(.skipAutomatic, false)
        downloadsAn            = w(.downloadsAn, false)
        onlyOverWLAN           = w(.onlyOverWLAN, true)
        bufferLevel            = w(.bufferLevel, BufferLevel.normal.rawValue)
        discordShow        = w(.discordShow, false)
        searchHistory            = w(.searchHistory, "")
        searchHistoryPerAccount     = w(.searchHistoryPerAccount, [String: String]())
        doneWatch         = w(.doneWatch, 0)
        discordHintShown  = w(.discordHintShown, false)
        savedGenre            = w(.savedGenre, "")
        startRails            = w(.startRails, [])
        startOut               = w(.startOut, [])
        startGenres            = w(.startGenres, [])
        genreChips             = w(.genreChips, false)
        startLibrariesPerServer = w(.startLibrariesPerServer, [String: String]())
        sortingPerPlace        = w(.sortingPerPlace, [:])
        filterPerPlace            = w(.filterPerPlace, [:])
        libraryPerGenre    = w(.libraryPerGenre, [:])
        windowWidth          = w(.windowWidth, 0)
        windowHeight           = w(.windowHeight, 0)
        windowMaximized       = w(.windowMaximized, false)
        surface            = w(.surface, 1.0)
    }

    /// Keys of earlier versions that are only read now.
    private enum OldKey: String, CodingKey { case nextAutomatic = "naechsteAutomatisch" }

    /// **By hand, because of the two renamed fields.** `alwaysDirectPlay` and `bitratesLimit` are
    /// now called `...Device` (device-wide; the real per-server choice is in `playbackPerServer`).
    /// A file from before this change must still read and write under the old keys.
    /// `activeServer` is deliberately not here: it comes from the session, not from disk.
    /// The raw values are the keys existing files carry; the Swift names were translated
    /// later and must not leak into the file (`Werkzeuge/codable-keys-check.py`).
    enum CodingKeys: String, CodingKey {
        case alwaysDirectPlayDevice = "immerDirectPlay"
        case bitratesLimitDevice = "bitratenGrenze"
        case playbackPerServer = "wiedergabeJeServer"
        case audioLanguage = "tonSprache", subtitleLanguage = "untertitelSprache", subtitleAutomatic = "untertitelAutomatisch", newArrivalsDisconnected = "neuzugaengeGetrennt",
             nextAutomaticSelected = "naechsteAutomatischGewaehlt", backSeconds = "zurueckSekunden",
             forwardSeconds = "vorSekunden", progressOnTiles = "fortschrittAufKacheln", watchlistShown = "merklisteAn", alphabetShown = "alphabetAn", titleAsLogo = "titelAlsLogo",
             fillFrame = "bildfuellend", remainingTimeAsEnd = "restzeitAlsEnde", volume = "lautstaerke",
             volumePrior = "lautstaerkeDavor", techBadge = "technikschild", skipAutomatic = "introAbspannAuto", downloadsAn, onlyOverWLAN = "nurUeberWLAN",
             bufferLevel = "pufferstufe", discordShow = "discordAnzeigen", searchHistory = "suchverlauf",
             searchHistoryPerAccount = "suchverlaufJeKonto", doneWatch = "fertigGeschaut",
             discordHintShown = "discordHinweisGezeigt", savedGenre = "merkgattung", startRails = "startReihen",
             startOut = "startAus", startGenres, genreChips, startLibrariesPerServer = "startBibliothekenJeServer",
             sortingPerPlace = "sortierungJeOrt", filterPerPlace = "filterJeOrt", libraryPerGenre = "bibliothekJeGattung",
             windowWidth = "fensterBreite", windowHeight = "fensterHoehe", windowMaximized = "fensterMaximiert",
             surface = "oberflaeche"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alwaysDirectPlayDevice, forKey: .alwaysDirectPlayDevice)
        try c.encode(bitratesLimitDevice, forKey: .bitratesLimitDevice)
        try c.encode(playbackPerServer, forKey: .playbackPerServer)
        try c.encode(audioLanguage, forKey: .audioLanguage)
        try c.encode(subtitleLanguage, forKey: .subtitleLanguage)
        try c.encode(subtitleAutomatic, forKey: .subtitleAutomatic)
        try c.encode(newArrivalsDisconnected, forKey: .newArrivalsDisconnected)
        try c.encode(nextAutomaticSelected, forKey: .nextAutomaticSelected)
        try c.encode(backSeconds, forKey: .backSeconds)
        try c.encode(forwardSeconds, forKey: .forwardSeconds)
        try c.encode(progressOnTiles, forKey: .progressOnTiles)
        try c.encode(watchlistShown, forKey: .watchlistShown)
        try c.encode(alphabetShown, forKey: .alphabetShown)
        try c.encode(titleAsLogo, forKey: .titleAsLogo)
        try c.encode(fillFrame, forKey: .fillFrame)
        try c.encode(remainingTimeAsEnd, forKey: .remainingTimeAsEnd)
        try c.encode(volume, forKey: .volume)
        try c.encode(volumePrior, forKey: .volumePrior)
        try c.encode(techBadge, forKey: .techBadge)
        try c.encode(skipAutomatic, forKey: .skipAutomatic)
        try c.encode(downloadsAn, forKey: .downloadsAn)
        try c.encode(onlyOverWLAN, forKey: .onlyOverWLAN)
        try c.encode(bufferLevel, forKey: .bufferLevel)
        try c.encode(discordShow, forKey: .discordShow)
        try c.encode(searchHistory, forKey: .searchHistory)
        try c.encode(searchHistoryPerAccount, forKey: .searchHistoryPerAccount)
        try c.encode(doneWatch, forKey: .doneWatch)
        try c.encode(discordHintShown, forKey: .discordHintShown)
        try c.encode(savedGenre, forKey: .savedGenre)
        try c.encode(startRails, forKey: .startRails)
        try c.encode(startOut, forKey: .startOut)
        try c.encode(startGenres, forKey: .startGenres)
        try c.encode(genreChips, forKey: .genreChips)
        try c.encode(startLibrariesPerServer, forKey: .startLibrariesPerServer)
        try c.encode(sortingPerPlace, forKey: .sortingPerPlace)
        try c.encode(filterPerPlace, forKey: .filterPerPlace)
        try c.encode(libraryPerGenre, forKey: .libraryPerGenre)
        try c.encode(windowWidth, forKey: .windowWidth)
        try c.encode(windowHeight, forKey: .windowHeight)
        try c.encode(windowMaximized, forKey: .windowMaximized)
        try c.encode(surface, forKey: .surface)
    }

    /// **The empty start.** Without a file, what is set on the fields above applies.
    init() {}

    private static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/swiftly/wahlen.json")
    }

    static func read() -> Choices {
        guard let data = try? Data(contentsOf: file) else { return Choices() }
        // The decoder above forgives missing keys; what still fails here is no longer valid JSON.
        // It is set aside instead of silently overwritten, see ``Speicher/beiseitelegen(_:weil:)``.
        do { return try JSONDecoder().decode(Choices.self, from: data) }
        catch {
            Cache.pagePut(file, because: error)
            return Choices()
        }
    }

    func secure() {
        let folder = Self.file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}

/// Which value list is currently expanded.
enum ValuesSelection { case bitrate, buffer, audio, subtitle, back, forward }

// `Spurbereich` (the tracks-left/choice-right panel of the playback menu) was dropped with
// the new player design. It is replaced by the three levels in `PlayerLayers.swift` (audio &
// subtitles, settings, episodes), copied from `Sources/macOS/PlayerLayers.swift`. As on the
// Mac, there is no playback speed there anymore.

/// The libVLC version, for the settings footer.
///
/// On the Apple versions this says "VLCKit 4.0.0-a23". Here there is no VLCKit, only the
/// system's libVLC, so the text names what is actually loaded instead of claiming a version.
enum VLCVersion {
    nonisolated(unsafe) static var text: String = "3.x"
}
