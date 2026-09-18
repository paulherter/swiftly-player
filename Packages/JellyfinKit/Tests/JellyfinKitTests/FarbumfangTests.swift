import Foundation
import Testing
@testable import JellyfinKit

@Suite("Farbumfang")
struct FarbumfangTests {

    @Test("Was HDR ist und was nicht")
    func istHDR() {
        #expect(Farbumfang.hdr10.istHDR)
        #expect(Farbumfang.hlg.istHDR)
        #expect(Farbumfang.dolbyVision.istHDR)
        #expect(Farbumfang.hdr10Plus.istHDR)
        #expect(!Farbumfang.sdr.istHDR)
        #expect(!Farbumfang.unbekannt.istHDR)
        // Dolby Vision **über** SDR ist kein HDR — der Name täuscht.
        #expect(!Farbumfang.dolbyVisionSDR.istHDR)
        #expect(!Farbumfang.dolbyVisionUngueltig.istHDR)
    }

    @Test("PQ und HLG sind nicht austauschbar")
    func kennlinie() {
        #expect(Farbumfang.hdr10.kennlinie == .pq)
        #expect(Farbumfang.hdr10Plus.kennlinie == .pq)
        #expect(Farbumfang.dolbyVision.kennlinie == .pq)
        #expect(Farbumfang.hlg.kennlinie == .hlg)
        #expect(Farbumfang.dolbyVisionHLG.kennlinie == .hlg)
        #expect(Farbumfang.sdr.kennlinie == nil)
        #expect(Farbumfang.unbekannt.kennlinie == nil)
    }

    @Test("Der Typ des Servers gilt zuerst")
    func typGiltZuerst() {
        #expect(Farbauskunft.umfang(typ: .hlg, kennlinie: "smpte2084",
                                    primaervalenzen: "bt2020") == .hlg)
    }

    @Test("Sagt der Typ nichts, tragen die rohen Angaben")
    func roheAngaben() {
        // Der Fall: eine Datei, die der Server nie analysiert hat.
        #expect(Farbauskunft.umfang(typ: .unbekannt, kennlinie: "smpte2084",
                                    primaervalenzen: "bt2020") == .hdr10)
        #expect(Farbauskunft.umfang(typ: nil, kennlinie: "arib-std-b67",
                                    primaervalenzen: nil) == .hlg)
    }

    @Test("Weite Primärvalenzen allein sind kein HDR")
    func bt2020IstKeinHDR() {
        // BT.2020 gibt es auch in SDR. Raten wäre schlimmer als lassen.
        #expect(Farbauskunft.umfang(typ: nil, kennlinie: nil,
                                    primaervalenzen: "bt2020") == .unbekannt)
    }

    @Test("Ohne jede Angabe wird nichts behauptet")
    func garnichts() {
        #expect(Farbauskunft.umfang(typ: nil, kennlinie: nil,
                                    primaervalenzen: nil) == .unbekannt)
    }

    @Test("Aus der Serverantwort gelesen")
    func ausJSON() throws {
        let roh = #"{"Type":"Video","Codec":"hevc","VideoRangeType":"HDR10","ColorTransfer":"smpte2084","ColorPrimaries":"bt2020"}"#
        let s = try JSONDecoder().decode(MediaStream.self, from: Data(roh.utf8))
        #expect(s.videoRangeType == .hdr10)
        #expect(s.colorTransfer == "smpte2084")
    }

    @Test("Eine unbekannte Schreibweise wirft nicht")
    func unbekannterWert() throws {
        // Jellyfin kann Werte ergaenzen; eine neue Fassung darf die App nicht
        // umbringen.
        let roh = #"{"Type":"Video","Codec":"hevc","VideoRangeType":"HDR42"}"#
        // **`try`, nicht `try?`.** Mit `try?` wuerde dieser Test auch dann
        // gruen, wenn das Einlesen ganz scheitert — und genau das waere der
        // Fehler: ein neuer Wert wuerde `MediaStream` unlesbar machen und die
        // Datei haette gar keine Angaben mehr.
        let s = try JSONDecoder().decode(MediaStream.self, from: Data(roh.utf8))
        #expect(s.codec == "hevc", "der Rest muss trotzdem ankommen")
        #expect(s.videoRangeType == nil)
    }
}
