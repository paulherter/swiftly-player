import Foundation
import Testing
@testable import JellyfinKit

/// **G3, Kehrseite: ein Bild gehoert keinem Konto.**
@Suite("Schluessel des Bildspeichers")
struct BildschluesselTests {

    @Test("Das Zugangsmerkmal faellt aus dem Schluessel")
    func ohneMerkmal() throws {
        let url = try #require(URL(string:
            "https://tv.example.de/Items/abc/Images/Primary?tag=xyz&maxHeight=450&ApiKey=GEHEIM"))
        let s = Bildschluessel.fuer(url)
        #expect(!s.contains("GEHEIM"))
        // **`tag` bleibt.** Er ist Jellyfins Fingerabdruck; ohne ihn faellt
        // eine geaenderte Fassung des Bildes nicht mehr auf.
        #expect(s.contains("tag=xyz"))
        #expect(s.contains("maxHeight=450"))
        #expect(s.contains("/Items/abc/Images/Primary"))
    }

    @Test("Auch die kleingeschriebene Fassung")
    func kleinGeschrieben() throws {
        let url = try #require(URL(string: "https://x.de/i?api_key=G&tag=1"))
        #expect(!Bildschluessel.fuer(url).contains("G"))
    }

    /// **Zwei Konten, dasselbe Plakat, ein Schluessel.** Sonst waere der
    /// Speicher nach jedem Wechsel kalt.
    @Test("Zwei Konten ergeben denselben Schluessel")
    func zweiKonten() throws {
        let a = try #require(URL(string: "https://x.de/i?tag=1&ApiKey=AAA"))
        let b = try #require(URL(string: "https://x.de/i?tag=1&ApiKey=BBB"))
        #expect(Bildschluessel.fuer(a) == Bildschluessel.fuer(b))
    }

    @Test("Eine Adresse ohne Merkmal bleibt, wie sie ist")
    func ohneAbfrage() throws {
        let url = try #require(URL(string: "https://x.de/i"))
        #expect(Bildschluessel.fuer(url) == "https://x.de/i")
    }
}
