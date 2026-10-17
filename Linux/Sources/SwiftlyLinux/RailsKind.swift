import Foundation
import JellyfinKit

/// The three home rows. They differ in more than the heading: image, title and
/// second line differ per row; see ``App/tileBuild(_:art:)``.
enum RailsKind {
    case continueWatching, next, new
}

/// A home row: title, kind, titles in it and, for a selected library or
/// collection, the target the header opens.
typealias StartRailsRow = (String, RailsKind, [Item], Item?)
