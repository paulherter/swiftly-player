import Foundation

/// Two decisions that look like UI but are not.
///
/// **Why they live here.** Both are numbers that must be identical on six platforms; each
/// version used to type them itself, which is how copies drift apart (`seconds > 0` did).
///
/// The wording of the display stays in the views, since it depends on the catalog and the
/// language. Here only **whether** something is shown.
public enum DisplayRules {

    /// Whether a runtime may be shown at all.
    ///
    /// **The case this exists for:** a series has no runtime of its own and the server
    /// reports `0`. Without this check the tile showed "0 min". Negative values and `nil`
    /// are rejected too, so a server reporting nonsense produces no display that looks like
    /// data.
    ///
    /// `Double` because `Item.runtimeSeconds` is one: the server counts in ticks, which
    /// become a fractional number on conversion.
    public static func runtimeShow(seconds: Double?) -> Bool {
        guard let seconds else { return false }
        return seconds > 0
    }

    /// When a search input goes to the server.
    ///
    /// **A single letter is not a search** but a query over half the library, repeated on
    /// every keystroke. Two characters is the threshold where the answer means something.
    /// Spaces do not count: "a " is one letter.
    public static func searchTermFits(_ term: String) -> Bool {
        term.trimmingCharacters(in: .whitespacesAndNewlines).count > 1
    }

    /// What is shown at the top right of a tile.
    ///
    /// **Three states, three icons.** There used to be only the progress bar, which says
    /// nothing for a series: it shows the progress of the started *episode*, not of the
    /// series.
    ///
    /// The precedence is deliberate:
    ///
    /// 1. **Watched beats everything.** Someone who finished a series does not want to read
    ///    its season count.
    /// 2. **Open episodes beat the season count.** Once someone has started, "12 left" is
    ///    more useful than "7 seasons".
    /// 3. **Otherwise the season count**, and only for series.
    ///
    /// A movie only gets the checkmark. "1 season" on a movie is nonsense, and a number
    /// that is always one tells nothing.
    public static func tileMark(art: String?, seasons: Int?,
                                   watched: Bool?, openEpisodes: Int?) -> TileMark? {
        if watched == true { return .watched }
        guard art == "Series" else { return nil }
        if let opened = openEpisodes, opened > 0 { return .opened(opened) }
        if let n = seasons, n > 0 { return .seasons(n) }
        return nil
    }
}

/// What is on a tile's badge. The view sets the **wording** because it depends on the
/// catalog; here only which information it is.
public enum TileMark: Equatable, Sendable {
    case watched
    case opened(Int)
    case seasons(Int)
}

public extension Item {
    /// **The icon a tile without an image carries**: a TV for series and their episodes, a
    /// film strip otherwise. An empty area looks like an app bug; an icon says an image
    /// belongs here and the server has none.
    ///
    /// This used to be a condition at every call site, once with `type`, once with
    /// `seriesId`, so depending on the place either the series or its episode got the film
    /// strip.
    var tileCharacter: String {
        type == "Series" || seriesId != nil ? "tv" : "film"
    }
}
