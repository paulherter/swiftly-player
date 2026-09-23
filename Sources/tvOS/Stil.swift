import Foundation
import JellyfinKit
import SwiftUI

/// Maße, Schriftgrößen und Bausteine für den Fernseher.
///
/// Die Farben stehen in `Sources/Shared/Farben.swift` und sind mit dem iPhone
/// identisch. Alles andere hier ist neu: 1920 × 1080 statt 390 × 844, drei
/// Meter Entfernung statt Armlänge, Fernbedienung statt Finger.
///
/// **Die eine Regel, die alles trägt: Fokus ist weiß, Auswahl ist Akzent.**
/// Der weiße Fokusgrund ist derselbe Knopf, der auf iOS `HauptknopfStil`
/// heißt — weiße Fläche, schwarze Schrift. Auf tvOS wird daraus der Zustand
/// „hier steht die Fernbedienung". Der Akzentring um eine fokussierte Kachel
/// bricht die iOS-Regel nicht, sondern wendet sie an: der Akzent trägt
/// Fortschritt, **Auswahl** und den Direct-Play-Beleg.
///
/// Bewusst keine Apple-Standardsteuerelemente, wie auf iOS auch: kein
/// `TabView`, keine `List`, kein `.buttonStyle(.card)` — Apples Karte bringt
/// Schatten, Parallaxe und ein Aufblitzen mit, die zu einer flachen
/// Gestaltung nicht passen.
extension Stil {
    /// **Dieselben Namen wie auf dem iPhone**, damit die geteilten Bausteine in
    /// `Sources/Shared` sie hier auch finden. Die Werte sind die dieser
    /// Plattform; die Rolle ist dieselbe.
    static var bewegungReduziert: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
    static let listentitel = Font.system(size: 30, weight: .semibold)

    // Die Eckenleiter steht weiter unten bei den uebrigen Massen, unter
    // „MARK: Ecken" — alle vier Stufen an einer Stelle, mit der Rechnung.

    // MARK: - Rueckmeldung auf den Druck

    /// **Dieselben zwei Stile wie auf dem iPhone**, damit die geteilten
    /// Bausteine in `Sources/Shared` sie hier auch finden. Eine Zeile bekommt
    /// eine Flaeche, ein Knopf wird kleiner — jeder Knopf antwortet auf den
    /// Druck, das steht in `Notizen/BRAND.md`, Abschnitt 5.
    struct Druckzeile: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Stil.schrift.opacity(configuration.isPressed ? 0.06 : 0))
                .animation(.linear(duration: 0.12), value: configuration.isPressed)
        }
    }

    struct Druckknopf: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.linear(duration: 0.12), value: configuration.isPressed)
        }
    }


    // MARK: Maße — Apple TV

    /// Der sichere Bereich auf 1920 × 1080. Apples Richtwert, und er stimmt:
    /// Fernseher schneiden am Rand ab, mal mehr, mal weniger.
    ///
    /// **Gemessen ab der Bildkante, nicht ab dem Systemrand.** tvOS haelt
    /// seitlich selbst 80 frei; wer `randSeite` daraufsetzt, landet bei 160
    /// und damit doppelt so weit innen wie der Entwurf. `HauptView` nimmt den
    /// Systemrand deshalb einmal fuer alle Bereiche weg — siehe dort.
    ///
    /// Weniger als 80 waere kein Feinschliff, sondern ein Risiko: darunter
    /// schneiden Fernseher ab, und man sieht es dem Simulator nie an.
    static let randSeite: CGFloat = 80
    static let randOben: CGFloat = 60

    // MARK: Kopfleiste

    /// Oberkante der Leiste, von der Bildkante aus — der sichere Bereich.
    ///
    /// Apples Richtlinie nennt für die **Systemleiste** feste 46 Punkt („its
    /// top edge is 46 points from the top of the screen"). Übernommen sah es
    /// schief aus, und zwar aus einem Grund, der in der Zahl nicht steckt:
    /// Apples Leiste ist waagerecht **mittig** und schmal, unsere ist
    /// linksbündig und beginnt bei 80. 46 oben gegen 80 seitlich liest sich
    /// dann als Fehler.
    ///
    /// Deshalb der sichere Bereich: 60 oben, 80 seitlich. Das ist auf tvOS
    /// ohnehin das Verhältnis, in dem der Rand gedacht ist — waagerecht mehr
    /// wegen des Überstrahlens am Bildrand.
    static let leisteOben: CGFloat = randOben
    static let leisteHoehe: CGFloat = 68
    /// Unterkante — daran hängt der Kopfverlauf, der sich damit selbst
    /// nachrechnet, wenn die Leiste je wandert.
    static var leisteUnten: CGFloat { leisteOben + leisteHoehe }

    // MARK: Ecken

    /// **Die Eckenleiter — dieselbe Rundung wie am iPhone, nicht dieselbe Zahl.**
    ///
    /// Hier stand einmal, die Ecken trugen am Fernseher „durchweg das
    /// Eineinhalbfache", und als Beleg zwei Zahlen, die beide nicht 1,5 waren:
    /// 16/8, 12/10, 16/10, 24/16 sind 2,0 / 1,2 / 1,6 / 1,5. Ein fester Faktor
    /// war also weder eingehalten noch der richtige Gedanke.
    ///
    /// **Der Massstab ist das Verhaeltnis von Radius zu Groesse des Dings, das
    /// er rundet.** Nur das entscheidet, wie rund eine Ecke *wirkt*: 10 auf ein
    /// 112 breites Plakat sind 0,089, 16 auf ein 208 breites nur 0,077 — am
    /// Fernseher war das Plakat also flacher als am Telefon, obwohl die Zahl
    /// groesser war. Und weil die Dinge am Fernseher **nicht** alle gleich
    /// stark wachsen (Plakat 112 → 208 ist 1,86, Knopf 48 → 76 nur 1,58),
    /// kann es einen festen Faktor fuer die Ecken gar nicht geben.
    ///
    /// Je Stufe also: iPhone-Verhaeltnis nehmen, mit dem Fernseher-Mass des
    /// **gleichen Dings** multiplizieren, auf eine gerade Zahl runden.
    ///
    ///     Stufe          iPhone: Ding / Ecke      Verh.   Fernseher: Ding      Rechnung        neu
    ///     eckeKlein      Marke 24 hoch  /  8      0,333   Marke 47 hoch        47 × 0,333 = 15,7
    ///                    Plakette 24 hoch / 8     0,333   Plakette.fern 41     41 × 0,333 = 13,7   14
    ///     ecke           Knopf 48 hoch  / 10      0,208   Knopf 76 hoch        76 × 0,208 = 15,8   16
    ///     eckeKachel     Plakat 112 breit / 10    0,089   Plakat 208 breit    208 × 0,089 = 18,6   18
    ///     eckeFlaeche    Tafel, Zeile 58 / 16     0,276   Tafel, Zeile 84     84 × 0,276 = 23,2   24
    ///
    /// Die Leiter ist damit **14 / 16 / 18 / 24** statt 16 / 12 / 16 / 24. Zwei
    /// Punkte Abstand sind am Fernseher kein zu feiner Unterschied, sondern der
    /// richtige: 1920 Punkt auf drei Meter Entfernung fuellen ungefaehr
    /// denselben Sehwinkel wie 390 Punkt auf Armlaenge, ein Fernseherpunkt ist
    /// also rund ein Fuenftel eines iPhone-Punkts.
    ///
    /// Auffaellig ist nur `eckeKlein`: es **sinkt** von 16 auf 14, obwohl alles
    /// andere steigt. Der Grund ist derselbe Rechenweg — die kleinen Marken
    /// wachsen vom Telefon zum Fernseher weniger als der Rest (24 → 41…47,
    /// also 1,7 bis 2,0 bei einer Ecke, die vorher das Doppelte trug).
    static let ecke: CGFloat = 16
    /// Plakate und Kacheln. Am iPhone dieselbe Zahl wie der Knopf (beide 10);
    /// hier zwei mehr als der Knopf, weil das Plakat staerker gewachsen ist als
    /// er. Zwei Punkte sind auf drei Meter kein Rang, sondern nur die ehrliche
    /// Rundung — wer sie zusammenlegen will, nimmt fuer beide 18.
    static let eckeKachel: CGFloat = 18
    /// **Die kleine Ecke, fuer Marken und Plaketten.** Traegt die Marke der
    /// `Belegzeile`, `Plakette.fern` und die Marke oben auf einer Kachel — alle
    /// drei zwischen 36 und 47 Punkt hoch.
    static let eckeKlein: CGFloat = 14
    /// **Eine eigene Flaeche oder Tafel:** die `Handlungstafel` und das
    /// Staffelblatt der Seerr-Seite, beide 620 Punkt breit mit Zeilen in
    /// `zeilenHoehe`. Sie stand bisher als Zahl `Stil.ecke + 8` in beiden
    /// Dateien und hier ungenutzt daneben.
    ///
    /// Gemessen wird an der **Zeilenhoehe**, nicht an der Breite: die Tafel
    /// ist am Fernseher 620 breit gegen 342 am iPhone, aber 1760 Punkt
    /// Inhaltsbreite gegen 354 — an der Breite gerechnet kaeme eine Ecke von
    /// 80 heraus, und das ist offensichtlich keine Tafel mehr. Die Zeile ist
    /// das Ding, an dem man die Rundung liest.
    static let eckeFlaeche: CGFloat = 24

    /// **Keine Stufe der Leiter, sondern ein Platzhalterbalken.** Ein
    /// `Ladefeld`, das fuer eine Textzeile steht, ist 16 bis 30 Punkt hoch;
    /// dieselben 0,23 wie beim kleinen Feld ergeben darauf 4 bis 7. Eine Zahl
    /// fuer alle drei, weil ein Punkt Unterschied an einem Balken, der nur
    /// sagt „hier kommt Text", nichts erzaehlt.
    static let eckeBalken: CGFloat = 5

    /// Poster bleiben 2:3 wie auf dem iPhone, nur größer.
    static let posterBreite: CGFloat = 208
    static let posterHoehe: CGFloat = 312

    /// Waagerecht 16:9 — für „Weiterschauen", wo ein Standbild mehr sagt als
    /// das Cover.
    static let querBreite: CGFloat = 448
    static let querHoehe: CGFloat = 252

    /// Alle Abstände sind so gewählt, dass die **fokussierte** Kachel noch
    /// Luft hat, nicht die ruhende. Bei ×1,08 wächst ein Poster um 25 Punkt,
    /// also gut 12 nach jeder Seite; eine Querkachel um 20. Wer die Abstände
    /// am ruhenden Zustand bemisst, bekommt sie beim ersten Fokus zu eng —
    /// genau das war hier zuerst der Fall.
    static let kachelAbstand: CGFloat = 40
    /// Hoehe der festen Auskunftszone, von der Bildkante gemessen.
    ///
    /// **Sie legt das Fenster der Reihen fest: 1080 − 510 = 570.** Und dieses
    /// Fenster muss einen ganzen Reihenabschnitt fassen, sonst kann tvOS Kopf
    /// und Kacheln nicht gemeinsam freistellen und der Titel rutscht wieder
    /// hinaus:
    ///
    ///     Plakatreihe = 24 + 45 + 16 + (20 + 390 + 20) + 28 = 543
    ///     Querreihe   = 24 + 45 + 16 + (20 + 331 + 20) + 28 = 484
    ///
    /// 510 statt der 560 aus `Start-A.dc.html`: mit 560 blieben nur 520, und
    /// da passt die Plakatreihe nicht mehr hinein.
    static let heldenHoehe: CGFloat = 510

    /// **Um so viel steht eine Detailseite tiefer als die Startseite.**
    ///
    /// Die Startseite setzt ihren Textblock bei 196 an, `Film-Neu.dc.html` den
    /// der Detailseite bei 140 — weil ueber der Startseite die Kopfleiste
    /// steht und ueber der Detailseite nichts. Auf dem Schirm ist das aber
    /// dieselbe Auskunft zum selben Film, und beim Druecken sprang sie um
    /// diese 56 nach oben.
    ///
    /// Genau das ist es: die Leiste wird nicht gezeichnet, ihr Platz aber
    /// freigehalten. **Der Hintergrund wandert nicht mit** — die Kulisse steht
    /// im selben Stapel und behaelt ihre Lage.
    ///
    /// Verschoben wird der ganze Block, nicht die Abstaende darin. Deshalb
    /// waechst auch die Kopfzone um denselben Betrag, und die Tafelmasse
    /// gelten unveraendert weiter:
    ///
    /// 196 + 68 + 14 + 34 + 22 + 80 + 36 + 76 = 526   Block endet 566 + 24
    /// = 590   Reihentitel 590 − 526                              =  64   wie
    /// in der Tafel
    static let kopfversatzDetail: CGFloat = 56

    /// Zeilenhoehe und Zeilenabstand der Beschreibung.
    ///
    /// **Gerechnet, nicht geschaetzt** — daran ist es einmal gescheitert. Die
    /// Tafel nennt eine Zeilenhoehe von 40; gemessen sind es bei 29 Punkt
    /// Schrift rund 35 plus die 11 `lineSpacing`, also 46 je Zeile ab der
    /// zweiten. Mit den 120 aus der Tafelrechnung passten deshalb nur zwei
    /// Zeilen in den Platz, obwohl `lineLimit` auf drei stand: die dritte
    /// wurde still abgeschnitten.
    ///
    /// **37, seit der Fliesstext auf 30 steht.** Die 35 galten fuer 29 Punkt;
    /// dieselbe Rechnung (Zeilenhoehe rund das 1,21-Fache des Grades) ergibt
    /// auf 30 rund 36,2. Aufgerundet auf 37, damit die dritte Zeile nicht
    /// genau an der Nachkommastelle wieder abgeschnitten wird — der Fehler,
    /// den der Absatz darueber beschreibt.
    static let beschreibungZeile: CGFloat = 37
    static let beschreibungLuft: CGFloat = 11

    /// Wie hoch `zeilen` Zeilen Beschreibung stehen: 3 → 133, 2 → 85.
    static func beschreibungHoehe(_ zeilen: Int) -> CGFloat {
        CGFloat(zeilen) * beschreibungZeile + CGFloat(zeilen - 1) * beschreibungLuft
    }

    /// Der Folgentitel ueber der Angabenzeile: 44 hoch, 10 Abstand.
    static let zweitzeileHoehe: CGFloat = 54

    /// **Feste Hoehe des Kopfblocks — Titel, Angabenzeile, Beschreibung.**
    ///
    /// Titel           68 + 14 Angaben    34 + 22 Beschr.   127 = 265
    ///
    /// Fest, damit nichts darunter vom Inhalt abhaengt: ein Film ohne
    /// Beschreibung, ein langer Titel, eine Folge mit Zweitzeile — der Block
    /// ist immer gleich hoch, also steht die Knopfreihe immer an derselben
    /// Stelle. **Wo das oberste Element jeder Seite endet.**
    ///
    /// Stimmt, und es war es nicht:
    ///
    /// Start, Detail   Titel 68 ab 196   endet 264 Bibliothek      Chips 48 ab
    /// 190   endet 238 Suche           Feld  76 ab 190   endet 266
    ///
    /// Ich hatte die **Anfaenge** auf 190 gelegt. Bei verschieden hohen
    /// Elementen richtet das nichts aus — sichtbar ist die Unterkante, weil
    /// darunter der Inhalt beginnt.
    ///
    /// 264 kommt vom Titel: 196 aus der Tafel plus seine Zeilenhoehe. Jede
    /// Seite rechnet ihren oberen Abstand daraus und aus der Hoehe ihres
    /// eigenen ersten Elements zurueck.
    static let erstesEnde: CGFloat = 264

    static var auskunftHoehe: CGFloat { auskunftHoehe(zweitzeile: false) }

    /// **Mit Folgentitel eine Zeile weniger Beschreibung.**
    ///
    /// Drei Zeilen sind richtig, solange der Titel allein oben steht. Kommt
    /// bei einer Folge der Folgentitel dazu, kostet er 54 Punkt — und die
    /// dritte Zeile lief dann in den Reihentitel darunter.
    ///
    /// ohne  68      + 14 + 34 + 22 + 127 = 265 mit   68 + 54 + 14 + 34 + 22 +
    /// 81 = 273
    ///
    /// Der Block waechst also nur um acht statt um 54: der Folgentitel nimmt
    /// sich seinen Platz groesstenteils von der Beschreibung, nicht von der
    /// Seite.
    static func auskunftHoehe(zweitzeile: Bool) -> CGFloat {
        68 + (zweitzeile ? zweitzeileHoehe : 0) + 14 + 34 + 22
        + beschreibungHoehe(zweitzeile ? 2 : 3)
    }

    /// Kopfzone einer Detailseite — **gerechnet, nicht gesetzt.**
    ///
    ///     196 (Block beginnt)  + 258 (auskunftHoehe) = 454
    ///     + 36 + 76 (Knopfreihe)                     = 566
    ///     + 64 (Abstand aus der Tafel) − 24 (reihenKopfLuft)
    ///     = 606
    ///
    /// Groesser als die 510 der Startseite, und das muss so sein: hier
    /// kommt die Knopfreihe dazu, und der Block steht 56 tiefer. Die
    /// Startseite braucht den Platz nicht — dort endet der Block bei 454
    /// und die Reihen beginnen unveraendert bei 534.
    static var heldenHoeheDetail: CGFloat {
        randOben + kopfversatzDetail + 80 + auskunftHoehe
        + 36 + knopfHoehe + abstandUnterDerKnopfreihe - reihenKopfLuft
    }

    /// Der Abstand unter der Knopfreihe — 64 aus `Film-Neu.dc.html`.
    ///
    /// Einmal auf 36 gekuerzt, weil ich glaubte, die erste Reihe rage 26 Punkt
    /// ueber den Schirm hinaus. **Sie tut es nicht.** An dem Bildschirmfoto mit der
    /// Kachelbreite als Massstab nachgemessen endet sie samt Beschriftung bei
    /// rund 1005 — 75 Punkt Luft. Die Rechnung davor stand auf zwei
    /// geschaetzten Werten (Reihentitel 46, Beschriftung 122), und beide waren
    /// zu gross.
    ///
    /// Die Zahl aus der Tafel gilt also weiter. Was beim Fokussieren passiert,
    /// kommt nicht von der Hoehe.
    static let abstandUnterDerKnopfreihe: CGFloat = 64

    /// Senkrechte Luft im waagerechten Streifen.
    ///
    /// Die fokussierte Kachel waechst um 1,08 ueber ihre Layoutgroesse
    /// hinaus — bei einem Plakat rund 25 Punkt, also gut 12 je Seite. Ohne
    /// diese Luft schneidet die Flaeche oben die Kachel und unten ihre
    /// Nebenzeile an.
    static let reihenLuft: CGFloat = 20

    /// Ueber dem Reihentitel — der obere Teil des Reihenabstands.
    ///
    /// Er gehoert **in den Abschnitt**, nicht zwischen die Abschnitte. Nur so
    /// zaehlt er mit, wenn tvOS den Abschnitt beim Fokussieren freistellt —
    /// zwischen den Abschnitten waere er wieder Beiwerk.
    static let reihenKopfLuft: CGFloat = 24

    /// Von Reihe zu Reihe. Drei Teile, alle im Abschnitt: Abstand unter dem
    /// Streifen (28) + dessen Fokusluft (20) + Luft ueber dem naechsten
    /// Titel (24).
    static let reihenAbstand: CGFloat = 72

    /// Zwischen Reihentitel und den Kacheln darunter. Die Fokusluft des
    /// Streifens zaehlt mit, der Kopf traegt nur den Rest.
    static let titelAbstand: CGFloat = 36

    /// Unter der letzten Reihe, **zusaetzlich**.
    ///
    /// Am Anschlag steht die Unterkante des Inhalts auf der Fensterkante.
    /// Darunter liegt schon der Abstand des letzten Abschnitts samt Fokusluft
    /// — 28 + 20 = 48. Hierher kommt nur der Rest auf die 60, die tvOS unten
    /// ohnehin freihaelt. Mehr waere genau die „riesige Luecke unten", die
    /// vorher da war; abgeleitet statt gesetzt kann sie nicht wieder
    /// auseinanderlaufen.
    static var abschlussLuft: CGFloat {
        randOben - (reihenAbstand - reihenLuft - reihenKopfLuft) - reihenLuft
    }

    /// Die Bibliothek als Gitter.
    static let gitterSpalten = 7
    /// **50, nicht 56 — sonst passt das Raster nicht auf den Schirm.**
    ///
    ///     7 × 208 + 6 × 56 + 2 × 80 = 1952   bei 1920 Breite
    ///     7 × 208 + 6 × 50 + 2 × 80 = 1916
    ///
    /// Mit 56 staucht `LazyVGrid` die Poster, damit die Reihe aufgeht — sie
    /// stehen dann schmaler als dieselben 208 auf der Startseite, und die
    /// Reihe wirkt gedraengt, ohne dass man den Grund sieht. Mit 50 bleiben
    /// die Poster, was sie sind, und vier Punkte Rest verteilen sich.
    static let gitterSpalte: CGFloat = 50
    static let gitterZeile: CGFloat = 72

    static let knopfHoehe: CGFloat = 76
    static let chipHoehe: CGFloat = 48
    static let zeilenHoehe: CGFloat = 84

    // MARK: Fokus

    /// **Die Fokusleiter: drei Stufen, nach der Groesse des Gegenstands.**
    ///
    /// `Sources/tvOS` vergroesserte fokussierte Dinge in sechs Stufen — 1,03 ·
    /// 1,04 · 1,06 · 1,08 · 1,10 · 1,12 —, und nur 1,08 war ein Token. Sechs
    /// Zahlen fuer **eine** Aussage („hier steht die Fernbedienung") sind
    /// gewachsen, nicht entworfen: wer eine davon aendert, aendert ein Fuenftel
    /// der App und weiss es nicht.
    ///
    /// **Das Kriterium ist, wie weit der Umriss wandert**, nicht wie viel
    /// Prozent es sind. Ein Prozentsatz sagt am Fernseher nichts: 8 % sind auf
    /// einem 60 Punkt grossen Profilkreis fuenf Punkte — das sieht man aus drei
    /// Metern nicht —, auf einer 760 Punkt breiten Zeile sind es einundsechzig.
    /// Gemessen wird deshalb die **laengste Seite** des Dings, und der Zuwachs
    /// soll ueberall in derselben Groessenordnung landen, rund 6 bis 25 Punkte:
    ///
    ///     Stufe               Wert    laengste Seite   Beispiele                       Zuwachs
    ///     fokusLupeKlein      1,10    bis 120          Profilkreis 60, Symbolknopf 88   +6 … +9
    ///     fokusLupe           1,06    120 bis 500      Chip 180, Knopf 250,
    ///                                                  Plakat 312, Querkachel 448      +11 … +27
    ///     fokusLupeBreit      1,03    ab 500           Leistenzeile 620,
    ///                                                  Geraetezeile 760                +19 … +23
    ///
    /// Klein waechst also staerker, gross weniger — genau umgekehrt zu vorher,
    /// wo der Profilkreis mit 1,12 **und** die Kachel mit 1,08 den grossen
    /// Zuwachs hatten und die Chips mit 1,06 den kleinen.
    ///
    /// **Es wird ausschliesslich skaliert, nie ein fester Betrag addiert.**
    /// `BRAND.md` §5 behauptete, der fokussierte Knopf wachse „um einen festen
    /// Betrag von 3 Punkt" — das stand nirgends im Code und steht auch jetzt
    /// nicht hier. Die Notizen sind korrigiert.
    ///
    /// Frei stehende Bilder bekommen zusaetzlich einen Ring (`ProfilStil`,
    /// `KontostreifenStil`): ein Bild kann nicht heller werden wie eine Kachel,
    /// und sechs Punkte Zuwachs allein sind auf drei Meter zu leise.
    ///
    /// Kein Schatten, keine Parallaxe, kein Aufblitzen — Apples Karte springt
    /// deutlich weiter und schiebt in einer dichten Reihe die Nachbarn optisch
    /// weg. BRAND 4.
    static let fokusLupeKlein: CGFloat = 1.10
    /// Der Grundwert: Kacheln, Plakate, Knoepfe, Chips, Reiter — alles zwischen
    /// 120 und 500 Punkt laengster Seite. Auf einer Kachel ist er das einzige,
    /// was Fokus ausmacht: kein Ring, keine Flaeche, kein Schatten.
    static let fokusLupe: CGFloat = 1.06
    /// Zeilen und Tafeln ab 500 Punkt Breite. Drei Prozent sind dort schon
    /// zwanzig Punkte — dieselbe sichtbare Bewegung wie zehn Prozent an einem
    /// Profilkreis.
    static let fokusLupeBreit: CGFloat = 1.03
    /// Die ruhige Fläche, die überall Fokus bedeutet, wo kein Knopf steht:
    /// Listenzeilen, Chips, Folgenzeilen. Weiß bleibt den Handlungsknöpfen
    /// vorbehalten — dort ist es der Hauptknopf vom iPhone.
    static let fokusflaeche = Color.white.opacity(0.12)

    /// Fokuswechsel sollen unmittelbar wirken — die Fernbedienung ist
    /// träge genug.
    ///
    /// **„Bewegung reduzieren" gilt auch hier.** `bewegungReduziert` stand
    /// oben in der Datei und wurde in ganz `Sources/tvOS` kein einziges Mal
    /// gelesen: jede Fokus- und Einblendbewegung lief unabhaengig von der
    /// Systemeinstellung. Der Fokus selbst bleibt sichtbar — nur die Kurve
    /// wird kurz und gerade, so wie am iPhone.
    static var fokusAnimation: Animation {
        bewegungReduziert ? .linear(duration: 0.1) : .easeOut(duration: 0.14)
    }

    /// Wie Inhalt erscheint, wenn er angekommen ist — dieselbe Kurve wie auf
    /// dem iPhone. **Nichts erscheint hart** (E18): Bilder blenden ein,
    /// Inhalt loest Platzhalter ab.
    static var einblenden: Animation {
        bewegungReduziert ? .linear(duration: 0.14) : .easeInOut(duration: 0.28)
    }

    // MARK: Seitenwechsel

    /// Überblenden zwischen zwei Bereichen.
    ///
    /// Reines Überblenden, ohne Verschiebung — mehr macht die Systemleiste
    /// auf tvOS auch nicht. `easeInOut`, weil an beiden Enden etwas
    /// passiert: das eine geht, das andere kommt.
    static var seitenwechsel: Animation {
        bewegungReduziert ? .linear(duration: 0.14) : .easeInOut(duration: 0.25)
    }

    // MARK: Schrift — Apple TV

    /// **Genau das Doppelte des iPhones** — eine Regel statt einer zweiten
    /// Tabelle (BRAND 2).
    ///
    /// Sie hing bis zum 22.09. an Apples tvOS-Rampe: 57 / 38 / 31 / 29 / 27 /
    /// 25 / 21. Keiner dieser Werte war das Doppelte, und `kachel` trug
    /// ausserdem noch die alte 14 als Vorlage, die es am iPhone seit dem
    /// 21.09. nicht mehr gibt. Wer am iPhone eine Stufe aendert, hat damit
    /// den Fernseher mitgeaendert — das war der Sinn der Regel, und sie galt
    /// hier nicht.
    static let titelGross = Font.system(size: 56, weight: .bold)       // iOS 28
    static let unterseitentitel = Font.system(size: 44, weight: .semibold) // iOS 22
    static let reihe      = Font.system(size: 40, weight: .semibold)   // iOS 20
    static let rubrikGross = Font.system(size: 34, weight: .semibold)  // iOS 17
    static let knopf      = Font.system(size: 30, weight: .semibold)   // iOS 15
    static let koerper    = Font.system(size: 30)                      // iOS 15
    static let kachel     = Font.system(size: 26, weight: .medium)     // iOS 13
    static let klein      = Font.system(size: 24)                      // iOS 12
    static let gruppe     = Font.system(size: 22, weight: .semibold)   // iOS 11
    static let plakette   = Font.system(size: 20, weight: .semibold)   // iOS 10

    // MARK: Sperrung — jeweils der em-Wert aus BRAND 2 mal der Punktgroesse
    /// 56 · −0,021 em
    static let sperrungTitel      = -1.176
    /// 44 · −0,014 em
    static let sperrungUnterseite = -0.616
    /// 34 · −0,008 em
    static let sperrungRubrik     = -0.272
    /// 22 · +0,14 em
    static let sperrungGruppe     = 3.08
    /// 20 · +0,10 em
    static let plaketteSperrung   = 2.0

    /// **Sperrung der Reihenueberschrift.** −0,012 em auf 40 Punkt.
    /// Mitgezogen, als die Leiter auf das Doppelte geradegezogen wurde.
    static let sperrungReihe = -0.48
}

// MARK: - Bild

/// Bild in fester Größe, mit Platzhalter.
///
/// Gleiches Vorgehen wie auf iOS: die Größe kommt vom Rahmen, das Bild legt
/// sich nur darüber. `aspectRatio(.fill)` direkt auf dem Bild macht es breiter
/// als seinen Rahmen — `clipped()` beschneidet dann die Darstellung, nicht die
/// Layoutgröße, und alles drumherum verrutscht.
struct Bild: View {
    let url: URL?
    var breite: CGFloat?
    var hoehe: CGFloat?
    var ecke: CGFloat = Stil.eckeKachel
    /// Fortschritt am unteren Rand, innerhalb der Maske.
    var fortschritt: Double? = nil

    /// Profil → Darstellung. Siehe `EnvironmentValues.fortschrittAufKacheln`.
    @Environment(\.fortschrittAufKacheln) private var balkenZeigen

    /// **Ein abgebrochener Abruf ist kein Fehlschlag — er ist einen zweiten
    /// Versuch wert.**
    ///
    /// `AsyncImage` bricht ab, sobald seine Kachel vom Schirm geht, und
    /// bleibt danach im Fehlerzustand stehen: kommt dieselbe Kachel zurück,
    /// versucht es von sich aus nichts mehr. Beim Kontowechsel geht die halbe
    /// Seite kurz durch die Hände des Fokusmotors, und dann trifft es viele
    /// Kacheln auf einmal. Am Gerät gemessen, zwanzigmal in Folge:
    ///
    ///     NSURLErrorDomain -999
    ///
    /// Das heißt „abgebrochen" — nicht abgelehnt, nicht verfehlt. Derselbe
    /// Aufruf von außen kam mit HTTP 200 und 158 KB zurück. Deshalb hier ein
    /// neuer Anlauf statt einer grauen Fläche; höchstens zwei, damit ein
    /// echter Ausfall nicht in eine Schleife läuft.
    @State private var anlauf = 0

    var body: some View {
        Color.clear
            .frame(width: breite, height: hoehe)
            .frame(maxWidth: breite == nil ? .infinity : nil)
            .overlay {
              // **Nur hinter einem Vorposten.** `AsyncImage` kann keine
              // eigenen Header senden (Issue #4); `Netzbild` kann es. Fuer
              // alle anderen bleibt es beim Bisherigen.
              if let url, !Eigenkoepfe.fuer(url).isEmpty {
                Netzbild(url: url)
              } else {
                // Die `transaction` blendet den Wechsel der Lagen weich;
                // ohne sie schaltet `AsyncImage` hart um. **Nichts erscheint
                // hart** — GESTALTUNG, Abschnitt E.
                AsyncImage(url: url,
                           transaction: Transaction(animation: Stil.einblenden)) { phase in
                    if case let .success(bild) = phase {
                        bild.resizable().aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        Stil.flaeche.onAppear {
                            guard case let .failure(f) = phase,
                                  (f as NSError).code == NSURLErrorCancelled,
                                  anlauf < 2 else { return }
                            anlauf += 1
                        }
                    }
                }
                .id(anlauf)
              }
            }
            // Eine neue Adresse heißt ein frischer Anlauf.
            .onChange(of: url) { _, _ in anlauf = 0 }
            .overlay(alignment: .bottom) {
                if let fortschritt, balkenZeigen {
                    Fortschrittsbalken(anteil: fortschritt)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ecke, style: .continuous))
    }
}

/// Dünner Balken am unteren Rand einer Kachel. Auf dem Fernseher 6 Punkt —
/// bei 2 wie auf dem iPhone sieht man ihn aus drei Metern nicht.
struct Fortschrittsbalken: View {
    let anteil: Double

    var body: some View {
        GeometryReader { rahmen in
            ZStack(alignment: .leading) {
                // Helle Spur, wie am iPhone: die Spur ist die Laenge des
                // Ganzen, nicht der fehlende Rest.
                Rectangle().fill(Color.white.opacity(0.30))
                Rectangle().fill(Stil.akzent)
                    .frame(width: rahmen.size.width * min(max(anteil, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Kleinteile

// `Reihentitel`, `Plakette`, `Lader` und `Profilzeichen` stehen jetzt in
// `Sources/Shared/Bausteine.swift`. Sie lagen dreimal da — hier, auf iOS und
// auf macOS —, weil `Shared/Stil.swift` iPhone-Maße mit neutralen Bausteinen
// mischte und dieses Ziel die Datei deshalb nicht einbinden konnte. Kopien
// laufen auseinander; bei `nachladen()` ist genau das passiert.
//
// **Die Maße bleiben hier, die Bausteine nicht.** Der geteilte Baustein nimmt
// sie entgegen, das Ziel gibt sie mit.

/// Die Fernseher-Maße der Plakette an einer Stelle.
///
/// Das ist **keine zweite Plakette**, sondern ein Satz Zahlen: die
/// iPhone-Werte (5/2, Rundung 3, Strich 1) sind auf drei Meter Entfernung zu
/// klein. Wer sie ändert, ändert sie hier — nicht in einer Kopie.
///
/// Die Randfarbe leitet sich aus der Schriftfarbe ab, so wie es die eigene
/// Fassung tat. Der geteilte Baustein hält beide getrennt, weil ein
/// gekoppelter Rand die Plakette auf dem iPhone aufgehellt hätte.
extension Plakette {
    static func fern(_ text: String, farbe: Color = Stil.schriftLeise) -> Plakette {
        // **Dieselbe Form wie die Marke nebenan, eine Stufe kleiner.**
        //
        // Hier stand die Haelfte der noetigen Masse: Innenabstand und Ecke
        // waren verdoppelt, die Schrift blieb bei 13 — sie war im geteilten
        // Baustein gar nicht einstellbar. Das war eine
        // Telefonbeschriftung in einem Fernseherkasten mit doppelt so
        // runden Ecken wie ihr Nachbar.
        //
        // Auf 27 gesetzt, also gleichauf mit der Marke, wurde sie zu
        // schwer: „etwas zu riesig verglichen mit denen daneben." Das ist
        // richtig so, und es hat einen Grund ausser dem Augenmass — „Direct
        // Play" ist die Aussage der Zeile, die Freigabe eine Nebenangabe
        // wie die Bewertung. 24 Medium in 14/6: dieselbe Form, sichtbar eine
        // Stufe leiser.
        //
        // **Die Ecke ist `eckeKlein`, keine eigene Zahl.** Hier stand 6 — auf
        // einer 41 Punkt hohen Plakette sind das 0,15, wo am iPhone 0,33
        // stehen; sie war damit das kantigste Ding der Seite. Am iPhone
        // nimmt dieselbe Plakette in der `Belegzeile` ebenfalls das kleine
        // Mass. Die Marke nebenan nimmt es auch, und genau darauf kommt es an.
        Plakette(text: text,
                 farbe: farbe,
                 innenWaagerecht: 14,
                 innenSenkrecht: 6,
                 rundung: Stil.eckeKlein,
                 groesse: 24)
    }
}

/// Der Beleg, dass der Server nicht transkodiert — der Grund für diese App.
///
/// Steht auf der Detailseite. Im Player ausdrücklich **nicht**: dort zählt
/// das Bild, und wer die Wiedergabe schon gestartet hat, hat den Beleg
/// gesehen.
struct Belegzeile: View {
    var direktplay: Bool
    var hinweis: String?
    var bewertung: Double?
    var freigabe: String?
    /// Der Beleg steht hinten statt vorn.
    ///
    /// Auf dem Detailkopf laeuft die Zeile „Jahr · Laufzeit · Gattung",
    /// Bewertung, Freigabe, Beleg — die Angaben zum Titel zuerst, die Aussage
    /// ueber die **Wiedergabe** zuletzt. Im Wiedergabeblatt ist es umgekehrt:
    /// dort ist der Beleg der Grund, warum die Zeile ueberhaupt dasteht.
    var belegZuletzt = false
    /// **Ein freier Beleg statt des Wiedergabeplans** — auf der Seerr-Seite
    /// der Stand der Anfrage, in derselben Huelle wie Direct Play und die
    /// Bewertung. Wie `Belegzeile.eigen` am iPhone.
    var eigen: (symbol: String, wort: String, farbe: Color)? = nil

    var body: some View {
        HStack(spacing: 24) {
            if !belegZuletzt { beleg }
            // In derselben Huelle wie Direct Play — wie am iPhone seit dem
            // 23.09.2026: vorher stand die Bewertung als einzige Angabe der
            // Zeile nackt da.
            if let bewertung {
                marke("star.fill",
                      Text(verbatim: String(format: "%.1f", bewertung)
                          .replacingOccurrences(of: ".", with: ",")),
                      farbe: Stil.schriftLeise, gewicht: .semibold)
            }

            if let freigabe { Plakette.fern(freigabe) }

            if belegZuletzt { beleg }
        }
    }

    @ViewBuilder
    private var beleg: some View {
        if let eigen {
            marke(eigen.symbol, Text(verbatim: eigen.wort),
                  farbe: eigen.farbe, gewicht: .semibold)
        } else if direktplay {
            // Halbfett, nicht `.heavy` — wie am iPhone. Extrafett war der
            // vierte Schnitt und damit einer zu viel (BRAND 2).
            marke("checkmark", Text("Direct Play"), farbe: Stil.akzent, gewicht: .semibold)
        } else if let hinweis {
            marke("exclamationmark.triangle.fill", Text(hinweis),
                  farbe: Stil.warnung, gewicht: .regular)
        }
    }

    /// Die Huelle, in der die Belege und die Bewertung stecken.
    ///
    /// **Warum eine Marke und kein loser Text.** Zeichen und Wort standen
    /// nackt auf dem Grund, und daneben liegt die Freigabe als umrandete
    /// Plakette — zwei verschiedene Formen fuer zwei Angaben, die gleich viel
    /// wiegen. Jetzt tragen beide dieselbe Ecke und lesen sich als Paar;
    /// welche Auskunft es ist, sagt die Farbe.
    ///
    /// **`eckeKlein`, dieselbe wie `Plakette.fern`** — nicht `Stil.ecke`. Es
    /// geht hier nicht um die Groesse der Flaeche, sondern darum, dass die
    /// beiden Nachbarn gleich aussehen. Hier stand 6: auf einer 47 Punkt hohen
    /// Marke 0,13, wo am iPhone auf 24 Punkt Hoehe 0,33 stehen.
    ///
    /// Fuenfzehn Prozent Toenung, keine Fuellung: der weisse Fokus bleibt
    /// die einzige gefuellte Flaeche des Bildschirms.
    private func marke(_ symbol: String, _ wort: Text,
                       farbe: Color, gewicht: Font.Weight) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: gewicht))
            // `Stil.kachel` — 26 Medium, das Doppelte der 13 Medium, die das
            // Wort am iPhone traegt. Vorher 27, eine Zahl ohne Stufe.
            wort.font(Stil.kachel)
        }
        .foregroundStyle(farbe)
        // Links enger als rechts: das Zeichen ist schmaler als seine
        // Zeichenzelle, sonst sitzt das Wort sichtbar aus der Mitte.
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
        .background(farbe.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous))
    }
}

/// Der Ladering in Fernseher-Größe — 68 statt der 34 vom Telefon.
///
/// Wie `Plakette.fern` nur ein Satz Zahlen. Der geteilte Baustein bringt
/// obendrein den blassen Hintergrundring mit, den die eigene Fassung nicht
/// hatte.
extension Lader {
    static var fern: Lader { Lader(groesse: 68, staerke: 5) }
}

/// Wenn nichts da ist.
struct Leerzustand: View {
    let symbol: String
    let titel: LocalizedStringKey
    var hinweis: LocalizedStringKey?
    /// Ein Ausweg, kein Sackgassenschild.
    ///
    /// Auf dem iPhone hat jeder Leerzustand einen: „Aktualisieren",
    /// „Filter zurücksetzen". Ohne den steht man davor und kann nichts tun —
    /// auf der Fernbedienung noch unangenehmer als am Finger.
    var knopf: (titel: LocalizedStringKey, tun: () -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                // 88 Regular: am iPhone ist das Zeichen 44 gross und traegt
                // kein eigenes Gewicht mehr — „drei Gewichte, Regular ist das
                // leichteste" (BRAND 2). Vorher 76 in `.light`.
                .font(.system(size: 88))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text(titel)
                .font(Stil.reihe)
                .foregroundStyle(Stil.schrift)
            if let hinweis {
                Text(hinweis)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
            }
            if let knopf {
                Button(knopf.titel, action: knopf.tun)
                    .buttonStyle(KnopfStil())
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// **Ein Wortlaut fuer „der Server hat nicht geantwortet", nicht dreizehn.**
///
/// Genau derselbe `Leerzustand`, den Bibliothek, Startseite und Suche schon
/// zeigen — nur stand er in jeder Datei einzeln, und ab dem 21.09.2026 braucht
/// ihn auch die Serienseite, die Personenseite, die Genrewahl und die
/// Seerr-Seite. Viermal abgeschrieben waere viermal die Gelegenheit, dass
/// einer davon anders klingt.
///
/// `adresse` ist wahlweise: auf einer Seerr-Seite hat Jellyseerr geschwiegen,
/// nicht der eigene Server, und die falsche Adresse im Satz waere die falsche
/// Fehlersuche.
struct Stoerzustand: View {
    let model: AppModel
    var adresse: String?
    var erneut: (() -> Void)?

    var body: some View {
        Leerzustand(
            symbol: "externaldrive.badge.xmark",
            titel: "Server ist abgetaucht",
            hinweis: "\(adresse ?? model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
            knopf: erneut.map { tun in (titel: LocalizedStringKey("Erneut versuchen"), tun: tun) })
    }
}


// MARK: - Kopfverlauf

/// Dunkelt den oberen Rand ab, damit die Kopfleiste über durchlaufendem
/// Bildmaterial lesbar bleibt.
///
/// **Der sichere Bereich zählt mit.** Genau daran ist die erste Fassung
/// gescheitert: der Verlauf ignoriert ihn (`ignoresSafeArea`) und beginnt bei
/// null, die Kopfleiste liegt darin und beginnt 60 Punkt tiefer. Die kräftige
/// Zone lag damit über leerem Rand, und die Wortmarke stand schon im
/// Ausklang — auf hellen Postern also praktisch ungeschützt. Mit rotem
/// Verlauf im Simulator war es auf einen Blick zu sehen.
///
/// Deshalb rechnet `kopfhoehe` von der Bildkante, nicht vom sicheren Bereich:
/// 60 Punkt Rand plus 56 Abstand plus 60 Zeile.
///
/// Der Reihentitel steht bei rund 240 und liegt im Ausklang, dort sind es
/// noch etwa 15 Prozent. Auf dem Grundton ist das nichts, und wo ein Poster
/// steht, ist es gewollt.
///
/// Sieben Stützpunkte. Drei ergäben eine sichtbare Kante, wo die Steigung
/// umspringt — derselbe Befund wie auf dem iPhone, dort in OFFEN.md notiert.
struct Kopfverlauf: View {
    /// Unterkante der Kopfleiste, von der Bildkante aus gemessen.
    var kopfhoehe: CGFloat = Stil.leisteUnten
    /// Wie weit der Ausklang darunter hinausreicht.
    ///
    /// Lang, und das ist der Punkt: der Übergang muss weich sein, sonst sieht
    /// man die Kante, an der er endet. Kurz gehalten müsste er in wenigen
    /// Dutzend Punkten von 90 Prozent auf null — das **ist** eine Kante, da
    /// hilft keine Verteilung.
    var ausklang: CGFloat = 220

    /// Ein einziger langer Abfall statt der abgestuften Kurve.
    ///
    /// Die Stufen unten sind fuer Seiten gedacht, auf denen Kacheln unter
    /// die Leiste scrollen: dort soll die kraeftige Zone kurz sein, damit die
    /// erste Reihe nicht angegraut wird. Auf der Startseite kommt nichts mehr
    /// hinauf — dafuer steht dort ein Querbild, und auf hellen Motiven sieht
    /// man jede Stufe als Band. Hier zaehlt nur Weichheit.
    var weich = false

    /// Die Stützpunkte in **Punkten**, nicht in Bruchteilen.
    ///
    /// Bruchteile waren ein Fehler, der sich zweimal gerächt hat: sobald sich
    /// `kopfhoehe` änderte, wanderte die ganze Kurve mit, und die kräftige
    /// Zone endete plötzlich neben der Leiste. So gerechnet hängt jeder Punkt
    /// an der Unterkante der Leiste und bleibt dort.
    ///
    /// Lücke und Weichheit sind **dieselbe Schraube**, und das ist der
    /// Grund, warum hier schon mehrfach hin und her gestellt wurde: je
    /// weiter der Abfall gezogen wird, desto weicher wird er — und desto
    /// tiefer muss die erste Reihe beginnen, damit er sie nicht angraut.
    ///
    /// Der Ausweg ist, nicht auf null zu zielen: beim Reihentitel liegen
    /// noch rund 10 Prozent an, und das sieht auf weißer Schrift niemand.
    /// Der Abfall darf deshalb kurz sein (104 Punkte), der Ausklang läuft
    /// trotzdem über 220 aus — nur eben unsichtbar leise statt sichtbar
    /// endend.
    private var stuetzpunkte: [Gradient.Stop] {
        let gesamt = kopfhoehe + ausklang
        func punkt(_ y: CGFloat, _ deckung: Double) -> Gradient.Stop {
            Gradient.Stop(color: Stil.grund.opacity(deckung),
                          location: min(max(y / gesamt, 0), 1))
        }
        if weich {
            return [
                punkt(0,                    0.72),
                punkt(kopfhoehe,            0.44),
                punkt(kopfhoehe + ausklang * 0.45, 0.14),
                punkt(gesamt,               0.00),
            ]
        }
        return [
            punkt(0,               0.92),
            punkt(kopfhoehe,       0.90),
            punkt(kopfhoehe +  18, 0.72),
            punkt(kopfhoehe +  36, 0.52),
            punkt(kopfhoehe +  54, 0.34),
            punkt(kopfhoehe +  72, 0.18),
            punkt(kopfhoehe +  86, 0.09),
            punkt(kopfhoehe + 104, 0.04),
            punkt(kopfhoehe + 132, 0.015),
            punkt(gesamt,          0.00),
        ]
    }

    var body: some View {
        LinearGradient(stops: stuetzpunkte, startPoint: .top, endPoint: .bottom)
        .frame(height: kopfhoehe + ausklang)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}


// MARK: - Hinweise

/// Kurze Meldung über allem, die von selbst wieder geht.
///
/// Auf dem iPhone landet jeder Serverfehler hier. Auf tvOS lief
/// `model.errorMessage` bisher ins Leere — Fehler waren schlicht unsichtbar,
/// und wenn etwas nicht ging, wusste niemand warum.
struct Hinweisstreifen: View {
    let text: String
    var schliessen: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
            Text(text)
                .font(Stil.kachel)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Stil.warnung)
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous)
                .strokeBorder(Stil.warnung.opacity(0.3), lineWidth: 2)
        }
        .frame(maxWidth: 1100)
        .task {
            // Von selbst wieder weg: auf tvOS gibt es keinen bequemen Weg,
            // eine Meldung wegzutippen, und stehen bleiben soll sie nicht.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            schliessen()
        }
    }
}

// MARK: - Umbrechende Reihe

/// Rubrik über einer Gruppe von Zeilen.
/// **Normalschreibung, nicht Versalien** — dieselbe Entscheidung wie am
/// iPhone: Versalien lassen sich schlechter lesen, brauchen Sperrung, um
/// ueberhaupt lesbar zu sein, und 21 Punkt war ueber einer Gruppe, deren
/// Zeilen 30 tragen, leiser als das, was er ueberschreibt. Auf drei Meter
/// zaehlt das doppelt.
struct Gruppentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Stil.reihe)
            .tracking(Stil.sperrungReihe)
            .foregroundStyle(Stil.schriftLeise)
            .padding(.leading, 26)
            .padding(.bottom, 16)
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
