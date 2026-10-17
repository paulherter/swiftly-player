import Testing
@testable import JellyfinKit

@Suite("Beschreibung")
struct DescriptionTests {

    @Test("Umbrueche werden zu Zeilen, in jeder Schreibweise")
    func breaks() {
        #expect(Description.readable("Eins<br>Zwei<BR/>Drei<br />Vier") == "Eins\nZwei\nDrei\nVier")
    }

    @Test("Absaetze werden zu einer Leerzeile")
    func paragraphs() {
        #expect(Description.readable("<p>Eins</p><p>Zwei</p>") == "Eins\n\nZwei")
    }

    @Test("Hervorhebungen fallen weg, der Text bleibt")
    func highlights() {
        #expect(Description.readable("<i>Kursiv</i> und <b>fett</b>") == "Kursiv und fett")
    }

    @Test("Zeichen werden aufgeloest, benannt und als Zahl")
    func symbolText() {
        #expect(Description.readable("Tom &amp; Jerry &quot;Klassiker&quot; &#39;99 &#x2013; neu &#8230;")
                == "Tom & Jerry \"Klassiker\" '99 – neu …")
    }

    @Test("Einmal aufgeloest, nicht zweimal")
    func inTimes() {
        #expect(Description.readable("&amp;lt;br&amp;gt;") == "&lt;br&gt;")
    }

    @Test("Ein Kleiner-als im Text ist keine Marke")
    func compare() {
        #expect(Description.readable("5 < 6 und 7 > 3") == "5 < 6 und 7 > 3")
    }

    @Test("Hoechstens eine Leerzeile am Stueck")
    func emptyRows() {
        #expect(Description.readable("A<br><br><br><br>B") == "A\n\nB")
    }

    @Test("Geschuetzte Leerzeichen werden normale — sonst bricht nichts um")
    func protectedEmptyCharacter() {
        #expect(Description.readable("Ein&#160;langer\u{00A0}Satz&nbsp;hier") == "Ein langer Satz hier")
        #expect(!Description.readable("a&#160;b\u{202F}c").contains("\u{00A0}"))
    }

    @Test("Schlichter Text bleibt, wie er ist")
    func plain() {
        let text = "Ein Berater des CBI nutzt seine Beobachtungsgabe, um Mordfälle zu lösen."
        #expect(Description.readable("  \(text)\n") == text)
    }
}
