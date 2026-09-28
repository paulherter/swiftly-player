import SwiftUI
import JellyfinKit

/// Maße, Schriftgrößen und Grundformen für den Mac.
///
/// Die Farben stehen in `Sources/Shared/Farben.swift` und sind mit iPhone und
/// Fernseher identisch. Alles hier ist neu, und zwar aus genau zwei Gründen:
/// **Zeiger statt Finger** und **Fenster statt Bildschirm**.
///
/// Die Schriftstufen bleiben dieselben wie auf dem iPhone — 28 / 20 / 16 / 15
/// / 14 / 12 / 10. Ein Mac steht kaum weiter weg als ein Telefon in der Hand;
/// was sich ändert, ist die Fläche, nicht die Leseentfernung. Übernommen
/// bleiben auch alle Seitenverhältnisse: Poster 2 : 3, Querkachel 16 : 9.
/// Nur die absoluten Werte wachsen mit.
extension Stil {
    /// Dieselbe Haarlinie wie auf dem iPhone, damit die geteilten Bausteine sie
    /// hier auch finden. Auf dem Mac gibt es sie als Baustein noch nicht;
    /// `Divider().overlay(Stil.linie)` war die Handfassung davon.

    /// **Dieselben Namen wie auf dem iPhone**, damit die geteilten Bausteine in
    /// `Sources/Shared` sie hier auch finden. Die Werte sind die dieser
    /// Plattform; die Rolle ist dieselbe.
    static var bewegungReduziert: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Mit reduzierter Bewegung die kurze Blende statt der Bewegung — derselbe
    /// Wert wie auf dem iPhone, für die geteilten Teile (Folgenkarte,
    /// Bildfarbe).
    static let blendeReduziert: Animation = .linear(duration: 0.14)

    /// **Die kleine Ecke, fuer Dinge unter 34 Punkt Hoehe.** Die Ecke waechst
    /// mit dem Ding: 10 auf 48 Hoehe sind 0,21, und dasselbe Verhaeltnis ergibt
    /// auf 30 Hoehe die 8. Am Fernseher ist alles verdoppelt, dort also 16.
    static let eckeKlein: CGFloat = 8

    // MARK: - Rueckmeldung auf den Druck

    /// **Dieselben zwei Stile wie auf dem iPhone**, damit die geteilten
    /// Bausteine in `Sources/Shared` sie hier auch finden. Eine Zeile bekommt
    /// eine Flaeche, ein Knopf wird kleiner — jeder Knopf antwortet auf den
    /// Druck, das steht in `Notizen/BRAND.md`, Abschnitt 5.
    struct Druckzeile: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Rumpf(gedrueckt: configuration.isPressed) { configuration.label } }

        private struct Rumpf<Inhalt: View>: View {
            let gedrueckt: Bool
            @ViewBuilder let inhalt: Inhalt
            @Environment(\.isFocused) private var fokussiert

            var body: some View {
                inhalt
                    .background(Stil.schwebeflaeche.opacity(gedrueckt || fokussiert ? 1 : 0),
                                in: RoundedRectangle(cornerRadius: Stil.ecke,
                                                     style: .continuous))
                    .animation(Stil.druckkurve(gedrueckt), value: gedrueckt)
                    .animation(Stil.zeitSchweben, value: fokussiert)
            }
        }
    }

    struct Druckknopf: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Rumpf(gedrueckt: configuration.isPressed) { configuration.label } }

        private struct Rumpf<Inhalt: View>: View {
            let gedrueckt: Bool
            @ViewBuilder let inhalt: Inhalt
            @Environment(\.isFocused) private var fokussiert

            var body: some View {
                inhalt
                    .scaleEffect(gedrueckt && !Stil.bewegungReduziert ? 0.97 : 1)
                    .opacity(gedrueckt ? 0.85 : 1)
                    // **Wo die Tastatur steht.** In ganz `Sources/macOS`
                    // stand kein einziger Fokuszustand: mit „Vollzugriff
                    // ueber Tastatur" lief man blind durch das Fenster, weil
                    // unsere eigenen Knopfstile den Systemring verdecken und
                    // selbst nur den Schwebezustand kannten — und der haengt
                    // an der Maus.
                    //
                    // Kein Ring (BRAND 5), sondern dieselbe Flaeche wie beim
                    // Schweben: dasselbe Zeichen fuer „hier bist du", einmal
                    // mit dem Zeiger, einmal mit der Tastatur.
                    //
                    // **Als eigene Ansicht und nicht als `@Environment` im
                    // Stil selbst**: ein `ButtonStyle` ist keine `View`, und
                    // Umgebungswerte darin werden nie aktualisiert.
                    .background(Stil.schwebeflaeche.opacity(fokussiert ? 1 : 0),
                                in: RoundedRectangle(cornerRadius: Stil.ecke,
                                                     style: .continuous))
                    .animation(Stil.druckkurve(gedrueckt), value: gedrueckt)
                    .animation(Stil.zeitSchweben, value: fokussiert)
            }
        }
    }

    /// **Die Flaeche, ueber der der Zeiger steht.** Weiss mit 6 Prozent, und
    /// zwar als ein Wert: sie stand an neun Stellen als Zahl im Aufruf. Der
    /// Schwebezustand ist die eine Sache, die es nur auf dem Mac gibt
    /// (BRAND 5), und er sagt „hier steht der Zeiger" — keine Auswahl.
    static let schwebeflaeche = Color.white.opacity(0.06)

    // MARK: - Bewegung
    //
    // **Dieselben Namen und dieselben Zahlen wie auf dem iPhone** (BAUTEILE
    // 5). Sie standen hier teils als `zeit...`, teils gar nicht — und die
    // `.linear(0.14)`-Fassung fuer „Bewegung reduzieren" stand viermal
    // woertlich im Code, ohne eigenen Namen.

    /// Was bei reduzierter Bewegung an die Stelle jeder Kurve tritt.
    static let linearReduziert = Animation.linear(duration: 0.14)

    /// Der Druck: sofort hinein, in 0,12 s heraus.
    static func druckkurve(_ gedrueckt: Bool) -> Animation? {
        gedrueckt ? nil : .easeOut(duration: 0.12)
    }

    /// Schalter und Haken — 0,10 s.
    static var umschalten: Animation {
        bewegungReduziert ? linearReduziert : .easeOut(duration: 0.10)
    }

    /// Tafel, Aufklappen, Handlungsliste — 0,22 s.
    static var sprung: Animation {
        bewegungReduziert ? linearReduziert : .snappy(duration: 0.22)
    }

    /// Wie stark der eintretende Bereich sich heranzieht.
    static var bereichsmass: CGFloat { bewegungReduziert ? 1 : bereichKleiner }


    // MARK: Fenster

    /// Kleinste Fenstergröße, unter der das Raster nicht mehr aufgeht:
    /// Seitenleiste plus zwei Kachelspalten plus Ränder.
    static let fensterMinBreite: CGFloat = 900
    static let fensterMinHoehe: CGFloat = 560

    /// **So breit wird eine Einstellungsseite hoechstens.**
    ///
    /// Die Seiten sind die des iPads: zwei Spalten, linksbuendig am Inhalt,
    /// nicht in der Mitte des Fensters. Dort zieht die Grenze das Geraet —
    /// 1366 Punkt im Querformat des groessten. Ein Fenster hat keine solche
    /// Grenze; ohne sie stuenden auf einem grossen Schirm zwei Karten zu je
    /// neunhundert Punkt nebeneinander, in denen der Schalter eine
    /// Handbreit vom Titel entfernt laege.
    static let einstellungBreite: CGFloat = 1366

    /// **Lesemass fuer eine einspaltige Unterseite.** Derselbe Wert wie in
    /// der iPhone- und iPad-Fassung (`Stil.lesebreite`): eine Zeile aus
    /// Symbol, Titel und einem Wert rechts, ueber die halbe Fensterbreite
    /// gezogen, laesst zwischen beiden Enden nichts als Luft.
    static let lesebreite: CGFloat = 700

    /// **So breit wird ein Formular** — Anmeldung, Serveraufnahme, Seerr.
    /// Derselbe Wert wie auf dem iPhone breit (BAUTEILE 4); er stand hier an
    /// drei Stellen als 380, 420 und 520.
    static let formularbreite: CGFloat = 420

    /// Platz für die Fensterampel — **nur in der Seitenleiste.**
    ///
    /// Die drei Punkte sitzen oben links im Fenster, also über der
    /// Seitenleiste. Sie enden bei rund 27; die Wortmarke bringt zudem
    /// eigene Luft mit, weil ihre Vorlage das Zeichen über dem „i" und die
    /// Unterlänge des „y" einschließt und die Buchstaben nur die halbe Höhe
    /// füllen. 40 reicht deshalb, wo vorher 52 standen.
    /// Wie weit von oben die Zone reicht, in der die Fensterampel im Player
    /// erscheint. Etwas grosszuegiger als die Ampel selbst, damit man sie
    /// nicht suchen muss.
    static let ampelzone: CGFloat = 90

    static let ampelHoehe: CGFloat = 40

    /// Oberer Rand im **Inhaltsbereich** — derselbe wie seitlich.
    ///
    /// Hier gibt es nichts freizuhalten: der Inhalt beginnt rechts der
    /// Seitenleiste, die Ampel liegt gar nicht darüber. Er stand trotzdem auf
    /// 52, also dem Doppelten des Seitenrandes. Rückmeldung vom 22.09.: „jetzt ist
    /// oben der Headspace einfach riesig, da ist so ein Riesenabstand von oben
    /// bis zu der Kategorie. Mach, dass der Abstand nach oben genauso ist wie
    /// der Abstand nach links, so dass es konsistent ist."
    ///
    /// Also derselbe Wert, und zwar als **derselbe** Wert und nicht als
    /// zweite 24: wer den Seitenrand ändert, ändert den oberen mit.
    static let inhaltOben: CGFloat = randAbstand

    /// **Die Leiste, die beim Scrollen kommt** (`Bestandsleiste`).
    ///
    /// 40, nicht `inhaltOben`: sie muss eine 17-Punkt-Zeile und den 40 Punkt
    /// hohen Rückpfeil tragen, und sie ist bewusst kürzer als der obere Rand
    /// des ruhenden Inhalts — sie soll eine Leiste sein, kein zweiter Kopf.
    static let kopfleisteHoehe: CGFloat = 40


    /// Höhe der Kopfleiste einer Detailseite (Pfeil und einblendender Titel).
    static let titelHoehe: CGFloat = 52

    static let seitenleisteBreite: CGFloat = 220

    // MARK: Maße

    /// **Die Eckenskala.** Dieselbe Regel wie auf dem iPhone (GESTALTUNG,
    /// Abschnitt B): je grösser die Fläche, desto runder — und Knopf und
    /// Kachel teilen sich die kleinste Stufe, weil beides kleine Gegenstände
    /// sind. Am 07.09.2026 gemeinsam um vier Punkte angehoben; vorher waren
    /// Knopf 6 und Plakat 8, und zwei Punkte Unterschied zwischen zwei
    /// Dingen, die nebeneinander stehen, liest man nicht als Rangfolge,
    /// sondern als Versehen.
    static let ecke: CGFloat = 10
    static let eckeKachel: CGFloat = 10
    static let eckeFeld: CGFloat = 12
    /// **Karte und Gruppe** — die Einstellungskarte, die Gruppe in einer
    /// Liste. Dieselbe 14 wie auf dem iPhone (BAUTEILE 3); sie fehlte hier
    /// und wurde an vier Stellen durch `eckeFlaeche` (16) vertreten.
    static let eckeKarte: CGFloat = 14
    /// Was eine eigene Fläche ist: Tafeln, Auskunftskästen.
    static let eckeFlaeche: CGFloat = 16
    /// **Das Blatt.** Auf dem Mac faehrt nichts von unten herein — die
    /// Handlungsliste klappt an Ort und Stelle auf. Der Wert steht trotzdem
    /// hier, damit ein geteilter Baustein ihn findet und niemand 28 als Zahl
    /// setzt.
    static let eckeBlatt: CGFloat = 28
    static let randAbstand: CGFloat = 24

    /// **Wo die Haarlinie in einer Einstellungskarte anfaengt.**
    ///
    /// Sie fluchtet mit dem Text, nicht mit der Kartenkante: 12 Innenabstand
    /// plus 20 Zeichenspalte plus 14 Abstand zum Text. Der Wert stand an
    /// dreiundzwanzig Stellen als 48 — gerechnet auf eine Zeichenspalte von
    /// 22, die es nicht mehr gibt.
    static let trennEinzugKarte: CGFloat = 46
    static let kachelAbstand: CGFloat = 12
    static let reihenAbstand: CGFloat = 28

    /// **Über welchen Scrollweg die Wertreihe zugeht** — 44, wie auf dem
    /// iPhone (BAUTEILE 4). Der Weg treibt nur Deckkraft, nie eine Höhe:
    /// sobald eine Kopfhöhe am Scrollversatz hängt, ändert sie den
    /// Sicherheitsrand, der in der Messung steckt, und der Kopf kommt nie
    /// zur Ruhe (BAUTEILE 10, erste Falle).
    static let wertreihenWeg: CGFloat = 44

    /// Poster, 2 : 3 — auf dem iPhone 112 × 168.
    static let kachelBreite: CGFloat = 150
    static let kachelHoehe: CGFloat = 225

    /// Weiterschauen liegt quer, 16 : 9 — auf dem iPhone 240 × 135.
    static let querBreite: CGFloat = 280
    static let querHoehe: CGFloat = 158

    /// Die Kopfzone der Detailseite.
    ///
    /// **Genau der Inhalt, keine Restluft**: 150 oben plus 230 Block.
    ///
    /// Die Luft liegt vollständig **oben**. Unten darf keine sein: der
    /// Abstand von der Knopfreihe zur ersten Überschrift soll derselbe sein
    /// wie zwischen allen anderen Abschnitten (26). Jede Restluft in dieser
    /// Zone käme dort obendrauf, und die Reihe „Besetzung" stünde weiter
    /// entfernt als „Ähnliches" von der Reihe darüber.
    static let heldHoehe: CGFloat = 380

    // MARK: Tippflächen — kleiner als auf dem iPhone

    /// Ein Zeiger trifft genauer als ein Finger. Apples eigene Seitenleisten
    /// stehen auf 28; 32 gibt der Schrift von 15 etwas mehr Luft.
    static let zeileHoehe: CGFloat = 32
    /// **Das Symbolfeld der Aktionsreihe** — auf dem iPhone 48 × 48.
    ///
    /// Hiess `knopfRund` und war ein Kreis mit Umriss. Ein Knopf ohne
    /// Beschriftung ist quadratisch (BRAND 7), und 40 statt 48 ist die eine
    /// erlaubte Abweichung: ein Zeiger trifft genauer als ein Finger.
    static let knopfFeld: CGFloat = 40
    /// Der Hauptknopf bleibt 48 hoch, aber **nicht** über die volle Breite:
    /// ein Zeiger trifft einen Knopf, ein Daumen braucht die Fläche.
    static let hauptknopfHoehe: CGFloat = 48

    /// **Feste Breite des Hauptknopfes.**
    ///
    /// Sonst richtet sich der ganze Rest der Reihe nach der Länge der
    /// Beschriftung, und Merkliste und Mehr stehen auf jeder Seite woanders.
    /// 200 trägt „Fortsetzen" wie „Abspielen" mit Luft.
    static let hauptknopfBreite: CGFloat = 200

    /// **Der Hauptknopf unter dem Zeiger.** Weiss auf 88 Prozent — die
    /// Zwischenstufe zwischen ruhend (voll) und gedrueckt (75, BAUTEILE 6).
    /// Sie stand als Zahl im Aufruf.
    static let hauptknopfSchwebt = Color.white.opacity(0.88)

    // MARK: Schrift — dieselbe Abstufung wie auf dem iPhone

    static let titelGross = Font.system(size: 28, weight: .bold)
    /// **Der Titel ueber einem Heldbild *ist* der Seitentitel.** Am Mac stand
    /// er auf 34 — eine eigene Stufe fuer dieselbe Rolle, und genau die ist
    /// in BRAND 2 gestrichen. Vorher trug dieser Name die 22 des
    /// Unterseitentitels; die heisst jetzt so, wie sie heisst.
    static let titel      = titelGross
    /// **Unterseitentitel**, 22 Semibold — derselbe Name wie auf dem iPhone.
    static let unterseitentitel = Font.system(size: 22, weight: .semibold)
    static let reihe      = Font.system(size: 20, weight: .semibold)
    /// Blattrubrik und Detailleiste.
    static let rubrikGross = Font.system(size: 17, weight: .semibold)
    /// Alter Name derselben Stufe. Bleibt, solange die Aufrufstellen ihn
    /// tragen.
    static let leiste     = rubrikGross
    static let listentitel = Font.system(size: 15, weight: .semibold)
    static let koerper    = Font.system(size: 15)
    /// Titel unter einem Plakat: 13, nicht 14 — 14 steht in keiner Leiter.
    static let kachel      = Font.system(size: 13, weight: .medium)
    /// Alter Name derselben Stufe.
    static let kachelTitel = kachel
    /// Angabe: Jahr, Rolle, Laufzeit.
    static let klein      = Font.system(size: 12)
    /// Alter Name derselben Stufe.
    static let zweitzeile = klein
    static let plakette   = Font.system(size: 10, weight: .semibold)
    /// Gruppentitel, 11 Semibold.
    static let gruppe     = Font.system(size: 11, weight: .semibold)
    /// Alter Name derselben Stufe.
    static let rubrik     = gruppe

    // MARK: Sperrung
    //
    // **Sie gehoert zur Stufe, nicht zur Fundstelle** (BAUTEILE 2). Jeder
    // Wert ist der em-Wert aus BRAND 2 mal der Punktgroesse — dieselben
    // Zahlen wie auf dem iPhone, denn Mac und iPhone tragen dieselbe Leiter.
    // Hier stand bisher nur `sperrungReihe`; die uebrigen vier standen als
    // Zahl im Aufruf oder fehlten ganz.

    /// 28 · −0,021 em
    static let sperrungTitel      = -0.6
    /// 22 · −0,014 em
    static let sperrungUnterseite = -0.308
    /// 20 · −0,012 em
    static let sperrungReihe      = -0.24
    /// 17 · −0,008 em
    static let sperrungRubrik     = -0.136
    /// 11 · +0,14 em
    static let sperrungGruppe     = 1.54
    /// 10 · +0,10 em
    static let plaketteSperrung: CGFloat = 1.0

    // MARK: Zeiten — wörtlich aus der iPhone-Fassung

    /// Der Schwebezustand — 0,12 s, dieselbe Zeit wie der Druck (BRAND 5).
    static let zeitSchweben   = Animation.easeOut(duration: 0.12)

    /// Die Blätterpfeile einer Reihe — kommen und gehen weich
    /// (`Blendzeiten.pfeile`), gleich auf Linux und Windows.
    static let zeitPfeile = Animation.easeInOut(duration: Blendzeiten.pfeile)

    // MARK: Seitenwechsel — drei Bewegungen, an drei Bedeutungen gebunden
    //
    // Vorher tat jede Stelle etwas anderes: der Bereichswechsel gar nichts,
    // der Phasenwechsel `.default`, der Player eine eigene Zeit. Von außen
    // sah das aus, als starte die App mal mit und mal ohne Animation.
    //
    // Die Regel: **Was die Bewegung bedeutet, bestimmt, wie sie aussieht.**
    //
    //   Ersetzen     Der Inhaltsbereich zeigt etwas anderes — Start gegen
    //                Filme, Anmeldung gegen Bibliothek. Nichts wandert,
    //                also blendet es über.
    //   Tiefer       Eine Ebene hinein: Detailseite, Einstellungen. Das
    //                schiebt von rechts, und den Weg zurück kennt man.
    //                Macht `NavigationStack` von sich aus.
    //   Aufsteigen   Der Player nimmt das ganze Fenster. Er kommt von unten
    //                und geht dorthin zurück — deshalb zeigt der Winkel oben
    //                links nach unten.

    /// Wie Inhalt erscheint, wenn er angekommen ist — dieselbe Kurve wie auf
    /// dem iPhone. **Nichts erscheint hart** (E18): Bilder blenden ein,
    /// Inhalt loest Platzhalter ab.
    static var einblenden: Animation {
        bewegungReduziert ? linearReduziert : .easeInOut(duration: 0.28)
    }

    // MARK: Der Wechsel in der Leiste — erst weg, dann da

    // **Keine Überblendung.** Das Alte geht zuerst, kurz und mit `easeIn`;
    // erst wenn es weg ist, kommt das Neue mit `easeOut`. Bis 27.09.2026
    // überlappten beide (0,20 s hinaus, 0,26 s herein ab 0,04 s), und in der
    // Mitte standen zwei halbe Seiten übereinander — das wirkt unsauber.
    // Dazu kamen Unschärfe und ein Hauch Zoom; beides ist raus, bewegt wird
    // nur die Deckkraft. Die Zahlen stehen im Paket (`Blendzeiten`), damit
    // Linux und Windows dieselben nehmen.

    /// Das Alte geht.
    static let zeitBereichHinaus = Animation.easeIn(duration: Blendzeiten.seiteHinaus)
    /// Das Neue kommt — erst danach, deshalb der Vorlauf in voller Länge.
    static let zeitBereichHerein = Animation.easeOut(duration: Blendzeiten.seiteHerein)
        .delay(Blendzeiten.seiteHinaus)

    /// Wie wenig ein Reiterinhalt beim Auftreten wächst (`bereichsmass`, im
    /// geteilten `Stil` benutzt) — 99,6 %, an der Fensterkante rund drei
    /// Punkte. Der Bereichswechsel selbst skaliert nicht mehr.
    static let bereichKleiner: CGFloat = 0.996

    /// Überblenden beim Ersetzen. 180 ms ease-out — dieselbe Zeit, in der auf
    /// dem iPhone die Player-Steuerung erscheint.
    static let zeitSeite = Animation.easeOut(duration: 0.18)

    /// Das Schieben beim Tiefergehen.
    ///
    /// **Nachgemessen, nicht geschätzt.** Der Verlauf wurde Einzelbild für
    /// Einzelbild mitgeschrieben; die Zahlen unten stammen daraus.
    ///
    /// `smooth(0.50)` — eine Feder — sah auf dem Papier richtig aus und war
    /// es nicht: sie legte **90 % der Strecke in 320 ms** zurück und kroch
    /// die restlichen zehn Prozent über 1,2 Sekunden hinterher. Vorne ein
    /// Wusch, hinten nichts. Genau das heisst „zu schnell und hart", obwohl
    /// „0,5 Sekunden" daneben steht: bei einer Feder ist die Dauer ein
    /// Empfinden, keine Strecke.
    ///
    /// `easeInOut` verteilt gleichmässig — die Hälfte der Strecke in der
    /// Hälfte der Zeit — und hört auf, wenn sie fertig ist. 450 ms, also die
    /// Hälfte länger als die 300, die zu kurz waren.
    static let zeitSeitenschub = Animation.easeInOut(duration: dauerSeitenschub)

    /// **Das Abzeichen „Hier weiterschauen" in der Seitenleiste** — seine
    /// Höhe und sein Abstand zu jeder Kante, an der es liegt (links, rechts,
    /// unten). Ein Wert, damit die drei nicht wieder auseinanderlaufen;
    /// Linux/Windows nehmen dieselben Zahlen.
    static let abzeichenHoehe: CGFloat = 40
    static let abzeichenRand: CGFloat = 12
    /// Dieselbe Zahl für `Einfahrt`: so lange wartet, was vom Server kommt.
    static let dauerSeitenschub: Double = 0.45
}

extension AnyTransition {
    /// Der Wechsel in der Leiste — nacheinander, nur Deckkraft (siehe
    /// `Stil.zeitBereichHinaus`).
    ///
    /// Berechnet statt abgelegt: `AnyTransition` ist nicht `Sendable`, eine
    /// gespeicherte Eigenschaft wäre unter Swift 6 ein gemeinsam genutzter
    /// veränderlicher Zustand.
    static var bereichswechsel: AnyTransition { .asymmetric(
        insertion: .opacity.animation(Stil.zeitBereichHerein),
        removal: .opacity.animation(Stil.zeitBereichHinaus)) }
}

/// **Eine Haarlinie, ein Baustein** — auch auf dem Mac.
///
/// Die geteilten Ansichten in `Sources/Shared` nehmen `Trennlinie()`. Auf dem
/// Mac gab es sie nicht, dort stand `Divider().overlay(Stil.linie)` von Hand.
/// Zwei Fassungen derselben Linie sind eine zu viel.
struct Trennlinie: View {
    var body: some View {
        Rectangle()
            .fill(Stil.linie)
            .frame(height: 1)
            .padding(.leading, Stil.randAbstand)
    }
}

/// **Die Trennlinie in einer Tafel oder einem Blatt — durchgehend.**
///
/// Der geteilte Baustein `Uebernahmeauswahl` liest sie. Ein Einzug ist in
/// einer Liste am Bildschirmrand richtig; in einer Tafel ist die gerundete
/// Kante schon die Gruppe, und der Einzug waere nur eine zweite Kante, die
/// mit keiner anderen fluchtet. Die ausfuehrliche Begruendung steht in
/// `Sources/Shared/Stil.swift`, wo die iPhone-Fassung sie traegt.
struct Blattlinie: View {
    var body: some View {
        Rectangle().fill(Stil.linie).frame(height: 1)
    }
}
