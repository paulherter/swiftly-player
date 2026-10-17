import JellyfinKit
import Foundation

/// The jump destinations of the navigation stack, the same on both
/// platforms.
///
/// They used to be scattered across the view files where they happened to
/// be needed first. For tvOS they had to come out: the same stack with the
/// same destinations applies there, but not a single one of the iPhone
/// views.
///
/// `Item` itself is also a destination and lives in JellyfinKit.

/// Its own type so that jumping into a library can be told apart from
/// jumping into a title; otherwise both are simply `Item`.
struct LibraryRoute: Hashable {
    let item: Item
    static func == (a: LibraryRoute, b: LibraryRoute) -> Bool { a.item.id == b.item.id }
    func hash(into h: inout Hasher) { h.combine(item.id) }
}

/// Destination for jumping into a season.
struct SeasonRoute: Hashable {
    let series: Item
    let season: Item
}

/// Jump destination for the profile page. Its own type so that it runs
/// over the same stack as everything else, and so the swipe back works.
struct ProfileRoute: Hashable {}

/// The watchlist. Not a section of its own (the fourth slot at the bottom
/// belongs to Downloads) but a jump destination from the home page header.
struct WatchlistRoute: Hashable {}

/// Its own jump destination: the row carries an arrow to the right, so a
/// page must also come from the right, not a sheet in disguise.
struct QuickConnectRoute: Hashable {}

/// **Adding a server: as a page, not a sheet.**
///
/// It came as a `fullScreenCover` from the bottom, while Quick Connect,
/// Seerr, settings, playback and appearance are pushed from the right. Two
/// motions for the same kind of destination: "a subpage you go back from".
/// From the bottom means something else in this app: a sheet you swipe
/// away.
///
/// `preset` is the address when creating a **second account on a
/// known server**; empty means "new server".
struct ServerRoute: Hashable {
    var preset: URL?
}

/// **Another account on the same server, also as a page.**
///
/// It came as a `fullScreenCover` from the bottom, like adding a server
/// before. Feedback: "I don't want anything from the bottom anymore".
struct AccountRoute: Hashable {}

struct SettingsRoute: Hashable {}

struct PlaybackRoute: Hashable {}

/// **Seerr hung as a built-in link on its row.**
///
/// Eleven destinations run through a route and `targetPlace(model:)`, one
/// does not. That was never visible until someone wants to jump there from
/// a second place, because a built-in link belongs to the row it sits in.
struct SeerrRoute: Hashable {}

/// Connect Trakt, next to Seerr under Integration.
struct TraktRoute: Hashable {}

/// A person's page. `origin` is the title you came through, where it
/// says "Patrick Jane in The Mentalist".
struct PersonRoute: Hashable {
    let person: Person
    let origin: String?
}

/// All titles of a genre, from the chips on the home page.
struct GenreRoute: Hashable {
    let name: String
}

/// Profile → Appearance: home page, rows, genres.
struct PresentationRoute: Hashable {}
