import Foundation
import OSLog
import JellyfinKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AppModel {

    /// **One per process, not one per `RootView.init`.**
    ///
    /// `@State private var model = AppModel()` evaluates the expression every time
    /// `RootView` is created; SwiftUI keeps only the first and discards the rest.
    /// Each discarded one had already done everything: read the keychain, restored
    /// the session, sent requests to the server, created a second background session
    /// with the same identifier. And because `init` runs in the app's `body`,
    /// SwiftUI tracked its reads: if a download was still running in the system at
    /// launch, the takeover then changed `entries`, the app rebuilt its `body`,
    /// created a new `RootView` and with it a new model. Measured in the iOS
    /// simulator: about 70 models per second, endlessly while the app was open.
    static let only = AppModel()

    enum Phase: Equatable {
        case disconnected
        case connecting
        case needsLogin(serverName: String, version: String)
        case ready
    }

    var phase: Phase = .disconnected
    var errorMessage: String?
    var views: [Item] = []
    /// For the header in the profile menu.
    var serverName: String?

    // MARK: Settings

    /// Never allow transcoding. The reason for this app, hence the default is on.
    /// **Per server.** One server may transcode, another not; the choice belongs to
    /// the server, not the device (`serverKey`).
    var alwaysDirectPlay: Bool { didSet { remember(alwaysDirectPlay, "immerDirectPlay" + serverKey) } }
    /// Upper limit in Mbit/s, 0 means unlimited. Applies only when Direct Play is
    /// not forced.
    var bitratesLimit: Int { didSet { remember(bitratesLimit, "bitratenGrenze" + serverKey) } }
    var landscapeFixed: Bool { didSet { remember(landscapeFixed, "querformatFest") } }
    var progressOnTiles: Bool { didSet { remember(progressOnTiles, "fortschritt") } }
    /// **The watchlist can be switched off**: its page, its filter and the button on
    /// detail pages disappear everywhere. The favourites stay on the server, so switching
    /// it back on brings everything back.
    var watchlistShown: Bool { didSet { remember(watchlistShown, "merklisteAn") } }
    /// **The letter strip beside A–Z grids** (``AlphabetIndex``), on by default.
    var alphabetShown: Bool { didSet { remember(alphabetShown, "alphabetAn") } }

    /// Empty means: take whatever the server specifies.
    var audioLanguage: String { didSet { remember(audioLanguage, "tonSprache") } }
    /// **Choosing a language switches "automatic" on.** On its own the language did nothing while the switch stayed off (the default), so a chosen language never showed at the start.
    var subtitleLanguage: String {
        didSet {
            remember(subtitleLanguage, "utSprache")
            if !subtitleLanguage.isEmpty, !subtitleAutomatic { subtitleAutomatic = true }
        }
    }
    /// Only enable subtitles if the audio is not in the preferred language.
    var subtitleAutomatic: Bool { didSet { remember(subtitleAutomatic, "utAuto") } }
    /// Whether playback continues on its own at the end. Rule in `Weiterschalten`:
    /// own choice before account setting before "on".
    var nextAutomatic: Bool {
        get { Advance.applies(ownSelection: nextAutomaticSelected, account: nextAutomaticAccount) }
        set { nextAutomaticSelected = newValue }
    }
    /// Set only if someone flipped the switch in Swiftly.
    private var nextAutomaticSelected: Bool? {
        didSet { if let nextAutomaticSelected { remember(nextAutomaticSelected, "naechsteAuto") } }
    }
    /// The account's `EnableNextEpisodeAutoPlay`. Not persisted: it arrives fresh
    /// on every launch, and another account has another.
    private var nextAutomaticAccount: Bool?
    /// Becomes `true` once the rating question is due after a title is finished.
    /// The root view asks and resets it.
    var ratingDue = false
    /// Same for the one-time hint about the community Discord (`Community`).
    var discordHintDue = false
    /// Whether a player is open right now. **Both prompts wait for it**: the
    /// switch to the next episode counts a title while the player keeps running, and
    /// a question over the picture would be the worst thing.
    var playerOpen = false

    /// "Recently added" split into movies and series.
    ///
    /// **Default off so nothing changes for anyone.** One row with everything is the
    /// state since the first version; whoever wants them split switches. Explicitly
    /// `false` on first launch: `UserDefaults` returns `false` for an unknown key
    /// anyway, but this states the intent instead of relying on chance.
    var newAccessDisconnected: Bool { didSet { remember(newAccessDisconnected, "neuGetrennt") } }

    // MARK: Home page as desired

    /// Order of the fixed rows. Hiding one keeps its place.
    ///
    /// **Duplicates are caught here, not in the three views.** Reordering happens in
    /// three places (`PresentationView` on iOS, the same file under `macOS`,
    /// `ProfileView` on tvOS) and each writes back the whole list. A check per view
    /// would be the same line three times, and the fourth view would lack it again.
    /// The rule lives in the package (`StartRailsEpisode.clean`), the place that
    /// enforces it is here.
    ///
    /// The second assignment runs `didSet` once more; by then the list is clean and
    /// it is stored. There cannot be more than this one pass, since `clean` applied
    /// to itself is identical.
    var startRails: [StartRail] {
        didSet {
            let clean = StartRailsEpisode.clean(startRails)
            guard clean == startRails else {
                let before = startRails.map(\.rawValue).joined(separator: ",")
                let afterwards = clean.map(\.rawValue).joined(separator: ",")
                Self.log.error("Startreihen doppelt — \(before, privacy: .public) wird zu \(afterwards, privacy: .public)")
                startRails = clean
                return
            }
            remember(startRails.map(\.rawValue), "startReihen")
        }
    }
    var startOut: Set<StartRail> { didSet { remember(startOut.map(\.rawValue), "startAus") } }
    /// **Genres either as chips or as rows**, never both: on means one row of
    /// chips under the header, off means the chosen genres appear as rows of their
    /// own. Off by default and without genres, so the home page stays as it was
    /// until someone wants something.
    var genreChips: Bool { didSet { remember(genreChips, "genreChips") } }
    var startGenres: [String] { didSet { remember(startGenres, "startGenres") } }
    /// **Libraries and collections as home page rows of their own**, in the chosen
    /// order. The choice belongs to the server (`serverKey`), since the IDs
    /// are its own, and it stays even if a library disappears there or is not
    /// accessible to the profile: the row is just missing
    /// (`HomeLoader.libraryRails`). The computation lives in the package
    /// (`StartLibraries`).
    var startLibraries: [StartLibrary] {
        didSet {
            let clean = StartLibraries.clean(startLibraries)
            guard clean == startLibraries else { startLibraries = clean; return }
            remember(StartLibraries.data(startLibraries) ?? Data(), "startBibliotheken" + serverKey)
        }
    }
    /// How much buffer the player holds. See ``BufferLevel`` in the package.
    var bufferLevel: BufferLevel { didSet { remember(bufferLevel.rawValue, "pufferstufe") } }
    /// **Shows on Discord what is playing, and is off until enabled.**
    ///
    /// It is the only setting of this app that sends something **outside**: enabling
    /// it tells everyone in your Discord servers which movie you are watching. An
    /// "on" default would not be a convenience but a publication nobody asked for,
    /// the same consideration as with the off-by-default rule and Seerr, only with more weight.
    var discordShow: Bool { didSet {
        remember(discordShow, "discordAnzeigen")
        // Whoever turns it off wants to be gone immediately, not at the next
        // change.
        if !discordShow { DiscordIndicator.shared.tidyAway() }
    } }
    var backSeconds: Int { didSet { remember(backSeconds, "zurueckSek") } }
    var forwardSeconds: Int { didSet { remember(forwardSeconds, "vorSek") } }

    /// **off until enabled.**
    ///
    /// Without this switch there is neither the bottom tab nor the field on the
    /// detail page nor the rings in the episode list. As with Seerr: whoever does
    /// not want it sees nothing of it besides the one settings row.
    var downloadsAn: Bool {
        didSet {
            remember(downloadsAn, "downloadsAn")
            // A disabled download does not continue. What is on disk stays; the pause rule asks
            // when turning off what should happen to it, and this line only pauses.
            if downloadsAn {
                downloads.networkObserve()
            } else {
                downloads.allHalt()
                // The path observer costs nothing noteworthy, but also does not run for
                // nothing while the feature is off.
                downloads.networkNotMoreObserve()
            }
        }
    }
    /// The account's `Policy.EnableContentDownloading`, as ``DownloadPermission``. Not
    /// persisted: arrives fresh on every launch, and another account has another
    /// right.
    private(set) var downloadPermission: DownloadPermission = .unknown
    /// May the server transcode video for this account? Otherwise the player
    /// offers no bitrate limit, since it would have no effect.
    private(set) var convertAllowed = true
    /// **Whether a smaller quality is selectable when downloading** (converting
    /// picture and audio), decided in the package (`DownloadQuality.waehlbar`).
    /// Allowed without an answer, as with the player.
    private(set) var downloadQualitySelectable = true

    /// **Whether a download button appears at all**: the switch above *and* the
    /// account's right, decided in the package.
    ///
    /// Not `downloadsAn` at the button sites: the bottom tab and the settings row
    /// still depend on the switch alone, otherwise someone who loses the right today
    /// could no longer reach the files downloaded yesterday, not even to delete
    /// them.
    var downloadButtonShow: Bool {
        DownloadPermission.offer(rights: downloadPermission, functionOn: downloadsAn)
    }

    /// **H5.** On at first activation; with original files everything else is
    /// unfriendly.
    var onlyOverWLAN: Bool {
        didSet {
            remember(onlyOverWLAN, "nurUeberWLAN")
            downloads.onlyOverWLAN = onlyOverWLAN
        if downloadsAn { downloads.networkObserve() }
        }
    }


    /// Suffix for settings that apply per server. Empty without a session, in which
    /// case the old device-wide value applies.
    private var serverKey: String {
        session.map { "|" + $0.serverURL.absoluteString } ?? ""
    }

    /// Direct Play and bitrate limit of the current server. If it has none of its
    /// own yet, the previous device-wide choice applies.
    private func playbackLoad() {
        let store = UserDefaults.standard
        let k = serverKey
        alwaysDirectPlay = store.object(forKey: "immerDirectPlay" + k) as? Bool
            ?? store.object(forKey: "immerDirectPlay") as? Bool ?? true
        bitratesLimit = store.object(forKey: "bitratenGrenze" + k) as? Int
            ?? store.integer(forKey: "bitratenGrenze")
        startLibraries = StartLibraries.read(store.data(forKey: "startBibliotheken" + k))
    }

    private func remember(_ value: Any, _ name: String) {
        UserDefaults.standard.set(value, forKey: name)
    }

    // MARK: - Several libraries of the same kind

    /// All libraries of a type, in the server's order.
    ///
    /// **A server can have several movie libraries**: one on an external disk, one
    /// local. The "Movies" tab used `views.first` and so showed only the first; the
    /// second was unreachable in the app. It was never noticed because our test
    /// server has exactly one.
    ///
    /// Search, "Continue Watching" and "Recently Added" go to the server without
    /// `ParentId` and so always saw everything; only browsing was halved.
    func libraries(art: String) -> [Item] {
        views.filter { $0.collectionType == art }
    }

    /// Which library was chosen last, remembered per type.
    ///
    /// By ID and not by position in the list: the server may reorder, and then
    /// "Movies" would suddenly show the other collection. If the remembered library
    /// is gone, the choice silently falls back to the first.
    func selectedLibrary(art: String) -> Item? {
        let available = libraries(art: art)
        if let identifier = UserDefaults.standard.string(forKey: Self.libraryName(art)),
           let hit = available.first(where: { $0.id == identifier }) {
            return hit
        }
        return available.first
    }

    func librarySelect(_ library: Item, art: String) {
        remember(library.id, Self.libraryName(art))
    }

    private static func libraryName(_ art: String) -> String { "bibliothek-\(art)" }


    // MARK: - Title menu: All, Collections, Libraries

    /// The account's collections; `nil` until asked.
    private(set) var collectionDirectory: CollectionDirectory?
    /// The account's video playlists ; `nil` until asked or
    /// if the server did not answer.
    private(set) var playlistDirectory: PlaylistDirectory?
    /// Movies and series per mixed library.
    private(set) var libraryShares: [String: LibraryShare] = [:]
    /// Which account and which libraries both apply to.
    private var offeringFor: String?
    private var offeringRuns: String?

    private var offeringKey: String {
        "\(accountSwitch)|" + views.map(\.id).joined(separator: ",")
    }

    /// What the title of this section offers for selection; the rule lives in the
    /// package (``SectionOffering``).
    ///
    /// **What belongs to another account does not count.** Until the new one has
    /// loaded, only what `views` alone provides is shown.
    func sectionOffering(art: String) -> SectionOffering {
        let applies = offeringFor == offeringKey
        return SectionOffering.compose(art: art, views: views,
                                      shares: applies ? libraryShares : [:],
                                      directory: applies ? collectionDirectory : nil,
                                      playlists: applies ? playlistDirectory : nil)
    }

    /// Fetches collections and shares of mixed libraries.
    ///
    /// **Not in `loadViews`**, but after the home page: `HomeModel` triggers
    /// it once the rows are up, so the first detail or library page does not wait
    /// for it.
    ///
    /// **Not only once per account.** An earlier version remembered the result until
    /// account or libraries changed; creating a collection on the server only showed
    /// after restarting the app. Now a state is valid for a minute; opening Movies
    /// or Series again after that checks again.
    func offeringLoad() async {
        guard let client, !views.isEmpty else { return }
        let of = offeringKey
        let freshValue = offeringTime.map { Date().timeIntervalSince($0) < 60 } ?? false
        guard offeringFor != of || !freshValue, offeringRuns != of else { return }
        offeringRuns = of
        defer { if offeringRuns == of { offeringRuns = nil } }
        let state = views
        async let shares = client.libraryShares(views: state)
        async let directory: CollectionDirectory? = {
            let withHidden = (try? await client.userViews(hidden: true)) ?? state
            if CollectionDirectory.hidden(visible: state, withHidden: withHidden) {
                return .empty
            }
            return try? await client.collectionDirectory(viewList: withHidden)
        }()
        // A server without an answer shows no playlists; that must not hold back
        // collections.
        async let playlists: PlaylistDirectory? = try? await client.playlistDirectory()
        let newPlaylists = await playlists
        let newShares = await shares
        let newDirectory = await directory
        // The account changed in the meantime: the result belongs to nobody
        // anymore.
        guard of == offeringKey else { return }
        libraryShares = newShares
        playlistDirectory = newPlaylists
        // **Failed is not empty.** Without an answer the state stays invalid, and the
        // next page asks again.
        guard let newDirectory else { return }
        collectionDirectory = newDirectory
        offeringFor = of
        offeringTime = Date()
    }
    private var offeringTime: Date?

    /// The IDs of the libraries that "All" reads from, for the filter, with the
    /// same filters as the page.
    func titleFilter(_ source: ShelfSource, filter: LibraryFilter) async -> TitleFilter? {
        guard let client else { return nil }
        do {
            return try await client.titleFilter(source, filters: filter.jellyfinFilter,
                                              isWatched: filter.isWatched)
        } catch {
            Self.log.error("Titelsieb fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The collections a title belongs to, from the directory, only if it belongs
    /// to this account.
    func collections(with title: Item) -> [ItemCollection] {
        guard offeringFor == offeringKey else { return [] }
        return collectionDirectory?.collections(with: title) ?? []
    }

    /// The posters of the first titles per collection, fetched once and then from
    /// memory: the mosaic asks anew on every appearance, and the same query each time
    /// would be wasteful. Like Android (`MosaicCache` in `CollectionPage.kt`).
    /// Cleared on account switch, in `afterSwitch()`.
    private var collectionTitleCache: [String: [Item]] = [:]

    /// The titles of a collection for the row on the detail page.
    ///
    /// **Silent, without `errorMessage`.** The row is an extra; if it fails it is
    /// missing. An error message over the whole page would be too loud for a row
    /// nobody asked for.
    func collectionTitle(_ collection: ItemCollection, art: String) async -> [Item]? {
        await collectionTitle(collection, art: art, limit: 100)
    }

    /// **The first four posters for the mosaic** of a collection without its own
    /// image: four titles, not a hundred. If the full list is already in memory,
    /// they come from there.
    func collectionPosters(_ collection: ItemCollection, art: String) async -> [Item]? {
        if let full = collectionTitleCache[collection.id + "|" + art] {
            return Array(full.prefix(4))
        }
        return await collectionTitle(collection, art: art, limit: 4)
    }

    private func collectionTitle(_ collection: ItemCollection, art: String, limit: Int) async -> [Item]? {
        let key = collection.id + "|" + art + (limit == 100 ? "" : "|\(limit)")
        if let saved = collectionTitleCache[key] { return saved }
        guard let client else { return nil }
        let source = ShelfSource(parent: collection.id, art: art, collection: true)
        guard let found = try? await client.items(parentID: source.parent, limit: limit,
                                       sortBy: Sorting.erscheinung.inputField,
                                       sortOrder: source.bearing(.erscheinung),
                                       recursive: source.recursive,
                                       includeItemTypes: source.types).items else { return nil }
        collectionTitleCache[key] = found
        return found
    }

    /// A "Part of the collection" row: the collection and its other titles.
    typealias CollectionRailsData = (collection: ItemCollection, title: [Item])

    /// The "Part of the collection" rows for a title; empty if it is in no
    /// collection. The movie page fetches them together with extras and similar
    /// titles and fades everything in at once.
    ///
    /// **Once here, not per platform.** The same loop existed in three
    /// `Sammlungsreihe` views (iPhone, Mac, TV). The views stay separate because
    /// pointer, focus and finger need different paths to the collection page; what
    /// they show is decided only by this function.
    func collectionRails(toward title: Item) async -> [CollectionRailsData] {
        guard let art = LibraryGenre.art(toType: title.type) else { return [] }
        // **An existing directory is enough; refreshing happens on the side.** The
        // detail page waits for these rows before fading in; with `await` it hung on
        // two sequential fetches on first open (and after every minute): `UserViews`
        // with hidden ones and all collections. Measured: movie page 417-527 ms, the
        // rest after title and plan being just this wait.
        if offeringFor == offeringKey {
            Task { await offeringLoad() }
        } else {
            await offeringLoad()
        }
        var found: [CollectionRailsData] = []
        // At most two rows. If a movie is in more collections, the others are mostly
        // automatically created duplicates.
        for collection in collections(with: title).prefix(2) {
            guard let list = await collectionTitle(collection, art: art) else { continue }
            let other = ListRules.withoutDouble(list).filter { $0.id != title.id }
            if !other.isEmpty { found.append((collection, other)) }
        }
        return found
    }

    /// The remembered choice of this section, checked against the offer.
    func sectionSelection(art: String) -> SectionSelection {
        sectionOffering(art: art)
            .choice(remembered: UserDefaults.standard.string(forKey: Self.libraryName(art)))
    }

    func sectionSelect(_ choice: SectionSelection, art: String) {
        remember(choice.rememberValue, Self.libraryName(art))
    }

    /// What is reported to the server as the limit. The computation lives in the
    /// package (``Bitratengrenze``) because Linux must give the same answer and it
    /// existed there verbatim a second time.
    private var profileBitrate: Int {
        BitratesLimit.of(alwaysDirectPlay: alwaysDirectPlay, megabit: bitratesLimit)
    }
    var serverVersion: String?
    var isWorking = false

    /// **One hook, and here.**
    ///
    /// `client` is set in five places: on connect, on sign-in, on account switch, on
    /// restore and on sign-out, and downloads must follow at all five. Five calls in
    /// five places are four chances to forget one; that is exactly how the remote
    /// control got stuck on account switch. `session` is already right here: `bundle`
    /// is set before `client` on each of the five paths.
    private(set) var client: JellyfinClient? {
        didSet {
            downloads.signIn(client: client, account: session?.userID)
            // The group belongs to the account: on switch and sign-out it is left with
            // the old client (`SharedModel.accountSwitched`).
            if client !== oldValue { SharedModel.shared.accountSwitched(alt: oldValue) }
        }
    }
    private(set) var session: Session? { didSet { if session?.serverURL != oldValue?.serverURL { playbackLoad() } } }

    /// All accounts on this server, in the order of the strip above the profile
    /// page. Empty while nobody is signed in.
    /// The Seerr connection. **Lives here because it holds a session**: a view that
    /// owns it loses it on closing, and a second model alongside would have a second
    /// access.
    let seerr = SeerrModel()
    /// Trakt: lives here for the same reason as `seerr`, and because the reports
    /// to Trakt arise alongside those to Jellyfin (`reportStart` and following).
    let trakt = TraktAccount()

    /// What is stored on the device. **Lives here for the same reason as
    /// `seerr`:** it holds a background session, and a view that owned it would
    /// lose it on closing, in the middle of a download.
    let downloads = DownloadManager()

    private(set) var accounts: [Session] = []

    /// Counts every account switch. Views attach to it to reload.
    ///
    /// **Why a counter and not `phase`.** On first sign-in the phase jumps from
    /// `disconnected` to `ready`, and the home page hangs on that. Switching between
    /// two accounts it stays at `ready`, so nothing happens and the screen keeps
    /// showing the previous account.
    private(set) var accountSwitch = 0

    /// **Counts every finished playback, but only once the server knows it.**
    ///
    /// Reported bug: leaving an episode after six or seven minutes, and the series
    /// page kept showing it as unwatched. Measured on the simulator against the test
    /// server: the final report arrived and the server tracked the position to the
    /// second (399 s reported, 399 s stored). Only the page underneath was wrong: it
    /// had fetched its state **before** playback and never again, since on tvOS and
    /// macOS the player lies as a layer over the page that stays put, and `.task`
    /// does not rerun.
    ///
    /// Counting happens after the final report and not when the player closes: a
    /// reload on close asks before the report arrived and gets the state of the last
    /// beat, up to ten seconds too early. Pages with progress attach their refresh
    /// here.
    private(set) var playbackEnded = 0
    /// A watch state was changed by hand (episode, season, series).
    private(set) var watchStateChanged = 0
    /// **What pages with watch state listen to.** Both change what is shown there:
    /// an episode watched to the end and a manual checkmark. Previously they
    /// listened only to the first; marking a whole series showed the episodes below
    /// still open until the page was reopened.
    var pagesRefresh: Int { playbackEnded + watchStateChanged }
    /// A title was added to or removed from the watchlist.
    private(set) var watchlistChanged = 0
    /// **What lists listen to** (watchlist, movies/series, search): watch state
    /// and bookmarks. Detail pages deliberately listen only to `pagesRefresh`,
    /// since they set the bookmark themselves.
    var listenRefresh: Int { pagesRefresh + watchlistChanged }

    /// **The source of truth for who is signed in.**
    ///
    /// `session` stays alongside because half the app reads it; it is updated from
    /// here and set nowhere else. Two places allowed to claim the same thing drift
    /// apart, which is exactly what happened with `hitInfo`.
    private var bundle: AccountBundle? {
        didSet {
            accounts = bundle?.accounts ?? []
            session = bundle?.activeOne
            // Seerr is tied to a server: on switching to another, its access applies.
            // Within one server nothing changes.
            seerr.serverSwitched(bundle?.activeOne.serverURL)
            // Trakt is tied to the account, not the server (`TraktAccount`).
            trakt.accountSwitched(bundle?.activeOne.accountKey)
            profileImagePrefetch()
        }
    }

    /// **The images of the other accounts, before anyone asks.**
    ///
    /// The URL is available immediately: it is built from server address, ID and
    /// access, without a network trip. The **image** itself was only fetched once
    /// the profile glyph first appeared on screen, so opening the profile the first
    /// time briefly showed the letter and then the image. Feedback: "on first open
    /// the other profile images appear later."
    ///
    /// There are at most a handful of small images, and they are fixed as soon as
    /// the bundle exists. Whoever fetches them then has them when needed. Without
    /// priority: the current poster goes first.
    private func profileImagePrefetch() {
        let addresses = accounts.compactMap { userImageURL(for: $0) }
        guard !addresses.isEmpty else { return }
        Task.detached(priority: .background) {
            for address in addresses {
                _ = await ImageCache.shared.load(address, onDevice: true)
            }
        }
    }

    /// The servers in the bundle, in the order of their first account.
    var server: [URL] { bundle?.server ?? [] }
    func accounts(on server: URL) -> [Session] { bundle?.accounts(on: server) ?? [] }

    nonisolated private static let sessionKey = "session"
    /// The key for the whole bundle. The old one above stays: starting an older
    /// version again finds its session there.
    private static let accountsKey = "konten"
    nonisolated static let log = Logger(subsystem: "de.paulherter.swiftly", category: "start")

    /// Stable device ID. Jellyfin lists the session with it in the dashboard.
    /// **No longer `private`.** `TakeoverModel` must know its own ID, otherwise
    /// the device shows itself as "playing elsewhere", which only becomes noticeable
    /// when a single device is running.
    static var deviceID: String = {
        let key = "de.paulherter.swiftly.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "Mac"
        #endif
    }

    init() {
        let store = UserDefaults.standard
        // `object(forKey:)` distinguishes "never set" from "off"; with
        // `bool(forKey:)` the default would always be false.
        alwaysDirectPlay = store.object(forKey: "immerDirectPlay") as? Bool ?? true
        bitratesLimit = store.integer(forKey: "bitratenGrenze")
        landscapeFixed = store.object(forKey: "querformatFest") as? Bool ?? true
        progressOnTiles = store.object(forKey: "fortschritt") as? Bool ?? true
        watchlistShown = store.object(forKey: "merklisteAn") as? Bool ?? true
        alphabetShown = store.object(forKey: "alphabetAn") as? Bool ?? true
        audioLanguage = store.string(forKey: "tonSprache") ?? ""
        let languageStored = store.string(forKey: "utSprache") ?? ""
        subtitleLanguage = languageStored
        var automaticStored = store.object(forKey: "utAuto") as? Bool ?? false
        // **Once:** a language chosen before the language started to switch "automatic" on never took effect. Set it now.
        if !store.bool(forKey: "utAutoNachgezogen") {
            store.set(true, forKey: "utAutoNachgezogen")
            if !languageStored.isEmpty, !automaticStored {
                automaticStored = true
                store.set(true, forKey: "utAuto")
            }
        }
        subtitleAutomatic = automaticStored
        // **Never set does not mean "on".** Then the Jellyfin account's setting
        // applies; whoever flipped the switch keeps it.
        nextAutomaticSelected = store.object(forKey: "naechsteAuto") as? Bool
        // **Split is the default.** Whoever explicitly turned it off keeps that;
        // whoever never touched it gets the two rows.
        newAccessDisconnected = store.object(forKey: "neuGetrennt") as? Bool ?? true
        // **The computation lives in the package** (`StartRailsEpisode.applicable`): a
        // row that did not exist when stored is appended, and anything duplicated in
        // the stored list comes out once. A second version of the same computation used
        // to live here and knew only the first half. A device on which "neueFilme" was
        // stored twice carried the error across every launch.
        let storedRails = store.stringArray(forKey: "startReihen") ?? []
        let applicableRails = StartRailsEpisode.applicable(stored: storedRails)
        if !storedRails.isEmpty, applicableRails.map(\.rawValue) != storedRails {
            let before = storedRails.joined(separator: ",")
            let afterwards = applicableRails.map(\.rawValue).joined(separator: ",")
            Self.log.info("Startreihen glattgezogen: abgelegt \(before, privacy: .public) → \(afterwards, privacy: .public)")
        }
        startRails = applicableRails
        startOut = Set((store.stringArray(forKey: "startAus") ?? []).compactMap(StartRail.init(rawValue:)))
        genreChips = store.object(forKey: "genreChips") as? Bool ?? false
        startGenres = store.stringArray(forKey: "startGenres") ?? []
        startLibraries = StartLibraries.read(store.data(forKey: "startBibliotheken"))
        bufferLevel = (store.string(forKey: "pufferstufe")
                       .flatMap(BufferLevel.init(rawValue:))) ?? .normal
        discordShow = store.object(forKey: "discordAnzeigen") as? Bool ?? false
        backSeconds = store.object(forKey: "zurueckSek") as? Int ?? 10
        forwardSeconds = store.object(forKey: "vorSek") as? Int ?? 30
        downloadsAn = store.object(forKey: "downloadsAn") as? Bool ?? false
        onlyOverWLAN = store.object(forKey: "nurUeberWLAN") as? Bool ?? true

        // `didSet` does not run during `init`; the switch must be passed through once
        // by hand, otherwise the manager downloads over cellular on first launch
        // despite the default forbidding it.
        downloads.onlyOverWLAN = onlyOverWLAN
        // Same reason for the path observer: without it the manager stayed at "Wi-Fi"
        // and "network available" after every restart, and "Wi-Fi only" only took
        // effect once someone touched a switch.
        if downloadsAn { downloads.networkObserve() }

        // **The package gets a thread to the outside.**
        //
        // `AppLog` lives here in the app because it writes to a file in the app
        // container; the package does not know it. But the quietest places in the whole
        // app are exactly there: a connection that does not come up, a response nobody
        // looks at.
        TrackSupport.write = { AppLog.writeOut($0) }
        StreamForwarder.log = { AppLog.writeOut($0) }
        // First launch, the App Store listener and the supporter status. Here because
        // this model exists exactly once per process, on every Apple platform.
        SupportModel.shared.start()

        // **Off the main path:** the test reads and writes only the "dauertest" entry
        // and reports to the log, nothing the sign-in needs. Previously up to four
        // keychain calls sat before the first frame.
        Task.detached(priority: .utility) { Self.keychainSelfIt() }
        // **Before the session.** Behind a gateway the very first request needs its
        // own headers, and the first posters right after.
        Self.ownHeadersLoad()
        #if DEBUG
        setTestSession()
        #endif
        restoreSession()
    }

    #if DEBUG
    /// **Self-test without a sign-in form.** Creates an account at a test address
    /// as if signed in, for launch and load tests against a replica server, without
    /// password and without interaction:
    ///
    /// xcrun simctl launch <device> <bundle-id> -testsitzung http://127.0.0.1:8899
    private func setTestSession() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-testsitzung"), i + 1 < arguments.count,
              let address = URL(string: arguments[i + 1]) else { return }
        let s = Session(accessToken: "testmerkmal", userID: "testnutzer",
                        userName: "Test", serverURL: address)
        // `-testsitzung2`: a second account on the same test server, for the account
        // switch self-test (`AccountSwitchRun`). Added first so the first account
        // remains the signed-in one.
        var before = loadBundle()
        if arguments.contains("-testsitzung2") {
            let second = Session(accessToken: "testmerkmal2", userID: "testnutzer2",
                                  userName: "Test 2", serverURL: address)
            before = AccountBundle.record(second, in: before).bundle
        }
        bundle = AccountBundle.record(s, in: before).bundle
        saveBundle()
        AppLog.writeOut("[Selbsttest] Testsitzung an \(address.absoluteString)")
    }
    #endif

    /// Checks whether the server answers and updates name and version.
    func connectionCheck() async -> String {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            let info = try await client.publicSystemInfo()
            // Switched to another server in the meantime: do not overwrite its name with
            // the one from before.
            guard self.client === client else { return String(localized: "Nicht angemeldet.") }
            serverName = info.serverName ?? serverName
            serverVersion = info.version ?? serverVersion
            // **Here and not in a timer of its own.** This is the one point where it is
            // proven that the server answers, and the check runs after every connect,
            // sign-in and account switch anyway. A second timer alongside would guess.
            await pendingSubmit()
            return String(localized: "Erreichbar — Jellyfin \(info.version ?? "?")")
        } catch {
            return readable(error)
        }
    }

    /// **"Check connection" for the button**, with a deadline.
    ///
    /// The check itself can take longer than the request: after the response the
    /// queued reports are sent, and they hang on the same network. Until then
    /// "One moment..." stood next to a disabled button with no end in sight. After
    /// `deadline` there is an answer and the button is free again; the check may finish
    /// in the background.
    func connectionCheck(deadline: Duration) async -> String {
        @MainActor final class InTimes { var done = false }
        let inTimes = InTimes()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let answer = await self.connectionCheck()
                guard !inTimes.done else { return }
                inTimes.done = true
                continuation.resume(returning: answer)
            }
            Task { @MainActor in
                try? await Task.sleep(for: deadline)
                guard !inTimes.done else { return }
                inTimes.done = true
                continuation.resume(returning: String(localized: "Der Server hat nicht geantwortet."))
            }
        }
    }

    /// Writes and reads a test value at launch. If that fails, the session is lost
    /// too; then the reason is in the log instead of wondering why you keep having to
    /// sign in again.
    nonisolated private static func keychainSelfIt() {
        // Deliberately left in place: this makes it measurable whether entries
        // survive a reinstall, which is exactly the question.
        if let alt = Keychain.load(key: "dauertest"),
           let text = String(data: alt, encoding: .utf8) {
            Self.log.info("Keychain: Eintrag überlebt seit \(text, privacy: .public)")
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date())
            do {
                try Keychain.save(Data(stamp.utf8), key: "dauertest")
                Self.log.info("Keychain: kein alter Eintrag, neu angelegt um \(stamp, privacy: .public)")
            } catch {
                Self.log.error("Keychain: Schreiben fehlgeschlagen — \(String(describing: error), privacy: .public)")
            }
        }
        Self.log.info("Keychain: Sitzung vorhanden = \(Keychain.load(key: sessionKey) != nil, privacy: .public)")
    }

    // MARK: - Verbinden

    /// Which address check is currently valid; see ``Pruefstand``.
    @ObservationIgnored private var checkState = CheckState()
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    /// **Starts the check of a typed address**, from the button as well as the
    /// keyboard's send key.
    ///
    /// If one is already running, it stays with it: the button is then disabled, the
    /// keyboard was not, and its second send started a second check alongside the
    /// first. Whoever changes the address cancels the running one via
    /// ``addressChanged(_:)`` before sending again.
    func connectStart(_ raw: String, headers: [OwnHeader] = []) {
        guard checkState.ongoing == nil else { return }
        let mark = checkState.begin(raw)
        checkTask = Task { await connect(to: raw, headers: headers, mark: mark) }
    }

    /// The address was changed during the check: cancel the check and release the
    /// form. Its response no longer arrives.
    ///
    /// If the field still shows the checked address, the check stays: "Last
    /// connected" sets the field and starts in the same step, and the field's change
    /// notification only arrives afterwards.
    func addressChanged(_ address: String) {
        guard let ongoing = checkState.ongoing, ongoing.address != address else { return }
        checkTask?.cancel()
        checkTask = nil
        checkState.discard()
        if phase == .connecting { phase = .disconnected }
        errorMessage = nil
    }

    /// `headers` come from "Advanced" on the sign-in page; empty for almost
    /// everyone, and then what is already stored for this address remains.
    ///
    /// **Every assignment after an `await` first asks the token.** A check that has
    /// been superseded touches neither phase nor message; otherwise its late error
    /// would reset the app to the address form although the next check had long led
    /// to sign-in.
    private func connect(to raw: String, headers: [OwnHeader], mark: CheckMark) async {
        defer { checkState.complete(mark) }
        errorMessage = nil
        phase = .connecting

        guard let url = Self.normalizeServerURL(raw) else {
            errorMessage = String(localized: "Die Adresse konnte nicht gelesen werden.")
            phase = .disconnected
            return
        }

        // First as guessed, then the other way around.
        //
        // Without a scheme, `https` is assumed for addresses outside the home network.
        // If a server without a certificate runs there, the first attempt fails at the
        // connection, not at a response. Exactly then, and only then, is a second
        // attempt over `http` worthwhile. With a response carrying an error code it
        // would be wrong: the server is there, it just says something else.
        if await connectWith(url, headers: headers, mark: mark) { return }
        guard checkState.applies(mark) else { return }

        // Keep the reason of the **first** attempt.
        //
        // Otherwise the fallback attempt overwrites it with its own, which is almost
        // always the wrong one: if `https` already fails at name resolution, `http`
        // fails the same way, but reports earlier that iOS blocks unencrypted
        // connections. The user then reads "set up https" although the server simply
        // could not be found.
        let realReason = errorMessage

        // **Not after every error.** If the name does not exist or the deadline
        // expired, `http` fails just the same, only twice as late.
        if raw.contains("://") == false,
           let firstOne = lastConnectionError,
           AddressCheck.fallbackPaysOff(to: firstOne),
           let alternate = AppModelURLNormalizer.reversed(url),
           await connectWith(alternate, headers: headers, mark: mark) { return }
        guard checkState.applies(mark) else { return }

        errorMessage = realReason
        phase = .disconnected
    }

    /// The raw error of the last attempt in ``connectWith(_:headers:mark:)``, for
    /// deciding whether the fallback attempt is worthwhile.
    @ObservationIgnored private var lastConnectionError: (any Error)?

    /// - Returns: `true` if the server answered. `false` with a superseded token,
    /// without touching anything.
    private func connectWith(_ url: URL, headers: [OwnHeader] = [], mark: CheckMark) async -> Bool {
        let c = JellyfinClient(baseURL: url, deviceID: Self.deviceID, deviceName: Self.deviceName)
        let before = OwnHeaders.registered(for: url)
        let new = OwnHeaders.cleaned(headers)
        if !new.isEmpty { OwnHeaders.setDown(new, for: url) }
        lastConnectionError = nil
        do {
            let info = try await c.checkReachability()
            guard checkState.applies(mark) else {
                if !new.isEmpty { OwnHeaders.setDown(before, for: url) }
                return false
            }
            // Store only now: for an address where nothing answers, nothing is left in
            // the keychain.
            if !new.isEmpty { ownHeadersSafe(new, for: url) }
            client = c
            serverName = info.serverName ?? url.host()
            serverVersion = info.version
            phase = .needsLogin(serverName: info.serverName ?? url.host() ?? "Server",
                                version: info.version ?? "?")
            serverRemember(address: url.host() ?? url.absoluteString,
                         name: info.serverName ?? url.host() ?? "Server",
                         version: info.version ?? "?")
            errorMessage = nil
            return true
        } catch {
            if !new.isEmpty { OwnHeaders.setDown(before, for: url) }
            guard checkState.applies(mark) else { return false }
            lastConnectionError = error
            errorMessage = connectionError(error, address: url)
            return false
        }
    }

    /// Connection errors presented so the cause is evident.
    ///
    /// The most common case with self-hosted servers is an unencrypted address
    /// outside the home network: iOS blocks it by itself, and the system's error
    /// message does not say so. Add the hint that makes the system error
    /// interpretable.
    ///
    /// **The case at hand is a false report by the system.** If the user denies the
    /// local network permission, URLSession reports "The Internet connection appears
    /// to be offline" although the network works fine and only this one permission
    /// is missing. Anyone reading that checks their Wi-Fi and finds nothing. So say
    /// it.
    ///
    /// The earlier hint ("set up https") is gone: since `NSAllowsArbitraryLoads` iOS
    /// no longer blocks http, and advice that is no longer true is worse than none.
    private func connectionError(_ error: any Error, address: URL) -> String {
        let text = readable(error)
        let inHomeNetwork = AppModelURLNormalizer.isHomeNetwork(address.host() ?? "")
        // Only for "offline", and only on the home network: outside, the same error
        // is simply a missing network, and the hint would be misleading.
        if inHomeNetwork, (error as? URLError)?.code == .notConnectedToInternet {
            return String(localized: "Der Server war nicht erreichbar. Hat Swiftly die Erlaubnis, Geräte im heimischen Netz zu suchen? Sie steht in den Systemeinstellungen unter „Swiftly · Lokales Netzwerk\".")
        }
        return text
    }

    /// What happens the same way after every successful sign-in, whether by
    /// password or Quick Connect.
    /// Takes a fresh session. Returns whether it was an **account switch**; then
    /// this function has already cleaned up and reloaded, and the caller must not
    /// load again.
    ///
    /// `signedInWith` is the client that was signed in on, if not the running one
    /// (``anmeldeclient()``). It is adopted only here, **after** the bundle, so
    /// `client.didSet` reaches downloads with the right account, and the group is
    /// still left with the previous account's identity.
    @discardableResult
    func sessionAdopt(_ s: Session, signedInWith newer: JellyfinClient? = nil) -> Bool {
        // **The rule lives in the package**, not here: the same server means add and
        // switch, another one means start from scratch. Both versions (this one and
        // GTK) had derived it themselves, and all cleanup hangs on this answer.
        let (newBundle, wasSignedIn) = AccountBundle.record(s, in: bundle)
        bundle = newBundle
        saveBundle()
        if let newer, newer !== client { client = newer }
        phase = .ready
        // **If the app was already signed in, this is an account switch.** The client
        // is already the new account's; everything else is missing. Without cleanup,
        // libraries and home page stay on the previous account, and queried with the
        // new identity the server does not return them. That is how "Sign-in rejected"
        // came about after a second account was added.
        if wasSignedIn { afterSwitch() }
        // Name and version are otherwise only available after a fresh connection;
        // settings then showed "Server · ?".
        Task { _ = await connectionCheck() }
        return wasSignedIn
    }

    /// What must be redone after every account switch, besides the client
    /// itself.
    private func afterSwitch() {
        // **Libraries are replaced, not cleared first.**
        //
        // This used to be `views = []`. It is the same mistake that already cost the
        // thumbnails, in another place: between clearing and the server's response the
        // sidebar stands empty and then rebuilds, which looks like a twitch of the
        // library list on the desktop and a jump on the phone.
        //
        // What remains belongs to the previous account for a fraction of a second. That
        // is tolerable: library IDs are valid server-wide, and `loadViews` replaces
        // them in one step once the response is in.
        //
        // **The trigger must come from here.** `HomeModel` only fetches
        // libraries if there are none; without clearing it would never reload, and the
        // previous account's list would stay.
        Task { await loadViews() }
        errorMessage = nil
        collectionTitleCache.removeAll()
        // The replacement for the header image hangs on the next episode, which is
        // different per account.
        headerImageFallback.removeAll()
        headerImageSearches.removeAll()
        accountSwitch += 1
        #if os(tvOS)
        Shelf.wipe()
        #endif
        // **The remote control belongs here, which is not obvious.** Otherwise it is
        // started only when the main view appears, but that stays put on a switch, and
        // the device would keep reporting to the server with the previous account's
        // identity.
        remoteControlNewStart()
    }

    /// The client on which a sign-in is to run.
    ///
    /// **Always a fresh one.** `authenticate` applies the client's identity to the
    /// client it runs on. If sign-in ran on the running client, the same instance
    /// stayed and `client.didSet` never fired: with "Add another account" the
    /// previous account's group was not left, and downloads stayed with the
    /// previous account (on first sign-in with no account). 
    /// ``sessionAdopt(_:signedInWith:)`` adopts it only once the sign-in
    /// worked.
    func loginClient() -> JellyfinClient? { client?.withoutAccount() }

    func login(username: String, password: String) async {
        guard let signInClient = loginClient() else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let s = try await signInClient.authenticate(username: username, password: password)
            // **Do not additionally load if it was a switch**, same reasoning as for
            // Quick Connect: `sessionAdopt` cleans up itself and triggers the reload,
            // and a second run alongside races with the first.
            //
            // This went unnoticed longer here than there: on TV, where the profile switch
            // was built first, "Add another account" leads to Quick Connect. Name and
            // password are the path on iPhone, iPad and desktop, i.e. exactly where four
            // platforms would have hit it. Found when reading through the code, not through
            // a failure.
            if !sessionAdopt(s, signedInWith: signInClient) { await loadViews() }
        } catch {
            errorMessage = readable(error)
        }
    }

    /// Quick Connect: authorize a code shown on another device.
    // MARK: - Additional server

    /// The server being added. **The running session stays as it is**:
    /// `connect(to:)` puts the whole app on the sign-in screen, and someone adding a
    /// second server in the middle should not land there and have to find their way
    /// back after cancelling. Only when sign-in works does the server join the
    /// bundle.
    @ObservationIgnored private var onboarding: JellyfinClient?
    @ObservationIgnored private var onboardingName: String?

    /// Checks an address and keeps the server ready: name and version, or `nil`
    /// with the reason in `errorMessage`.
    func serverCheck(_ raw: String, headers: [OwnHeader] = []) async -> (name: String, version: String)? {
        errorMessage = nil
        guard let url = Self.normalizeServerURL(raw) else {
            errorMessage = String(localized: "Die Adresse konnte nicht gelesen werden.")
            return nil
        }
        var candidates = [url]
        if !raw.contains("://"), let different = AppModelURLNormalizer.reversed(url) {
            candidates.append(different)
        }
        let new = OwnHeaders.cleaned(headers)
        var lastOne: (any Error)?
        for address in candidates {
            let c = JellyfinClient(baseURL: address, deviceID: Self.deviceID, deviceName: Self.deviceName)
            let before = OwnHeaders.registered(for: address)
            if !new.isEmpty { OwnHeaders.setDown(new, for: address) }
            let info: PublicSystemInfo
            do { info = try await c.checkReachability() } catch {
                lastOne = error
                if !new.isEmpty { OwnHeaders.setDown(before, for: address) }
                // No name, no answer within the deadline: `http` fails just the same, only
                // twice as late.
                if !AddressCheck.fallbackPaysOff(to: error) { break }
                continue
            }
            do {
                if !new.isEmpty { ownHeadersSafe(new, for: address) }
                onboarding = c
                let name = info.serverName ?? address.host() ?? String(localized: "Server")
                onboardingName = name
                return (name, info.version ?? "?")
            }
        }
        // A sign-in page in front is not a missing Jellyfin; the accompanying
        // sentence says what to do.
        if let j = lastOne as? JellyfinError, case let .transport(text) = j,
           text == OwnHeaders.loginPageText {
            errorMessage = text
            return nil
        }
        errorMessage = String(localized: "Unter dieser Adresse antwortet kein Jellyfin.")
        return nil
    }

    /// Signs in on the held server and adds it to the bundle. The app switches
    /// there, as when switching to another account.
    func signInAtNewServer(user: String, password: String) async -> Bool {
        guard let onboarding else { return false }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            serverRecord(try await onboarding.authenticate(username: user, password: password))
            return true
        } catch {
            errorMessage = readable(error)
            return false
        }
    }

    // **Quick Connect on the new server**: the same flow as the first sign-in
    // (`QuickConnectModel`), but with the held server instead of the one the app is
    // currently connected to.

    func quickConnectStartAtNewServer() async throws -> LoginCode {
        guard let onboarding else { throw JellyfinError.notAuthenticated }
        return try await onboarding.quickConnectStart()
    }

    func quickConnectAskAgainAtNewServer(_ preGait: LoginCode) async -> QuickConnectState {
        guard let onboarding else { return .failed }
        return await onboarding.quickConnectAskAgain(preGait)
    }

    func signInWithQuickConnectAtNewServer(_ preGait: LoginCode) async -> Bool {
        guard let onboarding else { return false }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            serverRecord(try await onboarding.signInWithQuickConnect(preGait))
            return true
        } catch {
            errorMessage = readable(error)
            return false
        }
    }

    /// The one completion for both paths: into the bundle, secure, switch.
    private func serverRecord(_ s: Session) {
        bundle = AccountBundle.record(s, in: bundle).bundle
        saveBundle()
        onboarding = nil
        newConnect()
        if let onboardingName { serverName = onboardingName }
    }

    func serverOnboardingCancel() {
        onboarding = nil
        onboardingName = nil
        errorMessage = nil
    }

    func quickConnectShare(code: String) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await client.quickConnectShare(code: code)
    }

    // MARK: Remote control

    /// The open socket connection over which commands arrive from the server.
    @ObservationIgnored private var far: RemoteControl?
    /// **Start and stop run in sequence, never side by side.**
    ///
    /// They are triggered from several places: the main view on appearing and
    /// disappearing, `signOut`, and the account switch. Each trigger was a task of
    /// its own, and between their `await`s they could overtake each other: one start
    /// saw `far == nil`, a second also, and two connections stood; or a stop ran
    /// before the previous account's start finished, and its connection stayed open.
    /// Each step now waits for the previous.
    @ObservationIgnored private var remoteChain: Task<Void, Never>?

    /// Appends a step to the chain and returns it.
    private func remoteInRails(_ step: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let before = remoteChain
        let task = Task { @MainActor in
            await before?.value
            await step()
        }
        remoteChain = task
        return task
    }
    /// Set by the player while it is on screen.
    @ObservationIgnored var remoteCommand: ((RemoteCommand) -> Void)?
    /// Set by whoever can watch together (so far only iPhone and iPad). Comes over
    /// the same channel as the remote commands.
    @ObservationIgnored var syncPlayPostDirection: ((SyncPlayPostDirection) -> Void)?
    /// **Who is taking over right now.** Arrives as a hint shortly before the stop
    /// (``JellyfinClient/handoffHint(an:geraet:)``). The player reads it at the
    /// stop: with a fresh hint the picture leaves as a card and flies out; without,
    /// it was a stop from the dashboard, and it closes as usual. The name appears
    /// only in the log.
    @ObservationIgnored var handoffTarget: (name: String, time: Date)?

    /// The name of the taking-over device if the last hint is fresh, and only
    /// once: the hint applies to exactly this stop.
    func handoffTargetTake() -> String? {
        guard let target = handoffTarget else { return nil }
        handoffTarget = nil
        return Takeover.isHandoff(hintPre: Date().timeIntervalSince(target.time)) ? target.name : nil
    }

    /// Report capabilities and listen.
    ///
    /// Both are needed for the dashboard to control the session: without the report
    /// its buttons stay gray, without the socket the commands never arrive.
    func remoteControlStart() async {
        await remoteInRails { [weak self] in await self?.remoteStart() }.value
    }

    func remoteControlEnd() async {
        await remoteInRails { [weak self] in await self?.remoteEnd() }.value
    }

    /// After an account switch: close the previous account's connection and open
    /// the new one, as **one** step so nothing interleaves.
    private func remoteControlNewStart() {
        _ = remoteInRails { [weak self] in
            await self?.remoteEnd()
            await self?.remoteStart()
        }
    }

    private func remoteStart() async {
        guard let client, far == nil else { return }
        do {
            try await client.reportCapabilities()
        } catch {
            AppLog.writeOut("[Uebernahme] Faehigkeiten nicht gemeldet: \(error)")
            Self.log.warning("Fähigkeiten nicht gemeldet: \(error.localizedDescription)")
        }
        guard let controls = try? await client.remoteControl() else { return }
        // Switched or signed out in the meantime: this connection belongs to an
        // account that no longer applies.
        guard self.client === client else {
            await controls.finish()
            return
        }
        far = controls
        await controls.syncPlayHear { [weak self] postDirection in
            Task { @MainActor in self?.syncPlayPostDirection?(postDirection) }
        }
        await controls.handoffHear { [weak self] name in
            Task { @MainActor in
                self?.handoffTarget = (name, Date())
                AppLog.writeOut("[Uebergabe] Hinweis: übernimmt \(name)")
            }
        }
        await controls.start { [weak self] command in
            Task { @MainActor in
                // What the command triggers is reported: pause and resume via
                // `runStateReported`, seeks via `jumpReported`. A separate report after
                // 400 ms from `PlayState` used to be here; after an episode change it went to
                // the old episode with the new position.
                self?.remoteCommand?(command)
            }
        }
    }

    private func remoteEnd() async {
        let old = far
        far = nil
        await old?.finish()
    }

    /// Libraries from the home page store, only while none from the server are
    /// there yet. `loadViews()` replaces them.
    func librariesPreOff(_ preOff: [Item]) {
        if views.isEmpty { views = preOff }
    }

    func loadViews() async {
        guard let client else { return }
        // **Applies only to the account that was asked about.** The cold-start store
        // triggers loading before anyone can switch accounts; if the previous account's
        // response arrived after the new one's, its libraries and download rights stood
        // under the new account.
        let account = accountSwitch
        func applies() -> Bool { account == accountSwitch && self.client === client }
        isWorking = true
        defer { isWorking = false }
        // On the side and without an error message: if nothing comes, it stays as it
        // was.
        Task {
            let guidelines = await client.accountDefaults()
            guard applies() else { return }
            nextAutomaticAccount = guidelines?.nextEpisodeAutomatic
            // Without an answer `.unknown`, hence allowed: a network error takes
            // nothing away from anyone. The hard barrier is held by
            // `JellyfinClient.downloadURL` anyway, which remembers the last known state.
            downloadPermission = guidelines?.downloadPermission ?? .unknown
            // Without an answer: allowed, so the quality choice stays in the player.
            convertAllowed = guidelines?.convertAllowed ?? true
            downloadQualitySelectable = guidelines?.downloadQualitySelectable ?? true
            AppLog.writeOut("[Konto] Nächste Folge automatisch: \(String(describing: nextAutomaticAccount)), Downloads: \(downloadPermission.rawValue)")
        }
        do {
            let new = try await client.userViews()
            guard applies() else { return }
            views = new
        } catch {
            guard applies() else { return }
            errorMessage = readable(error)
        }
    }

    /// Fetch a title fresh, mainly for the playback position.
    func item(id: String) async -> Item? {
        guard let client else { return nil }
        return try? await client.item(id: id)
    }

    /// The first trailer that exists as a file on the server.
    func trailer(toward item: Item) async -> Item? {
        guard let client else { return nil }
        return (try? await client.trailer(toward: item.id))?.first
    }

    /// Triggers the metadata refresh. The server continues in the background
    /// afterwards; the response only means "accepted".
    func metadataRefresh(_ item: Item) async -> String {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.metadataRefresh(item.id)
            return String(localized: "Der Server liest die Metadaten neu ein.")
        } catch {
            return readable(error)
        }
    }

    /// **`nil` means disturbed, `[]` means really nothing similar.**
    ///
    /// This used to be `(try? ...) ?? []`. A cancelled fetch then looked the same as
    /// a title without related items: the series page said "Nothing similar found"
    /// although it never reached the server. It is the same lie that had been fixed
    /// for search on its own; here it is gone at the root.
    func similar(_ item: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.similar(itemID: item.id, toward: item)
    }

    /// **`nil` means disturbed, `[]` means no extras.** See `similar`.
    func extras(_ item: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.extras(itemID: item.id)
    }

    /// **`nil` means disturbed, `[]` means nothing found.**
    ///
    /// This used to be `(try? ...) ?? []`, which turned every network error into an
    /// empty result list: search then said "Nothing on your server for this" although
    /// it never reached the server. An app that claims during network problems that
    /// the collection is empty loses trust faster than polish gains it.
    func search(_ term: String) async -> [Item]? {
        guard let client, term.count >= 2 else { return [] }
        return try? await client.search(term)
    }

    // MARK: - People and genres

    /// What the server has of a person: movies and series, newest first.
    ///
    /// **The rule lives in the package** (`JellyfinClient.title(person:)`), not
    /// here. It used to sit here and so did not reach Linux and Windows, which depend
    /// only on the package. There it now has tests too.
    /// **`nil` means disturbed, `[]` means: nothing by this person is stored.**
    func title(person id: String) async -> [Item]? {
        guard let client else { return nil }
        return await client.title(person: id)
    }

    /// Titles of a genre, most recently added first. `nil` if the server did not
    /// answer; then a row stays as it was.
    /// **The rule lives in the package** (`JellyfinClient.title(genre:)`) so Linux
    /// and Windows reach it.
    func title(genre: String, limit: Int = 24) async -> [Item]? {
        guard let client else { return nil }
        return await client.title(genre: genre, limit: limit)
    }

    /// One page of a genre **with the server's total count**, for the count badge
    /// and paging. `nil` means the server did not answer.
    func titleWithNumber(genre: String, limit: Int = AppModel.pagesSize,
                      startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        guard let client else { return nil }
        return await client.titleWithNumber(genre: genre, limit: limit, startIndex: startIndex)
    }

    /// One page of the filmography with the server's total count.
    func titleWithNumber(person id: String, limit: Int = AppModel.pagesSize,
                      startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        guard let client else { return nil }
        return await client.titleWithNumber(person: id, limit: limit, startIndex: startIndex)
    }

    /// **`nil` means disturbed, `[]` means: the server knows no genres.**
    ///
    /// The genre picker in settings stood empty on every network error, as if the
    /// server had no genres rather than having been silent.
    /// What is available as a home row of its own: the account's libraries and its
    /// collections, minus what is already chosen. The picker lacks the collections
    /// until the directory is fetched; that is awaited here.
    func startSelection() async -> [Item] {
        await offeringLoad()
        let applies = offeringFor == offeringKey
        let collections = applies ? (collectionDirectory?.all.map(\.item) ?? []) : []
        return StartLibraries.pick(
            libraries: views.filter { StartLibraries.selectable($0) },
            collections: collections, selected: startLibraries)
    }

    func genres() async -> [String]? {
        guard let client else { return nil }
        return try? await client.genres()
    }

    // MARK: - Kopfbild

    /// What a page header shows when there is no backdrop: searched once, then
    /// remembered.
    private(set) var headerImageFallback: [String: URL] = [:]
    @ObservationIgnored private var headerImageSearches: Set<String> = []

    /// **Always some image for a page header.**
    ///
    /// First what is really landscape (`ImageSelection.header`). If missing, the search
    /// continues in the background: for a series the still of the episode you would
    /// watch next (the first one otherwise, since any other might spoil what you
    /// have not seen), for everything else the poster. Cropped to landscape it does
    /// not look perfect, but something is there. Previously a series without a
    /// backdrop had an empty header.
    ///
    /// Answers immediately with what is already known; if the replacement arrives
    /// later, the pages redraw by themselves, since the model is observable.
    /// The same header image at a given width (in pixels), for the download that
    /// puts it on the device at screen resolution.
    func headerImageURL(for item: Item, width: Int) -> URL? {
        guard let images else { return nil }
        return ImageSelection.header(item, addresses: images, width: width)
    }

    /// Logo URL for the `TitleMark`; `nil` if the server has none.
    func logoURL(for item: Item) -> URL? {
        guard let images else { return nil }
        return ImageSelection.logo(item, addresses: images)
    }

    func headerImageURL(for item: Item) -> URL? {
        guard let images else { return nil }
        if let url = ImageSelection.header(item, addresses: images, width: 1200) { return url }
        if let substitute = headerImageFallback[item.id] { return substitute }
        guard !headerImageSearches.contains(item.id) else { return nil }
        headerImageSearches.insert(item.id)
        let account = accountSwitch
        Task { [weak self] in
            guard let self else { return }
            let (url, disrupted) = await self.headerImageFallbackSearch(for: item)
            // The previous account's response does not belong in the new account's store
            // (which was cleared on switch).
            guard account == self.accountSwitch else { return }
            // **Release again after a network drop.** Otherwise the mark stayed set and
            // this page never searched again until restart. If the title simply has no
            // image, it stays set, otherwise every redraw would ask again.
            if disrupted { self.headerImageSearches.remove(item.id) }
            guard let url else { return }
            self.headerImageFallback[item.id] = url
        }
        return nil
    }

    /// Only what is really landscape, without the search for a replacement. For
    /// the person page, whose banner cycles through the backdrops of their titles: a
    /// poster cropped to landscape does not belong in the rotation.
    func landscapeImageReal(for item: Item) -> URL? {
        guard let images else { return nil }
        return ImageSelection.header(item, addresses: images, width: 1200)
    }

    /// `disrupted`: none of the queries got through, so another attempt is
    /// worthwhile.
    private func headerImageFallbackSearch(for item: Item) async -> (URL?, disrupted: Bool) {
        guard let images else { return (nil, false) }
        var episode: Item?
        var disrupted = false
        if item.type == "Series", let client {
            var failures = 0
            do { episode = try await client.nextEpisodeSeries(seriesID: item.id) } catch { failures += 1 }
            if episode == nil {
                do { episode = try await client.episodes(seriesID: item.id).first } catch { failures += 1 }
            }
            disrupted = failures == 2
        }
        // Which image applies is decided in the package, the same rule as on
        // Android.
        return (ImageSelection.headerWithFallback(item, episode: episode, addresses: images), disrupted)
    }

    /// The one place where image URLs are built.
    ///
    /// Previously five nearly identical blocks did that, and two of them did not
    /// attach the access token, which only worked as long as the server returns
    /// images when not signed in.
    /// External subtitle files of a plan, with full URL; the player attaches them on
    /// opening. For downloads, those that came along when downloading.
    func subtitleFiles(_ plan: PlaybackPlan) -> [SubtitleFile] {
        if plan.url.isFileURL {
            return DownloadManager.subtitle(to: plan.url, attribute: VLCPlayerView.subtitleRememberTimes)
        }
        guard let session else { return [] }
        return SubtitleFile.from(streams: plan.source?.mediaStreams ?? [],
                                   server: session.serverURL, key: session.accessToken,
                                   attribute: VLCPlayerView.subtitleRememberTimes)
    }

    private var images: ImageAddress? {
        guard let session else { return nil }
        return ImageAddress(base: session.serverURL, token: session.accessToken)
    }

    /// A title's poster. **Without token**, since the caller does not always have
    /// one: Jellyfin returns the image anyway, and the token only serves the cache.
    /// 300 points tall: the row shows 96, and a poster that is loaded anyway should
    /// also be good enough on the iPad.
    func posterURL(itemID: String, mark: String? = nil) -> URL? {
        images?.construct(itemID: itemID, mark: mark, mass: .atMostHigh(300))
    }

    /// Portrait of a cast member.
    func personImage(_ person: Person, maxHeight: Int = 220) -> URL? {
        images?.construct(itemID: person.id, mark: person.primaryImageTag,
                      mass: .atMostHigh(maxHeight))
    }

    func setWatchlist(_ item: Item, an: Bool) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.setWatchlist(itemID: item.id, an: an)
            watchlistChanged += 1
            return nil
        }
        catch { return readable(error) }
    }

    /// **the expendable-titles rule and the missing-title rule get their information here.**
    ///
    /// Both rules depend on something only the server knows: whether a title has been
    /// watched, and whether it still exists at all. What follows from that is in
    /// ``Downloadverwaltung/nachziehen(vorhanden:gesehen:)``.
    ///
    /// **Nothing happens without an answer, and that is the normal case.** Downloads
    /// are built for on the road; on the road no server answers. If a failure
    /// counted as an answer, every title would say "no longer on the server",
    /// exactly where the feature is needed. If a part fails, everything stays as it
    /// was.
    func downloadsCatchUp() async {
        guard let client, !downloads.entries.isEmpty else { return }
        // **Report first, then read.** Otherwise the list hears the state from before
        // the flight from the server, and the checkmark of the episode watched offline
        // would vanish until the report is through.
        await pendingSubmit()
        let ids = downloads.entries.map(\.id)
        var available: Set<String> = []
        var watchState: [String: UserItemData] = [:]
        // A hundred IDs per request, the same measure the library pages page by. With
        // ten downloads it is one.
        for since in stride(from: 0, to: ids.count, by: 100) {
            let piece = Array(ids[since ..< min(since + 100, ids.count)])
            guard let answer = try? await client.items(limit: piece.count,
                                                        ids: piece) else { return }
            for title in answer.items {
                available.insert(title.id)
                watchState[title.id] = title.userData
            }
        }
        downloads.follow(available: available, watchState: watchState)
        downloads.sectionsCatchUp()
    }

    @discardableResult
    func setWatched(_ item: Item, an: Bool) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.setWatched(itemID: item.id, an: an)
            // **Here, not in the six views that call this.**
            //
            // The `SeriesCache` holds a series' episodes with watch state and does not
            // expire. The series page is assembled from it; the season view fetched fresh
            // and did not write back, so checking off a season and going back showed all
            // episodes open again. Having each view update individually would have meant the
            // seventh forgets it.
            //
            // For an episode and a season the series is affected, for a series itself.
            SeriesCache.shared.forget(item.seriesId ?? item.id)
            watchStateChanged += 1
            return nil
        } catch { return readable(error) }
    }

    /// Remove from "Continue Watching": position to zero, watched stays. Returns a
    /// readable reason if it fails.
    @discardableResult
    func fromContinueWatchingTake(_ item: Item) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.pointBackSet(itemID: item.id)
            SeriesCache.shared.forget(item.seriesId ?? item.id)
            watchStateChanged += 1
            return nil
        } catch { return readable(error) }
    }

    /// **`nil` means disturbed, `[]` means: the series has no seasons.**
    ///
    /// A series without seasons really exists (freshly created, nothing scanned
    /// yet). A silent server is something else, and the series page must be able to
    /// tell them apart.
    func seasons(_ series: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.seasons(seriesID: series.id)
    }

    /// **`nil` means disturbed, `[]` means: the season has no episodes.**
    func episodes(series: String, season: String?) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.episodes(seriesID: series, seasonID: season)
    }

    /// Where you are in this series, for the big button.
    /// **The rule lives in the package** (`JellyfinClient.stateInSeries(_:)`); it
    /// belongs to the next-episode rule and must give the same answer everywhere.
    func stateInSeries(_ series: Item) async -> Item? {
        guard let client else { return nil }
        return await client.stateInSeries(series.id)
    }

    /// Like `stateInSeries`, but a disturbance throws; `nil` means: no episodes.
    func stateInSeriesChecked(_ series: Item) async throws -> Item? {
        guard let client else { return nil }
        return try await client.stateInSeriesChecked(series.id)
    }

    /// The profile image from Jellyfin. If missing, the server answers 404 and the
    /// view falls back to the initial letter.
    /// **Always the same edge length, however large it is shown.**
    ///
    /// A size used to be an argument and callers used it: 120 in the header, 200 on
    /// the profile page, 240 in the account strip. Three sizes are **three URLs**,
    /// so three entries in the `ImageCache`, each fetched separately. That is why
    /// the profile image faded in anew every time the profile page opened, although
    /// the same face already stood in the bar above.
    ///
    /// 480 is the largest spot (240 points in the account strip, doubled for
    /// Retina). An avatar at that edge is a few kilobytes; fetched once it serves
    /// every spot, and `ImageCache` decodes it down to its own size anyway.
    static let userImageEdge = 480

    func userImageURL() -> URL? {
        guard let session else { return nil }
        return images?.user(session.userID, border: Self.userImageEdge)
    }

    /// The same for a specific account, for the strip where several stand side by
    /// side and only one is active.
    /// **From the account's server, with its access**, not the currently active one.
    /// Since multiple servers exist, the app asked the wrong server for the others'
    /// images, and they vanished until you switched to them.
    func userImageURL(for account: Session) -> URL? {
        ImageAddress(base: account.serverURL, token: account.accessToken)
            .user(account.userID, border: Self.userImageEdge)
    }

    /// Landscape image for the "Continue Watching" row.
    ///
    /// Deliberately from the parent title, not the episode: a still from the episode
    /// says little and looks arbitrary next to the other rows. The request was "a
    /// kind of cover".
    func landscapeImageURL(for item: Item, width: Int = 600) -> URL? {
        landscapeImage(for: item, width: width)?.url
    }

    /// **The chain now lives in the package**: `JellyfinKit.ImageSelection.landscape`.
    ///
    /// It used to be here, tying it to SwiftUI and making it unreachable for the
    /// Linux version. Nothing about it concerns UI or translation; the reasoning for
    /// each step lives there, including the measurement that an episode never has a
    /// backdrop of its own.
    private func landscapeImage(for item: Item, width: Int) -> (url: URL, source: String)? {
        guard let images else { return nil }
        return ImageSelection.landscape(item, addresses: images, width: width)
    }

    /// **An episode's image, landscape**, for the "Continue Here" card. `nil`
    /// without an image of its own.
    func episodeImageURL(for item: Item, width: Int = 1280) -> URL? {
        guard let mark = item.imageTags?["Primary"] else { return nil }
        return images?.construct(itemID: item.id, mark: mark, mass: .atMostWide(width))
    }

    /// The image for the lock screen and Control Center.
    ///
    /// **For episodes the episode's still, not the series poster.** The poster only
    /// says which series is playing, which is shown next to it as text anyway. The
    /// still shows *where* you are, which is the information that carries something
    /// there.
    ///
    /// Movies keep their poster: there is no still, and the poster *is* the title.
    func lockImageURL(for item: Item, height: Int = 600) -> URL? {
        if item.seriesId != nil, let mark = item.imageTags?["Primary"] {
            return images?.construct(itemID: item.id, mark: mark,
                                 mass: .atMostHigh(height))
        }
        return imageURL(for: item, maxHeight: height, portrait: true)
    }

    /// The running "Play shuffled" order, if there is one. It applies as long as the
    /// playing episode belongs to it; any other episode ends it.
    @ObservationIgnored private var shuffleRun: ShuffleRun?

    /// Mix all episodes of the series once and return the first one. `nil` if the
    /// series has no episodes or the server does not answer.
    func shuffleStart(_ series: Item) async -> Item? {
        guard let all = await episodes(series: series.id, season: nil), !all.isEmpty else { return nil }
        let run = ShuffleRun.mixed(all)
        shuffleRun = run
        return run.episodes.first
    }

    /// Starts a playlist: the entries in their order are the run, and "next episode"
    /// in the player walks along it, movies and episodes alike. Returns the first
    /// entry; `nil` for an empty list.
    func playlistStart(_ entries: [Item]) -> Item? {
        guard let first = entries.first else { return nil }
        shuffleRun = ShuffleRun(episodes: entries)
        return first
    }

    /// What a section shows of a playlist: movies in "Movies", episodes in "Series";
    /// without a section (search, watchlist) everything.
    static func playlistShown(_ entries: [Item], art: String?) -> [Item] {
        VideoPlaylist.shown(entries, art: art)
    }

    /// The entries of a playlist in the playlist's order. `nil` if the server did
    /// not answer.
    func playlistEntries(_ playlist: Item) async -> [Item]? {
        guard let client else { return nil }
        return try? await client.playlistEntries(playlist.id)
    }

    /// The episode after this one.
    func episodePost(_ item: Item) async -> Item? {
        // **A shuffled run goes along its order**, to its end ("nothing after that").
        if let run = shuffleRun {
            if run.contains(item.id) { return run.next(after: item.id) }
            shuffleRun = nil
        }
        // **Without a server, the next downloaded episode**; with a server as
        // before. The rule lives in the package (`DownloadRules.episodePost`).
        let client = self.client
        return await DownloadRules.episodePost(item, from: downloads.entries,
                                              withoutNetwork: downloads.noNetwork) {
            guard let client, let series = item.seriesId else { return nil }
            return try await client.episodePost(itemID: item.id, seriesID: series)
        }
    }

    /// Started titles.
    /// `nil` means the request failed. That differs from an empty list: with `try?`
    /// both looked the same, and a single dropout silently emptied the home page.
    func continueWatching() async -> [Item]? {
        guard let client else { return nil }
        return try? await client.resumeItems()
    }

    /// Next unwatched episodes of ongoing series.
    ///
    /// - Parameter ohne: titles already in "Continue Watching".
    /// Jellyfin lists started episodes in both queries; without filtering them out
    /// the same episode would appear twice on the home page.
    func nextEpisode(without alreadyShown: [Item] = []) async -> [Item]? {
        guard let client, let all = try? await client.nextUp() else { return nil }
        let alreadyPresent = Set(alreadyShown.map(\.id))
        return all.filter { !alreadyPresent.contains($0.id) }
    }

    /// Recently added across all libraries.
    /// New arrivals, one entry per series, newest first.
    ///
    /// Jellyfin's own grouping names only the series and the number of new episodes,
    /// not the season. So fetch ungrouped and group ourselves: the first episode per
    /// series is the newest, since the server already sorts by date.
    /// - Parameter in: only from this library. `nil` means from all.
    /// **The rule lives in the package** (`JellyfinClient.lastAdded`); it
    /// used to be here and did not reach Linux and Windows.
    func lastAdded(in library: String? = nil) async -> [Item]? {
        guard let client else { return nil }
        return await client.lastAdded(in: library)
    }

    /// One page from a library.
    ///
    /// Returns, besides the titles, how many there are in total; otherwise the view
    /// does not know when it may stop loading more. Previously the first two hundred
    /// were fetched blindly and the rest was unreachable through the UI.
    func items(in parentID: String,
               art: String? = nil,
               sorting: Sorting = .name,
               filter: LibraryFilter = .all,
               since startIndex: Int = 0,
               count: Int = AppModel.pagesSize) async -> (title: [Item], total: Int)? {
        await items(from: ShelfSource(parent: parentID, art: art), sorting: sorting,
                    filter: filter, since: startIndex, count: count)
    }

    /// One page from a library, from all, or from a collection; the differences
    /// are in ``ShelfSource``.
    func items(from source: ShelfSource,
               sorting: Sorting = .name,
               filter: LibraryFilter = .all,
               since startIndex: Int = 0,
               count: Int = AppModel.pagesSize) async -> (title: [Item], total: Int)? {
        guard let client else { return nil }
        // **"By name" is ordered here, not on the server** (``NaturalOrder``): the page is
        // a slice of the naturally sorted list, fetched by ID. The first page fetches the
        // list fresh, so titles added since show up.
        if sorting == .name {
            guard let list = await naturalList(from: source, filter: filter, fresh: startIndex == 0)
            else { return nil }
            do {
                let page = try await client.naturalPage(list, since: startIndex, count: count)
                return (page.items, page.totalRecordCount)
            } catch {
                Self.log.error("Bibliotheksabruf (Name) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        do {
            let answer = try await client.items(parentID: source.parent,
                                                 limit: count,
                                                 startIndex: startIndex,
                                                 sortBy: sorting.inputField,
                                                 sortOrder: source.bearing(sorting),
                                                 filters: filter.jellyfinFilter,
                                                 isWatched: filter.isWatched,
                                                 // Recursive once the type is set; otherwise the titles under the virtual
                                                 // folders stay unreachable.
                                                 recursive: source.recursive,
                                                 includeItemTypes: source.types)
            return (answer.items, answer.totalRecordCount)
        } catch {
            // Not into `errorMessage`: only the sign-in and server pages show that (and
            // it stayed there minutes later). The library page shows its own disturbance.
            Self.log.error("Bibliotheksabruf fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The naturally sorted lists (slim items), per source, filter and account. Not
    /// observed: a view never reads them, only the paging does.
    @ObservationIgnored private var naturalLists: [String: [Item]] = [:]

    /// **The whole list in "By name" order** (``NaturalOrder``), from one slim request:
    /// names only, no images. Reused for every later page, the letter strip and its jumps;
    /// `fresh` fetches it again.
    func naturalList(from source: ShelfSource, filter: LibraryFilter = .all,
                     fresh: Bool = false) async -> [Item]? {
        guard let client else { return nil }
        let key = "\(source.key)|\(filter.rawValue)|\(accountSwitch)"
        if !fresh, let cached = naturalLists[key] { return cached }
        do {
            let sorted = try await client.naturalList(parentID: source.parent,
                                                      sortOrder: source.bearing(.name),
                                                      filters: filter.jellyfinFilter,
                                                      isWatched: filter.isWatched,
                                                      recursive: source.recursive,
                                                      includeItemTypes: source.types)
            naturalLists[key] = sorted
            return sorted
        } catch {
            Self.log.error("Namensliste nicht geladen: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// **Name and sort name of the whole list, in "By name" order**, for the letter strip.
    func sortNames(from source: ShelfSource,
                   filter: LibraryFilter = .all) async -> [(name: String, sortName: String?)]? {
        await naturalList(from: source, filter: filter)?.map { ($0.name, $0.sortName) }
    }

    /// Everything bookmarked, **across all libraries**.
    ///
    /// Hence without `parentID`: the watchlist is not a library, its boundary is the
    /// bookmark and not a folder on disk. And hence **recursive**: otherwise
    /// Jellyfin returns only what lies at the very top, which is next to nothing on
    /// a server with virtual folders.
    ///
    /// `art` here is the page's type filter: `nil` means movies **and** series.
    /// Without the enumeration, seasons, episodes and collections would come along
    /// too, anything that ever had a bookmark.
    func remembered(art: String? = nil,
                  sorting: Sorting = .latest,
                  since startIndex: Int = 0,
                  count: Int = AppModel.pagesSize) async -> (title: [Item], total: Int)? {
        guard let client else { return nil }
        let genres = art.map { LibraryGenre.types(toward: $0) } ?? ["Movie", "Series"]
        do {
            // Once per work (``Items``): a movie from two libraries carries the bookmark
            // in both.
            let answer = try await client.rememberedItems(types: genres,
                                                         sortBy: sorting.inputField,
                                                         sortOrder: sorting.bearing,
                                                         startIndex: startIndex,
                                                         limit: count,
                                                         // The libraries are already there, which saves `UserViews` on every page.
                                                         libraries: views.isEmpty ? nil : views)
            return (answer.items, answer.totalRecordCount)
        } catch {
            // Not into `errorMessage`: only the sign-in and server pages show that (and
            // it stayed there minutes later). The library page shows its own disturbance.
            Self.log.error("Bibliotheksabruf fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Large enough that the first swipe does not reach the end, small enough that
    /// the first page appears quickly.
    static let pagesSize = 60

    // MARK: - Files whose index is useless





    /// Asks the server how it would deliver this title.
    ///
    /// `still`: an error lands only in the log, not as a message; for the background
    /// preparation (``EpisodePreparation``) nobody asked for.
    func plan(for itemID: String, still: Bool = false, sourceID: String? = nil) async -> PlaybackPlan? {
        // **if the file is here, the server is not needed.**
        //
        // Before the `guard`: without network `client` exists, but `playbackPlan` would
        // run into its deadline and return nothing. That is what downloading is for; a
        // loading screen that waits twenty seconds for a server that does not exist on
        // a plane would be the feature canceling itself out.
        //
        // The user notices nothing: no second button, no choice.
        if let file = downloads.file(for: itemID) {
            let p = downloads.entries(for: itemID)
            return .fromSlab(file, container: p?.container, mediaSourceID: p?.source,
                                 videoCodec: p?.videoCodec)
        }
        guard let client else { return nil }
        do {
            let plan = try await client.playbackPlan(for: itemID,
                                                       profile: .vlc(maxBitrate: profileBitrate),
                                                       mediaSourceID: sourceID)
            if plan == nil {
                // Occurs with series and seasons: they have no media file, only their
                // episodes do.
                Self.log.error("Kein Plan für \(itemID, privacy: .public) — Server nannte keine MediaSource")
            }
            return plan
        } catch {
            Self.log.error("PlaybackInfo fehlgeschlagen für \(itemID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !still { errorMessage = readable(error) }
            return nil
        }
    }

    /// Poster URL. Built here instead of in the client so views do not have to
    /// wait for the actor.
    func imageURL(for item: Item, maxHeight: Int = 480, portrait: Bool = false) -> URL? {
        guard let images else { return nil }
        // Portrait means, for an episode, the series poster. Why is in
        // `ImageSelection.portrait`; the same rule used to stand here a second time.
        if portrait {
            return ImageSelection.portrait(item, addresses: images, maxHeight: maxHeight)
        }
        guard let mark = item.imageTags?["Primary"] else { return nil }
        return images.construct(itemID: item.id, mark: mark,
                            mass: .atMostHigh(maxHeight))
    }

    /// Intro, recap and credits of an episode.
    ///
    /// Empty means the server knows nothing about them: no plugin, no analysis, or an
    /// older version. Then everything stays as before.
    func sections(for itemID: String) async -> [JellyfinKit.Segment] {
        // Those stored at download first; without network there are no others
        // (`DownloadRules.sections`).
        let client = self.client
        return await DownloadRules.sections(stored: downloads.entries(for: itemID)?.sections) {
            await client?.sections(for: itemID) ?? []
        }
    }

    /// Thumbnails while scrubbing; `nil` without trickplay on the server.
    func trickplay(for itemID: String, source: String?) async -> Trickplay? {
        guard let client else { return nil }
        return await client.trickplay(itemID: itemID, mediaSourceID: source)
    }

    /// The chapters of the running version; empty if the file has none or the
    /// server does not answer. Then the bar stays a single piece.
    func chapter(for itemID: String, source: String?) async -> [Chapter] {
        guard let client else { return [] }
        return await client.chapter(itemID: itemID, mediaSourceID: source)
    }

    func trickplaySheet(_ itemID: String, source: String?, width: Int, sheet: Int) async -> Data? {
        guard let client else { return nil }
        return await client.trickplaySheet(itemID: itemID, mediaSourceID: source,
                                           width: width, sheet: sheet)
    }

    // MARK: - Reporting playback
    //
    // If a report fails, that is no reason to disturb playback; so the error is only
    // noted here, not shown.

    /// What a report to the server needs. The client is captured when queued: if
    /// the account switches afterwards, the report still belongs to whoever
    /// watched.
    struct ReportContent: Sendable {
        let client: JellyfinClient?
        let item: Item
        let plan: PlaybackPlan
        let seconds: Double
        let tracks: TrackIndices
    }

    private enum ReportError: Error { case noServer }

    /// **Dispatched, not awaited.** The queue lives in the package
    /// (`ReportQueue`): order, coalescing, deadline and the stop lock per
    /// PlaySession. Here only what is sent.
    @ObservationIgnored private let messages = ReportQueue<ReportContent> { message in
        let content = message.payload
        guard let client = content.client else { throw ReportError.noServer }
        #if DEBUG
        // Measurement run: a server that does not answer (tvOS `-measurementRun`).
        if ProcessInfo.processInfo.arguments.contains("-meldungenHaengen") {
            try await Task.sleep(for: .seconds(30))
        }
        #endif
        let item = content.item, plan = content.plan
        let ticks = JellyfinClient.ticks(fromSeconds: content.seconds)
        switch message.art {
        case .start:
            try await AppModel.startSend(client: client, item: item, plan: plan, ticks: ticks,
                                           tracks: content.tracks)
            AppLog.writeOut("[Melden] Start \(Int(content.seconds)) s \(item.id) session \(plan.playSessionID ?? "nil")"
                + " Spuren \(content.tracks.audio.map(String.init) ?? "—")/\(content.tracks.subtitle.map(String.init) ?? "—")")
        case let .progress(paused):
            try await client.reportProgress(itemID: item.id, plan: plan,
                                            positionTicks: ticks, paused: paused, tracks: content.tracks)
            AppLog.writeOut("[Melden] Progress \(Int(content.seconds)) s pausiert \(paused) \(item.id)"
                + " Spuren \(content.tracks.audio.map(String.init) ?? "—")/\(content.tracks.subtitle.map(String.init) ?? "—")")
        case .stop:
            try await client.reportStopped(itemID: item.id, plan: plan, positionTicks: ticks)
        }
    }

    private func message(_ art: ReportQueue<ReportContent>.Art, item: Item,
                         plan: PlaybackPlan, seconds: Double) -> ReportQueue<ReportContent>.Message {
        .init(art: art,
              key: StopLock.key(itemID: item.id, playSessionID: plan.playSessionID),
              payload: ReportContent(client: client, item: item, plan: plan, seconds: seconds,
                                    tracks: runningTracks))
    }

    /// The tracks the player last reported, as Jellyfin index. They go out with
    /// start and progress; the player resets them on every open and anew after every
    /// choice.
    @ObservationIgnored private var runningTracks = TrackIndices()

    func tracksSelected(_ tracks: TrackIndices) {
        runningTracks = tracks
    }

    /// Returns immediately; sending happens in the queue.
    func reportStart(item: Item, plan: PlaybackPlan, seconds: Double) {
        // Also without a server: a title from disk plays again, and its next end
        // should be allowed to be reported; the queue releases the lock on enqueueing.
        runningTitle = (item, plan)
        reportedPaused = false
        StartMeasurement.shared.mark("Start an den Server")
        messages.report(message(.start, item: item, plan: plan, seconds: seconds))
        trakt.start(item: item, client: client, seconds: seconds)
    }

    private nonisolated static func startSend(client: JellyfinClient, item: Item,
                                                plan: PlaybackPlan, ticks: Int64,
                                                tracks: TrackIndices) async throws {
        // **Report capabilities again before every playback.**
        //
        // They used to be reported **once**, when the main view appeared. That is not
        // enough: handover stopped working on both devices at once, in both directions.
        //
        // The reason lies in how the server searches. `Sessions` is queried with
        // `controllableByUserId`, so only sessions that **accept commands** come back,
        // and the server knows that only through `Sessions/Capabilities/Full`. But a
        // session does not live forever there: server restart, timeout, a longer time in
        // the background, and it is gone. The next playback then creates a **new** one,
        // which never received the capabilities because that only happened at program
        // start. Both devices are then invisible to each other until someone restarts
        // the app. That also explains why it stopped "suddenly" and not gradually.
        //
        // The call is cheap, goes to the same peer that gets the start report right
        // after, and can be repeated any number of times. Here and nowhere else,
        // because this is the moment the other device must be able to see us.
        //
        // If it fails, the start still goes ahead, unless the deadline cancelled; then
        // the start is not due anymore either.
        do {
            try await client.reportCapabilities()
        } catch {
            try Task.checkCancellation()
            AppLog.writeOut("[Uebernahme] Faehigkeiten nicht gemeldet: \(error)")
        }
        try await client.reportStart(itemID: item.id, plan: plan, ticks: ticks, tracks: tracks)
    }

    /// What is playing right now, remembered so a remote command, a pause or a seek
    /// can be reported immediately without asking the player.
    ///
    /// **Follows the playback lifecycle:** set on start, cleared on stop. It used to
    /// be set only by progress and never reset, so a remote command shortly after a
    /// switch or close reported the new position to the old episode.
    @ObservationIgnored private var runningTitle: (item: Item, plan: PlaybackPlan)?
    /// What the server was last told as run state, so VLC's report goes out only
    /// once per change.
    @ObservationIgnored private var reportedPaused = false

    /// Returns immediately; sending happens in the queue. Discarded after this
    /// session's stop.
    func reportProgress(item: Item, plan: PlaybackPlan, seconds: Double, paused: Bool) {
        guard messages.report(message(.progress(paused: paused), item: item,
                                       plan: plan, seconds: seconds)) else {
            AppLog.writeOut("[Melden] Fortschritt nach Stopp verworfen \(item.id)")
            return
        }
        runningTitle = (item, plan)
        reportedPaused = paused
        // Watch time for "Support Swiftly": counted where progress is reported anyway,
        // local only, never sent. A paused player counts nothing.
        SupportModel.shared.playbackProgress(isPlaying: !paused)
    }

    /// **VLC paused or resumed: report immediately.**
    ///
    /// Hangs on `VLCPlayerView.runsReported`, not on the tap: the button waits for
    /// VLC, and reporting in the tap read the state from before (iOS reported pause
    /// as "playing"). Once here for all versions; before start and after stop there
    /// is no running title.
    func runStateReported(running: Bool, seconds: Double) {
        guard let runningTitle, reportedPaused == running else { return }
        AppLog.writeOut("[Melden] sofort: \(running ? "weiter" : "Pause") bei \(Int(seconds)) s")
        trakt.runState(running: running, seconds: seconds)
        reportProgress(item: runningTitle.item, plan: runningTitle.plan,
                       seconds: seconds, paused: !running)
    }

    /// **Seeked: report immediately**, with the target position. Hangs on
    /// `VLCPlayerView.jumpReported` so no seek path forgets it.
    func jumpReported(target: Double) {
        guard let runningTitle else { return }
        reportProgress(item: runningTitle.item, plan: runningTitle.plan,
                       seconds: max(0, target), paused: reportedPaused)
        trakt.leap(seconds: max(0, target))
    }

    /// **The app goes to the background:** report the state now, not at the next
    /// beat, which would never come while frozen.
    ///
    /// `beginBackgroundTask` keeps the app awake until the report is through or its
    /// deadline has passed.
    func backgroundReport(item: Item, plan: PlaybackPlan, seconds: Double, paused: Bool) {
        let entryRecord = message(.progress(paused: paused), item: item, plan: plan, seconds: seconds)
        guard messages.progressAllowed(entryRecord.key) else { return }
        AppLog.writeOut("[Melden] Hintergrund: \(Int(seconds)) s pausiert \(paused)")
        #if os(iOS) || os(tvOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Wiedergabe melden")
        Task {
            let result = await messages.reportAndWait(entryRecord)
            AppLog.writeOut("[Melden] Hintergrund: \(result)")
            UIApplication.shared.endBackgroundTask(task)
        }
        #else
        messages.report(entryRecord)
        #endif
        runningTitle = (item, plan)
        reportedPaused = paused
    }

    /// Counts a finished title and reports whether the rating prompt or the hint
    /// about the Discord is due next, at most one of them (``Gemeinschaft/anstoss``).
    func doneWatch(position: Double, duration: Double) {
        guard RatingQuestion.countsAsReady(position: position, duration: duration) else { return }
        let store = UserDefaults.standard
        let done = store.integer(forKey: "bewertungFertig") + 1
        store.set(done, forKey: "bewertungFertig")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #if os(tvOS)
        // tvOS has no review prompt; `requestReview` does not exist there.
        let ratingPossible = false
        #else
        let ratingPossible = true
        #endif
        switch Community.kickoff(done: done,
                                    ratingLast: store.string(forKey: "bewertungFassung"),
                                    version: version,
                                    discordShown: store.bool(forKey: "discordHinweisGezeigt"),
                                    ratingPossible: ratingPossible) {
        case .rating:
            store.set(version, forKey: "bewertungFassung")
            ratingDue = true
        case .discord:
            // Mark as shown right away: if the app crashes or is closed before, the hint
            // would rather never come than twice.
            store.set(true, forKey: "discordHinweisGezeigt")
            discordHintDue = true
        case nil:
            break
        }
    }

    /// The end, **awaited**, because the pages reload afterwards. The queue sends
    /// it behind a start that is still running; it does not arrive twice (stop lock in
    /// the queue).
    func reportStopped(item: Item, plan: PlaybackPlan, seconds: Double) async {
        let ticks = JellyfinClient.ticks(fromSeconds: seconds)
        // The current account, not the one after waiting: if it switches in between,
        // the position still belongs to whoever watched.
        let account = session?.userID
        // The remembered series state is stale from now on; see
        // `SeriesCache.stateForget`.
        if let series = item.seriesId { SeriesCache.shared.stateForget(series) }
        // With and without network: the download knows its own state.
        downloads.playbackRemember(item.id, ticks: ticks)
        // Also after a deferred report: the page should then at least show the state
        // of the last beat, not the one from before playing.
        //
        // **Only when the player is closed.** When switching to the next episode the old
        // one stops while the player stays open; if that counted, home page, movies,
        // series and detail pages behind the player reloaded. Closing then reports the
        // last episode.
        defer { if !playerOpen { playbackEnded += 1 } }
        SupportModel.shared.playbackStopped()
        let entryRecord = message(.stop, item: item, plan: plan, seconds: seconds)
        // Before awaiting: Trakt has its own queue and does not wait for Jellyfin, nor
        // Jellyfin for Trakt.
        trakt.stop(item: item, seconds: seconds)
        // Immediately, not after the response: a remote command in the meantime no
        // longer belongs to any title.
        if let runningTitle,
           StopLock.key(itemID: runningTitle.item.id,
                                  playSessionID: runningTitle.plan.playSessionID) == entryRecord.key {
            self.runningTitle = nil
        }
        let result = await messages.reportAndWait(entryRecord)
        switch result {
        case .sent:
            Self.log.info("Wiedergabe gemeldet: Ende bei \(Int(seconds)) s")
            AppLog.writeOut("[Melden] Stopped \(Int(seconds)) s \(item.id) session \(plan.playSessionID ?? "nil")")
            // An older position from the plane must not go out afterwards.
            if let account {
                pending = PostReportRules.overFetches(itemID: item.id, account: account, in: pending)
            }
        case .discarded:
            AppLog.writeOut("[Melden] Stopped doppelt verworfen \(item.id) session \(plan.playSessionID ?? "nil")")
        case .failed, .timeOverStep:
            // **This is where the information downloads exist for is created.**
            //
            // Whoever watches a title on a plane produces exactly one piece of information
            // nobody else has: where they stopped. If it were lost here, the server would
            // have the state from the start of the flight, and at home the episode would
            // start from the beginning. The offline rule, second half.
            Self.log.error("Ende-Meldung nicht durch (\(String(describing: result), privacy: .public)), wird nachgemeldet")
            AppLog.writeOut("[Melden] Stopped \(result) → Nachmeldung \(item.id)")
            reportLater(item.id, ticks, account: account)
        }
    }

    // MARK: what the server does not know yet

    private static let postReportKey = "nachmeldungen"

    private var pending: [PendingReport] {
        get {
            guard let raw = UserDefaults.standard.data(forKey: Self.postReportKey)
            else { return [] }
            return (try? JSONDecoder().decode([PendingReport].self, from: raw)) ?? []
        }
        set {
            guard let raw = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(raw, forKey: Self.postReportKey)
        }
    }

    #if DEBUG
    /// For the self-test (`OfflineRun`).
    var pendingReportsRun: [PendingReport] { pending }
    /// Slip in a report from earlier; checks "the newer state wins".
    func pendingReportUnderPush(_ itemID: String, ticks: Int64, moment: Date) {
        guard let account = session?.userID else { return }
        pending = PostReportRules.record(
            PendingReport(itemID: itemID, account: account, ticks: ticks, moment: moment), in: pending)
    }
    var runningTitleId: String? { runningTitle?.item.id }
    #endif

    private func reportLater(_ itemID: String, _ ticks: Int64, account: String?) {
        guard let account else { return }
        pending = PostReportRules.record(
            PendingReport(itemID: itemID, account: account, ticks: ticks),
            in: pending)
    }

    /// Send everything left over. Runs after every successful connection check,
    /// i.e. exactly when the server is demonstrably back, instead of guessing in a
    /// timer of its own, and before the downloads are brought up to date.
    ///
    /// **The package decides what applies** (`JellyfinClient.reportLater`): oldest
    /// first, a newer state on the server wins, on the first error the rest stays.
    /// **Never twice at once:** the check runs after connect, sign-in and account
    /// switch, and two passes side by side sent the same position twice.
    func pendingSubmit() async {
        guard !reportLaterRuns, let client, let account = session?.userID else { return }
        let opened = PostReportRules.due(pending, account: account)
        guard !opened.isEmpty else { return }
        reportLaterRuns = true
        defer { reportLaterRuns = false }
        let completed = await client.reportLater(opened) { AppLog.writeOut($0) }
        guard !completed.isEmpty else { return }
        pending = PostReportRules.completed(completed, in: pending)
        Self.log.info("\(completed.count) Stellen nachgemeldet")
    }

    @ObservationIgnored private var reportLaterRuns = false

    /// Switch to another account on the same server.
    ///
    /// **No new password.** Both tokens are in the keychain; the switch only changes
    /// which one applies. What must be rebuilt afterwards is in ``newConnect()``;
    /// it is more than you would think.
    func switchAccount(toward identifier: String) {
        // By account key: the same user ID can exist on two servers. A bare ID from
        // before still works.
        guard var new = bundle, let target = new.account(identifier),
              target.accountKey != new.activeOne.accountKey else { return }
        new.switchTo(toward: identifier)
        bundle = new
        saveBundle()
        newConnect()
    }

    /// Rebuilds everything that hangs on the signed-in account.
    ///
    /// **The remote control belongs here, which is not obvious.** Otherwise it is
    /// started only when the main view appears, but that stays put on an account
    /// switch, and the device would keep reporting to the server with the previous
    /// account's identity. On the iPhone the wrong playback would then have been
    /// offered for takeover.
    private func newConnect() {
        guard let s = session else { return }
        // Another server: until its response arrives, the address is shown instead of
        // the old name, not the previous server's name.
        if client?.baseURL.absoluteString.lowercased() != s.serverURL.absoluteString.lowercased() {
            serverName = s.serverURL.host()
            serverVersion = nil
        }
        // **Switching does not sign out.** `signOff()` sends `Sessions/Logout` to the
        // server and withdraws the token: right when signing out, disastrous when
        // switching, since the account being left would then be unusable and the way
        // back ends in "Sign-in rejected". The old client is simply dropped; the token
        // stays valid and sits in the keychain.
        let newer = JellyfinClient(baseURL: s.serverURL, deviceID: Self.deviceID,
                                   deviceName: Self.deviceName, session: s)
        client = newer
        phase = .ready
        afterSwitch()
        Task { _ = await connectionCheck() }
    }

    func signOut() {
        // The socket used to keep running, with an access token the user had just
        // wanted to get rid of. Since the remote control rebuilds itself after a drop,
        // it would have done so here too.
        let older = client
        // Enqueued immediately, not inside the task: otherwise the restart for the
        // next account (`newConnect` below) could end up in the chain before this
        // stop.
        let ended = remoteInRails { [weak self] in await self?.remoteEnd() }
        Task {
            await ended.value
            await older?.signOff()
        }
        // **Signing out affects only the active account.** If others remain, the app
        // switches to the next instead of falling back to the server sign-in; whoever
        // wants to leave the server entirely signs out each account individually. One
        // button, one meaning.
        if let account = session?.accountKey { HomeModel.storeDelete(account) }
        if let rest = bundle?.removed(bundle?.activeId ?? "") {
            bundle = rest
            saveBundle()
            newConnect()
            return
        }

        Keychain.delete(key: Self.accountsKey)
        Keychain.delete(key: Self.sessionKey)
        // Otherwise the Top Shelf keeps showing the previous account's titles.
        //
        // **Only on TV, hence wrapped in a condition.** A Top Shelf exists nowhere else:
        // `ShelfPreview.swift` lives in the tvOS app and its extension, in no other
        // target. Without the condition macOS fails at this line: there the shared files
        // are listed individually, while iOS takes `Sources/Shared` as a whole folder
        // and gets the file by accident. So a build on iOS proves nothing here.
        #if os(tvOS)
        Shelf.wipe()
        #endif
        bundle = nil
        client = nil
        views = []
        errorMessage = nil
        phase = .disconnected
    }

    // MARK: - Saving the session

    func saveBundle() {
        guard let bundle else { return }
        do {
            try Keychain.save(JSONEncoder().encode(bundle), key: Self.accountsKey)
            // Read back immediately: a write error that only shows at the next launch
            // needlessly costs a sign-in.
            guard Keychain.load(key: Self.accountsKey) != nil else {
                Self.log.error("Keychain: Sitzung geschrieben, aber nicht lesbar")
                errorMessage = String(localized: "Deine Anmeldung ließ sich nicht speichern. Beim nächsten Start musst du dich neu anmelden.")
                return
            }
            Self.log.info("Keychain: Sitzung gesichert")
        } catch {
            errorMessage = String(localized: "Deine Anmeldung ließ sich nicht speichern.")
        }
    }

    /// Reads the bundle and adopts a single session from the time before.
    ///
    /// **The adoption lives here and not in the package**, because only the state
    /// holder knows where something is stored. The old entry is not deleted: whoever
    /// starts an older version again should not suddenly be signed out.
    private func loadBundle() -> AccountBundle? {
        // **Only the state holder knows where the data lives; what it means is
        // defined in the package.** This separation was missing: the adoption of the
        // single session existed here and again in the GTK version, in two spellings.
        AccountBundle.outStore(bundle: Keychain.load(key: Self.accountsKey),
                             individual: Keychain.load(key: Self.sessionKey))
    }

    private func restoreSession() {
        guard let anew = loadBundle() else { return }
        bundle = anew
        let s = anew.activeOne
        let newer = JellyfinClient(baseURL: s.serverURL, deviceID: Self.deviceID,
                                   deviceName: Self.deviceName, session: s)
        client = newer
        phase = .ready
        Task {
            // Name and version are otherwise only available after a fresh connection;
            // settings then showed "Server · ?".
            //
            // **Both checks side by side.** `connectionCheck` waits for the queued
            // reports (deadline per request up to 20 s); a revoked token thus only led to
            // sign-out after that, and until then the home page showed "Server unreachable"
            // although the server answered.
            async let applies = newer.sessionAppliesStill()
            _ = await connectionCheck()

            // And check whether the token is still valid at all.
            //
            // Previously a keychain entry was enough to set `ready`. A revoked token then
            // led not to the sign-in screen but to "No contact with the server", and from
            // there the only way back is the profile menu.
            guard await applies else {
                // **Only if this account is still the active one.** The check can be slow;
                // someone who switched to another account in the meantime would otherwise be
                // signed out by its result: the new account instead of the revoked one.
                // `client` is created anew on every switch; if it is no longer this one, the
                // answer applies to nobody.
                guard client === newer else { return }
                let name = session?.userName
                signOut()
                // **After signing out an account can still be there.** Since there are
                // several, `signOut` switches to the next instead of falling back to the server
                // sign-in, and then "please sign in again" would simply be wrong: the user is
                // signed in, just with another account.
                if let proceed = session?.userName {
                    errorMessage = String(localized: "Die Anmeldung von \(name ?? "?") gilt nicht mehr. Jetzt angemeldet als \(proceed).")
                } else {
                    errorMessage = String(localized: "Die Anmeldung gilt nicht mehr. Bitte neu anmelden.")
                }
                return
            }
        }
    }

    /// Lives in JellyfinKit so it is testable without a simulator.
    static func normalizeServerURL(_ raw: String) -> URL? {
        AppModelURLNormalizer.normalize(raw)
    }
}

extension AppModel {
    /// **The path into playing an episode, once.**
    ///
    /// It stood character for character in `Shared/SeriesView.swift` and
    /// `tvOS/SeriesView.swift`, except for the assignment target. Exactly the kind
    /// that drifts apart: it is enough for one to change the message or add a check,
    /// and the platforms answer differently.
    ///
    /// Returns `nil` if the server delivers no plan. The message for that is in
    /// `episodeNotLoaded` so it, too, exists only once.
    func episodesRequest(_ episode: Item, since: Double) async -> PlayRequest? {
        guard let plan = await plan(for: episode.id) else { return nil }
        return PlayRequest(item: episode, plan: plan, startAt: since)
    }

    static var episodeNotLoaded: String {
        String(localized: "Die Folge konnte nicht geladen werden.")
    }
}

/// The fixed home page rows: can be turned on and off and reordered.
///
/// **New movies and new series are rows of their own** so they can be moved
/// individually: someone who wants series on top and movies at the bottom should
/// be able to. `newArrivals` is the shared row when "Split new additions" is
/// off.
// `StartRail` lives in the package (`StartRails.swift`): which row applies
// when is not a display question, and here it did not reach Linux and Windows.

/// Name and symbol of a row, **here and not in a view.**
///
/// They used to be in `PresentationView`, which exists only on iOS. The Mac
/// version needs the same words for the same rows; a second list would be
/// exactly the kind of copied function to avoid.
extension StartRail {
    var name: LocalizedStringKey {
        switch self {
        case .continueWatching: "Weiterschauen"
        case .nextEpisode: "Nächste Folge"
        case .newMovies:     "Neue Filme"
        case .newSeries:    "Neue Serien"
        case .newArrivals:   "Neu hinzugefügt"
        }
    }

    var symbol: String {
        switch self {
        case .continueWatching: "play.circle"
        case .nextEpisode: "forward.end"
        case .newMovies:     "film"
        case .newSeries:    "tv"
        case .newArrivals:   "sparkles"
        }
    }
}
