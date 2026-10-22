import JellyfinKit
import Observation
import SwiftUI

/// The per-section page stack, **managed by hand instead of `NavigationStack`.**
///
/// Not a matter of taste. On the Mac `NavigationStack` brought three things we had
/// to switch off again: a back arrow in the window controls, a toolbar background
/// over the image, and a safe-area inset that appeared only sometimes. The
/// open/close animation it was supposed to provide does not happen here anyway.
///
/// A custom stack is one array and two methods. It follows the rule from `Theme`
/// literally: **going deeper slides in from the right, going back slides out to the
/// right.**
@MainActor
@Observable
final class Navigator {
    /// What lies on which section. Switching between Movies and Shows returns to where
    /// you were.
    private var stack: [Region: [PagesTarget]] = [:]

    func pages(_ section: Region) -> [PagesTarget] { stack[section] ?? [] }

    func openIt(_ target: PagesTarget, in section: Region) {
        // **Pushed without animation.** The page should be in place and laid out first;
        // `MainView` starts the motion one frame later via `shownDeep`.
        // If the target is already on the stack, its id counts only once: go back to that
        // page instead of appending it twice.
        if let spot = stack[section]?.firstIndex(where: { $0.id == target.id }) {
            back(in: section, until: spot + 1)
            return
        }
        stack[section, default: []].append(target)
    }

    /// Remove everything (a stack belongs to one account).
    ///
    /// Without an explicit animation this would be a jump, so the pages slide out to the
    /// right as when going back, all at once. It stays a **single** motion because
    /// `MainView` pulls back the accompanying content in the same step.
    /// **The profile page is excluded:** it shows the bundle, not one account, and it is
    /// the page where switching happens. If it went too, it would have to be reopened
    /// between two switches, but the strip exists precisely for switching repeatedly.
    func emptyAll() {
        guard stack.contains(where: { !$0.value.isEmpty }) else { return }
        withAnimation(Theme.timePagesPush) {
            for (section, pages) in stack {
                // **`contains`, not `last`.** Adding a server from the profile leaves the user on
                // the onboarding page at switch time; that page is removed, the profile beneath
                // stays. With `last` the profile went too and the user landed on "Start" without
                // seeing the server just added.
                stack[section] = pages.contains(.profile) ? [.profile] : []
            }
        }
    }

    /// **Remove everything, including the profile page:** the account switch from the
    /// profile page (design D, as on iPhone). The page slides out to the right as when
    /// going back, and the profile picture flies into the sidebar (`AccountSwitchTransition`).
    /// The exception from the account-stack rule still applies to every other switch, e.g. signing in on a
    /// new server, after which the user wants to see that server in the profile.
    func clearEverything() {
        guard stack.contains(where: { !$0.value.isEmpty }) else { return }
        // With reduced motion only the fade, like the still image on iPhone, which fades
        // instead of sliding away.
        withAnimation(Theme.motionReduced ? Theme.fadeReduced : Theme.timePagesPush) {
            for section in stack.keys { stack[section] = [] }
        }
    }

    /// **The check belongs inside the animation, not before it.**
    ///
    /// It used to sit before it, and the app crashed when a second server was added:
    /// signing in there bumps `accountSwitch`, `MainView` reacts with `emptyAll()` to
    /// clear all stacks, and SwiftUI processes that observation inside `withAnimation`.
    /// Between the `guard` and the `removeLast` the stack was empty, and `removeLast` on
    /// an empty array traps.
    func back(in section: Region) {
        withAnimation(Theme.timePagesPush) {
            guard !(stack[section] ?? []).isEmpty else { return }
            stack[section]?.removeLast()
        }
    }

    /// **Go back, but only from exactly this page.**
    ///
    /// A subpage that closes itself does not know whether it is still on the stack: a
    /// sign-in clears the stack, and so does an account switch. A blind `back` call
    /// would then also remove the page below, which when adding a server was the
    /// profile page where the user wanted to see the new server.
    func close(_ target: PagesTarget, in section: Region) {
        withAnimation(Theme.timePagesPush) {
            guard stack[section]?.last == target else { return }
            stack[section]?.removeLast()
        }
    }

    /// Go back until only `depth` pages remain, in **one** motion.
    func back(in section: Region, until depth: Int) {
        withAnimation(Theme.timePagesPush) {
            guard let pages = stack[section], pages.count > depth else { return }
            stack[section] = Array(pages.prefix(depth))
        }
    }

    /// Whether the account branch lies on this stack (see `PagesTarget.inAccountBranch`).
    func inAccount(_ section: Region) -> Bool {
        pages(section).contains { $0.inAccountBranch }
    }

    /// Removes the account branch; whatever lay beneath stays.
    ///
    /// With animation this is an ordinary back. Without it, when the section is not
    /// visible or its root is being replaced, `MainView` has to update the shown depth
    /// itself.
    func closeAccountBranch(in section: Region, animated: Bool) {
        let pages = pages(section)
        guard let since = pages.firstIndex(where: { $0.inAccountBranch }) else { return }
        if animated {
            back(in: section, until: since)
        } else {
            stack[section] = Array(pages.prefix(since))
        }
    }
}

/// Where a page can lead.
///
/// A dedicated type instead of `any Hashable`: the stack must be comparable so
/// SwiftUI recognizes the change as such, and an enum shows on reading which
/// destinations exist.
enum PagesTarget: Hashable, Identifiable {
    case title(Item)
    /// **A library as its own page.**
    ///
    /// **No longer used.** The other libraries are in the title menu of
    /// Movies and Shows instead of the sidebar; the case stays only so an old restored
    /// stack does not break.
    case library(Item)
    /// **A collection:** from the title menu ("Sammlungen") or from "Teil der Sammlung"
    /// on the movie page. Unlike a library, a subpage with back arrow, as on iPhone.
    /// `art`: its movies or its shows; `nil`: everything in it.
    case collection(Item, art: String?)
    /// **A video playlist:** from the title menu ("Wiedergabelisten"); a subpage with back
    /// arrow. `art`: its movies or its episodes; `nil`: everything in it.
    case playlist(Item, art: String?)
    /// **A downloaded series:** from Downloads, no server; everything comes from disk.
    case downloadSeries(String, title: String)
    /// **No longer used.** The watchlist has been its own section in the sidebar since
    /// the watchlist moved there; the case stays only so an old restored stack does not break.
    ///
    /// Formerly a page from the sidebar. On iPhone it hangs off the icon at the top
    /// right.
    case watchlist
    /// Connect Seerr: an extra, hence behind the settings.
    case seerr
    /// Connect Trakt: behind the settings like Seerr.
    case trakt
    /// A title the own server does not have, coming from search.
    case seerrTitle(SeerrHit)
    /// A person from the cast: what exists of them.
    case person(Person, origin: String?)
    /// All titles of a genre, from the home page chips.
    case genre(String)
    case profile
    case settings
    case playback
    /// How the app looks and what the home page shows.
    case presentation
    /// Open-source licenses: the list, one component (by id), and source code with offer.
    case licenses
    case license(String)
    case licenseOffering
    /// Add a genre to the home page.
    case genreSelection
    /// Add a library or collection as its own home row.
    case librarySelection
    case quickConnect
    case accountAdd
    /// **A second Jellyfin.** With an address when the account is created on a server
    /// that already exists in the bundle; the address is then fixed and only displayed.
    case serverAdd(URL?)

    var id: String {
        switch self {
        case let .title(item):  "titel-\(item.id)"
        case let .library(b): "bibliothek-\(b.id)"
        case let .collection(s, art): "sammlung-\(s.id)-\(art ?? "")"
        case let .playlist(l, art): "wiedergabeliste-\(l.id)-\(art ?? "")"
        case let .downloadSeries(id, _): "downloadserie-\(id)"
        case .watchlist:        "merkliste"
        case .seerr:            "seerr"
        case .trakt:            "trakt"
        case let .seerrTitle(t): "seerr-\(t.art)-\(t.id)"
        case let .person(p, _): "person-\(p.id)"
        case let .genre(name): "gattung-\(name)"
        case .profile:           "profil"
        case .settings:    "einstellungen"
        case .playback:       "wiedergabe"
        case .presentation:      "darstellung"
        case .licenses:         "lizenzen"
        case let .license(id):   "lizenz-\(id)"
        case .licenseOffering:    "lizenzangebot"
        case .genreSelection:        "genrewahl"
        case .librarySelection:  "bibliothekswahl"
        case .quickConnect:     "quickconnect"
        case .accountAdd: "kontohinzufuegen"
        case let .serverAdd(url): "serverneu-\(url?.absoluteString ?? "")"
        }
    }

    /// **Does the page belong to the account rather than the section?**
    ///
    /// The profile is opened from the sidebar and lies on the stack of the currently open
    /// section, but belongs to none. The same goes for everything opened from there.
    /// While such a page is shown, the account carries the selection at the bottom, and
    /// a click on a section removes it again.
    var inAccountBranch: Bool {
        switch self {
        case .profile, .settings, .playback, .seerr, .trakt, .presentation,
             .licenses, .license, .licenseOffering, .genreSelection, .librarySelection, .quickConnect, .accountAdd, .serverAdd: true
        // **The person page belongs to the section, not the account.** It is reached from a
        // title and the user wants to continue from there to the next one, so it lies in
        // the same branch as the page that opened it. The same goes for a genre.
        case .title, .library, .collection, .playlist, .downloadSeries, .watchlist, .seerrTitle, .person, .genre: false
        }
    }

    static func == (a: PagesTarget, b: PagesTarget) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Which section is currently visible.
///
/// Passed through the environment because every tile deep in the tree must know which
/// stack to push onto, and a passed-down value would have had to go through every view
/// in between that does not need it.
extension EnvironmentValues {
    @Entry var section: Region = .start
}

/// **While a page slides in, nothing is swapped.**
///
/// The slide is an `.offset`, which SwiftUI evaluates on the main actor every frame.
/// If a server response arrived during that time (full title, seasons and episodes,
/// extras and similar, the plan, the image tint), SwiftUI rebuilt half the page in the
/// same pass and the slide dropped frames: an inch or two in, a short stall, then on.
/// That was the stutter in the first second after the click.
///
/// So responses wait until the page is settled (Linux: `postPush`). The fetch
/// still starts immediately; only applying the result waits, at most one slide
/// duration. Returning to a page that is already settled does not wait.
@MainActor
enum InTravel {
    private static var end = ContinuousClock.now

    /// Called by `MainView` when a new page starts sliding in.
    static func begins() {
        // One frame of slack: the last frame of the slide still belongs to it.
        end = .now + .milliseconds(Int(Theme.durationPagesPush * 1000) + 30)
    }

    /// Returns as soon as no page is sliding.
    static func waitFor() async {
        guard end > .now else { return }
        try? await Task.sleep(until: end, clock: .continuous)
    }
}

/// **Playback plans, fetched ahead** for the "Direct Play" badge in the detail page
/// header. Hovering a tile (after the `TileWrapper` delay) makes `prefetch` fetch the
/// plan already; if it is present on open, the badge shows immediately instead of
/// arriving late. The header still asks fresh and updates if something changed.
///
/// For a series it is the plan of the episode that would play next, as in the header
/// (`stateInSeries`). Linux/Windows: `App.planJob`.
@MainActor
enum PlanPreAdvice {
    private static var remembered: [String: PlaybackPlan] = [:]
    private static var ongoing: [String: Task<PlaybackPlan?, Never>] = [:]

    /// What a plan depends on: Direct Play switch, bitrate limit, account. If one
    /// changes, the stored plans no longer apply; otherwise the header would briefly show
    /// "Direct Play" where the new plan transcodes.
    private static var key = ""

    private static func reconcileWith(_ model: AppModel) {
        let new = "\(model.alwaysDirectPlay)|\(model.bitratesLimit)|\(model.accountSwitch)"
        guard new != key else { return }
        key = new
        remembered.removeAll()
        ongoing.values.forEach { $0.cancel() }
        ongoing.removeAll()
    }

    static func plan(_ id: String, with model: AppModel) -> PlaybackPlan? {
        reconcileWith(model)
        return remembered[id]
    }

    static func remember(_ id: String, _ plan: PlaybackPlan?) {
        remembered[id] = plan
    }

    /// `PlaybackInfo` is a POST in which the server touches the file, so one per title,
    /// even when hover and open coincide.
    static func prefetch(_ item: Item, with model: AppModel) {
        reconcileWith(model)
        guard item.type == "Movie" || item.type == "Series",
              remembered[item.id] == nil, ongoing[item.id] == nil else { return }
        let id = item.id
        let series = item.type == "Series"
        ongoing[id] = Task { @MainActor in
            let target: String?
            if series { target = await model.stateInSeries(item)?.id } else { target = id }
            guard let target else { ongoing[id] = nil; return nil }
            let plan = await model.plan(for: target, still: true)
            // Cancelled (setting or account changed): the plan no longer applies.
            guard !Task.isCancelled else { return nil }
            if let plan { remembered[id] = plan }
            ongoing[id] = nil
            return plan
        }
    }
}
