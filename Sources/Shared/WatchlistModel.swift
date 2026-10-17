import Foundation
import JellyfinKit
import Observation

/// What is bookmarked, across all libraries.
///
/// **A library like any other, except its boundary is the bookmark.** Not a
/// folder on disk but what the user tapped, so movies and series are mixed here.
/// To separate them use the type pill; that is the same question as in the
/// library, one level higher.
///
/// Layout and components are those of the library page: header with title,
/// control row with values and count badge, grid below. A page type of its own
/// would be a second grammar for the same thing.
@MainActor
@Observable
final class WatchlistModel {
    private(set) var items: [Item] = []
    private(set) var total = 0
    private(set) var loads = true
    private var loadsPost = false

    /// `nil` means movies **and** series.
    var genre: String? { didSet { secure() } }
    /// Most recently bookmarked first, which is the order a watchlist is read in.
    /// A-Z would be the order of a shelf, not of an intention.
    ///
    /// **And what is chosen once is there the next time.** The same rule as in
    /// `LibraryModel`, the same reasoning: a sort order is a setting, not an
    /// action.
    var sorting: Sorting = .latest { didSet { secure() } }

    init() {
        let store = UserDefaults.standard
        if let raw = store.string(forKey: "sortierung.merkliste"),
           let value = Sorting(rawValue: raw) { sorting = value }
        genre = store.string(forKey: "gattung.merkliste")
    }

    private func secure() {
        let store = UserDefaults.standard
        store.set(sorting.rawValue, forKey: "sortierung.merkliste")
        if let genre { store.set(genre, forKey: "gattung.merkliste") }
        else { store.removeObject(forKey: "gattung.merkliste") }
    }

    var identifier: String { "\(genre ?? "-")|\(sorting.rawValue)" }
    var stillMorePresent: Bool { ListRules.stillMorePresent(loaded: items.count, total: total) }

    func solvesLoadMoreOut(_ id: String, columns: Int) -> Bool {
        ListRules.postLoadSection(id, in: items, columns: columns)
    }

    /// The same distinction as in `LibraryModel`: the same list is refreshed,
    /// not cut back to the first page.
    private var loadedFor: String?

    /// **The fetch failed, which is not "nothing bookmarked".**
    ///
    /// `remembered` returns `nil` on a failure and an empty page for an empty list;
    /// only `if let` was checked here, and the `else` case fell through silently. The
    /// view saw an empty `items` and said "Nothing bookmarked yet", for a watchlist
    /// that may be full. `HomeModel` and `LibraryModel` make the same
    /// distinction.
    private(set) var disrupted = false

    /// Which account state `items` belongs to (`nil`: nothing loaded yet).
    private var forAccount: Int?
    /// Counts every load run; only the newest writes. A run cancelled by
    /// `.task(id:)` (sort or type changed quickly) would otherwise say "failed" and
    /// "done" while the new one was still running.
    private var run = 0

    func load(_ model: AppModel) async {
        run += 1
        let myOwn = run
        // **Another account: leave nothing of the previous one.** Otherwise the page
        // showed the previous profile's watchlist until the response, or, if the last
        // fetch had failed, "Server went away" / "Nothing bookmarked yet" before the
        // first load. Like `LibraryModel.veraltet(_:)`.
        if let forAccount, forAccount != model.accountSwitch {
            items = []
            total = 0
            disrupted = false
            loadedFor = nil
        }
        forAccount = model.accountSwitch
        loads = items.isEmpty
        // **Capture at the start what is being asked for.** After the response the sort
        // may already be a different one, and a late response would land under the new
        // key.
        let of = "\(identifier)|\(model.accountSwitch)"
        // On refresh fetch as much as is already shown (up to 300); see
        // `LibraryModel.load`.
        let reach = loadedFor == of
            ? min(300, max(AppModel.pagesSize, items.count)) : AppModel.pagesSize
        let answer = await model.remembered(art: genre, sorting: sorting, since: 0,
                                           count: reach)
        guard myOwn == run, !Task.isCancelled else { return }
        disrupted = answer == nil
        if let page = answer {
            // The same rule as on the home page; see `ListRules`.
            items = loadedFor == of
                ? ListRules.refresh(page.title, in: items,
                                           totalBefore: total, totalNow: page.total)
                : ListRules.withoutDouble(page.title)
            loadedFor = of
            total = page.total
        }
        loads = false
    }

    func loadMore(_ model: AppModel) async {
        guard stillMorePresent, !loadsPost, !loads else { return }
        loadsPost = true
        defer { loadsPost = false }
        let before = loadedFor
        let whatFor = identifier
        guard let page = await model.remembered(art: genre, sorting: sorting,
                                               since: items.count),
              loadedFor == before, identifier == whatFor else { return }
        // Append only what is really new: the server may return a page twice, and
        // `ForEach` complains about the duplicate id.
        items = ListRules.append(page.title, an: items)
        total = page.total
    }
}

// `Merkgattung` lives in the package (`Library.swift`); it used to be here
// and so did not reach Linux and Windows.
