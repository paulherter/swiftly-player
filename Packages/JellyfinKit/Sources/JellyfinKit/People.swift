import Foundation

/// What the server has for a person.
///
/// **Why this lives in the package and not in a view.** The rule is not in the
/// call but in its parameters: movies and series, newest first, at most sixty,
/// no duplicates. While it lived in `AppModel` it never reached Linux and
/// Windows, which depend only on the package. A second copy there would be the
/// copied function to avoid, and it would drift as soon as someone changes the
/// sorting.
public extension JellyfinClient {

    /// Movies and series this person worked on.
    ///
    /// **By year, newest first**: a filmography is read from the end. `SortName` is
    /// the second key so two titles of the same year have a fixed order; without it
    /// the server decides and the list looked different between two fetches.
    ///
    /// **Movie and series only.** Without `includeItemTypes` Jellyfin also returns
    /// the single episodes someone worked on, each with its series poster, so the
    /// same image twenty times in a row. Same reasoning as for search.
    ///
    /// **`nil` means failed, `[]` means this person has nothing.**
    ///
    /// Every failure used to become an empty list. The person page then showed name
    /// and picture and nothing below, as if the server had this person without a
    /// single title. Someone who does not know the Wi-Fi just dropped takes that
    /// for the truth. Only the caller can tell the two cases apart, so it has to
    /// receive them.
    func title(person id: String, limit: Int = 60) async -> [Item]? {
        guard let answer = try? await items(limit: limit,
                                             sortBy: "ProductionYear,SortName",
                                             sortOrder: "Descending",
                                             recursive: true,
                                             includeItemTypes: ["Movie", "Series"],
                                             personIDs: [id])
        else { return nil }
        return ListRules.withoutDouble(answer.items)
    }
}

public extension JellyfinClient {

    /// Titles of a genre, **most recently added first**.
    ///
    /// Tapping a genre usually means looking for what is new, hence `DateCreated`
    /// and not the name. As with the filmography only movie and series: without
    /// that limit single episodes would come along, each with its series poster.
    ///
    /// `nil` means the server did not answer. That differs from "nothing here": a
    /// row then stays as it was instead of emptying.
    func title(genre: String, limit: Int = 24) async -> [Item]? {
        guard let answer = try? await items(limit: limit,
                                             sortBy: "DateCreated",
                                             sortOrder: "Descending",
                                             recursive: true,
                                             includeItemTypes: ["Movie", "Series"],
                                             genres: [genre])
        else { return nil }
        return ListRules.withoutDouble(answer.items)
    }
}

public extension JellyfinClient {

    /// A page of the filmography **with the server's total**; `title(person:)`
    /// discards it. Whoever loads more needs it for the count badge and for "is
    /// there more". Each work once (``Items``) within the page; `gesamt` counts
    /// server entries. `nil` means the server did not answer.
    func titleWithNumber(person id: String, limit: Int = 60,
                      startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        guard let answer = try? await items(limit: limit, startIndex: startIndex,
                                             sortBy: "ProductionYear,SortName",
                                             sortOrder: "Descending",
                                             recursive: true,
                                             includeItemTypes: ["Movie", "Series"],
                                             personIDs: [id])
        else { return nil }
        let without = ListRules.withoutDouble(answer.items)
        return (await jeItemInTimes(without), max(answer.totalRecordCount, answer.items.count))
    }

    /// A page of a genre, most recently added first, **with the server's total**.
    /// Otherwise like ``titleWithNumber(person:limit:startIndex:)``.
    func titleWithNumber(genre: String, limit: Int = 24,
                      startIndex: Int = 0) async -> (items: [Item], total: Int)? {
        guard let answer = try? await items(limit: limit, startIndex: startIndex,
                                             sortBy: "DateCreated",
                                             sortOrder: "Descending",
                                             recursive: true,
                                             includeItemTypes: ["Movie", "Series"],
                                             genres: [genre])
        else { return nil }
        let without = ListRules.withoutDouble(answer.items)
        return (await jeItemInTimes(without), max(answer.totalRecordCount, answer.items.count))
    }
}
