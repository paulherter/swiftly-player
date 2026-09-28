import Foundation
import Testing
@testable import JellyfinKit

@Suite struct VorpufferTests {
    @Test func erstGegenEnde() {
        #expect(!Vorpuffer.jetzt(position: 1000, dauer: 2600, abspannVon: nil, netzGuenstig: true))
        #expect(Vorpuffer.jetzt(position: 2600 - Vorpuffer.restsekunden, dauer: 2600,
                                abspannVon: nil, netzGuenstig: true))
    }

    @Test func abDemAbspann() {
        #expect(Vorpuffer.jetzt(position: 2300, dauer: 2600, abspannVon: 2290, netzGuenstig: true))
        #expect(!Vorpuffer.jetzt(position: 2280, dauer: 2600, abspannVon: 2290, netzGuenstig: true))
    }

    @Test func nichtUeberTeuresNetz() {
        #expect(!Vorpuffer.jetzt(position: 2550, dauer: 2600, abspannVon: nil, netzGuenstig: false))
    }

    @Test func nichtBeiKurzenTiteln() {
        #expect(!Vorpuffer.jetzt(position: 200, dauer: 240, abspannVon: nil, netzGuenstig: true))
        #expect(!Vorpuffer.jetzt(position: .nan, dauer: 2600, abspannVon: nil, netzGuenstig: true))
    }

    @Test func planVerfaellt() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(Vorpuffer.frisch(vorbereitet: t, jetzt: t.addingTimeInterval(60)))
        #expect(!Vorpuffer.frisch(vorbereitet: t, jetzt: t.addingTimeInterval(Vorpuffer.haltbarkeit)))
    }

    @Test func anfangNurBeiDirectPlayUebersNetz() {
        let netz = URL(string: "https://server.example/Videos/1/stream.mkv?static=true")!
        #expect(Vorpuffer.anfangLaden(adresse: netz, methode: .directPlay))
        #expect(!Vorpuffer.anfangLaden(adresse: netz, methode: .transcode))
        #expect(!Vorpuffer.anfangLaden(adresse: URL(fileURLWithPath: "/tmp/a.mkv"), methode: .directPlay))
    }
}
