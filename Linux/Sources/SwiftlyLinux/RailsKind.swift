import Foundation
import JellyfinKit

/// The three home rows. They differ in more than the heading: image, title and
/// second line differ per row; see ``App/tileBuild(_:art:)``.
enum RailsKind {
    case continueWatching, next, new
}

/// What the heading of a home row opens.
enum RailHeader {
    /// A selected library or collection.
    case collection(Item)
    /// The movies or series area in an order (``StartRail/libraryJump``).
    case library(LibraryJump)
}

/// A home row: title, kind, titles in it and, where it has one, what the header opens.
typealias StartRailsRow = (String, RailsKind, [Item], RailHeader?)
