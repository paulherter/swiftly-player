import Foundation
import Testing
@testable import JellyfinKit

/// Der Flug des Profilbilds beim Kontowechsel — Apple, Android, Linux und Windows fliegen dieselbe Bahn.
@Suite struct KontowechselkurveTests {
    /// Von der Kontokarte (Mitte links unten) nach oben rechts, wie am iPhone.
    private let kurve = Kontowechselkurve(vonX: 60, vonY: 420, groesse: 40, nachX: 360, nachY: 70)

    /// **Erst wächst es am Ort**, dann hebt es ab; am Ende ruht es genau am Ziel in Zielgröße.
    @Test func vonDerKarteNachOben() {
        let anfang = kurve.lage(0)
        #expect(anfang.x == 60 && anfang.y == 420 && anfang.s == 40)
        #expect(abs(kurve.lage(Kontowechselkurve.wachsen).s - 42.4) < 0.01)
        let ende = kurve.lage(kurve.tausch)
        #expect(abs(ende.x - 360) <= 0.3 && abs(ende.y - 70) <= 0.3 && abs(ende.s - 34) <= 0.3)
    }

    /// **Erst Landung, dann Ring; der Wechsel vor der Ruhe** — frühestens nach 0,6 s. (Die Landung kann
    /// nach der Ruhe liegen: steht das Bild knapp über dem Ziel, kreuzt es die Zielhöhe erst danach.)
    @Test func zeitplan() {
        #expect(kurve.landung > Kontowechselkurve.wachsen)
        #expect(kurve.ringEnde > kurve.landung)
        #expect(kurve.wechsel >= 0.6 && kurve.wechsel <= kurve.tausch)
        #expect(kurve.tausch < 3)
    }

    /// **Der Ring** ploppt aus 60 % und geht nach 0,8 s aus, höchstens 55 % Deckung.
    @Test func ring() {
        #expect(abs(Kontowechselkurve.ring(0).mass - 0.6) < 0.001)
        #expect(Kontowechselkurve.ring(0).deckung == 0)
        #expect(abs(Kontowechselkurve.ring(0.3).deckung - 0.55) < 0.001)
        #expect(Kontowechselkurve.ring(0.8).deckung < 0.001)
    }

    /// Die Strecke des Entwurfs: 297 nach rechts, 171 nach oben, 72 → 34.
    let entwurf = Kontowechselkurve(von: (100, 400), groesse: 72, nach: (397, 229), zielgroesse: 34)

    @Test func beginntAmStartUndHebtAb() {
        let a = entwurf.lage(0)
        #expect(a.x == 100 && a.y == 400 && a.s == 72)
        let b = entwurf.lage(Kontowechselkurve.wachsen)
        #expect(abs(b.s - 72 * 1.06) < 0.01)
    }

    @Test func ruhtAmZiel() {
        let e = entwurf.lage(entwurf.tausch)
        #expect(abs(e.x - 397) <= 0.3 && abs(e.y - 229) <= 0.3 && abs(e.s - 34) <= 0.3)
        #expect(entwurf.tausch > 0.6 && entwurf.tausch < 3)
    }

    /// Erst zur Seite ausholen, dann hin — der Schwung zeigt weg vom Ziel.
    @Test func holtAus() {
        let frueh = entwurf.lage(Kontowechselkurve.wachsen + 0.03)
        #expect(frueh.x < 100)
    }

    /// Der Ring kommt bei der Landung (die kann nach der Ruhe auf 0,3 Punkt
    /// liegen — der letzte Schwung ist kleiner); das Konto wechselt vor der
    /// Ruhe, frühestens nach 0,6 s.
    @Test func reihenfolge() {
        #expect(entwurf.landung > Kontowechselkurve.wachsen)
        #expect(entwurf.ringEnde > entwurf.landung)
        #expect(entwurf.wechsel >= Kontowechselkurve.wechselFruehestens)
        #expect(entwurf.wechsel <= max(entwurf.tausch, Kontowechselkurve.wechselFruehestens))
    }

    /// Ohne Weg keine Bewegung: steht das Bild schon am Ziel, ruht es sofort.
    @Test func ohneWeg() {
        let k = Kontowechselkurve(von: (10, 10), groesse: 34, nach: (10, 10), zielgroesse: 34)
        #expect(k.tausch < 1)
    }
}
