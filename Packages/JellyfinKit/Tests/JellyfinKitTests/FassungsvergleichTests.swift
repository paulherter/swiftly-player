import Testing
@testable import JellyfinKit

@Suite("Fassungsvergleich")
struct FassungsvergleichTests {

    @Test("Eine hoehere Fassung ist neuer")
    func hoehereFassung() {
        #expect(Fassungsvergleich.neuer(dort: "1.0.4", hier: "1.0.3"))
        #expect(Fassungsvergleich.neuer(dort: "1.1.0", hier: "1.0.9"))
        #expect(Fassungsvergleich.neuer(dort: "2.0.0", hier: "1.9.9"))
    }

    @Test("Eine niedrigere oder gleiche ist es nicht")
    func nichtNeuer() {
        #expect(!Fassungsvergleich.neuer(dort: "1.0.2", hier: "1.0.3"))
        #expect(!Fassungsvergleich.neuer(dort: "1.0.3", hier: "1.0.3"))
        #expect(!Fassungsvergleich.neuer(dort: "0.9.9", hier: "1.0.0"))
    }

    /// Der Grund, warum diese Regel im Paket liegt und nicht bei der
    /// Windows-Fassung: als Zeichenkette verglichen waere 1.0.10 aelter.
    @Test("Zehn ist groesser als neun, nicht kleiner")
    func zweistellig() {
        #expect(Fassungsvergleich.neuer(dort: "1.0.10", hier: "1.0.9"))
        #expect(!Fassungsvergleich.neuer(dort: "1.0.9", hier: "1.0.10"))
    }

    @Test("Fehlende Stellen zaehlen als null")
    func fehlendeStellen() {
        #expect(!Fassungsvergleich.neuer(dort: "1.1", hier: "1.1.0"))
        #expect(Fassungsvergleich.neuer(dort: "1.2", hier: "1.1.9"))
    }

    @Test("Gleiche Fassung, hoeherer Bau: neuer")
    func hoehererBau() {
        #expect(Fassungsvergleich.neuer(dort: "1.0.3", hier: "1.0.3", bauDort: 2, bauHier: 1))
        #expect(!Fassungsvergleich.neuer(dort: "1.0.3", hier: "1.0.3", bauDort: 2, bauHier: 2))
        #expect(!Fassungsvergleich.neuer(dort: "1.0.3", hier: "1.0.3", bauDort: 1, bauHier: 7))
    }

    @Test("Ohne Baunummer gilt gleiche Fassung als derselbe Stand")
    func ohneBaunummer() {
        #expect(!Fassungsvergleich.neuer(dort: "1.0.3", hier: "1.0.3", bauHier: 1))
    }

    @Test("Eine hoehere Fassung schlaegt jede Baunummer")
    func fassungVorBau() {
        #expect(Fassungsvergleich.neuer(dort: "1.0.4", hier: "1.0.3", bauDort: 1, bauHier: 99))
    }

    @Test("Die Baunummer wird aus dem Text gelesen")
    func baunummerLesen() {
        #expect(Fassungsvergleich.baunummer(ausText: "## Update — September 20 (build 2, Windows)") == 2)
        #expect(Fassungsvergleich.baunummer(ausText: "Neu in Bau 7: schneller") == 7)
        #expect(Fassungsvergleich.baunummer(ausText: "Nichts davon") == nil)
    }

    /// Ein Text, der mehrere Bauten aufzaehlt, nennt den aeltesten zuerst.
    @Test("Die groesste genannte Zahl gewinnt")
    func groessteZahl() {
        let text = "build 2 brachte X\n\nbuild 7 bringt Y"
        #expect(Fassungsvergleich.baunummer(ausText: text) == 7)
    }
}
