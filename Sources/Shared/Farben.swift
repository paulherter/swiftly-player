import SwiftUI

/// Die Farben — das einzige Stück Erscheinungsbild, das beide Plattformen
/// wörtlich teilen.
///
/// Maße und Schriftgrößen stehen bewusst **nicht** hier: iPhone und Apple TV
/// haben nichts gemeinsam, was Abstände angeht. Ein Poster misst auf dem
/// iPhone 112 × 168 und auf dem Fernseher 208 × 312, und eine Zeile, die auf
/// Armlänge mit 15 Punkt lesbar ist, braucht über drei Meter 29. Jede
/// Plattform erweitert `Stil` deshalb um ihre eigenen Werte —
/// `Sources/iOS/Stil.swift` und `Sources/tvOS/Stil.swift`.
///
/// Die Farben dagegen sind Entfernung egal. Sie liegen einmal hier, damit sie
/// nicht auseinanderlaufen.
enum Stil {

    // MARK: Die drei Tiefen
    //
    // **Gemessen aus Plex, nicht gewaehlt.** Rückmeldung vom 21.09.: „ich habe mich
    // doch gegen OLED entschieden, wir sollten das machen wie Plex — die haben
    // das farblich ganz gut." Die Werte sind aus seinen Bildschirmfotos
    // ausgezaehlt, Bildpunkt fuer Bildpunkt, nicht nachempfunden:
    //
    //     Startseite, Grund      #101010   (34 567 Treffer)
    //     Bibliothekspillen      #1C1C1C
    //     Einstellungen, Grund   #101010   (54 643 Treffer)
    //     Einstellungszeilen     #1E1E1F
    //
    // Zwei Dinge stehen darin, die man sich nicht ausdenkt.
    //
    // **Erstens: ein Grund, ueberall derselbe.** Plex faehrt #101010 auf der
    // Startseite *und* in den Einstellungen. Der `gruppengrund`, der hier
    // gestern fuer Kartenseiten entstand, faellt damit weg — er loeste ein
    // Problem, das nur reines Schwarz hat. #101010 liegt auf OKLCH L 0,1730,
    // und der Sprung zur Karte ist 0,0534 statt der ganzen Strecke von 0,2443.
    //
    // **Zweitens: echt neutral.** C = 0,000, R = G = B. Hier standen erst
    // 285,9 Grad (das las sich roetlich), dann die Hue des Akzents (das las
    // sich gruenstichig), dann Apples Spur Blau. Plex traegt gar keine — und
    // das ist die richtige Antwort fuer einen Player, dessen Flaechen gross
    // und dessen Inhalt bunt ist.
    //
    // Reines Schwarz bleibt, wo es hingehoert: hinter dem Bild im Player.
    static let grund   = Color(red: 0.063, green: 0.063, blue: 0.063)   // #101010
    /// **Jede Flaeche, die man anfassen kann** — Einstellungskarte, Blatt,
    /// Knopf unter dem Abspielknopf, Staffelknopf, Eingabefeld.
    ///
    /// Sie **sahen** identisch aus und waren es nicht: Knoepfe und
    /// Staffelknopf trugen `erhoeht`, die Karten `flaeche` — zwei Toene mit
    /// einem Abstand knapp unter der Wahrnehmungsschwelle. Das ist die
    /// schlechteste Sorte Unterschied: er kostet eine Entscheidung je
    /// Aufrufstelle und zahlt nichts zurueck. Jetzt tragen sie alle diesen.
    /// **Heller als Plex' eigener Kartenton, und mit Grund.**
    ///
    /// Gemessen war Plex bei #1C1C1C. Das sitzt dort auf grossen, ruhigen
    /// Bloecken — bei uns traegt derselbe Ton die **Knoepfe** unter dem
    /// Abspielknopf, und die sind klein und stehen neben einem gefuellten
    /// Hauptknopf. Ein kleiner Gegenstand braucht mehr Abstand zum Grund als
    /// ein grosser, um sich als Gegenstand zu lesen. Rückmeldung vom 21.09.: „die
    /// Buttons und so sind noch zu dunkel."
    ///
    /// #262626 verdoppelt den Sprung zum Grund fast (0,0956 statt 0,0534) und
    /// ist zugleich die Obergrenze: eine Stufe hoeher faellt
    /// `schriftSehrLeise` darauf unter 4,5.
    static let flaeche = Color(red: 0.149, green: 0.149, blue: 0.149)   // #262626
    /// **Der Grund einer Gruppe auf einer Einstellungsseite.**
    ///
    /// `flaeche` traegt Knoepfe — kleine Gegenstaende, die sich vom Grund
    /// abheben muessen, um als Gegenstand zu lesen. Eine Einstellungskarte ist
    /// das Gegenteil: ein grosser, ruhiger Block, und derselbe Ton wirkt
    /// darauf deutlich heller, weil die Flaeche gross ist. Rückmeldung vom 22.09.:
    /// „die Kacheln in den Settings sind ein Stueck zu hell, das ist zu doller
    /// Kontrast."
    ///
    /// Der Sprung zum Grund ist damit 0,062 statt 0,096 — knapp zwei Drittel.
    /// Die Zeilen darin bleiben lesbar: `schriftSehrLeise` traegt 5,78.
    static let gruppenflaeche = Color(red: 0.118, green: 0.118, blue: 0.118)  // #1E1E1E

    /// **Die acht Toene der Profilzeichen.**
    ///
    /// Sie sind die eine Stelle, an der die App mehr als eine Farbe traegt,
    /// und das hat einen Grund: ein Profilzeichen steht fuer einen Menschen.
    /// Grau sah aus wie eine Liste, die nicht fertig geladen hat.
    ///
    /// Acht Hues im Abstand von 45 Grad, der erste ist der des Akzents. Alle
    /// mit **derselben Helligkeit und Saettigung**, damit keiner lauter ist
    /// als der andere — OKLCH L 0,52 / C 0,105 oben, L 0,36 / C 0,085 unten.
    /// Weiss darauf traegt zwischen 5,13 und 5,84.
    ///
    /// Sie zaehlen nicht als semantische Farben: sie sagen nichts ueber einen
    /// Zustand, sie unterscheiden nur Personen.
    static let profiltoene: [(oben: Color, unten: Color)] = [
        (Color(red: 0.000, green: 0.478, blue: 0.498), Color(red: 0.000, green: 0.290, blue: 0.306)),
        (Color(red: 0.157, green: 0.431, blue: 0.631), Color(red: 0.020, green: 0.255, blue: 0.400)),
        (Color(red: 0.404, green: 0.369, blue: 0.631), Color(red: 0.235, green: 0.204, blue: 0.404)),
        (Color(red: 0.553, green: 0.314, blue: 0.510), Color(red: 0.341, green: 0.165, blue: 0.314)),
        (Color(red: 0.612, green: 0.302, blue: 0.318), Color(red: 0.384, green: 0.157, blue: 0.169)),
        (Color(red: 0.573, green: 0.353, blue: 0.106), Color(red: 0.357, green: 0.192, blue: 0.000)),
        (Color(red: 0.431, green: 0.427, blue: 0.078), Color(red: 0.255, green: 0.251, blue: 0.000)),
        (Color(red: 0.180, green: 0.478, blue: 0.298), Color(red: 0.039, green: 0.290, blue: 0.153)),
    ]
    /// **Was auf einer `flaeche` liegt** — ein Chip in einer Karte, ein
    /// gewaehlter Filterchip, der Druck auf eine Zeile. Nicht das, was auf der
    /// Seite liegt: das ist `flaeche`.
    static let erhoeht = Color(red: 0.188, green: 0.188, blue: 0.188)   // #303030

    /// **Volle Werte, keine Deckkraft.** Deckkraft aendert ihre Wirkung, sobald
    /// etwas anderes darunter liegt — ueber einem Plakat wurde aus „leise"
    /// „unlesbar".
    ///
    /// Gerechnet auf `grund`: 19,03 / 11,85 / 6,60. Auf `flaeche` 15,13 /
    /// 9,42 / 5,25, auf `erhoeht` 13,58 / 8,22 / 4,58.
    ///
    /// **Die leiseste Stufe ist Apples `systemGray`, unveraendert.** Genau
    /// dieser Ton steht in den Bildern unter „Deine Mediathek ist leer" und
    /// neben „Film · Action · 2025". Dass er auf `erhoeht` bei 4,27 liegt und
    /// damit knapp unter 4,5: Apples eigener `secondaryLabel` liegt dort bei
    /// 4,22, also liefert Apple diese Paarung selbst aus. Auf `grund` und
    /// `flaeche`, wo er fast immer steht, traegt er 6,44 und 5,22.
    ///
    /// `schriftLeise` ist die Zwischenstufe, die Apple nicht hat: dort gibt es
    /// nur `label` und `secondaryLabel` plus einen Platzhalterton. Unsere
    /// Ansichten haben drei Raenge, also braucht es einen dazwischen — Weiss
    /// mit 80 Prozent, fest ausgerechnet.
    static let schrift          = Color(red: 1.000, green: 1.000, blue: 1.000)  // #FFFFFF
    static let schriftLeise     = Color(red: 0.800, green: 0.800, blue: 0.800)  // #CCCCCC

    /// **0,48 und nicht 0,38 — bei 0,38 war es zu blass, um es zu lesen.**
    ///
    /// Ausgerechnet, nicht geschaetzt. Weiss mit 0,38 Deckkraft ergibt gegen
    /// die drei Untergruende dieser App Kontraste von 3,52 (`grund`), 3,58
    /// (`flaeche`) und 3,54 (`erhoeht`). Gefordert sind fuer Text unter 18 pt
    /// **4,5** — und dieser Ton traegt genau solchen Text: Nebenzeilen,
    /// Hinweise, Leerzustaende, quer durch alle sechs Fassungen bei 12 bis
    /// 13 pt.
    ///
    /// 0,46 haette gereicht (4,67 / 4,65 / 4,54), liegt aber auf `erhoeht`
    /// nur vier Hundertstel ueber der Schwelle — eine Nachkommastelle
    /// Rundung, und wir waeren wieder darunter.
    ///
    /// Als voller Wert traegt er 6,60 / 5,25 / 4,58 und bleibt deutlich hinter
    /// `schriftLeise` (11,85) zurueck: die Abstufung bleibt sichtbar. Auf
    /// `erhoeht` ist 4,58 der engste Fall der App und liegt ueber 4,5. Er ist
    /// mit den Flaechen mitgewandert: auf dem alten #8E8E8E waere er dort auf
    /// 4,00 gefallen. Wer die Flaechen anhebt, hebt die leisen Schriften mit.
    ///
    /// Der Ton traegt auch Zeichen und Kreise, die keine 4,5 braeuchten. Die
    /// werden dadurch eine Spur heller — kein Verlust, und es waere die
    /// falsche Reihenfolge, achtundachtzig Aufrufstellen einzeln zu sortieren,
    /// um einem Zeichen sein Grau zu erhalten.
    /// Neutral wie der Rest der Leiter — Apples #8E8E93 traegt eine Spur
    /// Blau, und neben einem Grund ohne jedes Chroma faellt sie auf.
    static let schriftSehrLeise = Color(red: 0.596, green: 0.596, blue: 0.596)  // #989898
    /// **Zurueck auf 7 und 12 Prozent.**
    ///
    /// Sie standen kurz auf 20 und 22, hochgerechnet aus Apples `separator`
    /// (#545458 mit 60 Prozent, ueber Schwarz #323235 — das entspricht Weiss
    /// mit rund 20). Die Rechnung stimmt, die Uebertragung nicht: Apples
    /// Trenner ist eine **feste Farbe mit Alpha**, unserer eine
    /// **Weiss-Deckkraft**. Ueber Schwarz landen beide gleich; ueber der
    /// Karte (`flaeche`) landet Apples bei #3E3E41 und unserer bei #49494B.
    /// In den Einstellungen liegen fast alle Linien auf einer Karte, und
    /// genau dort sah man es: Rückmeldung vom 21.09. — „die Striche sind so ultra
    /// hell jetzt, die Kontraste passen nicht mehr im Vergleich zu vorher."
    ///
    /// Bei 12 Prozent ueber der Karte kommt #373739 heraus und damit fast
    /// genau Apples Wert. Die 7 fuer `linie` bleiben, wo sie waren.
    ///
    /// Als Deckkraft und nicht als fester Wert, weil beide auch ueber Plakaten
    /// liegen — dort soll die Linie mit dem Bild gehen, nicht als grauer
    /// Strich darauf stehen.
    static let linie            = Color.white.opacity(0.07)
    static let rand             = Color.white.opacity(0.12)

    /// **Die Flaeche einer gewaehlten oder laufenden Zeile: acht Prozent.**
    ///
    /// Gewaehlt heisst Weiss und Gewicht, nicht Farbe — und dort, wo eine
    /// ganze Zeile gemeint ist, sagt eine leise Flaeche dasselbe, ohne den
    /// Akzent zu verbrauchen. Sie stand an drei Stellen als roher Wert.
    static let gewaehlt         = Color.white.opacity(0.08)

    /// **Die Flaeche eines gedrueckten Sekundaerknopfs.**
    ///
    /// Hier stand einmal `erhoeht.opacity(1.6)` — Deckkraft ueber 1 klemmt auf
    /// 1,0, und `erhoeht` ist deckend: der Druck war unsichtbar. Das ist
    /// dieselbe Farbe, eine Stufe heller, und zwar als eigener Wert, damit es
    /// niemand wieder ueber die Deckkraft versucht.
    /// **Nur volle Schrift darauf.** Gerechnet: `schrift` 11,38:1,
    /// `schriftSehrLeise` nur **3,94:1** — fuer Text zu wenig (4,5 ist die
    /// Grenze), fuer ein Bedienzeichen gerade ueber 3. Hier stand 2,74; das
    /// war zu pessimistisch und damit als Warnung wertlos, weil die echte
    /// Zahl knapper daneben liegt. Heute trifft der Fall nicht zu: leise
    /// Schrift traegt allein der **gesperrte** Nebenknopf, und ein gesperrter
    /// Knopf bekommt kein `isPressed`. Wer hier spaeter leise Schrift in einen
    /// bedienbaren Zustand setzt, soll die Zahl gelesen haben.
    static let gedruecktFlaeche = Color(red: 0.227, green: 0.227, blue: 0.227)  // #3A3A3A

    /// Trägt nur Fortschritt, Auswahl und den Direct-Play-Beleg — nie
    /// Flächen oder Knöpfe. Bewusst weder Plex-Orange noch Netflix-Rot.
    ///
    /// Auf tvOS trägt er zusätzlich den Fokusring — das ist dieselbe Regel,
    /// nicht ihre Aufweichung: der Ring zeigt eine Auswahl.
    static let akzent  = Color(red: 0.314, green: 0.835, blue: 0.855)   // #50D5DA

    /// **Der Akzent, aufgehellt — der fokussierte Schalter auf dem
    /// Fernseher.** Sonst nirgends: auf dem iPhone gibt es keinen Fokus, und
    /// der Druckzustand laeuft ueber Flaeche und Massstab, nicht ueber eine
    /// zweite Akzentfarbe. (`akzentTief` stand als Gegenstueck daneben und
    /// wurde nie benutzt — heraus damit.)
    static let akzentHell = Color(red: 0.478, green: 0.902, blue: 0.918)  // #7AE6EA
    /// Die Flaeche unter Akzentschrift — Plaketten tragen 15 Prozent, dieser
    /// Wert ist derselbe Ton schon ausgerechnet.
    static let akzentLeise = Color(red: 0.067, green: 0.204, blue: 0.208)  // #113435
    /// Schrift auf einer Akzentflaeche.
    static let aufAkzent = Color(red: 0.024, green: 0.071, blue: 0.071)   // #061212

    /// **Gestrichen am 21.09.2026: `kuehl` und `scheinMitte`.**
    ///
    /// `kuehl` (#7E9BFF) trug, was auf einem anderen Geraet passiert — das
    /// Angebot „hier weiterschauen", die Fernsteuerung —, und `scheinMitte`
    /// (#6EB4E1) war der Stuetzpunkt, der den Farbschein der Startseite von
    /// Tuerkis nach Blau fuehrte.
    ///
    /// Beide sind weg, weil die Regel eindeutiger ist als die Unterscheidung
    /// war: **der Akzent traegt Zustand, und „laeuft woanders" ist einer.**
    /// Unterschieden wird ueber das Zeichen — ein Geraetesymbol sagt
    /// „woanders" deutlicher als ein zweiter Blauton. Der Schein laeuft
    /// seitdem in einem Ton von 0,22 auf 0,14; seine Tiefe kommt aus der
    /// Menge, nicht aus einem Farbwechsel.

    static let warnung = Color(red: 0.910, green: 0.514, blue: 0.227)   // #E8833A

    /// **Etwas ist schiefgegangen — und das ist nicht dasselbe wie „wartet".**
    ///
    /// Der Token stand in der Vorlage und fehlte im Code: Anmeldefehler,
    /// gescheiterte Downloads und die Umrechnungswarnung trugen alle
    /// `warnung`. Zwei Bedeutungen in einer Farbe ist genau die Verwechslung,
    /// die fuenf semantische Farben vermeiden sollen. Gerechnet auf `grund`:
    /// 6,30:1.
    static let fehler  = Color(red: 0.937, green: 0.396, blue: 0.404)   // #EF6567
}
