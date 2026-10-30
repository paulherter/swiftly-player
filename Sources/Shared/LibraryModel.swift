import Foundation
import JellyfinKit
import Observation

/// A library with filter, sorting and paging, for both platforms.
///
/// This existed twice in nearly identical form, with a subtlety easy to miss
/// when rebuilding it: the server can add items between two pages, which
/// would yield a duplicate title and make `ForEach` complain about the
/// duplicate id.
@MainActor
@Observable
final class LibraryModel {
    private(set) var items: [Item] = []
    private(set) var total = 0
    private(set) var loads = true
    /// The server did not answer, as opposed to "nothing here". `HomeModel`
    /// makes the same distinction; without it the library showed an unreachable
    /// server as an empty shelf.
    private(set) var disrupted = false
    private var loadsPost = false

    /// Which account the contents belong to.
    ///
    /// **The shelf survives an account switch, the view above it not
    /// necessarily.** On the Mac `LibraryView` hangs on `.task(id:)` with
    /// sort and filter; neither changes on a switch, so nothing reloaded and the
    /// previous account's collection stayed until restart. Found in the Mac
    /// session and fixed in the view there; this is the half all platforms share.
    private var forAccount = 0
    /// Counts every load run; only the latest writes. Otherwise runs from
    /// `.task(id:)`, account switches and "Retry" overtake each other, and a
    /// late older one overwrote the newer state.
    private var run = 0

    /// Do the contents still belong to the signed-in account?
    ///
    /// The answer is the same on every platform, the reload trigger is not: on
    /// Apple a view hangs on `.task(id:)`, on Linux and Windows there is no
    /// `onChange` and the counter is compared by hand. So the question lives
    /// here, not the trigger.
    func outdated(_ model: AppModel) -> Bool { forAccount != model.accountSwitch }

    /// **Sort and filter survive a restart.**
    ///
    /// A user's feedback: they sort by most recent because it is practical, and
    /// after leaving and reopening the app they are back at the default. That is
    /// right and not minor: a sort order is a setting, not an action; you choose
    /// it once and expect to find it again.
    ///
    /// It is remembered **per place**, not globally: movies by year and series by
    /// date added is a sensible combination, and a shared value would play them
    /// against each other. `rememberName` tells them apart; without a name nothing
    /// is remembered.
    var sorting: Sorting = .name { didSet { secure() } }
    var filter: LibraryFilter = .all { didSet { secure() } }

    /// Name under which both are stored; `nil` means not at all.
    private let rememberName: String?

    init(rememberName: String? = nil) {
        self.rememberName = rememberName
        guard let rememberName else { return }
        let store = UserDefaults.standard
        if let raw = store.string(forKey: "sortierung.\(rememberName)"),
           let value = Sorting(rawValue: raw) { sorting = value }
        if let raw = store.string(forKey: "filter.\(rememberName)"),
           let value = LibraryFilter(rawValue: raw) { filter = value }
    }

    private func secure() {
        guard let rememberName else { return }
        let store = UserDefaults.standard
        store.set(sorting.rawValue, forKey: "sortierung.\(rememberName)")
        store.set(filter.rawValue, forKey: "filter.\(rememberName)")
    }

    /// If either changes, reload.
    var identifier: String { "\(sorting.rawValue)|\(filter.rawValue)" }

    // MARK: Letter strip

    /// The letters of this list (``AlphabetIndex``); `nil` unless sorted A–Z and loaded.
    private(set) var alphabet: AlphabetIndex?
    private var alphabetFor: String?

    /// Fetches the sort names once per list (source, filter, account). Only for A–Z: any
    /// other order has no letters to jump between.
    func loadAlphabet(_ model: AppModel, from source: ShelfSource?) async {
        guard let source, sorting == .name else { alphabet = nil; alphabetFor = nil; return }
        let key = "\(source.key)|\(identifier)|\(model.accountSwitch)"
        guard alphabetFor != key else { return }
        guard let titles = await model.sortNames(from: source, filter: filter) else { return }
        guard sorting == .name else { return }
        alphabet = AlphabetIndex(titles: titles)
        alphabetFor = key
    }

    /// The same for a library page that knows its kind, not its source.
    func loadAlphabet(_ model: AppModel, art: String?, library: Item?) async {
        let bib = await source(model, art: art, library: library)
        await loadAlphabet(model, from: bib.map { ShelfSource(parent: $0.id, art: art ?? $0.collectionType) })
    }

    @ObservationIgnored private var jumpAsked = 0

    /// **The title to scroll to for a letter**, loading until it is there. Loads in steps
    /// sized by where the letter starts on the server, so a jump to the end of a long
    /// library takes a few requests, not dozens.
    func jumpTarget(_ letter: String, model: AppModel, from source: ShelfSource) async -> String? {
        guard let alphabet else { return nil }
        // Swiping over the rail asks for many letters; only the newest may scroll, even when
        // an older one finishes loading later.
        jumpAsked += 1
        let asked = jumpAsked
        let start = alphabet.entries.first { $0.letter == letter }?.first ?? 0
        for _ in 0..<20 {
            if let i = alphabet.target(for: letter, inLoaded: items.map { ($0.name, $0.sortName) }) {
                return asked == jumpAsked ? items[i].id : nil
            }
            guard stillMorePresent else { break }
            // A page being appended right now blocks `loadMore`; wait for it instead of
            // giving up.
            if loadsPost || loads {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let before = items.count
            await loadMore(model, from: source,
                           count: max(AppModel.pagesSize, start - items.count + AppModel.pagesSize))
            if items.count == before { break }
        }
        return items.last?.id
    }

    /// The same for a library page that knows its kind, not its source.
    func jumpTarget(_ letter: String, model: AppModel, art: String?, library: Item?) async -> String? {
        guard let bib = await source(model, art: art, library: library) else { return nil }
        return await jumpTarget(letter, model: model,
                                from: ShelfSource(parent: bib.id, art: art ?? bib.collectionType))
    }

    /// Whether there is more beyond what is already shown.
    /// **Loading more failed** (tunnel, server briefly down). Without this the
    /// skeleton row stayed forever as if more were coming; the view now shows a
    /// tappable row.
    private(set) var loadMoreFailed = false

    var stillMorePresent: Bool {
        filterRef == nil ? ListRules.stillMorePresent(loaded: items.count, total: total)
                    : ListRules.stillMorePresent(loaded: rawOffset, total: rawTotal)
    }

    /// **Several libraries are sifted** (``TitleFilter``). Paging then follows the
    /// server's response, not what remained: `rawOffset` is how much the server
    /// has delivered so far, `rawTotal` how much it has.
    private var filterRef: TitleFilter?
    private var rawOffset = 0
    private var rawTotal = 0

    /// Whether this tile triggers loading more: any of the last three rows,
    /// see `ListRules.postLoadSection`.
    func solvesLoadMoreOut(_ id: String, columns: Int) -> Bool {
        ListRules.postLoadSection(id, in: items, columns: columns)
    }

    /// What `items` was loaded for: library, sort, filter, account.
    /// Same means refresh only; different means replace.
    private var loadedFor: String?

    /// Which library is meant: named, or looked up by type.
    ///
    /// **No longer `views.first`.** If the server had two libraries of the same
    /// type, the second was unreachable. Now the remembered choice applies and
    /// the first is only the fallback.
    private func source(_ model: AppModel, art: String?, library: Item?) async -> Item? {
        if let library { return library }
        if model.views.isEmpty { await model.loadViews() }
        guard let art else { return nil }
        return model.selectedLibrary(art: art)
    }

    func load(_ model: AppModel, art: String? = nil, library: Item? = nil) async {
        loads = items.isEmpty
        let bib = await source(model, art: art, library: library)
        await load(model, from: bib.map { ShelfSource(parent: $0.id, art: art ?? $0.collectionType) })
    }

    /// The same with a ready-made source: "All" across libraries, or a
    /// collection. `nil` means there is nothing in this area.
    func load(_ model: AppModel, from source: ShelfSource?) async {
        run += 1
        let myOwn = run
        // **Empty right after an account switch.** Otherwise the previous account's
        // titles stayed until the response arrived and were then swapped. This way
        // placeholders show until the new account fades in at once.
        if outdated(model) {
            items = []
            total = 0
            filterRef = nil
            loadedFor = nil
        }
        loads = items.isEmpty
        disrupted = false
        loadMoreFailed = false
        forAccount = model.accountSwitch
        guard let source else {
            // Two cases look the same here: a server without a library of this type,
            // and one that did not answer at all. Tell them apart by whether any
            // libraries are known.
            disrupted = model.views.isEmpty
            loads = false
            return
        }
        if source.isFiltering {
            await filteredLoad(model, from: source, run: myOwn)
            if myOwn == run { loads = false }
            return
        }
        filterRef = nil
        // **When refreshing, fetch as many as are already shown** (up to 300):
        // otherwise someone who finished something at title 90 found an old
        // progress bar there, since only the first 60 were fresh.
        let forRetrieval = "\(source.key)|\(identifier)|\(forAccount)"
        let reach = loadedFor == forRetrieval
            ? min(300, max(AppModel.pagesSize, items.count)) : AppModel.pagesSize
        let answer = await model.items(from: source, sorting: sorting,
                                        filter: filter, since: 0, count: reach)
        // A newer run is in flight; it writes, this one does not.
        guard myOwn == run else { return }
        if let page = answer {
            // This runs again when returning from a detail page and must not shrink
            // to the first page, see `auffrischen`.
            let of = "\(source.key)|\(identifier)|\(forAccount)"
            items = loadedFor == of
                ? ListRules.refresh(page.title, in: items,
                                           totalBefore: total, totalNow: page.total)
                : ListRules.withoutDouble(page.title)
            loadedFor = of
            total = page.total
        } else if !Task.isCancelled {
            // If something is already shown it stays; what was loaded did not become
            // wrong just because the follow-up failed.
            //
            // **A cancellation is not an outage.** `.task(id:)` cancels the old task when
            // the id changes; the running request then returns as a failure and used to
            // look like a silent server. The page showed "No contact with the server"
            // over the posters its successor had just loaded.
            disrupted = items.isEmpty
        }
        loads = false
    }

    func loadMore(_ model: AppModel, art: String? = nil, library: Item? = nil) async {
        guard !outdated(model), stillMorePresent, !loadsPost, !loads else { return }
        guard let bib = await source(model, art: art, library: library) else { return }
        await loadMore(model, from: ShelfSource(parent: bib.id, art: art ?? bib.collectionType))
    }

    /// - Parameter count: How many to fetch; a jump in the alphabet strip asks for more than
    ///   a page so it does not walk there sixty titles at a time.
    func loadMore(_ model: AppModel, from source: ShelfSource,
                  count: Int = AppModel.pagesSize) async {
        // **Nothing is appended after an account switch.** What is shown belongs to
        // the previous account; the second page would come from the new one, and
        // together they would form a collection that exists nowhere. Loading more
        // without reloading first yields nothing here.
        guard !outdated(model) else { return }
        guard stillMorePresent, !loadsPost, !loads else { return }
        // Locked before the first `await`: otherwise two tiles of the loading area
        // get through at the same time.
        loadsPost = true
        defer { loadsPost = false }
        let before = loadedFor
        loadMoreFailed = false
        if source.isFiltering, var s = filterRef {
            let filled = await fill(model, from: source, filterRef: &s,
                                         since: rawOffset, first: count)
            guard loadedFor == before else { return }
            guard let (new, offset, raw) = filled else {
                if !Task.isCancelled { loadMoreFailed = true }
                return
            }
            filterRef = s
            items = ListRules.append(new, an: items)
            rawOffset = offset
            rawTotal = raw
            return
        }
        guard let page = await model.items(from: source, sorting: sorting,
                                            filter: filter, since: items.count, count: count)
        else {
            if !Task.isCancelled { loadMoreFailed = true }
            return
        }
        // If it was re-sorted or filtered meanwhile, the page belongs to a different
        // list.
        guard loadedFor == before else { return }
        items = ListRules.append(page.title, an: items)
        total = page.total
    }

    // MARK: Filtered

    /// First page from several libraries. When returning from a detail page,
    /// refetch as far as was already paged, in one go, so the list does not shrink
    /// to the first page while tile progress stays fresh.
    private func filteredLoad(_ model: AppModel, from source: ShelfSource, run myOwn: Int) async {
        let of = "\(source.key)|\(identifier)|\(forAccount)"
        let fetched = await model.titleFilter(source, filter: filter)
        guard myOwn == run else { return }
        guard var newFilter = fetched else {
            if !Task.isCancelled { disrupted = items.isEmpty }
            return
        }
        let first = max(AppModel.pagesSize, loadedFor == of ? rawOffset : 0)
        let filled = await fill(model, from: source, filterRef: &newFilter, since: 0, first: first)
        guard myOwn == run else { return }
        guard let (new, offset, raw) = filled else {
            if !Task.isCancelled { disrupted = items.isEmpty }
            return
        }
        filterRef = newFilter
        items = new
        rawOffset = offset
        rawTotal = raw
        total = newFilter.total
        loadedFor = of
    }

    /// Fetches pages until something remains. A page can consist almost entirely
    /// of duplicates; then no new tile would appear to trigger the next load and
    /// the list would stall.
    private func fill(_ model: AppModel, from source: ShelfSource, filterRef: inout TitleFilter,
                         since start: Int, first: Int) async -> ([Item], Int, Int)? {
        var new: [Item] = []
        var offset = start
        var raw = 0
        var count = first
        repeat {
            guard let page = await model.items(from: source, sorting: sorting,
                                                filter: filter, since: offset, count: count)
            else { return nil }
            new += filterRef.seven(page.title)
            offset += page.title.count
            raw = page.total
            count = AppModel.pagesSize
            if page.title.isEmpty { break }
        } while new.count < AppModel.pagesSize / 2 && offset < raw
        return (new, offset, raw)
    }
}
