import Foundation
import JellyfinKit
import Observation

/// What the home page shows and how it loads it - for both platforms.
///
/// Used to exist twice, nearly identical, in `HomeView`: once iPhone, once
/// TV. "Nearly" is the danger - if one side changes the order or fallback
/// behaviour, the other does not notice. So loading lives here and the views
/// only display.
@MainActor
@Observable
final class HomeModel {
    private(set) var continueWatching: [Item] = []
    private(set) var nextEpisode: [Item] = []
    private(set) var recent: [Item] = []
    /// Only filled when `AppModel.newAccessDisconnected` is on.
    ///
    /// **Separate instead of additional.** When the setting is on, this pair
    /// replaces the `recent` row; when off it stays empty and nothing is fetched
    /// for it. So the setting costs nothing while unused - and tvOS and macOS,
    /// which share this model, notice nothing.
    private(set) var newMovies: [Item] = []
    private(set) var newSeries: [Item] = []
    /// The chosen genres as their own rows - only when there are no chips.
    private(set) var genreRails: [GenreRail] = []

    /// The chosen libraries and collections as their own rows. Shown in the
    /// order of the choice (`libraryRails(fuer:)`), not of the fetch.
    private(set) var libraryRails: [Home.LibraryRail] = []

    /// The rows for the **current** choice: what is no longer chosen drops out
    /// at once, even if the next fetch is still running.
    func libraryRails(for choice: [StartLibrary]) -> [Home.LibraryRail] {
        let je = Dictionary(libraryRails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return choice.compactMap { je[$0.id] }
    }

    struct GenreRail: Identifiable {
        let name: String
        let items: [Item]
        var id: String { name }
    }
    private(set) var loaded = false
    /// None of the three calls got through - so it is the server, not an
    /// empty library.
    private(set) var disrupted = false

    /// When last fetched. Basis for `Refresh`.
    ///
    /// **Set only on success.** A load attempt where nothing arrived does not
    /// make the rows fresh - otherwise after a server outage the data counts as
    /// current for half a minute though it is unchanged and old.
    private(set) var lastLoaded: Date?

    /// **How many runs are in flight.** Only for
    /// ``needsRefresh``: while one runs, nothing is due.
    private var runningRuns = 0

    /// Which account state the content belongs to.
    private var forAccount = 0
    /// Counts every load run. **Only the latest writes.** Triggers come from
    /// several places - account switch, setting, return from the player,
    /// pull to refresh - and runs overtake each other: an older one arriving later
    /// would overwrite the newer state, after an account switch even with the
    /// previous account's.
    private var run = 0

    /// **Genre rows count too.** Someone who hides all fixed rows and shows only
    /// genres has a full home page - without this line the empty state would
    /// appear on top.
    var allEmpty: Bool {
        continueWatching.isEmpty && nextEpisode.isEmpty
            && recent.isEmpty && newMovies.isEmpty && newSeries.isEmpty
            && genreRails.allSatisfy { $0.items.isEmpty }
            && libraryRails.isEmpty
    }

    /// The state belongs to a previous account - the home page was not in the
    /// tree during the switch and did not notice.
    func outdated(_ model: AppModel) -> Bool { forAccount != model.accountSwitch }

    func load(_ model: AppModel) async {
        let itAccount = model.accountSwitch
        runningRuns += 1
        defer { runningRuns -= 1 }
        run += 1
        let myOwn = run
        /// After every `await`: does this run still apply?
        func applies() -> Bool { myOwn == run && itAccount == model.accountSwitch }
        // **Empty immediately after an account switch**, not only when the answer
        // arrives. Until then the previous account's home page sat under the new
        // profile image and then changed row by row. Now the placeholders show and
        // the new account fades in in one go (see below).
        if itAccount != forAccount, loaded || !allEmpty { wipe() }
        // **First the last-time state, then the server** - see
        // `HomeStore`. Only while nothing is shown yet: on refresh the old
        // state stays until the new one arrives anyway.
        if !loaded, allEmpty, let account = model.session?.accountKey,
           let store = await Self.storeRead(account) {
            guard applies() else { return }
            if allEmpty { previewShow(store, model: model) }
            forAccount = itAccount
        }
        if model.views.isEmpty {
            await model.loadViews()
        } else if !loadedServer {
            // The libraries came from storage: fetch fresh, but do not wait for it -
            // the rows only need their IDs.
            Task { await model.loadViews() }
        }
        guard applies() else { return }
        // Without a client nothing arrived - as before, when the helpers returned `nil`.
        guard let client = model.client else {
            disrupted = !Task.isCancelled
            loaded = true
            return
        }
        let disconnected = model.newAccessDisconnected

        // **The genre rows run alongside, not afterwards.**
        //
        // Their fetch used to be at the end of this function and only started once
        // the fixed rows were already there - so **after** a full network round trip.
        // On the device: you scroll down, nothing is there, and eventually the last
        // category appears all at once.
        //
        // The idea behind it was right - the fixed rows should appear first - but
        // "show first" is not the same as "fetch first". `async let` starts the fetch
        // immediately and is only collected below: the fixed rows appear first as
        // before, but the genres arrive a round trip earlier.
        async let genres = model.genreChips ? [] :
            HomeLoader.genreRails(from: client, names: model.startGenres)
                .map { GenreRail(name: $0.name, items: $0.items) }

        // **The library rows run alongside likewise**, all at once and at most once
        // per run. A library that no longer exists or does not belong to the profile
        // returns nothing and silently drops out.
        let choice = model.startLibraries
        async let libraryState: [Home.LibraryRail] = choice.isEmpty ? [] :
            HomeLoader.libraryRails(from: client, choice: choice)

        // **The rule lives in the package** (`HomeLoader`), shared with
        // Linux/Windows and Android. Here only the transfer into state - with the same
        // distinction as before: if a fetch did not get through, the old state stays,
        // except after an account switch.
        let state = await HomeLoader.load(from: client, .init(
            disconnected: disconnected,
            filmLibrary: model.selectedLibrary(art: "movies")?.id,
            seriesLibrary: model.selectedLibrary(art: "tvshows")?.id,
            genres: nil,
            untilFromContinueWatching: continueWatching))
        guard applies() else { return }
        // **Cancelled does not mean "server silent".** Otherwise all fetches would
        // count as `nil`: `loaded = true`, empty rows and "Nothing here yet" until
        // the `task` restart completes.
        guard !Task.isCancelled else { return }
        // **On first appearance, everything in one go.** If nothing is shown yet -
        // first launch or fresh after an account switch - the page also waits for the
        // genres instead of pushing them under the fixed rows a moment later. They run
        // alongside anyway (above); when refreshing a standing page they still arrive later.
        let firstMal = !loaded
        let preOff: [GenreRail]? = firstMal ? await genres : nil
        let preOffLibraries: [Home.LibraryRail]? = firstMal ? await libraryState : nil
        guard applies() else { return }
        let change = itAccount != forAccount
        forAccount = itAccount
        func adopt(_ new: [Item]?, _ alt: [Item]) -> [Item] {
            new ?? (change ? [] : alt)
        }
        continueWatching = adopt(state.continueWatching, continueWatching)
        nextEpisode = adopt(state.nextEpisode, nextEpisode)
        if disconnected {
            recent = []
            newMovies = adopt(state.newMovies, newMovies)
            newSeries = adopt(state.newSeries, newSeries)
        } else {
            newMovies = []
            newSeries = []
            recent = adopt(state.recent, recent)
        }
        disrupted = !Task.isCancelled && state.disrupted
        // If only one of the fixed fetches did not get through, the old state stays
        // - and does not count as fresh: the next return fetches again instead of
        // keeping the stale row past the deadline.
        let partFailure = state.continueWatching == nil || state.nextEpisode == nil
        if !disrupted, !partFailure { lastLoaded = Date() }
        loaded = true
        // **And the old state stays until the new one is there.**
        //
        // Refreshing used to clear the list and then refill it - the rows vanished
        // and returned every time you scrolled up and down again. This is the same
        // distinction `adopt` makes for all other rows: an empty result after an
        // account switch means empty, otherwise it means "the fetch did not get through".
        if let preOff {
            genreRails = preOff
        } else {
            let freshOnes = await genres
            guard applies() else { return }
            if !freshOnes.isEmpty || change || model.genreChips { genreRails = freshOnes }
        }
        if let preOffLibraries {
            libraryRails = preOffLibraries
        } else {
            let freshOnes = await libraryState
            guard applies() else { return }
            if !freshOnes.isEmpty || change || choice.isEmpty { libraryRails = freshOnes }
        }
        // **Not on TV.** Prefetching fills the cache that
        // `SeriesCache.series(fuer:with:)` reads - and only iPhone, iPad and Mac do
        // that, on the way from an episode to its series. tvOS goes via
        // `SeriesCache.state` and `Item.preCommonSeries`. Measured in the tvOS
        // simulator: 18 individual `Items/<id>` requests at the same time as the
        // first posters, whose result nobody read.
        if !disrupted {
            loadedServer = true
            if let account = model.session?.accountKey { storeWrite(account, model: model) }
            // Collections and shares of mixed libraries up front - otherwise the detail
            // page shows its collection row only after two more fetches.
            Task { await model.offeringLoad() }
        }
        #if !os(tvOS)
        SeriesCache.shared.prefetch(
            continueWatching + nextEpisode + recent + newSeries, with: model)
        #else
        // **Where to continue is already in these rows** - the episode in "Next
        // up" and "Continue watching" is the server's. The series page's main button
        // can name it immediately. Continue watching last: a started episode wins.
        SeriesCache.shared.nextRemember(from: nextEpisode)
        SeriesCache.shared.nextRemember(from: continueWatching)
        // **Bundled on TV, one request per row** - for the details line in the
        // header. Low priority and only now, after the rows loaded: posters go first.
        // See `SeriesCache.prefetchBundle`.
        for rail in [continueWatching, nextEpisode, recent] where !rail.isEmpty {
            Task(priority: .utility) {
                await SeriesCache.shared.prefetchBundle(rail, with: model)
            }
        }
        #endif
    }

    // MARK: - Ablage

    /// Whether this state has come from the server yet - until then the libraries
    /// may come from storage and are refreshed alongside.
    private var loadedServer = false

    private func previewShow(_ store: HomeStore, model: AppModel) {
        model.librariesPreOff(store.libraries)
        let disconnected = model.newAccessDisconnected
        continueWatching = store.continueWatching
        nextEpisode = store.nextEpisode
        recent = disconnected ? [] : store.recent
        newMovies = disconnected ? store.newMovies : []
        newSeries = disconnected ? store.newSeries : []
        // Only genres that are still chosen, in the chosen order.
        let je = Dictionary(store.genreRails.map { ($0.name, $0.items) },
                            uniquingKeysWith: { a, _ in a })
        genreRails = model.genreChips ? [] : model.startGenres.compactMap { name in
            je[name].map { GenreRail(name: name, items: $0) }
        }
        loaded = true
    }

    private static var storeFolder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Startseite", isDirectory: true)
    }

    private static func storeRead(_ account: String) async -> HomeStore? {
        guard let folder = storeFolder else { return nil }
        let file = folder.appendingPathComponent(HomeStore.fileName(account: account))
        return await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: file)).flatMap(HomeStore.read)
        }.value
    }

    private func storeWrite(_ account: String, model: AppModel) {
        guard let folder = Self.storeFolder else { return }
        let store = HomeStore(
            libraries: model.views, continueWatching: continueWatching,
            nextEpisode: nextEpisode, recent: recent, newMovies: newMovies,
            newSeries: newSeries,
            genreRails: genreRails.map { .init(name: $0.name, items: $0.items) })
        Task.detached(priority: .utility) {
            guard let data = try? store.data() else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent(HomeStore.fileName(account: account)),
                             options: .atomic)
        }
    }

    /// On sign-out: the state of an account no longer on the device does not
    /// linger.
    static func storeDelete(_ account: String) {
        guard let folder = storeFolder else { return }
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent(HomeStore.fileName(account: account)))
    }

    /// Back to "nothing loaded yet" - the page shows its placeholders.
    private func wipe() {
        continueWatching = []
        nextEpisode = []
        recent = []
        newMovies = []
        newSeries = []
        genreRails = []
        libraryRails = []
        loaded = false
        disrupted = false
        lastLoaded = nil
        // After an account switch or sign-out this applies again: what comes from
        // storage is refreshed from the server alongside.
        loadedServer = false
    }

    /// Must it be fetched again when returning to the foreground?
    ///
    /// **Not while a run is in flight.** On cold start the phase flips to "active"
    /// while the first run is still waiting - `lastLoaded` is then `nil`, so
    /// everything counted as due, and a second run fetched libraries and all rows
    /// again. Measured in the tvOS simulator: up to five duplicate requests per
    /// launch, the first run discarded. The Mac hangs on the same question
    /// (`didBecomeActiveNotification`).
    var needsRefresh: Bool {
        runningRuns == 0 && Refresh.dueReturn(recent: lastLoaded)
    }
}
