import Foundation
import Testing
@testable import JellyfinKit

@Suite("Gemeinschaft")
struct CommunityTests {

    private func kickoff(_ done: Int, recent: String? = nil, shown: Bool = false,
                         possible: Bool = true) -> Community.Trigger? {
        Community.kickoff(done: done, ratingLast: recent, version: "1.0.3",
                             discordShown: shown, ratingPossible: possible)
    }

    @Test("Vor dem dritten Titel kommt nichts")
    func firstTitleQuiet() {
        #expect(kickoff(1) == nil)
        #expect(kickoff(2) == nil)
    }

    @Test("Dritter Titel: Bewertung, vierter: nichts, fuenfter: Discord")
    func railsEpisode() {
        #expect(kickoff(3) == .rating)
        #expect(kickoff(4, recent: "1.0.3") == nil)
        #expect(kickoff(5, recent: "1.0.3") == .discord)
        #expect(kickoff(6, recent: "1.0.3", shown: true) == nil)
    }

    @Test("Beide faellig: erst die Bewertung, der Discord beim naechsten Titel")
    func neverBothAtOnce() {
        #expect(kickoff(10, recent: "1.0.2") == .rating)
        #expect(kickoff(11, recent: "1.0.3") == .discord)
    }

    @Test("Ohne Bewertungsabfrage blockiert die Frage den Discord nicht")
    func withoutRating() {
        #expect(kickoff(3, possible: false) == nil)
        #expect(kickoff(5, possible: false) == .discord)
        #expect(kickoff(9, shown: true, possible: false) == nil)
    }

    @Test("Das Issue traegt Fassung und Plattform, sonst nichts")
    func errorAddress() throws {
        let url = Community.errorReport(version: "1.0.3 (14)", platform: "iOS 26.0")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "github.com")
        #expect(parts.path == "/paulherter/swiftly-player/issues/new")
        #expect(parts.queryItems?.count == 1)
        let text = try #require(parts.queryItems?.first?.value)
        #expect(text.contains("1.0.3 (14)"))
        #expect(text.contains("iOS 26.0"))
    }

    @Test("Die Discord-Kurzform ist die Einladung ohne Schema")
    func shortShape() {
        #expect(Community.discord.absoluteString == "https://" + Community.discordShort)
    }
}
