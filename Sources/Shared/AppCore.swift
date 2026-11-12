import Foundation
import JellyfinKit

#if canImport(SwiftlyCore)
import SwiftlyCore
import os

/// The core's name for a signed-in account (lets files that do not import `SwiftlyCore` name it).
typealias CoreAccount = SwiftlyCore.AccountRef

/// **The one place that creates the Rust core** and hands out its view models (`AppModel.core`).
///
/// Everything the core needs from the platform is wired here and nowhere else: the URLSession
/// HTTP client, the Keychain and UserDefaults stores, the device name and the log. Screens and models
/// never build a `SwiftlyCore.Core` themselves; they ask `AppCore` for the model of their screen
/// with the current session, so replacing one Swift logic call is a one-line change:
///
///     let model = try core.home(session: session, prefs: prefs)       // instead of HomePageLoader
///
/// The core picks the device profile itself (`DeviceProfile::vlc` in `swiftly-vm`); the app only
/// passes the device name and id. A session the core cannot serve yet (Plex, none) gives `nil` /
/// `CoreError.unsupported`, and the caller keeps its Swift path for as long as the old path exists.
///
/// Models are made per account and screen and kept by their owner (the page model), not here, so a
/// dropped screen drops its model. The factory methods are cheap.
@MainActor
final class AppCore {
    /// One core per process: runtime, HTTP client and stores are shared by every model.
    static let shared = AppCore()

    /// The raw core. Prefer the factory methods below.
    let raw: SwiftlyCore.Core

    /// The core's store (the app's UserDefaults under the old keys). Code that still reads a key the core
    /// also writes (the unsent play reports) goes through it, so it sees a write that is still on its way.
    let store = UserDefaultsKeyValueStore()

    /// Language code of the UI (`de`, `en`, `ru`), as the core's wording tables expect it.
    nonisolated static var language: String {
        Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
    }

    /// Why a model could not be made.
    enum Unavailable: Error {
        /// No session, or a server kind the core does not serve yet (Plex).
        case account
    }

    /// The stores are the app's own: same Keychain service and UserDefaults keys as the Swift code
    ///.
    private init() {
        let platform = AppPlatform(name: AppModel.deviceName)
        raw = SwiftlyCore.Core(
            platform: platform, secrets: KeychainSecretStore(),
            store: store,
            // The user's own gateway headers go to the own server, like every other request of the app.
            http: URLSessionHttpClient(prepare: { $0.ownHeadersSet() }, observe: Self.observer))
        // Track and file lines name languages in the device's language, as `TrackLabel.language` always did.
        // The server's device list shows the app's own version, as the Swift clients always sent it.
        raw.setClientVersion(version: VersionNumber.outBundle)
        raw.setLanguageNames(names: platform)
        #if os(tvOS)
        // The TV's tiles are larger than a phone's: posters 600 high, wide pictures 900, what its tiles always asked for.
        raw.setTileImageSizes(posterHeight: 600, backdropWidth: 900)
        #endif
    }

    #if os(iOS) && (DEBUG || SWIFTLY_SHADOW)
    private static let observer: (@Sendable (URL, Data) -> Void)? = { ShadowHome.raw($0, $1) }
    #else
    private static let observer: (@Sendable (URL, Data) -> Void)? = nil
    #endif

    // MARK: Account

    /// The account the core works with, or `nil` (no session, Plex).
    func account(_ session: Session?) -> SwiftlyCore.AccountRef? {
        session.flatMap { SwiftlyCore.AccountRef($0) }
    }

    private func required(_ session: Session?) throws -> SwiftlyCore.AccountRef {
        guard let account = account(session) else { throw Unavailable.account }
        return account
    }

    // MARK: Screens (one model each; the page keeps it)

    func home(session: Session?, prefs: HomePrefs) throws -> SwiftlyCore.HomeModel {
        SwiftlyCore.HomeModel(
            vm: try raw.homeVmWith(account: try required(session), locale: Self.language, prefs: prefs))
    }

    func library(session: Session?, spec: SwiftlyCore.LibrarySpec) throws -> SwiftlyCore.LibraryModel {
        SwiftlyCore.LibraryModel(
            vm: try raw.libraryVm(account: try required(session), locale: Self.language, spec: spec))
    }

    func search(session: Session?) throws -> SwiftlyCore.SearchModel {
        SwiftlyCore.SearchModel(vm: try raw.searchVm(account: try required(session), locale: Self.language))
    }

    func detail(session: Session?, tile: SwiftlyCore.Tile) throws -> SwiftlyCore.DetailModel {
        SwiftlyCore.DetailModel(
            vm: try raw.detailVm(account: try required(session), locale: Self.language, tile: tile))
    }

    func series(session: Session?, tile: SwiftlyCore.Tile, spec: SwiftlyCore.SeriesSpec) throws
        -> SwiftlyCore.SeriesModel
    {
        SwiftlyCore.SeriesModel(
            vm: try raw.seriesVm(account: try required(session), locale: Self.language, tile: tile, spec: spec))
    }

    /// The person page of a cast entry; `origin` is the title the tap came from.
    func person(session: Session?, person: Person, origin: String?) throws -> SwiftlyCore.PersonController {
        let info = SwiftlyCore.PersonInfo(
            id: person.id, name: person.name, role: person.role, kind: person.type, imageTag: person.primaryImageTag)
        return SwiftlyCore.PersonController(
            model: try raw.personModel(
                account: try required(session), locale: Self.language, person: info, origin: origin))
    }

    /// A video playlist page; `art` is the section (`Movie`/`Series`) or `nil` for everything.
    func playlist(session: Session?, playlist: Item, art: String?) throws -> SwiftlyCore.PlaylistController {
        SwiftlyCore.PlaylistController(
            model: try raw.playlistModel(
                account: try required(session), locale: Self.language,
                playlist: SwiftlyCore.Tile(standIn: playlist), art: art))
    }

    /// Saved accounts and every way to add one (sign-in, Quick Connect, extra server, switch/remove, Plex),
    /// over the same Keychain entries as `ServerBundles` (`konten`, `konten.emby`, `konten.plex`).
    func accounts() throws -> SwiftlyCore.AccountsModel {
        try raw.accountsModel(deviceId: AppModel.deviceID, locale: Self.language)
    }

    /// The report queue of the player screens for the signed-in account (`AppModel.reportStart/Progress/Stopped`).
    func playReporter(session: Session) throws -> SwiftlyCore.PlayReporter {
        try raw.playReporter(
            account: try required(session), locale: Self.language, accountKey: session.storageAccount)
    }

    /// The player of a server title over the app's own report queue (`CorePlaybackBackend`).
    func playerShared(
        session: Session, start: SwiftlyCore.PlayerStart, prefs: SwiftlyCore.PlayerPrefs,
        engine: SwiftlyCore.PlayerEngine, reporter: SwiftlyCore.PlayReporter
    ) throws -> SwiftlyCore.PlayerModel {
        SwiftlyCore.PlayerModel(
            vm: try raw.playerVmShared(
                account: try required(session), accountKey: session.storageAccount, locale: Self.language,
                start: start, prefs: prefs, engine: engine, reporter: reporter))
    }

    func player(
        session: Session?, start: SwiftlyCore.PlayerStart, prefs: SwiftlyCore.PlayerPrefs,
        engine: SwiftlyCore.PlayerEngine
    ) throws -> SwiftlyCore.PlayerModel {
        // The key the app files unsent stops under (`storageAccount`), so `pendingSubmit` finds them.
        SwiftlyCore.PlayerModel(
            vm: try raw.playerVmKeyed(
                account: try required(session), accountKey: session?.storageAccount ?? "",
                locale: Self.language, start: start, prefs: prefs, engine: engine))
    }

    /// Settings read and write the `@AppStorage` keys themselves (`UserDefaultsSettingsStore` over
    /// `UserDefaults.standard`), so the screens and the core always agree.
    func settings(facts: SwiftlyCore.SettingsFacts) -> SwiftlyCore.SettingsModel {
        SwiftlyCore.SettingsModel(
            vm: raw.settingsVmNative(store: UserDefaultsSettingsStore(), locale: Self.language, facts: facts))
    }

    func downloads(host: SwiftlyCore.DownloadHost, onlyOverWlan: Bool, nextAuto: Bool) -> SwiftlyCore.DownloadsModel {
        SwiftlyCore.DownloadsModel(
            vm: raw.downloadsVm(host: host, locale: Self.language, onlyOverWlan: onlyOverWlan, nextAuto: nextAuto))
    }
}

/// The host side the core asks for: a device name and a log.
final class AppPlatform: SwiftlyCore.Platform, SwiftlyCore.LanguageNames {
    private let logger = Logger(subsystem: "de.paulherter.swiftly", category: "rust-kern")
    private let name: String

    /// The folder for disposable files is `CorePlatform`'s (`Caches/de.paulherter.swiftly/core`).
    private let folders = SwiftlyCore.CorePlatform(deviceName: "")

    init(name: String) { self.name = name }

    func cacheDir() -> String? { folders.cacheDir() }

    func deviceName() -> String { name }
    func log(line: String) { logger.info("\(line, privacy: .public)") }

    // MARK: Language names (`LanguageNames`)

    /// **The system's name of a language in the interface language**, what `TrackLabel.language` always asked
    /// (`Locale.localizedString(forLanguageCode:)`): an English app says "German", a German one "Deutsch".
    func languageName(code: String, language: String) -> String? {
        Locale(identifier: language).localizedString(forLanguageCode: code)
    }

    /// Whether the system knows the code at all (the English probe of `TrackLabel.code(of:)`).
    func knowsLanguage(code: String) -> Bool {
        Locale(identifier: "en").localizedString(forLanguageCode: code) != nil
    }
}

#if os(iOS) && (DEBUG || SWIFTLY_SHADOW)
/// **Shadow comparison of the home page (temporary, on in `Werkzeuge/to-iphone.sh` builds and Debug).**
/// After each core load the old Swift `HomeLoader` runs once against the same server, its result is NOT
/// shown, and one log line per rail says what each side has (count, ids, first titles, what only one side
/// has). `raw` logs the server's own `Resume` / `NextUp` answers as the core's HTTP client received them.
/// Read it with `Werkzeuge/fetch-log.sh` (lines start with `Schatten`). Remove together with the old
/// Swift home loading.
enum ShadowHome {
    private static func label(_ item: Item) -> String {
        var text = item.name
        if let series = item.seriesName {
            let season = item.parentIndexNumber.map { "S\($0)" } ?? ""
            let episode = item.indexNumber.map { "E\($0)" } ?? ""
            text = "\(series) \(season)\(episode) \(item.name)"
        }
        return "\(item.type ?? "?"):\(text)"
    }

    private static func short(_ ids: [String]) -> String { ids.map { String($0.prefix(6)) }.joined(separator: ",") }

    @MainActor static func run(_ model: AppModel, rust: [(rail: String, items: [Item])]) async {
        guard let client = model.client else { return }
        let old = await HomeLoader.load(
            from: client,
            .init(
                disconnected: model.newAccessDisconnected,
                filmLibrary: model.startLibrary(art: "movies")?.id,
                seriesLibrary: model.startLibrary(art: "tvshows")?.id,
                genres: nil, untilFromContinueWatching: []))
        let swift: [String: [Item]?] = [
            "continueWatching": old.continueWatching, "nextEpisode": old.nextEpisode, "recent": old.recent,
            "newMovies": old.newMovies, "newSeries": old.newSeries,
        ]
        for (rail, rustItems) in rust {
            guard let entry = swift[rail] else { continue }
            guard let swiftItems = entry else {
                AppLog.writeOut("Schatten Startseite [\(rail)] swift=kam nicht durch rust=\(rustItems.count)")
                continue
            }
            let swiftIDs = Set(swiftItems.map(\.id))
            let rustIDs = Set(rustItems.map(\.id))
            let onlyRust = rustItems.filter { !swiftIDs.contains($0.id) }
            let onlySwift = swiftItems.filter { !rustIDs.contains($0.id) }
            AppLog.writeOut(
                "Schatten Startseite [\(rail)] swift=\(swiftItems.count) rust=\(rustItems.count) "
                    + "nurRust=\(onlyRust.count) nurSwift=\(onlySwift.count) "
                    + "| swift5=\(swiftItems.prefix(5).map(label)) | rust5=\(rustItems.prefix(5).map(label)) "
                    + "| nurRust5=\(onlyRust.prefix(5).map(label)) | nurSwift5=\(onlySwift.prefix(5).map(label)) "
                    + "| idsSwift=\(short(swiftItems.map(\.id))) | idsRust=\(short(rustItems.map(\.id)))")
        }
    }

    /// The server's answer to `Resume` / `NextUp` as the core received it.
    static func raw(_ url: URL, _ body: Data) {
        let path = url.path.lowercased()
        guard path.hasSuffix("/resume") || path.hasSuffix("/nextup") else { return }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let items = object["Items"] as? [[String: Any]]
        else {
            AppLog.writeOut("Schatten Rohantwort \(url.path) nicht lesbar (\(body.count) Bytes)")
            return
        }
        let series = Set(items.compactMap { $0["SeriesId"] as? String ?? ($0["Type"] as? String == "Series" ? $0["Id"] as? String : nil) })
        let first = items.prefix(5).map { item -> String in
            let name = (item["SeriesName"] as? String).map { "\($0) / " } ?? ""
            let percent = ((item["UserData"] as? [String: Any])?["PlayedPercentage"] as? Double).map { String(Int($0)) } ?? "-"
            return "\(item["Type"] as? String ?? "?"):\(name)\(item["Name"] as? String ?? "?") \(percent)%"
        }
        let query = (url.query ?? "").prefix(240)
        AppLog.writeOut(
            "Schatten Rohantwort \(url.path) items=\(items.count) gesamt=\(object["TotalRecordCount"] ?? "-") "
                + "serien=\(series.count) | erste5=\(first) | query=\(query)")
    }
}
#endif

#endif
