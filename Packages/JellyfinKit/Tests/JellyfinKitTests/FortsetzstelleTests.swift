import Testing
@testable import JellyfinKit

@Suite("Fortsetzstelle")
struct FortsetzstelleTests {

    @Test func unterEinerMinuteVonVorn() {
        #expect(Fortsetzstelle.ab(position: 30, laufzeit: 3600) == nil)
        #expect(Fortsetzstelle.ab(position: 60, laufzeit: 3600) == nil)
        #expect(Fortsetzstelle.ab(position: 61, laufzeit: 3600) == 61)
    }

    /// Der Fall vom 04.09.2026: Folge durchgelaufen, Ende gemerkt.
    @Test func amEndeVonVorn() {
        #expect(Fortsetzstelle.ab(position: 3707, laufzeit: 3707) == nil)
        #expect(Fortsetzstelle.ab(position: 3660, laufzeit: 3707) == nil)
        #expect(Fortsetzstelle.ab(position: 3646, laufzeit: 3707) == 3646)
    }

    /// Ueber die Laufzeit hinaus — kommt vor, wenn Server und Datei sich
    /// nicht einig sind. Auch das ist „von vorn", nicht „irgendwohin".
    @Test func ueberDieLaufzeitHinaus() {
        #expect(Fortsetzstelle.ab(position: 4000, laufzeit: 3707) == nil)
    }

    /// Ohne Laufzeit bleibt nur die untere Grenze. Raten waere schlimmer.
    @Test func ohneLaufzeitNurDieUntereGrenze() {
        #expect(Fortsetzstelle.ab(position: 3707, laufzeit: nil) == 3707)
        #expect(Fortsetzstelle.ab(position: 30, laufzeit: nil) == nil)
        #expect(Fortsetzstelle.ab(position: 3707, laufzeit: 0) == 3707)
    }

    @Test func ohnePositionNichts() {
        #expect(Fortsetzstelle.ab(position: nil, laufzeit: 3600) == nil)
    }
}
