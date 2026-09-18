import Testing
@testable import JellyfinKit

@Suite("Pufferstufe")
struct PufferstufeTests {

    @Test("Normal faesst VLCs Zeitvorlauf nicht an")
    func normalLaesstVLCInRuhe() {
        #expect(Pufferstufe.normal.netzvorlaufMillisekunden == nil)
        #expect(Pufferstufe.normal.prefetchKiB == 16_384)
    }

    @Test("Jede Stufe haelt mehr als die davor")
    func stufenWachsen() {
        let stufen = Pufferstufe.allCases
        for (a, b) in zip(stufen, stufen.dropFirst()) {
            #expect(a.prefetchKiB < b.prefetchKiB)
        }
    }

    /// Der Punkt, an dem die Frage des Nutzers haengt: dieselbe Einstellung
    /// traegt bei 4K viel weniger Zeit als bei einer Serie.
    @Test("Dieselben Bytes sind je nach Bitrate ganz verschiedene Sekunden")
    func sekundenHaengenAnDerBitrate() {
        let stufe = Pufferstufe.normal
        let serie = stufe.ungefaehrSekunden(bitsJeSekunde: 5_000_000)
        let vierK = stufe.ungefaehrSekunden(bitsJeSekunde: 80_000_000)
        #expect(serie != nil && vierK != nil)
        #expect(serie! > 20 && serie! < 30)
        #expect(vierK! < 3)
    }

    @Test("Ohne Bitrate keine erfundene Zahl")
    func ohneBitrateNil() {
        #expect(Pufferstufe.schlecht.ungefaehrSekunden(bitsJeSekunde: 0) == nil)
    }

    @Test("Die hoechste Stufe traegt auch bei 4K ueber eine halbe Minute")
    func sehrSchlechtTraegtAuchBei4K() {
        let s = Pufferstufe.sehrSchlecht.ungefaehrSekunden(bitsJeSekunde: 40_000_000)
        #expect(s != nil && s! >= 30)
    }
    /// **Die Benennung lag zuerst in der iPhone-Ansicht.** Dort haette der
    /// Fernseher sie nicht gesehen und nachgebaut — deshalb steht sie im
    /// Paket, und deshalb prueft das hier jemand.
    @Test("Jede Stufe hat einen eigenen Namen")
    func namenSindDaUndVerschieden() {
        let namen = Pufferstufe.allCases.map(\.name)
        #expect(namen.allSatisfy { !$0.isEmpty })
        #expect(Set(namen).count == Pufferstufe.allCases.count)
    }

}
