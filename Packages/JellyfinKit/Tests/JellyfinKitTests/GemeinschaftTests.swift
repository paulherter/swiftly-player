import Foundation
import Testing
@testable import JellyfinKit

@Suite("Gemeinschaft")
struct GemeinschaftTests {

    private func anstoss(_ fertig: Int, zuletzt: String? = nil, gezeigt: Bool = false,
                         moeglich: Bool = true) -> Gemeinschaft.Anstoss? {
        Gemeinschaft.anstoss(fertig: fertig, bewertungZuletzt: zuletzt, fassung: "1.0.3",
                             discordGezeigt: gezeigt, bewertungMoeglich: moeglich)
    }

    @Test("Vor dem dritten Titel kommt nichts")
    func ersteTitelRuhig() {
        #expect(anstoss(1) == nil)
        #expect(anstoss(2) == nil)
    }

    @Test("Dritter Titel: Bewertung, vierter: nichts, fuenfter: Discord")
    func reihenfolge() {
        #expect(anstoss(3) == .bewertung)
        #expect(anstoss(4, zuletzt: "1.0.3") == nil)
        #expect(anstoss(5, zuletzt: "1.0.3") == .discord)
        #expect(anstoss(6, zuletzt: "1.0.3", gezeigt: true) == nil)
    }

    @Test("Beide faellig: erst die Bewertung, der Discord beim naechsten Titel")
    func nieBeideZugleich() {
        #expect(anstoss(10, zuletzt: "1.0.2") == .bewertung)
        #expect(anstoss(11, zuletzt: "1.0.3") == .discord)
    }

    @Test("Ohne Bewertungsabfrage blockiert die Frage den Discord nicht")
    func ohneBewertung() {
        #expect(anstoss(3, moeglich: false) == nil)
        #expect(anstoss(5, moeglich: false) == .discord)
        #expect(anstoss(9, gezeigt: true, moeglich: false) == nil)
    }

    @Test("Das Issue traegt Fassung und Plattform, sonst nichts")
    func fehlerAdresse() throws {
        let url = Gemeinschaft.fehlerMelden(fassung: "1.0.3 (14)", plattform: "iOS 26.0")
        let teile = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(teile.host == "github.com")
        #expect(teile.path == "/paulherter/swiftly-player/issues/new")
        #expect(teile.queryItems?.count == 1)
        let text = try #require(teile.queryItems?.first?.value)
        #expect(text.contains("1.0.3 (14)"))
        #expect(text.contains("iOS 26.0"))
    }

    @Test("Die Discord-Kurzform ist die Einladung ohne Schema")
    func kurzform() {
        #expect(Gemeinschaft.discord.absoluteString == "https://" + Gemeinschaft.discordKurz)
    }
}
