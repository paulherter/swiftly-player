import Foundation
import Testing
@testable import JellyfinKit

/// **Which season is shown on opening.**
///
/// The bug these checks pin down had a visible form:
/// at the top "Abspielen S6E1", below it the episode list of season 5. Both
/// came from the same page and contradicted each other.
@Suite("Staffelwahl beim Oeffnen")
struct SeasonSelectionTests {

    private func season(_ id: String, number: Int?) -> Item {
        let json = """
        {"Id":"\(id)","Name":"Staffel \(number.map(String.init) ?? "?")","Type":"Season"
        \(number.map { ",\"IndexNumber\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private func episode(seasonID: String?, seasonNumber: Int?) -> Item {
        let json = """
        {"Id":"f1","Name":"Folge","Type":"Episode"
        \(seasonID.map { ",\"SeasonId\":\"\($0)\"" } ?? "")
        \(seasonNumber.map { ",\"ParentIndexNumber\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    private var all: [Item] {
        [season("s1", number: 1), season("s5", number: 5), season("s6", number: 6)]
    }

    @Test("Ein Hinweis mit Kennung gilt")
    func identifier() {
        #expect(SeasonSelectionRule.choose(from: all, hintID: "s5")?.id == "s5")
    }

    /// The server does not always return a `SeasonId` on an episode.
    /// Then the ID comparison hits nothing, and only the
    /// number still counts, so both are checked.
    @Test("Ohne Kennung traegt die Nummer")
    func number() {
        #expect(SeasonSelectionRule.choose(from: all, hintNumber: 6)?.id == "s6")
        // An ID that does not exist must not override the number.
        #expect(SeasonSelectionRule.choose(from: all, hintID: "gibtsnicht",
                                        hintNumber: 5)?.id == "s5")
    }

    /// **The core of the fix.** Without a hint, season 1 used to show while
    /// the main button next to it said "Weiterschauen S6E1".
    @Test("Ohne Hinweis gilt die laufende Staffel, nicht die erste")
    func running() {
        let state = episode(seasonID: "s6", seasonNumber: 6)
        #expect(SeasonSelectionRule.choose(from: all, state: state)?.id == "s6")
    }

    @Test("Ohne SeasonId am Stand traegt dessen Staffelnummer")
    func stateWithoutId() {
        let state = episode(seasonID: nil, seasonNumber: 5)
        #expect(SeasonSelectionRule.choose(from: all, state: state)?.id == "s5")
    }

    /// The episode comes without `SeasonId`, but another season is being
    /// watched right now. The hint's number beats the state's ID,
    /// whereas the old copies on iOS and tvOS checked the other way round.
    @Test("Hinweisnummer schlägt Kennung des Stands")
    func hintNumberPreState() {
        let state = episode(seasonID: "s5", seasonNumber: 5)
        #expect(SeasonSelectionRule.choose(from: all, hintID: nil, hintNumber: 6,
                                        state: state)?.id == "s6")
    }

    @Test("Ohne alles bleibt die erste")
    func fallBack() {
        #expect(SeasonSelectionRule.choose(from: all)?.id == "s1")
        #expect(SeasonSelectionRule.choose(from: []) == nil)
    }

    /// The state is only fetched when it is needed; a fetch nobody
    /// reads costs one request on every series page.
    @Test("Der Stand wird nur ohne Hinweis geholt")
    func stateOnlyWithoutHint() {
        #expect(SeasonSelectionRule.needsState(hintID: nil, hintNumber: nil))
        #expect(!SeasonSelectionRule.needsState(hintID: "s1", hintNumber: nil))
        #expect(!SeasonSelectionRule.needsState(hintID: nil, hintNumber: 1))
    }

    /// A season without a number, such as "Specials", must not match a
    /// `nil` hint, otherwise it wins every comparison.
    @Test("Eine Staffel ohne Nummer passt auf keinen leeren Hinweis")
    func withoutNumber() {
        let withSpecials = [season("sp", number: nil)] + all
        #expect(SeasonSelectionRule.choose(from: withSpecials, hintNumber: nil)?.id == "sp",
                "Ohne jeden Hinweis gilt die erste der Liste — hier Specials")
        #expect(SeasonSelectionRule.choose(from: withSpecials, hintNumber: 5)?.id == "s5")
        let state = episode(seasonID: nil, seasonNumber: nil)
        #expect(SeasonSelectionRule.choose(from: withSpecials, state: state)?.id == "sp")
    }
}
