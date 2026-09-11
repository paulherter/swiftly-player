import Testing
@testable import JellyfinKit

@Suite("Beschreibung")
struct BeschreibungTests {

    @Test("Umbrueche werden zu Zeilen, in jeder Schreibweise")
    func umbrueche() {
        #expect(Beschreibung.lesbar("Eins<br>Zwei<BR/>Drei<br />Vier") == "Eins\nZwei\nDrei\nVier")
    }

    @Test("Absaetze werden zu einer Leerzeile")
    func absaetze() {
        #expect(Beschreibung.lesbar("<p>Eins</p><p>Zwei</p>") == "Eins\n\nZwei")
    }

    @Test("Hervorhebungen fallen weg, der Text bleibt")
    func hervorhebungen() {
        #expect(Beschreibung.lesbar("<i>Kursiv</i> und <b>fett</b>") == "Kursiv und fett")
    }

    @Test("Zeichen werden aufgeloest, benannt und als Zahl")
    func zeichen() {
        #expect(Beschreibung.lesbar("Tom &amp; Jerry &quot;Klassiker&quot; &#39;99 &#x2013; neu &#8230;")
                == "Tom & Jerry \"Klassiker\" '99 – neu …")
    }

    @Test("Einmal aufgeloest, nicht zweimal")
    func einmal() {
        #expect(Beschreibung.lesbar("&amp;lt;br&amp;gt;") == "&lt;br&gt;")
    }

    @Test("Ein Kleiner-als im Text ist keine Marke")
    func vergleiche() {
        #expect(Beschreibung.lesbar("5 < 6 und 7 > 3") == "5 < 6 und 7 > 3")
    }

    @Test("Hoechstens eine Leerzeile am Stueck")
    func leerzeilen() {
        #expect(Beschreibung.lesbar("A<br><br><br><br>B") == "A\n\nB")
    }

    @Test("Geschuetzte Leerzeichen werden normale — sonst bricht nichts um")
    func geschuetzteLeerzeichen() {
        #expect(Beschreibung.lesbar("Ein&#160;langer\u{00A0}Satz&nbsp;hier") == "Ein langer Satz hier")
        #expect(!Beschreibung.lesbar("a&#160;b\u{202F}c").contains("\u{00A0}"))
    }

    @Test("Schlichter Text bleibt, wie er ist")
    func schlicht() {
        let text = "Ein Berater des CBI nutzt seine Beobachtungsgabe, um Mordfälle zu lösen."
        #expect(Beschreibung.lesbar("  \(text)\n") == text)
    }
}
