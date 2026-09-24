import JellyfinKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Maße, Schriftgrößen und Bausteine für das iPhone. Die Farben stehen in
/// `Farben.swift`, weil sie sich beide Plattformen teilen.
///
/// Bewusst weg von iOS-Standardmaterialien: kein `.ultraThinMaterial`, keine
/// Glaseffekte, keine Systemhintergründe. Flächen sind flach und
/// undurchsichtig, damit das Bildmaterial die einzige Farbe im Raum ist.
extension Stil {

/// **Was bei „Bewegung reduzieren" an die Stelle jeder Kurve tritt.**
///
/// Apple ersetzt Bewegung nicht durch Stillstand, sondern durch eine kurze
/// Ueberblendung — ein harter Schnitt waere schlechter als eine sanfte
/// Bewegung. Die 0,14 Sekunden standen viermal woertlich in den Kurven
/// darunter: dieselbe Rolle, vier Fundstellen, und wer eine fuenfte Kurve
/// schreibt, tippt sie ein fuenftes Mal. (`umschalten` hat ihre eigene,
/// kuerzere Blende von 0,10 — die gehoert zu einem Schalter, nicht zu einem
/// Seitenwechsel.)
static let blendeReduziert: Animation = .linear(duration: 0.14)

    /// Wie ein Bereich wechselt: der Inhalt kommt aus einer Spur zu klein
/// heran und blendet dabei ein.
///
/// **Sehr wenig, mit Absicht.** 0,97 und 0,22 Sekunden — man sieht es nicht,
/// man merkt es. Genau so macht es iOS beim Wechsel zwischen Reitern, und
/// genau deshalb fühlt sich ein Wechsel dort weich an statt wie ein Schnitt.
static var bereichswechsel: Animation {
    bewegungReduziert ? blendeReduziert
                      : .snappy(duration: 0.20, extraBounce: 0)
}
/// Wie stark der eintretende Bereich zusammengezogen anfängt.
///
/// **0,995, und dreimal nach unten korrigiert.** Mit 0,97 wanderte die
/// Oberkante einer 844 Punkt hohen Seite zwölf Punkt nach innen, mit 0,99 noch
/// vier — beides war als Kante zu sehen. Zwei Punkte sind die Grenze, an der
/// die Bewegung noch trägt und nichts mehr auffällt.
static var bereichsmass: CGFloat { bewegungReduziert ? 1 : 0.995 }

/// Wie Inhalt erscheint, wenn er vom Server angekommen ist.
///
/// **Der Ladering ist aus der Oberfläche verschwunden.** Er stand auf jeder
/// Seite, die etwas holt, und ein drehender Ring sagt nur „warte" — er zeigt
/// weder, was kommt, noch wie viel. An seiner Stelle stehen jetzt Platzhalter
/// in der Form des kommenden Inhalts, und wenn er da ist, wird überblendet.
static var einblenden: Animation {
    bewegungReduziert ? blendeReduziert : .smooth(duration: 0.28)
}

/// Wie ein Blatt von unten hereinfährt.

/// Wie ein Blatt von unten hereinfährt.
    ///
    /// **Auf Apples Blatt gelegt, nicht geraten.** Schnell heran, kein
    /// Nachschwingen — dieselbe Kennlinie, die `.sheet` zeigt. Sie steht
    /// hier und nicht an den Aufrufstellen, weil sonst vier Blätter vier
    /// Kurven hätten.
    static var blattbewegung: Animation {
        bewegungReduziert ? blendeReduziert
                          : .spring(response: 0.35, dampingFraction: 0.86)
    }

    /// **Eine Zeile, die auf den Druck antwortet — nicht erst auf das Loslassen.**
    ///
    /// `onTapGesture` kennt keinen Druckzustand: zwischen Auflegen und
    /// Loslassen passiert nichts, und genau in dieser Zehntelsekunde
    /// entscheidet sich, ob eine Oberflaeche wach wirkt. Apple legt die
    /// Rueckmeldung deshalb auf den Druck; `apple-design` nennt das den
    /// Punkt, an dem das Gefuehl von Unmittelbarkeit „von der Klippe faellt".
    ///
    /// **Zeilen dunkeln ab, Knoepfe schrumpfen.** Eine bildschirmbreite
    /// Zeile, die sich zusammenzieht, sieht aus wie ein Fehler; ein kleiner
    /// Knopf, der nur die Farbe wechselt, wirkt matt. Deshalb zwei Stile
    /// und nicht einer.
    /// **Der Druck kommt sofort, das Loslassen darf nachklingen.**
    ///
    /// Beides gleich schnell zu machen war mein erster Griff und ist falsch:
    /// eine Rueckmeldung auf den Finger darf keine Dauer haben — jede
    /// Millisekunde dort ist die, an der Unmittelbarkeit verlorengeht. Das
    /// Zurueckgehen dagegen ist eine Systemantwort und darf weich sein.
    /// `nil` heisst hier ausdruecklich „ohne Animation", nicht „Vorgabe".
    static func druckkurve(_ gedrueckt: Bool) -> Animation? {
        // easeOut, nicht linear: das Loslassen soll auslaufen, nicht
        // abbrechen. Die Dauer stand richtig, die Kurve nicht.
        gedrueckt ? nil : .easeOut(duration: 0.12)
    }

    struct Druckzeile: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(Stil.schrift.opacity(configuration.isPressed ? 0.06 : 0))
                .animation(Stil.druckkurve(configuration.isPressed),
                           value: configuration.isPressed)
        }
    }

    struct Druckknopf: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !bewegungReduziert ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Stil.druckkurve(configuration.isPressed),
                           value: configuration.isPressed)
        }
    }

    /// **Ein kurzer Ruck zur Bestaetigung.**
    ///
    /// Apples „Designing Fluid Interfaces" behandelt Haptik nicht als
    /// Zierrat, sondern als zweiten Kanal derselben Rueckmeldung: Bewegung
    /// sagt *was* passiert, der Ruck sagt *dass* es passiert ist. Ohne ihn
    /// wirkt ein Knopf, der eine Netzanfrage anstoesst, unentschlossen.
    ///
    /// **Nur auf dem Telefon.** Ein Fernseher hat nichts, was rucken
    /// koennte, und auf dem Mac gibt es das nur unter dem Trackpad — dort
    /// waere es an einem Knopf eher irritierend.
    ///
    /// Ausgeloest wird beim **Druck**, nicht nach der Antwort des Servers:
    /// ein Ruck, der eine halbe Sekunde spaeter kommt, gehoert gefuehlt zu
    /// nichts mehr.
    /// `erfolg` stand hier als dritter Fall und wurde nie ausgeloest — eine
    /// Meldung, die der Server bestaetigt, kommt zu spaet fuer einen Ruck
    /// (siehe oben: ausgeloest wird beim Druck). Heraus damit, statt sie als
    /// Angebot stehen zu lassen.
    enum Ruckart { case leicht, mittel }

    @MainActor
    static func ruck(_ art: Ruckart) {
        #if os(iOS)
        guard !bewegungReduziert else { return }
        switch art {
        case .leicht:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .mittel:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        #endif
    }

    /// **Hat der Nutzer „Bewegung reduzieren" eingeschaltet?**
    ///
    /// Apple ersetzt Bewegung dann durch eine Ueberblendung, nicht durch
    /// Stillstand — ein harter Schnitt waere schlechter als eine sanfte
    /// Bewegung. Deshalb geben die Kurven oben in diesem Fall eine kurze
    /// lineare Blende zurueck und `bereichsmass` faellt auf 1, sodass gar
    /// nichts mehr skaliert.
    ///
    /// **Hier zentral und nicht an 31 Aufrufstellen.** `einblenden` steht
    /// allein 31-mal im Code; jede Stelle einzeln fragen zu lassen waere
    /// genau die Sorte Doppelung, die spaeter auseinanderlaeuft.
    static var bewegungReduziert: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return false
        #endif
    }


    // MARK: Maße — iPhone

    /// **Die Eckenskala — vier Zahlen, und je größer die Fläche, desto
    /// runder.** Sie stand nicht als Regel da, sondern als vier Zahlen an
    /// vierzig Stellen; prompt hat der Auskunftskasten auf der Seerr-Seite das
    /// Feldmaß genommen, obwohl er eine Fläche ist. Wer etwas Neues baut,
    /// nimmt die Zahl, die zur Art des Dings passt — nicht die, die gerade in
    /// der Nähe stand.
    ///
    /// | Was | Ecke | |---|---| | Knopf, Plakat, Kachel | 10 | | Feld, Eingabe
    /// | 12 | | Fläche, Blatt, Tafel | 16 | | Chip, Hinweis | Kapsel |
    ///
    /// **Am 06.09.2026 einmal aufgerundet, um vier Punkte.** Vorher stand
    /// 6/8/10/12, und Zwei Punkte Unterschied zwischen zwei Dingen, die
    /// nebeneinander stehen, liest man nicht als Rangfolge, sondern als
    /// Versehen.
    ///
    /// Knopf und Kachel tragen deshalb **dieselbe** Ecke — beides sind kleine
    /// Gegenstände, und die Rangfolge fängt erst darüber an. „Nicht so extrem
    /// viel, aber einfach ein bisschen mehr."
    static let ecke: CGFloat = 10
    /// Plakate und Kacheln — dieselbe Ecke wie ein Knopf.
    static let eckeKachel: CGFloat = 10
    /// Such- und Eingabefelder.
    static let eckeFeld: CGFloat = 12

    /// **Die kleine Ecke, fuer Dinge unter 34 Punkt Hoehe.** Die Ecke waechst
    /// mit dem Ding: 10 auf 48 Hoehe sind 0,21, und dasselbe Verhaeltnis ergibt
    /// auf 30 Hoehe die 8. Traegt das Staffelfeld und die Plaketten.
    static let eckeKlein: CGFloat = 8
    /// Was eine eigene Fläche ist: die Tafel, Auskunftskästen.
    ///
    /// **Nicht das Blatt von unten** — das nimmt `eckeBlatt` (28) und stand
    /// hier trotzdem als Beispiel. Wer den Vermerk las, statt den Baustein
    /// aufzuschlagen, baute ein Blatt mit 16.
    static let eckeFlaeche: CGFloat = 16

    /// **Die Karte: 14.** Sie trug `eckeFlaeche` (16) und war damit so rund wie
    /// ein Blatt — zwei Bauarten mit einer Ecke. 14 steht in der Leiter genau
    /// fuer Karten und Gruppen.
    static let eckeKarte: CGFloat = 14

    /// **Das Blatt von unten: 28.** Es trug 16 und sah damit kantiger aus als
    /// jedes Systemblatt daneben.
    static let eckeBlatt: CGFloat = 28
    static let randAbstand: CGFloat = 18
    static let kachelAbstand: CGFloat = 12
    static let reihenAbstand: CGFloat = 28

    /// Poster sind überall hochkant, 2:3. Von 132 × 198 verkleinert: die
    /// Kacheln waren zu wuchtig, mehr passt nebeneinander.
    static let kachelBreite: CGFloat = 112
    static let kachelHoehe: CGFloat = 168

    /// Heldenbild auf den Detailseiten — für Film und Serie **gleich**.
    static let heldHoehe: CGFloat = 300

    /// Höhe der Navigationsleiste ohne den Bereich des Home-Indikators.
    static let leisteHoehe: CGFloat = 54

    /// **Der Weg, ueber den die Wertreihe zugeht — und den sie freigibt.**
    ///
    /// 30 Punkt Pillenhoehe plus die 14 Abstand darueber.
    static let wertreihenWeg: CGFloat = 44


    // MARK: Maße — iPad

    /// Die Leiste liegt auf dem iPad **links**, nicht oben.
    ///
    /// Der Fernseher hat sie oben, und die Versuchung war groß, das
    /// abzuschreiben. Dort bedient aber eine Fernbedienung — Erreichbarkeit
    /// spielt keine Rolle. An einem gehaltenen iPad ist die obere Kante die
    /// schlechteste Stelle überhaupt. Vom Fernseher kommt deshalb die
    /// Komposition der Seiten, nicht die Griffhöhe.
    ///
    /// 88 Punkt, weil die Wortmarke bei 20 Punkt Höhe 59 breit ist und mit
    /// je 14 Punkt Luft hineinpasst.
    static let seitenleisteBreite: CGFloat = 88

    /// Seitlicher Rand auf der breiten Fassung. Zwischen iPhone (18) und
    /// Fernseher (80); dort sind die 80 zur Hälfte Überstrahlung am Bildrand,
    /// die es hier nicht gibt.
    static let randSeiteBreit: CGFloat = 28

    /// Heldenbild auf der breiten Fassung.
    ///
    /// Bemisst sich am **Inhalt**, nicht am Schirm: Poster 252 plus 40 unten
    /// plus 128 Luft oben. Auf dem Fernseher füllt das Heldbild die ganzen
    /// 1080 Punkt, und das trägt dort auch — auf 768 hieße volle Höhe nur,
    /// dass man zur Beschreibung erst scrollen muss.
    static let heldHoeheBreit: CGFloat = 420

    /// Poster auf den Detailseiten der breiten Fassung: 2:3 wie überall.
    static let heldPosterBreite: CGFloat = 168
    static var heldPosterHoehe: CGFloat { heldPosterBreite * 1.5 }

    /// Zielbreite einer Kachel im Raster. Geht in `spalten(nutzbar:breit:)`.
    ///
    /// Schmal 104, und das ist nicht frei gewählt: damit ergibt die Formel auf
    /// **jedem** iPhone genau drei Spalten, von 375 (SE) bis 440 (Pro Max).
    /// Der ausgelieferte Stand bleibt Zeichen für Zeichen, wie er ist.
    ///
    /// Breit 124. Mit 104 auch auf dem iPad kamen dort neun Spalten heraus
    /// und damit Kacheln von 104 Punkt — **schmaler als auf dem iPhone**, wo
    /// sie 110 messen. Auf dem größten Schirm die kleinsten Plakate: das war
    /// im Bild sofort zu sehen und ist offensichtlich verkehrt herum.
    static func kachelZiel(breit: Bool) -> CGFloat { breit ? 124 : 104 }

    /// Breite für Fließtext und Listenzeilen auf der breiten Fassung.
    ///
    /// Eine Beschreibung über 1036 Punkt ist eine Zeile mit 140 Zeichen, und
    /// eine Folgenzeile über 1036 Punkt setzt den Haken einen halben Meter
    /// neben den Titel. Galerien und Raster gehen weiter über die volle
    /// Breite — die sind zum Überfliegen da, nicht zum Lesen.
    static let lesebreite: CGFloat = 700

    static func rand(breit: Bool) -> CGFloat { breit ? randSeiteBreit : randAbstand }

    /// Wo die Haarlinie zwischen zwei Zeilen beginnt: hinter dem Symbol.
    ///
    /// Die 52 auf dem iPhone sind nicht frei gewählt, sondern Rand 18 plus
    /// Symbol 20 plus Abstand 14. Mit dem breiten Rand werden daraus 62 —
    /// wer nur den Rand ändert und diese Zahl stehen lässt, bekommt Linien,
    /// die gegenüber dem Text verrutschen.
    ///
    /// **Nicht bündig mit dem Text, und das ist keine Nachlässigkeit,
    /// sondern eine Messung.** `Trennlinie` bringt selbst noch
    /// `.padding(.leading, randAbstand)` mit; die Linie beginnt deshalb
    /// weitere 18 Punkt weiter rechts als der Text. Auf dem iPhone ist das
    /// seit jeher so. Diese Formel gibt genau dasselbe Verhältnis auch auf
    /// dem iPad — am Simulator nachgemessen: Text bei 167, Linie bei 184.
    static func trennEinzug(breit: Bool) -> CGFloat { rand(breit: breit) + 34 }

    /// Derselbe Einzug **innerhalb einer Karte**.
    ///
    /// Die Karte ist schon um `rand` eingerueckt; wer dort den vollen Einzug
    /// nimmt, schiebt die Haarlinie um genau diesen Rand zu weit nach rechts.
    /// `Trennlinie` bringt ihre eigenen 18 mit — deshalb 34 und nicht 52.
    static func trennEinzugKarte(breit: Bool) -> CGFloat { 34 }

    /// Wie tief unter dem sicheren Bereich eine Seitenkopfzeile beginnt.
    ///
    /// Derselbe Wert, mit dem die Wortmarke in der Seitenleiste sitzt — sonst
    /// stehen Überschrift und Wortmarke auf verschiedenen Höhen, und das
    /// sieht man sofort: die Seite fängt oben an, die Leiste daneben ein
    /// Stück tiefer.
    static let kopfOben: CGFloat = 26

    /// Kachelmaße der Reihen auf der Startseite.
    ///
    /// Auf dem iPhone messen Reihe und Raster praktisch dasselbe — 112 gegen
    /// 110 —, und auf dem Fernseher steht für beides eine einzige Zahl (208).
    /// Auf dem iPad wuchs nur das Raster mit der Breite, die Reihen blieben
    /// bei 112: dasselbe Plakat war auf der Startseite ein Fünftel kleiner
    /// als in der Bibliothek. Auf einem Gerät, zwei Größen.
    ///
    /// Die Reihen bleiben trotzdem **fest** — sie zeigen bei mehr Platz mehr,
    /// nicht Größeres. Nur der feste Wert ist breit ein anderer, gewählt in
    /// der Mitte dessen, was das Raster dort ergibt: 126 hochkant, 138 quer.
    static func reihenBreite(breit: Bool) -> CGFloat { breit ? 132 : kachelBreite }
    static func reihenHoehe(breit: Bool) -> CGFloat { reihenBreite(breit: breit) * 1.5 }

    /// Waagerecht 16:9 für „Weiterschauen", rund doppelt so breit wie ein
    /// Poster — dasselbe Verhältnis wie auf dem iPhone (236 zu 112) und auf
    /// dem Fernseher (448 zu 208).
    static func reihenQuerBreite(breit: Bool) -> CGFloat { breit ? 280 : 236 }
    static func reihenQuerHoehe(breit: Bool) -> CGFloat { breit ? 158 : 133 }

    /// Ab dieser Fensterbreite liegen Abspielknopf und Aktionsreihe
    /// nebeneinander. Poster 168 + 32 Abstand + rund 620 Knopfreihe + zweimal
    /// Rand ergeben knapp 900.
    static let querKopfAbBreite: CGFloat = 900

    /// Breite für Anmeldung, Server und Quick Connect.
    ///
    /// Ein Eingabefeld über 1288 Punkt ist kein Feld mehr, sondern ein
    /// Streifen — und der Weg vom Anfang der Zeile zum Knopf darunter ist
    /// absurd. 420 ist die Breite, die dieselben Seiten auf einem großen
    /// iPhone haben; mehr braucht ein Formular aus drei Zeilen nicht.
    static let formularbreite: CGFloat = 420

    /// Wie viele Spalten in die nutzbare Breite passen.
    ///
    /// Der Fernseher hat dafür eine Konstante (`gitterSpalten = 7`), und das
    /// genügt dort: sein Schirm ist immer 1920 breit. Ein iPad ist es nicht —
    /// im geteilten Bildschirm bleiben davon 320 übrig.
    ///
    /// Mindestens zwei. Bei 320 Punkt Fensterbreite wären drei Kacheln
    /// 87 Punkt breit, und darunter ist ein Poster kein Poster mehr.
    static func spalten(nutzbar: CGFloat, breit: Bool) -> Int {
        max(2, Int((nutzbar + kachelAbstand) / (kachelZiel(breit: breit) + kachelAbstand)))
    }

    /// Ob das Gerät ein iPad ist — unabhängig davon, wie breit das Fenster
    /// gerade ist.
    ///
    /// `@MainActor`, und das ist nicht Zierde: `UIDevice.current` gehört dem
    /// Hauptakteur. Ohne die Angabe stand hier eine nicht isolierte
    /// Eigenschaft, die auf Zustand des Hauptakteurs zugreift — dieselbe
    /// Klasse Fehler wie in der Wiedergabezentrale, nur andersherum. Der
    /// Übersetzer hat sie hier gemeldet, weil ich nichts zugesichert hatte,
    /// was er hätte glauben können.
    @MainActor
    static var amPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: Schrift — iPhone

    // Durchweg eine Stufe größer als vorher — die Schrift war zu klein.
    // Maßstab an Plex genommen, die genauen Werte stehen im Canvas unter
    // „Maßstab".
    // Zehn Stufen, mehr nicht. Die Leiter steht in `Notizen/BRAND.md`,
    // Abschnitt 2 — Mac und iPad tragen dieselbe, der Fernseher das Doppelte.
    static let titelGross  = Font.system(size: 28, weight: .bold)
    /// **Derselbe Grad wie `titelGross`.** Der Titel ueber einem Heldbild *ist*
    /// der Seitentitel; eine zweite Stufe fuer dieselbe Rolle heisst nur, dass
    /// irgendwann irgendwo die falsche gilt. Vorher 27.
    static let titel       = Font.system(size: 28, weight: .bold)
    /// **Unterseitentitel.** Er stand in der Leiter (BRAND 2) und hatte
    /// keinen Token — der `Unterseitenkopf` setzte 22 Semibold als Zahl.
    static let unterseitentitel = Font.system(size: 22, weight: .semibold)
    static let reihe       = Font.system(size: 20, weight: .semibold)
    /// Blattrubrik und Detailleiste.
    static let rubrikGross = Font.system(size: 17, weight: .semibold)
    static let listentitel = Font.system(size: 15, weight: .semibold)
    static let koerper     = Font.system(size: 15)
    // **Mitwachsende Fassungen derselben Stufen.**
    //
    // Die Vorlage sagt: „Fliesstext, Listen, Einstellungen und Leerzustaende
    // folgen der Systemschrift. Plakate, Leisten und Player bleiben fest."
    // Genau diese vier Stufen sind es, und sie standen alle fest — wer die
    // Schrift am iPhone groesser stellte, sah in Einstellungen, Profil,
    // Downloads, Suche und allen Listen **keine Aenderung**. Die festen
    // Fassungen bleiben daneben stehen: Kacheln, Leisten und Player brauchen
    // sie, sonst laufen sie aus ihrem Rahmen.
    // Wer sie mitwachsen lassen will, nimmt `.mitwachsend(15, .semibold)`
    // statt `.font(Stil.listentitel)` — der Modifikator rechnet mit
    // `@ScaledMetric`, was eine `Font`-Konstante nicht kann.
    /// Titel unter einem Plakat. Vorher 14 — 14 steht in keiner Leiter, und die
    /// Kachel soll leiser sein als eine Listenzeile.
    static let kachel      = Font.system(size: 13, weight: .medium)
    static let klein       = Font.system(size: 12)
    /// **Versalien, +0,14 em gesperrt — und derzeit ohne Fundstelle.**
    ///
    /// Sie war die Rubrik ueber einer Gruppe. `Gruppentitel` traegt seit dem
    /// Umbau 20 Semibold in Normalschreibung, und mit der Suchrubrik ist die
    /// letzte Stelle weggefallen, die noch 11 in Versalien setzte. Die Stufe
    /// bleibt in der Leiter stehen, weil BRAND 2 sie fuehrt; wer sie wieder
    /// benutzt, soll wissen, dass sie **nicht** die Gruppenrubrik ist.
    static let gruppe      = Font.system(size: 11, weight: .semibold)
    static let plakette    = Font.system(size: 10, weight: .semibold)

    // MARK: Sperrung
    //
    // **Sie gehoert zur Stufe, nicht zur Fundstelle.** Sie stand an
    // siebzehn Stellen als Zahl im Aufruf, und dieselbe Stufe trug dabei
    // zwei Werte: die Reihenueberschrift −0,24 im Baustein und −0,3 in
    // `HomeView`, die Blattrubrik −0,136 hier und −0,14 im Profil, der
    // Leerzustand −0,3 auf 20 Punkt statt −0,24. Kein Ausrutscher, sondern
    // die Folge davon, dass die Zahl neben der Schrift stand und nicht bei
    // ihr: wer eine Stufe setzt, schaetzt die Sperrung dazu.
    //
    // Jeder Wert ist der em-Wert aus BRAND 2 mal der Punktgroesse.
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
    /// Sperrung der Plakette: +0,10 em auf 10 Punkt sind 1,0.
    static let plaketteSperrung: CGFloat = 1.0
}

// MARK: - Breite Fassung

private struct BreitSchluessel: EnvironmentKey {
    static let defaultValue = false
}

private struct WeitSchluessel: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Genug Breite, um die Knopfreihe der Detailseite **neben** das Poster
    /// zu legen.
    ///
    /// `breit` allein reicht dafür nicht, und das war ein teurer Irrtum: ein
    /// iPad im Hochformat ist `regular`, hat neben dem Poster aber nur 476
    /// Punkt. „Fortsetzen ab 53 min" plus „Von vorn" plus vier Aktionsknöpfe
    /// brauchen rund 620. SwiftUI hat die Beschriftungen daraufhin senkrecht
    /// gesetzt — ein Buchstabe je Zeile.
    ///
    /// Auf dem Fernseher konnte das nicht auffallen: der ist immer quer.
    var weit: Bool {
        get { self[WeitSchluessel.self] }
        set { self[WeitSchluessel.self] = newValue }
    }

    /// Die breite Fassung: Seitenleiste statt Leiste unten, Detailseiten
    /// quer komponiert, Einstellungen zweispaltig.
    ///
    /// Gesetzt wird sie **einmal** in `RootView` aus Größenklasse und Gerät,
    /// nicht überall neu ausgerechnet. Beide Bedingungen sind nötig: ein
    /// iPhone Pro Max meldet im Querformat ebenfalls `regular`, und dort
    /// wäre eine Seitenleiste falsch — die App liegt dort ohnehin hochkant
    /// fest, aber verlassen will ich mich darauf nicht.
    var breit: Bool {
        get { self[BreitSchluessel.self] }
        set { self[BreitSchluessel.self] = newValue }
    }
}

// MARK: - Schrift, die mitwächst

/// Eine Schriftgröße, die der Systemeinstellung folgt.
///
/// `@ScaledMetric` gibt bei der Standardeinstellung genau die übergebene Zahl
/// zurück — die Gestaltung sieht also unverändert aus und wächst erst, wenn
/// jemand die Schrift größer stellt. Genau deshalb steht hier keine Umstellung
/// auf Apples Textstile: `Font.system(.body)` sind 17 Punkt, unser Fließtext
/// misst 15, und das wäre eine sichtbare Änderung ohne Not.
///
/// **Bewusst nicht überall angewandt.** Kacheln, Navigationsleiste und die
/// Player-Steuerung stehen auf festen Punktmaßen (112 × 168, Leistenhöhe 54,
/// Knöpfe 44). Dort würde größere Schrift aus dem Rahmen laufen, statt ihn zu
/// dehnen. Angewandt ist sie da, wo der Rahmen mitgeht: Fließtext,
/// Listenzeilen, Einstellungen, Leerzustände. Der Rest ist ein eigener
/// Arbeitsblock — er verlangt, jede feste Höhe durchzugehen.
struct Mitwachsend: ViewModifier {
    @ScaledMetric private var groesse: CGFloat
    private let gewicht: Font.Weight

    init(groesse: CGFloat, gewicht: Font.Weight) {
        _groesse = ScaledMetric(wrappedValue: groesse, relativeTo: .body)
        self.gewicht = gewicht
    }

    func body(content: Content) -> some View {
        content.font(.system(size: groesse, weight: gewicht))
    }
}

extension View {
    /// Wie `.font(.system(size:weight:))`, nur folgt die Größe der
    /// Systemeinstellung.
    func mitwachsend(_ groesse: CGFloat, _ gewicht: Font.Weight = .regular) -> some View {
        modifier(Mitwachsend(groesse: groesse, gewicht: gewicht))
    }
}

// MARK: - Knöpfe

/// Der große weiße Knopf, der auf jeder Detailseite oben steht. Weiß mit
/// schwarzer Schrift, damit er über jedem Poster lesbar bleibt.
struct HauptknopfStil: ButtonStyle {
    /// Gesperrt heißt gedämpft, nicht durchscheinend.
    ///
    /// Weiß auf 40 Prozent über unserem Grund ergibt ein kräftiges Grau — das
    /// sieht nach einem Knopf aus, der einfach nicht reagiert, statt nach
    /// einem, der noch auf eine Eingabe wartet. Eine dunkle Fläche mit leiser
    /// Schrift sagt dasselbe wie überall sonst in der App.
    @Environment(\.isEnabled) private var freigegeben

    /// Über die volle Breite, oder nur so breit wie die Beschriftung.
    ///
    /// Schmal ist die volle Breite richtig: der Knopf steht allein in seiner
    /// Zeile. Breit steht er neben der Aktionsreihe und darf sie nicht
    /// wegdrücken.
    var dehnt = true

    /// **Worauf der gesperrte Knopf liegt.** Gesperrt faellt er auf
    /// `flaeche` — auf einem Blatt, das selbst `flaeche` ist, verschwaende er
    /// dann ganz, und es bliebe leise Schrift ohne Knopf. Dort liegt er eine
    /// Stufe hoeher, wie die Karten darueber (Ladeauswahl).
    var gesperrtFlaeche: Color = Stil.flaeche

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Hauptknopf: 17 Semifett. 16 steht in keiner Leiter; 17 ist die
            // Stufe der Blattrubrik, und ein Hauptknopf ist mindestens so laut.
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(freigegeben ? Stil.aufAkzent : Stil.schriftSehrLeise)
            .padding(.horizontal, dehnt ? 0 : 28)
            .frame(maxWidth: dehnt ? .infinity : nil, minHeight: 48)
            .background(flaeche(gedrueckt: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
            // **Auch der Hauptknopf schrumpft.** Er loeste den Druck nur ueber
            // die Flaeche — und war damit der einzige Knopf ohne Massstab. Die
            // Flaeche bleibt: eine weisse Flaeche, die dunkler wird, ist am
            // Finger deutlicher als ein Massstab allein.
            .scaleEffect(configuration.isPressed && !Stil.bewegungReduziert ? 0.97 : 1)
            .animation(Stil.druckkurve(configuration.isPressed),
                       value: configuration.isPressed)
    }

    /// **Weiss, und zwar überall.**
    ///
    /// Hier liess sich einmal eine andere Fläche setzen — für den
    /// Anfragen-Knopf bei Seerr, in Akzent. Das ist wieder heraus: auf einer
    /// Seerr-Seite trägt der Stand schon Akzent, und ein Knopf in derselben
    /// Farbe daneben macht aus einem Zeichen für *Zustand* eine Grundfarbe.
    ///
    /// **E2 sagt genau das:** der Akzent trägt Fortschritt, Auswahl und den
    /// Direct-Play-Beleg — nie die Grundfarbe eines Knopfes. Die Regel stand
    /// da, bevor der Parameter kam.
    private func flaeche(gedrueckt: Bool) -> Color {
        guard freigegeben else { return gesperrtFlaeche }
        return Color.white.opacity(gedrueckt ? 0.75 : 1)
    }
}

/// Zweitrangig: gedämpfte Fläche, weiße Schrift.
///
/// **Dieselbe Höhe wie der Hauptknopf.** Er war zwei Punkte niedriger, und
/// auf der Filmseite wie auf der Anmeldeseite stehen beide direkt
/// übereinander — dort sah man den Versatz. Ein Grund stand nirgends; den
/// Unterschied tragen Fläche und Schriftgrad, die Höhe muss ihn nicht
/// mittragen.
struct NebenknopfStil: ButtonStyle {
    var dehnt = true
    /// **Die Schrift im Akzent, die Flaeche nicht.**
    ///
    /// Fuer den zweiten Weg zum selben Ziel: Quick Connect steht unter dem
    /// Anmeldeknopf und ist kein Ersatz fuer ihn, sondern ein Angebot. Der
    /// Akzent an der Schrift macht ihn sichtbar, ohne eine zweite gefuellte
    /// Flaeche auf die Seite zu bringen — die eine gehoert dem Hauptknopf
    /// (BRAND 5). Paul am 22.09.: „der Quick-Connect-Knopf kann gerne in
    /// Akzentfarbe sein."
    ///
    /// Gerechnet: `akzent` auf `flaeche` traegt 8,55:1.
    var akzent = false
    /// Gesperrt heisst gedaempfte Schrift — dieselbe Begruendung wie am
    /// Hauptknopf, und sie fehlte hier ganz: „Von vorn" sah bedienbar aus,
    /// solange kein Plan da war, und tat nichts.
    @Environment(\.isEnabled) private var freigegeben

    private var schriftfarbe: Color {
        guard freigegeben else { return Stil.schriftSehrLeise }
        return akzent ? Stil.akzent : Stil.schrift
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(schriftfarbe)
            .padding(.horizontal, dehnt ? 0 : 22)
            .frame(maxWidth: dehnt ? .infinity : nil, minHeight: 48)
            // **Der Druck war unsichtbar.** Hier stand
            // `Stil.erhoeht.opacity(1.6)` — Deckkraft ueber 1 klemmt auf 1,0,
            // und `erhoeht` ist deckend: gedrueckt sah Pixel fuer Pixel aus wie
            // ruhend. Jetzt eine eigene, hellere Flaeche.
            .background(configuration.isPressed ? Stil.gedruecktFlaeche : Stil.flaeche,
                        in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
            // Und derselbe Massstab wie an jedem anderen Knopf: ohne ihn war
            // der Nebenknopf der einzige, der beim Druck stillstand.
            .scaleEffect(configuration.isPressed && !Stil.bewegungReduziert ? 0.97 : 1)
            .animation(Stil.druckkurve(configuration.isPressed),
                       value: configuration.isPressed)
    }
}

// MARK: - Kleinteile



/// Dünner Fortschrittsbalken am unteren Rand einer Kachel.
///
/// Misst sich selbst statt am umgebenden Rahmen. `containerRelativeFrame`
/// nahm die Breite des nächsten *Containers* — in einer waagerechten Reihe ist
/// das die ganze Reihe, nicht die Kachel. Der Balken lief dadurch weit über
/// die Kachel hinaus und schob in der Reihe „Weiterschauen" sogar den Titel
/// nach unten. `GeometryReader` geht hier trotzdem nicht: der dehnt sich
/// gierig aus. `onGeometryChange` misst, ohne das Layout anzufassen.
struct Fortschrittsbalken: View {
    let anteil: Double
    /// **Kapsel, wo er frei in einer Zeile steht** — in der Downloadliste.
    /// Auf einer Kachel bleibt er eckig: dort bildet er die Kante des Bildes,
    /// und eine gerundete Kante stuende davor.
    var rund = false
    @State private var breite: CGFloat = 0

    /// **Buendig am unteren Rand, nicht schwebend.**
    ///
    /// Er hat einmal geschwebt — acht Punkt Abstand, Kapselform. Paul am
    /// 21.09. am Geraet: unten sah es besser aus. Ein Balken, der die Kante
    /// bildet, liest sich als Teil des Bildes; einer, der darin schwimmt, als
    /// zweites Ding darauf.
    var body: some View {
        ZStack(alignment: .leading) {
            // **Helle Spur, nicht dunkle.**
            //
            // Sie war einmal hell, wurde dunkel, und die Begruendung dafuer
            // war „ein heller Grauton verschwindet auf hellen Plakaten". Das
            // stimmt fuer einen *Grauton*; Weiss mit 30 Prozent verschwindet
            // nicht, es liegt als Schleier darauf — und es ist das, was
            // Apples TV-App auf ihren Karten zeigt. Paul am 21.09.: „das
            // hatten wir ganz vorher auch hell, das sah besser aus."
            //
            // Der Unterschied ist nicht Geschmack. Dunkel gelesen heisst der
            // Balken „hier fehlt etwas"; hell gelesen heisst er „so lang ist
            // das Ganze, und so weit bist du" — die Spur ist die Laenge, nicht
            // der Rest. Und auf einer Kachel, die selbst dunkel gerahmt ist,
            // verschwand die dunkle Spur in der Kante.
            Rectangle().fill(Color.white.opacity(0.30))
            // Der gefuellte Teil ist selbst eine Kapsel, sonst endet er
            // innen gerade.
            (rund ? AnyShape(Capsule()) : AnyShape(Rectangle()))
                .fill(Stil.akzent)
                .frame(width: breite * min(max(anteil, 0), 1))
        }
        .clipShape(rund ? AnyShape(Capsule()) : AnyShape(Rectangle()))
        // Vier statt drei Punkt — bei drei war er auf den Kacheln kaum zu
        // erkennen.
        .frame(height: 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { breite = $0 }
    }
}

/// Derselbe Balken, aber nur, wenn der Schalter in den Einstellungen es
/// erlaubt.
///
/// Der Schalter heißt „Fortschritt auf Kacheln" und meint genau das — der
/// Balken unter dem Abspielknopf auf der Serienseite bleibt davon unberührt
/// und nimmt deshalb weiter den nackten `Fortschrittsbalken`.
///
/// Dass die Abfrage hier steht und nicht in `Bild`, ist keine Feinheit:
/// `@AppStorage` hängt einen Beobachter an die Voreinstellungen, und in `Bild`
/// bekam den jede Kachel — bei hundert sichtbaren Plakaten hundert Beobachter
/// für einen Schalter, der sich beim Scrollen nie ändert. Hier bekommen ihn
/// nur die wenigen Titel, die überhaupt einen Fortschritt haben.
struct Kachelfortschritt: View {
    let anteil: Double
    @AppStorage("fortschritt") private var zeigen = true

    var body: some View {
        if zeigen { Fortschrittsbalken(anteil: anteil) }
    }
}

/// Bild in fester Größe.
///
/// Wichtig: die Größe kommt vom Rahmen, das Bild legt sich nur darüber.
/// Setzt man stattdessen `aspectRatio(.fill)` direkt auf das Bild, wird es
/// breiter als sein Rahmen — `clipped()` beschneidet dann zwar die Darstellung,
/// nicht aber die Layoutgröße, und der ganze Aufbau drumherum verrutscht.
struct Bild<Platzhalter: View>: View {
    let url: URL?
    var breite: CGFloat?
    var hoehe: CGFloat?
    /// Statt einer festen Höhe: die Höhe folgt der Breite.
    ///
    /// Nötig, sobald die Kachel ihre Spalte füllt, statt ein festes Maß zu
    /// haben. Vorher rechnete das Plakatraster die Höhe aus `kachelBreite`
    /// — auf dem iPhone stimmte das zufällig, weil drei Spalten dort rund
    /// 110 Punkt breit sind. Auf iPad und Mac sind die Spalten breiter, die
    /// Höhe blieb bei 168, und die Plakate standen gestaucht.
    var verhaeltnis: CGFloat?
    var ecke: CGFloat = Stil.ecke
    /// Fortschritt am unteren Rand. Bewusst **hier** und nicht als Auflage
    /// von aussen: eine Auflage liegt ausserhalb der Maske, dann steht der
    /// Balken mit eckigen Enden ueber die runden Ecken hinaus.
    var fortschritt: Double? = nil
    @ViewBuilder var platzhalter: () -> Platzhalter

    /// Profil → Darstellung. Siehe `EnvironmentValues.fortschrittAufKacheln`.
    @Environment(\.fortschrittAufKacheln) private var balkenZeigen

    /// **Laedt ueber ``Bildspeicher``, nicht ueber `AsyncImage`.**
    ///
    /// Hier stand `AsyncImage`, und daneben lag seit dem 05.09.2026 in
    /// `Netzbild.swift` ein Lader, der genau dessen drei Fehler nicht hat: er
    /// entschluesselt abseits des Hauptlaufs, merkt sich das Ergebnis und
    /// rechnet auf die noetige Kantenlaenge herunter. Am 10.09.2026
    /// nachgesehen, wer ihn benutzt: der Mac, die Downloadseite und das
    /// Profilzeichen. **Die Startseite und die Bibliothek nicht** — also
    /// ausgerechnet die beiden Flaechen, ueber die gescrollt wird und auf
    /// denen fuenfzig Plakate gleichzeitig entschluesseln.
    ///
    /// Gebaut und nicht angeschlossen, dieselbe Klasse wie die beiden
    /// Downloadregeln. Kein Test sieht so etwas: beide Lader funktionieren.
    ///
    /// **Der Anlaufzaehler faellt damit weg**, und das ist kein Verlust. Er
    /// zaehlte `NSURLErrorCancelled` mit — den Abbruch, den `AsyncImage` von
    /// sich aus ausloest, sobald seine Kachel den Schirm verlaesst, um danach
    /// im Fehlerzustand stehenzubleiben. Ein Verband um eine fremde
    /// Eigenschaft. `Bildspeicher` holt mit einer eigenen Aufgabe, die an der
    /// Kachel nicht haengt; es gibt nichts abzubrechen und nichts zu
    /// wiederholen.
    @State private var geladen: Image?
    @State private var sichtbar = false
    /// Kein Bild zu erwarten: keine Adresse, oder der Abruf kam ohne eines
    /// zurueck. Erst dann tritt das Zeichen des Aufrufers ein — nicht schon
    /// waehrenddessen, sonst blitzt es vor jeder Kachel kurz auf.
    @State private var ohneBild = false

    /// **Bekanntes einmal beim Anlegen nachschlagen, nicht bei jedem Zeichnen.**
    ///
    /// Hier stand der Griff in den Speicher im `body`. Das sah harmlos aus
    /// und war es nicht: `Bildspeicher.bild(_:)` zerlegt zuerst die Adresse,
    /// um das Zugangsmerkmal herauszunehmen — `URLComponents`, filtern,
    /// wieder zusammensetzen. Im `body` heisst das: bei **jedem** Durchgang,
    /// fuer **jede** Kachel, auf dem Hauptlauf. Eine Detailseite zeichnet
    /// viele Bilder und laeuft dabei durch mehrere Durchgaenge; das war
    /// Arbeit, die dem Laden die Bahn wegnahm, ohne je etwas beizutragen.
    ///
    /// Deshalb hier, wie es `Netzbild` von Anfang an macht: einmal fragen,
    /// bevor gezeichnet wird. Ein nachgereichter Wert kaeme einen Durchgang
    /// zu spaet, und der eine Durchgang ist das Aufblitzen.
    @MainActor
    init(url: URL?, breite: CGFloat? = nil, hoehe: CGFloat? = nil,
         verhaeltnis: CGFloat? = nil, ecke: CGFloat = Stil.ecke,
         fortschritt: Double? = nil,
         @ViewBuilder platzhalter: @escaping () -> Platzhalter) {
        self.url = url
        self.breite = breite
        self.hoehe = hoehe
        self.verhaeltnis = verhaeltnis
        self.ecke = ecke
        self.fortschritt = fortschritt
        self.platzhalter = platzhalter
        let sofort = url.flatMap { Bildspeicher.geteilt.bild($0) }
        _geladen = State(initialValue: sofort)
        _sichtbar = State(initialValue: sofort != nil)
        _ohneBild = State(initialValue: url == nil)
    }

    var body: some View {
        rahmen
            .overlay {
                if let geladen {
                    geladen.resizable().aspectRatio(contentMode: .fill)
                        .opacity(sichtbar ? 1 : 0)
                } else if url != nil, !ohneBild {
                    // **Waehrend des Ladens steht kein Zeichen da.** Der
                    // Platzhalter der Aufrufer ist das Filmsymbol und heisst
                    // „zu diesem Titel gibt es kein Bild". Waehrend des Abrufs
                    // ist das schlicht falsch, und man sah es.
                    Ladefeld(ecke: 0)
                } else {
                    platzhalter()
                }
            }
            .task(id: url) {
                guard let url else { geladen = nil; ohneBild = true; return }
                ohneBild = false
                if let da = Bildspeicher.geteilt.bild(url) {
                    geladen = da
                    sichtbar = true
                    return
                }
                geladen = nil
                sichtbar = false
                // **Die Kachel kennt ihre Groesse, also sagt sie sie.**
                //
                // Ohne Angabe wird jedes Bild auf 1200 Punkt entschluesselt —
                // fuer ein Plakat in 112 Punkt Breite das Zwoelffache an
                // Speicher. Der Bildschirm hat hoechstens drei Bildpunkte je
                // Punkt; etwas dazu, damit ein Plakat beim Federn nicht
                // ausfranst, und mehr braucht niemand.
                //
                // Wo keine feste Breite vorliegt (im Raster gibt die Spalte
                // sie vor), bleibt es bei der vollen Kantenlaenge.
                let noetig = [breite, hoehe].compactMap { $0 }.max()
                    .map { Int($0 * 3.2) }
                guard let neu = await Bildspeicher.geteilt.laden(url, kante: noetig) else {
                    ohneBild = true
                    return
                }
                geladen = neu
                withAnimation(Stil.einblenden) { sichtbar = true }
            }
            .overlay(alignment: .bottom) {
                // **Null ist kein Fortschritt.**
                //
                // Hier stand nur `if let fortschritt`. Jellyfin liefert an
                // einem nie angefangenen Titel aber nicht `nil`, sondern
                // **0** — der Balken wurde also gezeichnet, nur mit Breite
                // null. Solange seine Spur dunkel war, fiel das kaum auf;
                // seit sie hell ist (weiss 30 %), liegt auf jeder nicht
                // angefangenen Serie ein heller Streifen. Paul am 22.09.:
                // „Streifen taucht auch auf bei nicht angefangenen Serien."
                //
                // Ein Balken sagt „so weit bist du". Wer nicht angefangen
                // hat, hat keine Stelle, und dann gehoert dort nichts hin.
                if let fortschritt, fortschritt > 0, balkenZeigen {
                    Kachelfortschritt(anteil: fortschritt)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: ecke, style: .continuous))
    }

    /// Die Flaeche, an der sich alles misst.
    private var flaeche: some View {
        Color.clear
            .frame(width: breite, height: hoehe)
            .frame(maxWidth: breite == nil ? .infinity : nil)
    }

    /// **`aspectRatio` nur, wenn es ein Verhaeltnis gibt.**
    ///
    /// `aspectRatio(nil, contentMode: .fit)` heisst nicht „lass es bleiben",
    /// sondern „nimm das Verhaeltnis des Inhalts" — und der Inhalt ist hier
    /// ein `Color.clear`, das keins hat. Wo eine Breite gesetzt ist, faellt
    /// das nicht auf: die Flaeche steht dann ohnehin fest. Wo nur eine Hoehe
    /// gesetzt ist, bleibt nichts uebrig, woran die Breite haengt — die
    /// Flaeche fiel auf einen Streifen am linken Rand zusammen.
    ///
    /// Genau so kam `Heldbild` daher (Hoehe ja, Breite nein, Verhaeltnis
    /// nein), und damit das Bild oben auf jeder Detailseite im schmalen
    /// Aufbau. Das Verhaeltnis kam nachtraeglich aus main dazu, fuer das
    /// Plakatraster; die Aufrufer ohne eines waren nicht mitgedacht.
    @ViewBuilder
    private var rahmen: some View {
        if let verhaeltnis {
            flaeche.aspectRatio(verhaeltnis, contentMode: .fit)
        } else {
            flaeche
        }
    }
}

extension Bild where Platzhalter == Color {
    init(url: URL?, breite: CGFloat? = nil, hoehe: CGFloat? = nil,
         verhaeltnis: CGFloat? = nil, ecke: CGFloat = Stil.ecke,
         fortschritt: Double? = nil) {
        self.init(url: url, breite: breite, hoehe: hoehe,
                  verhaeltnis: verhaeltnis, ecke: ecke,
                  fortschritt: fortschritt) {
            Stil.flaeche
        }
    }
}

/// Eigene Auswahl statt `Menu` oder `Picker`.
///
/// Apples Menü bringt sein eigenes Erscheinungsbild mit — abgerundetes Glas,
/// eigene Schrift, eigene Abstände. Das steht neben unserer flachen, dunklen
/// Gestaltung wie ein Fremdkörper. Diese Auswahl gehört uns vollständig:
/// abgedunkelter Grund, flache Fläche, unsere Schrift, unser Akzent.
struct Auswahlblatt<Eintrag: Identifiable>: View {
    @Binding var offen: Bool
    /// Wie hoch die Einträge zusammen sind — gemessen, nicht angenommen.
    @State private var inhaltshoehe: CGFloat = 0
    let titel: LocalizedStringKey
    let eintraege: [Eintrag]
    let beschriftung: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    let waehlen: (Eintrag) -> Void
    /// **Eine Rubrik vor einem Eintrag** — Trennstrich, darunter die
    /// Überschrift. Im Titelmenü von Filme und Serien steht so „Bibliotheken"
    /// über den einzelnen Bibliotheken, abgesetzt von „Alle" und
    /// „Sammlungen", die keine Bibliotheken sind.
    var rubrik: (Eintrag) -> LocalizedStringKey? = { _ in nil }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .blatt(offen: $offen) {
                Blattrubrik(text: Text(titel))

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(eintraege) { eintrag in
                            if let ueber = rubrik(eintrag) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Trennlinie()
                                    Text(ueber)
                                        .font(Stil.gruppe)
                                        .tracking(Stil.sperrungGruppe)
                                        .textCase(.uppercase)
                                        .foregroundStyle(Stil.schriftSehrLeise)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, Stil.randAbstand)
                                        .padding(.top, Stil.kachelAbstand)
                                        .padding(.bottom, 4)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                            Button {
                                waehlen(eintrag)
                                offen = false
                            } label: {
                                // **Die Auswahlzeile, wie im Player.**
                                //
                                // Der Haken steht **links** und ist immer da —
                                // als Platz, auch wenn er nichts zeigt. Sonst
                                // ruecken alle Beschriftungen, sobald sich die
                                // Wahl aendert.
                                //
                                // Gewaehlt heisst **volles Weiss und Semifett**,
                                // nicht Akzent: der Akzent traegt Zustand, nie
                                // Rangfolge, und „das hier ist es" ist
                                // Rangfolge. Vorher stand der Haken rechts und
                                // in Tuerkis, und die Zeile war 50 hoch.
                                // **17, nicht 15 — und 52 hoch, nicht 40.**
                                //
                                // Ein Blatt, das von unten kommt, ist kein
                                // Listenausschnitt in einer Seite: es steht
                                // fuer sich, hat nur wenige Zeilen und den
                                // ganzen Platz dafuer. Mit 15 auf 40 sassen
                                // sie aufeinander wie Kleingedrucktes. Paul am
                                // 21.09.: „der Abstand zwischen den Zeilen ist
                                // zu klein, die Zeilen sind selber so duenn —
                                // das sieht zusammengedrueckt aus."
                                //
                                // 17 ist Apples `body` (ausgelesen mit
                                // `Werkzeuge/systemfarben.sh`) und der Grad,
                                // den jedes Systemmenue hier setzt; 52 gibt
                                // der Zeile oben und unten gut 17 Punkt Luft.
                                HStack(spacing: 14) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(istGewaehlt(eintrag) ? Stil.schrift : .clear)
                                        .frame(width: 18)
                                    Text(beschriftung(eintrag))
                                        .font(.system(size: 17,
                                                      weight: istGewaehlt(eintrag) ? .semibold : .regular))
                                        .foregroundStyle(istGewaehlt(eintrag) ? Stil.schrift
                                                                              : Stil.schriftLeise)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Stil.randAbstand)
                                // `minHeight`: mit groesserer Schrift muss die
                                // Zeile wachsen duerfen, sonst schneidet sie an.
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(Stil.Druckzeile())
                        }
                    }
                    // Gemessen, nicht angenommen — siehe unten.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { inhaltshoehe = $0 }
                }
                // **So hoch wie die Einträge, höchstens 340.**
                //
                // `.frame(maxHeight:)` allein reicht nicht: eine `ScrollView`
                // ist senkrecht gierig und nimmt sich die 340 auch dann, wenn
                // vier Zeilen nur 204 brauchen. Übrig blieb ein Hohlraum unter
                // der letzten Zeile, der nichts tut.
                .frame(height: min(inhaltshoehe, 340))
                .scrollIndicators(.hidden)

                Blattabbruch { offen = false }
            }
    }
}

/// Eigener Schalter statt `Toggle`.
///
/// Apples Schalter bringt eigene Maße, eigenen Radius und eigene Animation
/// mit und wirkt neben flachen Flächen wie ein Fremdkörper.
struct Schalter: View {
    @Binding var an: Bool
    /// **Gesperrt heisst gedaempft, nicht durchscheinend** (BRAND 5).
    ///
    /// Beide Knopfstile kennen den Zustand laengst, `Schalter` und
    /// `Eingabefeld` kannten ihn gar nicht: ein gesperrter Schalter stand in
    /// vollem Akzent da und sah bedienbar aus. Die Zuordnung ist dieselbe wie
    /// am Hauptknopf — die gefuellte Flaeche faellt auf `flaeche`, das
    /// Weisse darauf auf `schriftSehrLeise`.
    @Environment(\.isEnabled) private var bedienbar

    var body: some View {
        Button {
            an.toggle()
        } label: {
            ZStack(alignment: an ? .trailing : .leading) {
                Capsule()
                    // Aus: `rand`, nicht eine eigene Deckkraft. Dieselbe Rolle wie
                    // jeder ruhende Rand, also derselbe Token.
                    .fill(an ? (bedienbar ? Stil.akzent : Stil.flaeche) : Stil.rand)
                    .frame(width: 46, height: 28)
            // **Die Trefferflaeche fuellt die Zeile, statt sie aufzublasen.**
            //
            // Hier stand `.frame(height: 44)` — als Mindestziel gedacht, und
            // es war eine feste Hoehe. Der Schalter machte damit **jede Zeile
            // mit Schalter 72 Punkt hoch**, waehrend eine ohne bei 47 liegt:
            // 44 plus zweimal 14 Innenabstand. Genau das sah man in den
            // Einstellungen. Paul am 22.09.: „warum ist der so riesig? Die
            // koennen ruhig wieder so wie vorher."
            //
            // `maxHeight: .infinity` nimmt, was die Zeile ohnehin hoch ist,
            // und fordert nichts. Eine Zeile mit Unterzeile ist gut 60 hoch,
            // eine ohne knapp 50 — in beiden Faellen mehr als die 44, um die
            // es ging, und die Zeile bestimmt wieder ihre eigene Hoehe.
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
                Circle()
                    .fill(bedienbar ? (an ? Stil.grund : Color.white)
                                    : Stil.schriftSehrLeise)
                    .frame(width: 22, height: 22)
                    .padding(.horizontal, 3)
            }
        }
        // **Hier bleibt `.plain`, und das ist Absicht.** Ein Schalter
        // antwortet ueber seinen Knopf, der wandert — Apples Schalter
        // verkleinern sich beim Druck nicht, und `Druckknopf` wuerde die ganze
        // Pille schrumpfen lassen. Die drei anderen `.plain` der App (das „x"
        // im Suchfeld, die aufklappende Beschreibung, das Auge im
        // Passwortfeld) hatten dagegen keine Antwort und haben jetzt eine.
        .buttonStyle(.plain)
        .animation(Stil.umschalten, value: an)
        // Eigene Steuerelemente sind für VoiceOver zunächst nur „Taste".
        // `isToggle` sagt, worum es geht, und liest den Zustand mit vor.
        .accessibilityRepresentation {
            Toggle(isOn: $an) { Text("Ein") }
        }
    }
}

/// Rubrik über einer Gruppe von Zeilen.
///
/// **Es gab sie zweimal.** Hier mit Sperrung 0,7 und `schriftSehrLeise`, in
/// `Einstellungsgruppe` mit Sperrung 1,2 und einem eigenen „weiß 40 %" —
/// dieselbe Rolle, zwei Fassungen, und auf Profilseite und Einstellungen
/// eine Seite nebeneinander zu sehen. Jetzt eine: die weitere Sperrung, weil
/// sich Versalien bei 11 Punkt sonst zusammendrängen, und die **Marke**
/// statt der eigenen Zahl.
/// **Eine Gruppe als eigene Flaeche.**
///
/// Die Einstellungsseiten trugen ihre Zeilen randbuendig zwischen zwei
/// Haarlinien. Das ist die aeltere Bauart der App und stand neben Start und
/// Detail sichtbar aelter da; entschieden am 11.09.2026 fuer die Karte, weil
/// sie die Gruppe ohne Leerraum abgrenzt und weil sie die Form ist, die man
/// vom Geraet kennt.
///
/// **Sie ist die eine Ausnahme von „hoechstens eine gefuellte Flaeche je
/// Seite".** Eine Einstellungsseite hat keine Hauptsache, der eine gefuellte
/// Knopf fehlt hier also nicht — es gibt ihn gar nicht. Die Regel schuetzt
/// die Aussage des Hauptknopfs, und wo keiner steht, schuetzt sie nichts.
struct Karte<Inhalt: View>: View {
    @Environment(\.breit) private var breit
    @ViewBuilder var inhalt: () -> Inhalt

    var body: some View {
        VStack(spacing: 0) { inhalt() }
            // Karte = 14, nicht 16: 16 gehoert eigenen Flaechen und dem
            // Blattgrund, 14 den Karten und Gruppen. Und `gruppe` statt
            // `flaeche`: ein grosser Block traegt denselben Ton heller als ein
            // Knopf — die Begruendung steht am Token.
            .background(Stil.gruppenflaeche,
                        in: RoundedRectangle(cornerRadius: Stil.eckeKarte, style: .continuous))
            .padding(.horizontal, Stil.rand(breit: breit))
    }
}

/// **Normalschreibung, nicht Versalien.**
///
/// Er stand in 11 Punkt, in Grossbuchstaben, mit +0,14 em gesperrt — das
/// Muster aus iOS 6, das Apple seit Jahren nicht mehr setzt. In der TV-App
/// steht ueber einer Gruppe schlicht „Automatische Wiedergabe": derselbe
/// Grad wie eine Reihenueberschrift, in gedaempftem Ton, normal geschrieben.
/// Paul am 21.09. mit Bildern aus der TV-App als Richtung.
///
/// Der Gewinn ist nicht nur Mode: Versalien lassen sich schlechter lesen,
/// brauchen Sperrung, um ueberhaupt lesbar zu sein, und werden von VoiceOver
/// je nach Wort buchstabiert. Und 11 Punkt war der kleinste Grad der App
/// ueber einer Gruppe, deren Zeilen 15 tragen — die Ueberschrift war leiser
/// als das, was sie ueberschreibt.
struct Gruppentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Stil.reihe)
            .tracking(Stil.sperrungReihe)
            .foregroundStyle(Stil.schriftLeise)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            // 10 statt 8: der Grad ist von 11 auf 20 gewachsen, und ein
            // Abstand, der zu einer 11er Zeile passte, klebt unter einer 20er.
            .padding(.bottom, 10)
    }
}

/// Rubrik plus die Zeilen darunter, oben und unten von einer Haarlinie
/// gefasst.
///
/// Stand zweimal da — in `EinstellungenView` und in
/// `WiedergabeEinstellungenView` —, zeichengleich bis in den Kommentar über
/// `textCase` hinein. Der Mac-Chat hat es beim Nachbauen gemeldet: er hatte
/// es bei sich von vornherein als **einen** Baustein.
///
/// Keine Karte, keine Umrandung: getrennt wird nur durch Leerraum und den
/// kleinen gesperrten Titel.
struct Einstellungsgruppe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder var inhalt: () -> Inhalt

    // `Stil.swift` geht nur ins iOS-Ziel — Fernseher und Mac haben eigene
    // Fassungen. Hier kann also nichts auseinanderlaufen; auf dem iPhone
    // bleibt `breit` falsch und damit alles, wie es war.
    @Environment(\.breit) private var breit

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Nicht noch einmal selbst gesetzt.** Genau daran sind die
            // beiden Rubriken auseinandergelaufen; `Gruppentitel` bringt
            // Grad, Schnitt, Sperrung, Farbe und den unteren Abstand mit.
            Gruppentitel(text: titel)
                .padding(.horizontal, Stil.rand(breit: breit) - Stil.randAbstand)
                .padding(.top, 26)
                .padding(.bottom, 2)
            Karte { inhalt() }
        }
    }
}

/// **Die leise Zeile unter einer Gruppe oder einer Seite.**
///
/// Sie stand dreimal fast gleich da — die Fassungsangabe in den
/// Einstellungen, dieselbe Angabe im Profil und der Hinweis unter der
/// Reihenliste in der Darstellung. Drei Stellen, ein Grad, eine Farbe, und
/// jede mit ihrem eigenen Vermerk daneben, warum es 12 und nicht 13 ist.
///
/// **Mitwachsend, nicht fest** (BRAND 2): sie steht in Einstellungen, und die
/// folgen der Systemschrift. Rand und Abstand bleiben bei der Aufrufstelle —
/// die eine sitzt in einer Liste, die andere in einem Stapel.
struct Fusszeile: View {
    let text: Text

    init(_ text: Text) { self.text = text }
    /// Fuer feste Beschriftungen; `Text(verbatim:)` fuer alles, was vom
    /// Server oder aus dem Buendel kommt.
    init(_ schluessel: LocalizedStringKey) { self.text = Text(schluessel) }

    var body: some View {
        text
            // 12 Regular ist die Angabe der Leiter. 13 Regular gibt es dort
            // nicht — 13 ist die Stufe unter dem Plakat und traegt Medium.
            .mitwachsend(12)
            // Weiss 30 Prozent ergaeben 2,60:1 — gerechnet, nicht geschaetzt.
            // Fuer Text sind 4,5:1 die Grenze, `schriftSehrLeise` traegt 5,9:1.
            .foregroundStyle(Stil.schriftSehrLeise)
    }
}

/// Haarlinie zwischen Zeilen, links eingerückt wie im Entwurf.
struct Trennlinie: View {
    var body: some View {
        Rectangle().fill(Stil.linie).frame(height: 1)
            .padding(.leading, Stil.randAbstand)
    }
}

/// **Der Rueckweg jeder Unterseite: ein runder Knopf, kein blanker Pfeil.**
///
/// Er stand dreimal fast gleich da — im `Unterseitenkopf`, im `Detailkopf` und
/// im `Seitenpfeil` —, und schon einmal mit zwei verschiedenen
/// Trefferflaechen. Ein Pfeil ist auch dreimal derselbe Pfeil.
///
/// **Ohne Scheibe.** Er hatte am 21.09. kurz eine, nach Apples TV-App. Paul
/// noch am selben Tag: „der Zurueckknopf als so ein fetter Knopf ist
/// irgendwie nicht so schoen, das war schoener, als der noch einfach so ein
/// kleines Ding war."
///
/// Der Punkt dahinter gilt allgemein: wir muessen nicht alles nachbauen, was
/// Apple macht — wir haben ein eigenes Design und bleiben dabei. Aus der
/// TV-App kommen die Farben und die Form der Ecken, nicht die Moebel.
///
/// Der Baustein bleibt trotzdem: er stand dreimal fast gleich da, einmal
/// sogar mit zwei verschiedenen Trefferflaechen. 20 Punkt Zeichen, 44 als
/// Ziel.
struct Zurueckknopf: View {
    let tun: () -> Void

    var body: some View {
        Button(action: tun) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        // **Ohne das liest VoiceOver „chevron.left".** Der Rueckweg jeder
        // Unterseite — die Stelle, an der eine fehlende Beschriftung nicht
        // eine Ansicht trifft, sondern alle.
        .accessibilityLabel(Text("Zurück"))
    }
}

/// Kopfzeile einer Unterseite: Pfeil links, Titel linksbündig daneben.
/// Nicht Apples zentrierter Titel, kein grauer Kreis.
struct Unterseitenkopf<Rechts: View>: View {
    /// Trägt den Namen einer Bibliothek — der kommt vom Server und wird
    /// deshalb nicht übersetzt.
    let titel: String
    /// `nil` heisst: **diese Seite ist eine Wurzel, kein Weg.**
    ///
    /// Die Merkliste ist auf dem iPad ein Bereich in der Leiste und auf dem
    /// iPhone eine Seite, die von rechts hereinfaehrt. Derselbe Kopf, zwei
    /// Rollen — und ein Zurueckpfeil auf einer Wurzel zeigt nirgendwohin.
    var zurueck: (() -> Void)?
    /// **Was unter dem Kopf frei bleibt.**
    ///
    /// Er brachte fest 18 mit. Steht darunter noch eine Wertreihe, addieren
    /// sich die 18 mit deren eigenem Abstand — auf der Merkliste waren es
    /// zusammen 32, waehrend Bibliothek und Downloads 14 hatten. Dieselbe
    /// Stelle, drei Zahlen. Wer eine Reihe darunter setzt, gibt hier 0 mit und
    /// laesst den Abstand vom Stapel kommen.
    var unten: CGFloat = 18
    @ViewBuilder var rechts: () -> Rechts

    var body: some View {
        HStack(spacing: 4) {
            if let zurueck {
                Zurueckknopf(tun: zurueck)
            } else {
                // Ohne Pfeil beginnt der Titel dort, wo er sonst auch steht —
                // sonst ruckte er auf der Wurzel um 44 Punkt nach links, und
                // die Seite saehe anders aus als ihre Nachbarn.
                Color.clear.frame(width: 12, height: 44)
            }

            Text(titel)
                .font(Stil.unterseitentitel)
                .tracking(Stil.sperrungUnterseite)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)

            Spacer(minLength: 0)
            rechts()
        }
        // **Acht, nicht zwölf, und ohne `Unschaerfekopf` darum.** Dieselbe
        // Zahl wie in `Seitenpfeil`: mit 8 sitzt das Zeichen 30 Punkt von
        // der Kante, genau dort, wo es auf jeder anderen Unterseite steht.
        //
        // Wer diesen Kopf in `Unschaerfekopf` haengt, bekommt dessen 18
        // Punkt Rand obendrauf — 48 statt 30, und beim Wechseln zwischen
        // zwei Seiten springt der Pfeil sichtbar. Diese Huelle braucht er
        // nicht: er steht ueber der Scrollflaeche, nicht darin, es laeuft
        // also nichts unter ihm durch.
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.bottom, unten)
    }
}

extension Unterseitenkopf where Rechts == EmptyView {
    init(titel: String, zurueck: @escaping () -> Void) {
        self.init(titel: titel, zurueck: zurueck) { EmptyView() }
    }
}

/// Runder Knopf mit Beschriftung darunter — die Aktionsreihe auf Detailseiten.
/// Eine Nebenhandlung auf einer Detailseite — Merkliste, Trailer, Gesehen,
/// Mehr.
///
/// **Vier Felder, keine Kreise.** Es waren vier gefüllte Scheiben mit einer
/// Beschriftung darunter — und damit die einzigen Kreise der ganzen App: sonst
/// gibt es nur Rechtecke mit unserer Ecke und Kapseln. Von zwölf nachgesehenen
/// Streaming-Apps setzt genau eine Kreise, und die stellt sie **neben** den
/// Abspielknopf statt darunter.
///
/// Die Wahl fiel auf die Form von Paramount+: vier gleich breite Felder, nur
/// Zeichen, keine Wörter. Der Preis ist bekannt und angenommen — vier Zeichen
/// ohne Beschriftung muss man kennen. Für die Sprachausgabe bleibt die
/// Beschriftung erhalten, sie steht nur nicht mehr im Bild.
///
/// **Was an ist, trägt Akzent — das Zeichen, nicht die Fläche.** Eine gefüllte
/// Akzentscheibe wäre der Akzent als Grundfarbe, und das verbietet E2.
struct Aktionsknopf: View {
    let symbol: String
    /// Steht nicht mehr im Bild, aber in der Sprachausgabe.
    let titel: LocalizedStringKey
    var aktiv: Bool = false
    /// Über die volle Breite, oder nur so breit wie nötig.
    ///
    /// Schmal teilen sich vier Felder die Zeile. Breit steht die Reihe neben
    /// dem Abspielknopf und darf ihn nicht wegdrücken.
    var dehnt = true
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                // Symbolknopf im Kopf: 17. 19 steht in keiner Leiter. Vorher 19.
                .font(Stil.rubrikGross)
                .foregroundStyle(aktiv ? Stil.akzent : Stil.schrift)
                .frame(maxWidth: dehnt ? .infinity : nil)
                // 48, nicht 44: 44 ist die Trefferflaeche, 48 das Mass. Und
                // quadratisch, wenn er allein steht — ein Knopf ohne
                // Beschriftung ist quadratisch, sagt die Vorlage.
                .frame(width: dehnt ? nil : 48, height: 48)
                // **Flaeche ohne Rand.** Mit Rand hatte jedes Feld eine
                // Kante, und vier Felder nebeneinander ergaben ein Gitter —
                // Paul am 21.09.: „ohne war schoener". Die Flaeche allein
                // reicht: sie sagt „hier kann man druecken", ohne zu zeichnen.
                .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(Text(titel))
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }
}

/// Reiterreihe mit Akzentstrich unter dem aktiven Eintrag.
struct Reiter: View {
    let titel: [LocalizedStringKey]
    @Binding var gewaehlt: Int

    var body: some View {
        HStack(spacing: 26) {
            ForEach(Array(titel.enumerated()), id: \.offset) { paar in
                let aktiv = paar.offset == gewaehlt
                Button {
                    withAnimation(Stil.umschalten) { gewaehlt = paar.offset }
                } label: {
                    Text(paar.element)
                        // **Ein Gewicht.** `aktiv ? .semibold : .regular` in
                        // einer waagerechten Reihe verschiebt beim Umschalten
                        // die Nachbarn rechts davon — Semifett ist breiter.
                        // Welcher Reiter offen ist, sagen Ton und Strich, und
                        // keines von beiden aendert eine Breite.
                        .font(Stil.listentitel)
                        .foregroundStyle(aktiv ? Stil.schrift : Stil.schriftLeise)
                        .padding(.bottom, 11)
                        .overlay(alignment: .bottom) {
                            // **Weiss, nicht Akzent.** Der Akzent traegt
                            // Zustand, nie Rangfolge — und „dieser Reiter ist
                            // gewaehlt" ist Rangfolge. Der Strich bleibt: er
                            // zeigt, *welcher* es ist, und das kann Gewicht
                            // allein auf drei Woertern nicht.
                            Rectangle()
                                .fill(aktiv ? Stil.schrift : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                // Welcher Reiter offen ist, hing allein am Akzentstrich und an
                // der Fettung — für VoiceOver waren alle drei gleich. Der
                // tvOS-Chat hat den Fall bei sich gefunden: überall dort, wo
                // ein Zustand nur an der Farbe hängt, wird er nicht gesprochen.
                .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Stil.randAbstand)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }
}

/// Zeile im Datei-Auszug: Bezeichnung links, Wert rechts.
///
/// **Kein `hervorgehoben` mehr.** Der Wert stand im Akzent, und die
/// Aufrufstelle uebergab es fuer jede Tonspur **unbedingt** — der Akzent war
/// also immer an und markierte damit gar keinen Zustand. Ein Spurname ist
/// laut BRAND 1 eine bloße Angabe, und der Akzent traegt nie eine Angabe.
/// Bei den Untertiteln hing es an `!untertitel.isEmpty`, also an etwas, das
/// der Text daneben schon sagt.
struct Dateizeile: View {
    /// „Video", „Ton", „Untertitel" — feste Beschriftungen.
    let bezeichnung: LocalizedStringKey
    let wert: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(bezeichnung)
                .foregroundStyle(Stil.schriftLeise)
            Spacer(minLength: 0)
            Text(wert)
                .foregroundStyle(Stil.schrift)
                .multilineTextAlignment(.trailing)
        }
        // **Tabellarisch.** Die Werte stehen rechtsbuendig in fuenf Zeilen
        // untereinander und sind Aufloesungen, Bildraten und Bitraten — genau
        // die Spalte, fuer die BRAND 2 die Regel geschrieben hat. Der Grad ist
        // `klein` aus der Leiter, vorher als Zahl.
        .font(Stil.klein.monospacedDigit())
        // 8, bei 12 pt Schrift: 9 stand ohne Grund neben der Leiter.
            .padding(.vertical, 8)
    }
}

/// Rundes Porträt mit Name und Rolle.
struct Besetzungskachel: View {
    let bild: URL?
    let name: String
    let rolle: String?

    var body: some View {
        VStack(spacing: 7) {
            Bild(url: bild, breite: 76, hoehe: 76, ecke: 38)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Stil.schrift)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let rolle, !rolle.isEmpty {
                Text(rolle)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(width: 84)
    }
}

/// Pille, unter der eine Liste direkt aufklappt — nach Netflix-Vorbild.
/// Kein Blatt von unten: die Entscheidung bleibt am Ort, an dem sie
/// ausgelöst wurde.
struct Aufklappliste<Eintrag: Identifiable>: View {
    let beschriftung: String
    let eintraege: [Eintrag]
    let text: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    let waehlen: (Eintrag) -> Void
    @Binding var offen: Bool
    /// Im Player sitzt sie an Stelle der Metazeile unter dem Titel — dort
    /// kleiner, sonst dieselbe Wahl.
    /// **15 Semifett, nicht 13.** Netflix setzt die Staffelwahl in der Groesse
    /// einer Listenzeile, nicht in der einer Angabe — sie ist der Schalter,
    /// mit dem man die ganze Liste darunter umstellt, und 13 las sich daneben
    /// wie eine Fussnote. Im Player bleibt es kleiner: dort steht sie an
    /// Stelle der Metazeile.
    var schrift: Font = Stil.listentitel
    var hoehe: CGFloat = 34
    /// **Ein Feld, keine nackte Ueberschrift.** Im Player steht sie zwischen
    /// Titel und Folgen und traegt dort keine Flaeche.
    var alsFeld = true

    var body: some View {
        Button {
            if eintraege.count > 1 { withAnimation(Stil.sprung) { offen.toggle() } }
        } label: {
            // **Ein leises Feld, keine Ueberschrift.**
            //
            // Erst war sie ein gefuellter Kasten in Reihengroesse, dann eine
            // nackte Ueberschrift in 20 — und damit so laut wie „Hier
            // weiterschauen", obwohl sie nur ein Filter ist. Paul am 21.09.:
            // „Warum ist Staffel 1 so riesig?"
            //
            // Jetzt die leise Stufe in einer Flaeche: man sieht, dass man
            // druecken kann, und sie schreit nicht. Dieselbe Bauart auf allen
            // Geraeten — am Fernseher 26 / 60 und Ecke 14: die Ecke ist dort
            // `eckeKlein`, und die haelt das iPhone-Verhaeltnis 8 zu 34 auf
            // 60 Punkt Hoehe, statt sich mit der Schrift zu verdoppeln. Steht
            // in `Notizen/BRAND.md`, Abschnitt 7, „Das Feld".
            HStack(spacing: 7) {
                Text(beschriftung)
                    .font(schrift)
                    .foregroundStyle(Stil.schrift)
                if eintraege.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .rotationEffect(.degrees(offen ? 180 : 0))
                }
            }
            .padding(.horizontal, alsFeld ? 11 : 0)
            // Die Trefferfläche bleibt, auch ohne Fläche darunter.
            .frame(height: hoehe)
            .background(alsFeld ? Stil.flaeche : .clear,
                        in: RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(beschriftung)
        .accessibilityHint(eintraege.count > 1 ? "Öffnet die Auswahl" : "")
        .buttonStyle(Stil.Druckknopf())
        .overlay(alignment: .topLeading) {
            if offen {
                VStack(spacing: 0) {
                    ForEach(eintraege) { eintrag in
                        Button {
                            waehlen(eintrag)
                            withAnimation(Stil.sprung) { offen = false }
                        } label: {
                            HStack(spacing: 12) {
                                // **Gewaehlt heisst Weiss und Gewicht, nicht
                                // Farbe.** Der Akzent traegt Zustand, nie
                                // Rangfolge — und „das hier ist es" ist
                                // Rangfolge. So steht es im Player, und der
                                // Player gibt den Ton an.
                                // **Der Haken markiert, das Gewicht nicht.**
                                //
                                // Gewaehlt stand hier zusaetzlich in Semifett.
                                // Das ist eine zweite Auskunft fuer dieselbe
                                // Sache — und Semifett ist breiter, also
                                // aenderte die Wahl die Breite der Tafel.
                                // Netflix setzt nur den Haken.
                                //
                                // Die Spalte ist 18 breit wie im Auswahlblatt;
                                // 14 war die dritte Hakenbreite der App.
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(istGewaehlt(eintrag) ? Stil.schrift : .clear)
                                    .frame(width: 18)
                                Text(text(eintrag))
                                    .font(Stil.listentitel)
                                    .foregroundStyle(istGewaehlt(eintrag) ? Stil.schrift
                                                                          : Stil.schriftLeise)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            // 9 statt 12: mit 12 wurde jede Zeile 43 hoch, und
                            // bei acht Staffeln stand eine Tafel da, die den
                            // halben Schirm nimmt. Netflix' Zeilen sind knapp
                            // ueber 30 — dieselbe Zahl, die eine Auswahlzeile
                            // in einer Liste traegt.
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        // Zeilen in einer Auswahl sind Knoepfe und
                        // muessen auf den Druck antworten, nicht erst
                        // auf die Wahl.
                        .buttonStyle(Stil.Druckzeile())
                    }
                }
                // **So breit wie der laengste Name, nicht fest 200.**
                //
                // „Staffel 1" braucht 140, „Specials" auch, und 200 liess
                // rechts eine Luecke, die nach Fehler aussah. Bei einer Staffel
                // mit langem Namen wurde umgekehrt gekuerzt. `fixedSize`
                // nimmt, was der Text braucht; die Untergrenze haelt schmale
                // Tafeln davon ab, wie ein Versehen auszusehen.
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 180, alignment: .leading)
                // **Die Marke, nicht eine von Hand getippte Farbe.** Hier
                // stand 0,090/0,090/0,102 — `Stil.flaeche` ist
                // 0,086/0,086/0,098. Der Unterschied war nicht zu sehen und
                // genau deshalb gefährlich: eine Farbe, die der Marke folgen
                // soll, es aber nicht tut.
                // Ecke `ecke` (10), nicht `eckeFlaeche` (16): die Tafel ist
                // klein und sitzt an einem Knopf, keine eigene Flaeche. Bei 16
                // sah sie neben ihrem Ausloeser (8) unpassend rund aus.
                .background(Stil.flaeche,
                            in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                // **Kein Schatten.** Tiefe kommt aus der Flaechenhelligkeit,
                // nicht aus Schlagschatten — `erhoeht` liegt schon eine Stufe
                // ueber der Karte darunter. Der Schatten war ausserdem der
                // einzige der ganzen iPhone-Fassung.
                .offset(y: hoehe + 6)
                .zIndex(10)
                // **Sie waechst aus ihrem Ausloeser.** Vorher stand sie
                // schlagartig da — kein Uebergang, kein Ursprung. Eine Liste
                // aus dem Nichts laesst offen, wozu sie gehoert; eine, die
                // aus dem Knopf herauswaechst, beantwortet das ohne ein Wort.
                // Der Anker liegt oben links, weil sie dort auch haengt, und
                // 0,94 statt 0 — nichts in der Wirklichkeit entsteht aus
                // nichts.
                .transition(.scale(scale: 0.94, anchor: .topLeading)
                    .combined(with: .opacity))
            }
        }
    }
}

/// Drehender Ring fuer Wartezeiten.
///
/// Eigener Baustein statt ProgressView: der Systemring bringt seine eigene
/// Strichstaerke und sein eigenes Grau mit und faellt neben den uebrigen
/// Bausteinen auf. Hier bestimmen Akzentfarbe und Staerke das Bild.
extension Stil {
    /// Fuer alles, was springt — Knoepfe wie Doppeltipp.
    ///
    /// Die Bewegung selbst macht SF Symbols mit '.bounce'. Ein eigener
    /// Drehwinkel war ein Fehler: er liess sich nur aufaddieren, nie
    /// zuruecknehmen, und die Knoepfe blieben schief stehen.
    /// Sprung: 0,22 `snappy`. Bei reduzierter Bewegung eine kurze Blende
    /// statt eines Sprungs — das ist der Sinn der Einstellung.
    static var sprung: Animation {
        bewegungReduziert ? blendeReduziert : .snappy(duration: 0.22)
    }
    /// Umschalten zwischen zwei Zustaenden, etwa Wiedergabe und Pause.
    ///
    /// 0,10 `easeOut`, nicht `snappy`: ein Schalter federt nicht, er kippt.
    static var umschalten: Animation {
        bewegungReduziert ? .linear(duration: 0.1) : .easeOut(duration: 0.1)
    }
}


/// Zeitregler im Player: 4-pt-Balken, beim Spulen 6 pt mit Griff.
///
/// Eigener Baustein statt Slider. Apples Regler bringt einen grossen
/// Schattengriff und eine eigene Spurhoehe mit — neben dem uebrigen Player
/// sieht das aus wie ein Fremdkoerper, und im Entwurf steht ein duenner
/// Strich. Die Grifflaeche bleibt trotzdem 28 pt hoch, damit man ihn mit dem
/// Daumen trifft; sichtbar sind davon nur die drei Punkt.
struct Zeitregler: View {
    /// „1 Stunde 12 Minuten" statt „1:12:30" — VoiceOver liest Doppelpunkte
    /// als Doppelpunkte vor.
    static func gesprochen(_ sekunden: Double) -> String {
        let ganz = Int(max(0, sekunden))
        let stunden = ganz / 3600, minuten = (ganz % 3600) / 60
        if stunden > 0 {
            return "\(stunden) Stunden \(minuten) Minuten"
        }
        return "\(minuten) Minuten"
    }

    @Binding var wert: Double
    let bis: Double
    /// **Wo die Abschnitte anfangen, in Sekunden.**
    ///
    /// Der Player laedt sie langst — fuer die Ueberspringen-Karte und den
    /// Countdown —, und der Regler wusste nichts davon. Ein Regler, der die
    /// Kerben zeigt, sagt in einem Blick, wie der Film gebaut ist: wo der
    /// Vorspann endet, wo der Abspann anfaengt. Leer heisst „keine bekannt",
    /// und dann sieht der Regler aus wie vorher.
    var marken: [Double] = []
    var beimSchieben: (Bool) -> Void

    @State private var breite: CGFloat = 0
    @State private var amSchieben = false

    private var anteil: CGFloat {
        guard bis > 0 else { return 0 }
        return min(max(CGFloat(wert / bis), 0), 1)
    }

    /// Die Abschnittsgrenzen als Anteil, ohne die an den beiden Kanten.
    private var kerben: [CGFloat] {
        guard bis > 0 else { return [] }
        return marken.map { CGFloat($0 / bis) }
            .filter { $0 > 0.01 && $0 < 0.99 }
    }

    var body: some View {
        // **Im Stehen nur der Strich, beim Spulen Griff in Akzentfarbe.** So
        // steht es im Entwurf des Players: vier Punkt ohne Griff, beim
        // Anfassen sechs Punkt und ein Griff — die einzige Stelle im Player,
        // an der die Akzentfarbe auftaucht.
        let dicke: CGFloat = amSchieben ? 6 : 4
        let griff: CGFloat = 18

        ZStack(alignment: .leading) {
            // **Weiss 18 %.** Die Playersteuerung liegt auf reinem Schwarz
            // (BRAND 4), also traegt die Spur einen hellen Ton und der Balken
            // darueber das volle Weiss. Der Vermerk ueber eine *dunkle* Spur,
            // der hier stand, gehoerte zum Blattgriff und ist dorthin
            // zurueckgezogen; dunkel bleibt die Spur nur da, wo sie ueber
            // einem Plakat liegt — am Kachelbalken.
            Capsule().fill(Color.white.opacity(0.18)).frame(height: dicke)
            Capsule().fill(.white).frame(width: breite * anteil, height: dicke)

            // **Kerben an den Abschnittsgrenzen.**
            //
            // Zwei Punkt breit, in `grund` — also dunkel, denn sie liegen
            // sowohl auf der hellen Spur als auch auf dem weissen Balken und
            // muessen auf beiden zu sehen sein. Ein heller Strich waere auf
            // dem Balken verschwunden.
            //
            // Die Grenze bei 0 und die bei der Gesamtlaenge fallen weg: die
            // eine faellt mit dem Anfang zusammen, die andere mit dem Ende,
            // und eine Kerbe direkt an der Kante liest sich als Ausfransen.
            ForEach(kerben, id: \.self) { stelle in
                Rectangle().fill(Stil.grund)
                    .frame(width: 2, height: dicke)
                    .offset(x: breite * stelle - 1)
            }

            Circle().fill(Stil.akzent).frame(width: griff, height: griff)
                .scaleEffect(amSchieben ? 1 : 0.4)
                .opacity(amSchieben ? 1 : 0)
                .offset(x: breite * anteil - griff / 2)
        }
        .animation(Stil.umschalten, value: amSchieben)
        // Für VoiceOver ein Regler, nicht eine namenlose Fläche: mit
        // `adjustableAction` lässt sich die Stelle auch wischend ändern.
        .accessibilityElement()
        .accessibilityLabel("Abspielstelle")
        .accessibilityValue(String(localized: "\(Self.gesprochen(wert)) von \(Self.gesprochen(bis))"))
        .accessibilityAdjustableAction { richtung in
            let schritt = max(bis / 20, 10)
            switch richtung {
            case .increment: wert = min(bis, wert + schritt)
            case .decrement: wert = max(0, wert - schritt)
            @unknown default: break
            }
            beimSchieben(false)
        }
        // 44 statt 28: der Balken ist drei Punkt hoch, treffen muss man ihn
        // trotzdem mit dem Daumen. Sichtbar bleibt nur der Strich.
        .frame(height: 44)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { breite = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { geste in
                    amSchieben = true
                    beimSchieben(true)
                    guard breite > 0 else { return }
                    wert = Double(min(max(geste.location.x / breite, 0), 1)) * bis
                }
                .onEnded { _ in
                    amSchieben = false
                    beimSchieben(false)
                }
        )
    }
}

// MARK: - Navigationsleiste

/// Die vier Bereiche unten. Ersetzt die Knöpfe „Filme" und „Serien", die
/// vorher als Kacheln auf der Startseite standen.
enum Bereich: Int, CaseIterable, Identifiable {
    // **`downloads` steht hinten, obwohl es vorn angezeigt wird.**
    //
    // Die Rohwerte sind Feldindizes: `HauptView` haelt seine Seitenstapel als
    // `pfade[bereich.rawValue]`. Wuerde `downloads` zwischen `serien` und
    // `suche` eingefuegt, ruecke `suche` von 3 auf 4 — und jeder Stapel
    // laege danach unter einem fremden Bereich. Wo es in der Leiste steht,
    // sagt ``sichtbare(downloads:)``, nicht die Reihenfolge hier.
    case start, filme, serien, suche, downloads, merkliste
    var id: Int { rawValue }

    /// Die Leiste, in ihrer Reihenfolge. **H1:** ohne den Schalter gibt es
    /// den Downloadplatz gar nicht.
    ///
    /// Downloads steht links neben der Suche, und die Suche bleibt ganz
    /// rechts — sie ist die einzige, die man mit dem Daumen im Halbschlaf
    /// trifft, und sie stand dort seit der ersten Fassung.
    ///
    /// **Die Merkliste gibt es nur breit.** Schmal haengt sie am Zeichen
    /// oben rechts, neben dem Profil — unten waeren es sechs Reiter, und der
    /// Platz gehoert dort den vier Orten, zwischen denen man staendig
    /// wechselt. Breit gibt es die Zeichengruppe nicht, die wohnt in der
    /// Leiste; dort ist die Merkliste eine Zeile wie Filme und Serien.
    /// Vorher stand sie dort als `NavigationLink` unten bei den Zielen — und
    /// tat **nichts**, weil die Seitenleiste ausserhalb des
    /// `NavigationStack` liegt und ein Link ohne Stapel ins Leere zeigt.
    static func sichtbare(downloads: Bool, breit: Bool = false) -> [Bereich] {
        var liste: [Bereich] = [.start, .filme, .serien]
        if breit { liste.append(.merkliste) }
        if downloads { liste.append(.downloads) }
        liste.append(.suche)
        return liste
    }

    var name: LocalizedStringKey {
        switch self {
        case .start:     "Start"
        case .filme:     "Filme"
        case .serien:    "Serien"
        case .suche:     "Suche"
        case .downloads: "Downloads"
        case .merkliste: "Merkliste"
        }
    }

    var symbol: String {
        switch self {
        case .start:     "house"
        case .filme:     "film"
        case .serien:    "tv"
        case .suche:     "magnifyingglass"
        // **Der Kreis gehoert dazu.** Ein nackter Pfeil zwischen Haus, Film,
        // Fernseher und Lupe liest sich als Richtungszeichen, nicht als Ort.
        case .downloads: "arrow.down.circle"
        case .merkliste: "bookmark.fill"
        }
    }
}

/// Ein Bereich in der Leiste — unten auf dem iPhone, links auf dem iPad.
///
/// **Ein Baustein für beide Leisten.** Er stand zweimal da, siebzehn Zeilen
/// wortgleich, und der Kommentar an `Seitenleiste` sagte es selbst:
/// „Gleiche Symbole, gleiche Größen, gleicher Akzent". Genau so fangen die
/// Fassungen an auseinanderzulaufen — wer die Auswahlfarbe ändert, ändert
/// eine von zwei Leisten und sieht die andere erst auf dem anderen Gerät.
///
/// Verschieden sind nur zwei Dinge, und beide stehen jetzt als Parameter da:
/// die Seitenleiste gibt eine feste Zeilenhöhe vor, und bei ihr trägt
/// keiner der vier Bereiche die Auswahl, solange das Profil offen ist.
private struct Bereichsknopf: View {
    let bereich: Bereich
    let aktiv: Bool
    /// Feste Zeilenhöhe. Die Leiste unten gibt keine vor — dort teilen sich
    /// die vier die Höhe der Leiste selbst.
    var hoehe: CGFloat?
    /// Wie viele Downloads gerade laufen. `0` heisst: keine Marke.
    ///
    /// **Die Zahl der laufenden, nicht die der fertigen.** Ein Abzeichen, das
    /// dauerhaft „12" sagt, ist nach zwei Tagen unsichtbar; eines, das
    /// erscheint und wieder verschwindet, sagt etwas.
    var laufen: Int = 0
    let waehlen: () -> Void

    var body: some View {
        Button(action: waehlen) { inhalt }
            .buttonStyle(Stil.Druckknopf())
            .accessibilityLabel(Text(bereich.name))
            .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var inhalt: some View {
        let kern = VStack(spacing: 4) {
            Image(systemName: bereich.symbol)
                .font(.system(size: 20, weight: aktiv ? .semibold : .regular))
                .overlay(alignment: .topTrailing) {
                    if laufen > 0 {
                        Text(verbatim: laufen.formatted())
                            // Plakette: 10 Semifett. 9 steht in keiner Leiter. Vorher 9.
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Stil.grund)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Stil.akzent, in: Capsule())
                            // Nach aussen versetzt: auf dem Zeichen selbst
                            // deckt sie den Pfeil zu, und dann sieht man
                            // nicht mehr, welcher Reiter es ist.
                            .offset(x: 11, y: -7)
                            .accessibilityLabel(Text("\(laufen) laden gerade"))
                    }
                }
            Text(bereich.name)
                .font(.system(size: 10, weight: aktiv ? .semibold : .medium))
        }
        // **Die eine Ausnahme: hier traegt der Akzent die Auswahl.**
        //
        // „Gewaehlt heisst Weiss und Gewicht" gilt fuer alles — ausser fuer die
        // Leiste unten. Apples eigene Apps faerben den gewaehlten Reiter dort im
        // Akzent, und zwar ausnahmslos: Musik, Fotos, App Store, Einstellungen.
        // Das ist keine Geschmacksfrage, sondern die Stelle, an der jeder
        // Nutzer die Farbe einer App zum ersten Mal sieht. Eine Leiste in Weiss
        // waere nicht eigener, sondern fremder — sie saehe aus wie eine App, die
        // ihre Farbe vergessen hat.
        //
        // Die Reiter **innerhalb** einer Seite (`Reiter`) bleiben bei Weiss und
        // Gewicht: dort ist der Akzent nicht Konvention, und ein zweites
        // Auswahlzeichen in derselben Farbe auf demselben Schirm waere eins zu
        // viel. Steht als Ausnahme in `Notizen/BRAND.md`, Abschnitt 1.
        .foregroundStyle(aktiv ? Stil.akzent : Stil.schriftSehrLeise)
        .frame(maxWidth: .infinity)

        // Nicht `.frame(height: hoehe)` mit einem `nil`: das legt auch dann
        // eine Rahmenschicht ein, wenn keine gemeint ist. Hier soll die
        // Leiste unten genau den Baum bekommen, den sie vorher hatte.
        if let hoehe {
            kern.frame(height: hoehe).contentShape(Rectangle())
        } else {
            kern.contentShape(Rectangle())
        }
    }
}

/// Eigene Leiste statt `TabView`.
///
/// Apples Leiste bringt auf iOS 26 ihr eigenes Glasmaterial mit, dazu eigene
/// Höhe, eigene Symbolgrößen und eine Auswahlfarbe, die sich nur teilweise
/// setzen lässt. Diese hier gehört uns: unscharfer Grund in unserem Ton,
/// Haarlinie oben, 22-pt-Symbole.
struct Navileiste: View {
    @Binding var gewaehlt: Bereich
    /// H1 — ohne den Schalter gibt es den fuenften Platz nicht.
    var mitDownloads = false
    var laufen = 0

    var body: some View {
        // **Durchgehend, nicht schwebend — zurueckgenommen.**
        //
        // Sie war am 21.09. eine Kapsel mit Abstand zu allen drei Kanten, nach
        // Apples TV-App. Am Geraet hat Paul sie sofort zurueckgeholt: „du hast
        // die Navleiste irgendwie rund gemacht — wieder zurueck."
        //
        // Der Grund, den man vorher nicht sieht: Apples Kapsel traegt **fuenf**
        // Eintraege mit kurzen Namen und hat rechts und links Luft. Unsere
        // traegt vier bis fuenf mit „Downloads" und „Merkliste" darin, und
        // eingerueckt um zweimal 16 Punkt werden daraus gequetschte Spalten.
        // Eine Form, die bei Apple aus Luft entsteht, ergibt bei uns Enge.
        HStack(spacing: 0) {
            ForEach(Bereich.sichtbare(downloads: mitDownloads)) { bereich in
                Bereichsknopf(bereich: bereich, aktiv: bereich == gewaehlt,
                              laufen: bereich == .downloads ? laufen : 0) {
                    gewaehlt = bereich
                }
            }
        }
        .padding(.top, 9)
        .frame(height: Stil.leisteHoehe, alignment: .top)
        // Der Grund muss bis zur Unterkante laufen, nicht nur bis zum
        // sicheren Bereich — sonst blitzt unter der Leiste weiter Inhalt
        // durch, im Bereich des Home-Indikators.
        .background {
            // **Deckend, kein Glas.** „Fast deckend" hiess: 14 Prozent des
            // Inhalts scheinen durch, und im Bereichswechsel sah man genau
            // das — Kacheln, die sich sichtbar durch die Leiste schoben.
            //
            // `Stil.grund` und nicht `flaeche`: die Leiste soll keine eigene
            // Flaeche sein, sondern der Grund, auf dem die Seite endet. Die
            // Haarlinie darueber ist alles, was sie braucht.
            Stil.grund.ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }
}

/// Die Ziele oben rechts — auf **jeder** Wurzelseite dieselben, in derselben
/// Reihenfolge, mit denselben Abständen.
///
/// **Sie gehören zusammen, also stehen sie zusammen.** Merkliste und Profil
/// standen auf der Startseite nebeneinander und auf Filme und Serien allein;
/// dieselbe Ecke des Bildschirms hielt auf zwei Seiten Verschiedenes bereit.
///
/// `vorn` ist der Platz für das, was nur eine Seite hat — auf der Startseite
/// das Angebot „hier weiterschauen". Es steht links vom Rest, weil es kommt
/// und geht: dazwischen würde es die dauerhaften Ziele hin und her schieben.
struct Kopfziele<Vorn: View>: View {
    let name: String
    let bild: URL?
    @ViewBuilder var vorn: () -> Vorn

    /// **Das Angebot gehoert zur Gruppe, nicht zur Startseite.**
    ///
    /// Es stand bis zum 10.09.2026 nur dort, mit der Begruendung, ein Tipp
    /// darauf starte die Wiedergabe und der Player haenge an der Startseite.
    /// Das war ein Grund aus dem Bau, keiner aus der Bedienung: wer auf
    /// „Filme" steht, waehrend im Wohnzimmer etwas laeuft, will es genauso
    /// uebernehmen koennen — und ein Zeichen, das nur auf einer von fuenf
    /// Seiten auftaucht, sieht nach Versehen aus. Der Player ist deshalb
    /// eine Ebene hoeher gewandert, in ``HauptView``.
    ///
    /// Optional, damit der Baustein ohne die Umgebung auskommt: `nil` heisst
    /// schlicht „kein Angebot".
    @Environment(Uebernahmemodell.self) private var uebernahme: Uebernahmemodell?

    var body: some View {
        HStack(spacing: 0) {
            // **Links von den dauerhaften Zielen** (GESTALTUNG J): es kommt
            // und geht und wuerde dazwischen Merkliste und Profil
            // verschieben.
            if let uebernahme, let angebot = uebernahme.angebot {
                Button { uebernahme.angetippt = true } label: {
                    // **Der Akzent, und das Zeichen macht den Unterschied.**
                    // `kuehl` ist gestrichen: der Akzent traegt Zustand, und
                    // „laeuft woanders" ist einer. Was es von einem
                    // Fortschrittsbalken unterscheidet, ist das
                    // Geraetezeichen selbst.
                    Image(systemName: angebot.geraetezeichen)
                        .font(.system(size: 20))
                        .foregroundStyle(Stil.akzent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                .accessibilityLabel(Text("Hier weiterschauen"))
                .accessibilityValue(Text(angebot.titelzeile))
                // **Mit Anker.** Ohne ihn wuchs das Zeichen aus der Mitte des
                    // Kopfes statt aus seiner eigenen Stelle — „was aus einem
                    // Knopf aufgeht, geht in ihn zurueck" gilt auch, wenn der
                    // Knopf nur erscheint.
                    .transition(.opacity.combined(with: .scale(scale: 0.85,
                                                              anchor: .trailing)))
            }

            vorn()

            NavigationLink(value: MerklisteRoute()) {
                // **Gefüllt, nicht als Umriss.** Ein hohles Lesezeichen bei
                // 20 Punkt ist fast nur Kontur. In der Knopfreihe auf den
                // Detailseiten heisst gefüllt „gemerkt"; hier ist es kein
                // Zustand, sondern ein Ziel, und dort steht es allein.
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckknopf())
            .accessibilityLabel(Text("Merkliste"))

            Profilziel(name: name, bild: bild)
        }
        .animation(Stil.sprung, value: uebernahme?.angebot?.id)
    }
}

extension Kopfziele where Vorn == EmptyView {
    init(name: String, bild: URL?) {
        self.init(name: name, bild: bild) { EmptyView() }
    }
}

/// Das Profilbild oben rechts — auf **jeder** Wurzelseite an derselben Stelle.

/// Das Profilbild oben rechts — auf **jeder** Wurzelseite an derselben Stelle.
///
/// **Es stand zweimal da und ist prompt verrutscht.** Auf der Startseite kam
/// mit der Merkliste eine Trefferfläche von 44 Punkt dazu, auf Filme und
/// Serien blieb es beim nackten Kreis von 30 — und damit saß dasselbe Bild auf
/// zwei Seiten an zwei Stellen.
///
/// Die 44 sind richtig (E12), aber sie ragen 7 Punkt über den Kreis hinaus;
/// ohne den Ausgleich stünde der Kreis 7 Punkt weiter innen als der Rand der
/// Seite. Diese Rechnung gehört an **eine** Stelle.
struct Profilziel: View {
    let name: String
    let bild: URL?

    var body: some View {
        NavigationLink(value: ProfilRoute()) {
            Profilzeichen(name: name, bild: bild)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .padding(.trailing, -7)
    }
}

/// Wohin ein Antippen der Bereichsleiste geht — oder `nil`, wo es keine gibt.
///
/// Über die Umgebung und nicht als Argument: sonst müsste jede Wurzelansicht
/// die Bindung durchreichen, und die nächste, die dazukommt, vergisst es.
private struct Bereichswahlschluessel: EnvironmentKey {
    static let defaultValue: Binding<Bereich>? = nil
}

/// Ist dieser Bereich der vorderste? Steuert das Heranziehen beim Wechsel.
private struct BereichAktivSchluessel: EnvironmentKey {
    static let defaultValue = true
}

/// Ob es den Downloadreiter gibt und wie viele gerade laufen.
///
/// **Aus demselben Grund über die Umgebung wie ``bereichswahl``:** die Leiste
/// wird von drei Wurzelansichten angelegt, und die vierte, die dazukommt,
/// vergisst sonst das Durchreichen. Beides zusammen in einem Wert, weil beides
/// dieselbe Leiste betrifft und immer gemeinsam gesetzt wird.
struct Downloadleiste: Equatable {
    var an = false
    var laufen = 0
}

private struct DownloadleisteSchluessel: EnvironmentKey {
    static let defaultValue = Downloadleiste()
}

/// **Wie oft der schon offene Reiter noch einmal getippt wurde.**
///
/// Ein Zaehler und kein Schalter: die Seite soll jedes Mal reagieren, nicht
/// nur beim ersten Mal, und ein Schalter muesste jemand zuruecksetzen.
///
/// Der Weg fuehrt ueber ``bereichswahl``: die Leiste schreibt dorthin auch
/// dann, wenn sich nichts aendert, und ``HauptView`` erkennt daran den
/// zweiten Tipp. Jede andere App macht es so — der erste Tipp bringt einen
/// hin, der zweite tut etwas.
private struct ReiterNochmalSchluessel: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var bereichswahl: Binding<Bereich>? {
        get { self[Bereichswahlschluessel.self] }
        set { self[Bereichswahlschluessel.self] = newValue }
    }

    var bereichAktiv: Bool {
        get { self[BereichAktivSchluessel.self] }
        set { self[BereichAktivSchluessel.self] = newValue }
    }

    var downloadleiste: Downloadleiste {
        get { self[DownloadleisteSchluessel.self] }
        set { self[DownloadleisteSchluessel.self] = newValue }
    }

    var reiterNochmal: Int {
        get { self[ReiterNochmalSchluessel.self] }
        set { self[ReiterNochmalSchluessel.self] = newValue }
    }
}

extension View {
    /// Legt die Bereichsleiste unten an diese Ansicht.
    ///
    /// **Sie gehört in die Wurzelansicht, nicht über den Seitenstapel.** Dort
    /// hing sie, und daraus folgten zwei Fehler, die wie zwei aussahen und
    /// einer waren:
    ///
    /// **Beim Blättern auf eine Unterseite verschwand sie schlagartig.** Sie
    /// hing an „ist der Pfad leer" und wurde ausgehängt, während die neue
    /// Seite noch von rechts hereinfuhr. Liegt sie in der Wurzel, schiebt der
    /// Stapel die neue Seite von selbst darüber — es gibt nichts auszuhängen.
    /// - **Ein Blatt lag darunter.** Ein Blatt hängt in der Seite, die Leiste
    /// lag eine Ebene höher. Der Umweg über einen Unterrand versteckte es nur;
    /// der Versuch, den Seitenstapel darüber zu heben, deckte die Leiste mit
    /// undurchsichtigem Grund zu — sie war weg statt gedämpft.
    ///
    /// In der Wurzel stimmt die Reihenfolge von selbst: Inhalt, Leiste, Blatt.
    /// Deshalb steht dieser Aufruf **vor** den Blättern einer Seite.
    func bereichsleiste() -> some View {
        modifier(Bereichsleiste())
    }

    /// Zieht diesen Inhalt beim Bereichswechsel eine Spur heran.
    ///
    /// **Gehört an die Scrollfläche, nicht an die Seite.** Es sass am ganzen
    /// Seitenkörper, und der trägt oben die Kopfzeile: auf Filme und Serien
    /// wanderten Titel und Profilbild mit, auf der Startseite nicht — dort
    /// lag es zufällig schon an der richtigen Stelle. Zwei Seiten, zwei
    /// Verhalten, und das obendrein.
    ///
    /// Die Kopfzeile ist eine Leiste wie die untere: sie liegt fest, und der
    /// Inhalt bewegt sich darunter.
    func bereichsinhalt() -> some View {
        modifier(Bereichsinhalt(unterlage: nil))
    }

    /// Wie ``bereichsinhalt()``, nur mit einer eigenen Lage **zwischen Grund
    /// und Inhalt**.
    ///
    /// Der Grund hinter der Scrollflaeche deckt. Wer dahinter etwas zeigen
    /// will, kommt sonst nicht hin und legt es am Ende darueber — und dann
    /// liegt es auch ueber Schrift und Plakaten. Die Lage gehoert zum Grund:
    /// der Inhalt scrollt darueber weg.
    func bereichsinhalt<U: View>(@ViewBuilder unterlage: () -> U) -> some View {
        modifier(Bereichsinhalt(unterlage: AnyView(unterlage())))
    }

    /// **Nur das Heranziehen, ohne eigenen Grund.**
    ///
    /// `bereichsinhalt()` legt eine deckende Flaeche hinter den Inhalt, damit
    /// beim Heranziehen an den Raendern nichts freigegeben wird. Ein
    /// Leerzustand liegt aber **ueber** der Scrollflaeche und damit ueber
    /// deren Kopf — eine deckende Flaeche wuerde den Kopf verdecken.
    ///
    /// Er braucht sie auch nicht: er sitzt mittig und laesst an den Raendern
    /// ohnehin den Grund stehen. Was ihm fehlte, war allein die Bewegung —
    /// und deshalb war die Downloadseite die eine, die beim Oeffnen hart ins
    /// Bild sprang, waehrend Start, Filme und Serien heranziehen. Paul am
    /// 22.09.: „wird niemand bemerken, aber ich bemerke das."
    func bereichsmitzug() -> some View {
        modifier(Bereichsmitzug())
    }
}

private struct Bereichsmitzug: ViewModifier {
    @Environment(\.bereichAktiv) private var aktiv

    func body(content: Content) -> some View {
        content
            // Anker oben, wie in `Bereichsinhalt` — unten verankert kam er
            // sichtbar von unten herauf, waehrend die Seiten daneben von oben
            // heranziehen. Paul am 22.09.: „animiert falsch rein, irgendwie
            // von unten, das passt nicht."
            .scaleEffect(aktiv ? 1 : Stil.bereichsmass, anchor: .top)
            .opacity(aktiv ? 1 : 0)
            .animation(Stil.bereichswechsel, value: aktiv)
    }
}

private struct Bereichsinhalt: ViewModifier {
    @Environment(\.bereichAktiv) private var aktiv
    let unterlage: AnyView?

    func body(content: Content) -> some View {
        content
            // **Oben verankert, nicht unten.**
            //
            // Mittig ginge gar nicht: dann bewegen sich beide Kanten. Die
            // Frage ist also nur, welche stillstehen soll — und die Antwort
            // war eine Zeit lang die falsche.
            //
            // Unten verankert steht die untere Kante still und die **obere**
            // wandert. Dort liegt aber der Kopfverlauf, und der ist oben bei
            // 0,98 praktisch deckend: waehrend der 0,2 Sekunden klafft unter
            // ihm der blanke Grund, wo sonst Plakate durchlaufen. Am Geraet
            // ist das genau das, was man sieht — Paul am 22.09.: „beim
            // Verlauf oben ist fuer ein paar ms eine schwarze Flaeche
            // anstatt des Verlaufs."
            //
            // Oben verankert steht die Kante unter dem Kopf still. Die untere
            // wandert dafuer — und dort ist es folgenlos, weil darueber die
            // Navileiste liegt: 54 Punkt deckender Grund, hinter denen die
            // paar Punkt verschwinden. Die Kante, die man frueher fuer die
            // sichtbare hielt, ist die verdeckte.
            .scaleEffect(aktiv ? 1 : Stil.bereichsmass, anchor: .top)
            // **Ein fester Grund hinter dem bewegten Inhalt.**
            //
            // Zieht er sich heran, gibt er an allen Rändern etwas frei — und
            // was dort zum Vorschein kommt, gehört nicht mehr ihm. Dieser
            // Grund ist derselbe Ton und bewegt sich nicht mit; damit gibt es
            // dort nichts freizugeben.
            .background {
                ZStack(alignment: .top) {
                    Stil.grund.ignoresSafeArea()
                    if let unterlage { unterlage }
                }
            }
            .animation(Stil.bereichswechsel, value: aktiv)
    }
}

private struct Bereichsleiste: ViewModifier {
    @Environment(\.breit) private var breit
    @Environment(\.bereichswahl) private var wahl
    @Environment(\.downloadleiste) private var downloads

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if !breit, let wahl {
                Navileiste(gewaehlt: wahl, mitDownloads: downloads.an,
                           laufen: downloads.laufen)
                    // **Der volle Rahmen davor ist nicht schmückend.** Die
                    // Auflage misst sich an ihrem Gastgeber, und der ist bei
                    // offener Tastatur bereits geschrumpft — die Leiste stand
                    // dann mitten im Bild, über der Tastatur. Erst der volle
                    // Rahmen plus das Ignorieren des Tastaturbereichs hängt
                    // sie wieder an den **echten** unteren Rand.
                    //
                    // Auf der Suchseite ist genau das gewollt: die Tastatur
                    // legt sich darüber, die Leiste bleibt darunter stehen
                    // und ist wieder da, sobald das Feld schliesst.
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
    }
}

/// Dieselbe Leiste, um 90 Grad gedreht — für die breite Fassung.
///
/// **Nicht die Kopfleiste vom Fernseher.** Die liegt dort oben, weil eine
/// Fernbedienung bedient und Erreichbarkeit keine Rolle spielt. An einem
/// gehaltenen iPad ist die obere Kante die schlechteste Stelle. Vom
/// Fernseher kommt die Komposition der Seiten, nicht die Griffhöhe.
///
/// Gleiche Symbole, gleiche Größen, gleicher Akzent, gleiches Glas wie
/// `Navileiste` — nur die Haarlinie sitzt rechts statt oben.
///
/// Wortmarke und Profilzeichen wandern hier hinein. Auf dem iPhone stehen
/// sie im Kopf jeder Seite; das kostet dort nichts, weil der Kopf ohnehin
/// da ist. Nebengewinn: das Profil ist damit zum ersten Mal aus **allen
/// vier** Bereichen erreichbar — in der Suche fehlte es bisher.
///
/// Sie weicht auf Unterseiten **nicht**, anders als unten auf dem iPhone.
/// Dort gibt das Weichen 54 Punkt Höhe zurück; hier gäbe es 88 Punkt Breite
/// zurück und verschöbe dabei jedes Poster. Ein waagerechter Sprung stört
/// mehr als ein senkrechter.
struct Seitenleiste: View {
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    /// Optional, wie in `Kopfziele`: ohne das Modell in der Umgebung gibt es
    /// schlicht kein Angebot.
    @Environment(Uebernahmemodell.self) private var uebernahme: Uebernahmemodell?
    @Environment(\.downloadleiste) private var downloads
    @Binding var gewaehlt: Bereich
    /// Die Profilseite ist offen — dann trägt keiner der vier Bereiche die
    /// Auswahl, sondern das Zeichen unten.
    var imProfil = false
    let name: String
    var bild: URL?
    let aufsProfil: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Wortmarke(hoehe: 20)
                .padding(.top, Stil.kopfOben + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
                .padding(.bottom, 32)

            ForEach(Bereich.sichtbare(downloads: downloads.an, breit: true)) { bereich in
                Bereichsknopf(bereich: bereich,
                              aktiv: bereich == gewaehlt && !imProfil,
                              hoehe: 64,
                              laufen: bereich == .downloads ? downloads.laufen : 0) {
                    gewaehlt = bereich
                }
            }

            Spacer(minLength: 0)

            // **Die Merkliste stand hier und steht jetzt oben bei den
            // Bereichen.** Als `NavigationLink` tat sie hier nichts: die
            // Seitenleiste liegt ausserhalb des `NavigationStack`, und ein
            // Link ohne Stapel zeigt ins Leere. Unten blieb also nur das
            // Profil — was auch stimmiger ist, denn das Profil ist kein Ort
            // in der App, sondern wer man ist.

            // **„Hier weiterschauen" über dem Profil.** Auf dem iPhone steht
            // es in `Kopfziele`, links vom Profilbild. Die gibt es breit nicht
            // — Profil und Merkliste wohnen dort in dieser Leiste —, und als
            // das Angebot am 10.09.2026 in die Kopfziele zog, fiel es auf dem
            // iPad deshalb ganz weg. Hier steht es wieder bei dem, zu dem es
            // gehört: dieselbe Form wie auf dem iPhone, dieselbe Stelle wie
            // auf dem Mac, über dem Konto.
            if let uebernahme, let angebot = uebernahme.angebot {
                Button { uebernahme.angetippt = true } label: {
                    // Der Akzent; `kuehl` ist gestrichen. Das Geraetezeichen
                    // sagt „woanders laeuft etwas", nicht die Farbe.
                    Image(systemName: angebot.geraetezeichen)
                        .font(.system(size: 20))
                        .foregroundStyle(Stil.akzent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                .accessibilityLabel(Text("Hier weiterschauen"))
                .accessibilityValue(Text(angebot.titelzeile))
                .padding(.bottom, 12)
                // **Mit Anker.** Ohne ihn wuchs das Zeichen aus der Mitte des
                    // Kopfes statt aus seiner eigenen Stelle — „was aus einem
                    // Knopf aufgeht, geht in ihn zurueck" gilt auch, wenn der
                    // Knopf nur erscheint.
                    .transition(.opacity.combined(with: .scale(scale: 0.85,
                                                              anchor: .trailing)))
            }

            Button(action: aufsProfil) {
                Profilzeichen(name: name, bild: bild, hervorgehoben: imProfil)
            }
            .buttonStyle(Stil.Druckknopf())
            .padding(.bottom, 24)
        }
        .animation(Stil.sprung, value: uebernahme?.angebot?.id)
        .frame(width: Stil.seitenleisteBreite)
        // Wie unten: der Grund muss bis an beide Kanten laufen, nicht nur bis
        // zum sicheren Bereich.
        .background {
            // Deckend wie die Leiste unten auf dem iPhone und wie beide
            // Koepfe — dieselbe Begruendung, dieselbe Farbe.
            Stil.grund.ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Stil.linie).frame(width: 1).ignoresSafeArea()
        }
    }
}

/// Unscharfer Grund, der nach unten weich ausläuft.
///
/// **Die Maske muss in UIKit liegen, nicht in SwiftUI.** Eine
/// `UIVisualEffectView` verwischt, was in der Ebenenhierarchie *hinter* ihr
/// liegt. SwiftUIs `.mask` schiebt sie dafür in eine eigene Zeichenebene —
/// dort gibt es keinen Hintergrund mehr, und es bleibt nur die Eigenfarbe des
/// Materials übrig. Genau das war vorher zu sehen: ein grauer Streifen, aber
/// nie Unschärfe.
///
/// Als `layer.mask` auf derselben Ansicht bleibt der Hintergrund erhalten.
struct Unschaerfe: UIViewRepresentable {
    /// Das dünnste Material — jedes dickere hellt sichtbar auf.
    ///
    /// Dunkel wird es nicht durch die Wahl des Materials, sondern durch den
    /// Grundton darüber. Alle Materialien tragen eine helle Schicht; je dicker,
    /// desto mehr. `.dark` wäre von Haus aus dunkel, ist aber seit iOS 13
    /// abgekündigt und zeichnet mit einer Ebenenmaske gar nicht mehr.
    var stil: UIBlurEffect.Style = .systemUltraThinMaterialDark
    /// Anteil der Höhe, bis zu dem die Unschärfe voll steht. Darunter
    /// verläuft sie aus. `nil` heißt: über die ganze Fläche, ohne Verlauf.
    var vollBis: CGFloat? = nil
    /// 0 bis 1. Geregelt wird über die **Maske**, nicht über `.opacity` —
    /// letzteres schiebt die Ansicht in eine eigene Zeichenebene, und dann
    /// hat sie keinen Hintergrund mehr zu verwischen.
    var staerke: Double = 1

    final class Ansicht: UIVisualEffectView {
        let verlauf = CAGradientLayer()
        var mitVerlauf = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // Ohne das bleibt die Maske auf der Größe von null stehen und die
            // ganze Ansicht ist unsichtbar.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            verlauf.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Ansicht {
        let ansicht = Ansicht(effect: UIBlurEffect(style: stil))
        ansicht.isUserInteractionEnabled = false
        ansicht.verlauf.startPoint = CGPoint(x: 0.5, y: 0)
        ansicht.verlauf.endPoint = CGPoint(x: 0.5, y: 1)
        setze(ansicht)
        return ansicht
    }

    func updateUIView(_ ansicht: Ansicht, context: Context) { setze(ansicht) }

    private func setze(_ ansicht: Ansicht) {
        ansicht.effect = UIBlurEffect(style: stil)
        let a = CGFloat(min(max(staerke, 0), 1))

        guard let vollBis else {
            // Ohne Verlauf: die Stärke sitzt dann in einer gleichmäßigen Maske.
            ansicht.verlauf.colors = [UIColor.black.withAlphaComponent(a).cgColor,
                                      UIColor.black.withAlphaComponent(a).cgColor]
            ansicht.verlauf.locations = [0, 1]
            ansicht.layer.mask = a < 1 ? ansicht.verlauf : nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ansicht.verlauf.colors = [UIColor.black.withAlphaComponent(a).cgColor,
                                  UIColor.black.withAlphaComponent(a).cgColor,
                                  UIColor.black.withAlphaComponent(a * 0.45).cgColor,
                                  UIColor.clear.cgColor]
        ansicht.verlauf.locations = [0, NSNumber(value: Double(vollBis)),
                                     NSNumber(value: Double((vollBis + 1) / 2)), 1]
        ansicht.layer.mask = ansicht.verlauf
        CATransaction.commit()
    }
}

/// Eine Leiste wie in Apples Apps: gleichmäßig unscharf, mit Haarlinie.
///
/// **Kein Verlauf.** Der sah unruhig aus, weil die Unschärfe auf halber Höhe
/// anfing zu verschwinden und die Kanten der Buchstaben dahinter wieder
/// scharf wurden. Apples Leisten sind über ihre ganze Höhe gleich und setzen
/// unten eine Haarlinie — das liest sich als Fläche, nicht als Schleier.
/// **Zurzeit benutzt das niemand — und das ist Absicht.**
///
/// Am 06.09.2026 sind alle drei Glasleisten der iPhone-Fassung auf eine
/// deckende Fläche umgestellt worden: die Bereichsleiste unten, der
/// Bibliothekskopf und der Kopf der Detailseiten. Der Grund steht bei jeder
/// einzeln, er ist überall derselbe — **Apples Materialien tragen alle eine
/// helle Schicht**, auch das dünnste. Über unserem Grund (#0B0B0D) und
/// bunten Plakaten wird daraus ein grauer Block, und beim Federn blitzt er
/// auf, weil `Unschaerfe` ihre Stärke über eine Maske regelt, die je Bild
/// neu gerechnet wird.
///
/// Der Baustein bleibt stehen, weil in ihm eine Messung steckt, die man
/// sonst zweimal macht (siehe `Unschaerfe`: `.dark` ist seit iOS 13
/// abgekündigt und zeichnet mit einer Ebenenmaske gar nicht mehr). **Wer ihn
/// wieder einsetzt, prüft vorher am Gerät, ob die Leiste heller ist als die
/// Seite.**
struct Leistenglas: View {
    var staerke: Double = 1
    /// Wie viel Grundton mit hineinspielt.
    var tiefe: Double = 0.5

    var body: some View {
        ZStack {
            Unschaerfe(staerke: staerke)
            Stil.grund.opacity(tiefe * staerke)
        }
        .allowsHitTesting(false)
    }
}

/// Kopfzeile, die beim Scrollen unscharf wird statt hart abzuschneiden.
///
/// Vorher war dort schwarze Fläche mit harter Kante. Der Inhalt läuft jetzt
/// sichtbar darunter durch.
struct Unschaerfekopf<Inhalt: View>: View {
    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    /// Wie weit die Seite gescrollt ist. **Nur wer ihn angibt, bekommt die
    /// Haarlinie** — auf der Startseite laufen Kacheln durch und dort ist
    /// eine Kante falsch. In der Bibliothek läuft Schrift durch, und ohne
    /// Kante sieht der Übergang aus wie Brei statt wie eine Trennung.
    var versatz: CGFloat?
    /// Wie stark der Verlauf steht — **nur für den Fall ohne Versatz.**
    ///
    /// Im Ruhezustand liegt unter dem Kopf noch gar kein Inhalt: die
    /// Scrollflaeche faengt darunter an. Der Verlauf deckt dort also nichts
    /// ab, er ist reine Zierde — und Zierde hat diese Gestaltung nicht. Wer
    /// hier eine Zahl mitgibt, laesst ihn erst aufziehen, wenn wirklich
    /// etwas darunter durchlaeuft.
    var verlaufStaerke: Double = 1
    /// Eine Lage **über** `Kopfverlauf` und **unter** dem Kopfinhalt.
    ///
    /// Die Reihenfolge ist der ganze Zweck: was hier hineingegeben wird,
    /// deckt der Verlauf nicht mit ab.
    var lage: AnyView?
    @ViewBuilder var inhalt: () -> Inhalt

    /// Dieselbe Mechanik wie in `Detailkopf`: über dreissig Punkt Weg steht
    /// die Linie voll.
    private var kante: Double {
        guard let versatz else { return 0 }
        return Double(min(max(versatz / 30, 0), 1))
    }

    var body: some View {
        inhalt()
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, (breit ? Stil.kopfOben : 0)
                     + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
            .padding(.bottom, 12)
            // **Keine Haarlinie mehr.** Sie war die Unterkante der Leiste,
            // und es gibt keine Leiste mehr — der Verlauf laeuft gegen reines
            // Schwarz aus und hat keine Kante, die verdeckt werden muesste.
            // Ein Strich ueber einem Verlauf waere ein zweites Zeichen fuer
            // dieselbe Sache.
            .background {
                // **Ein Verlauf, kein Glas — und zwar immer derselbe.**
                //
                // Hier stand dreimal etwas anderes: Glas mit 0,62 Grundton,
                // dann ein blosser Verlauf, dann Glas mit 0,28 plus Haarlinie,
                // und dazu die Fallunterscheidung „ohne Versatz ein Verlauf,
                // mit Versatz eine Leiste". Zwei Bauarten fuer dieselbe Stelle,
                // je nachdem, ob die Seite Kacheln oder Schrift traegt — und
                // am Geraet sieht man genau das: die Koepfe verhalten sich
                // nicht gleich.
                //
                // Paul am 21.09., zum dritten Mal an dieser Stelle: „das
                // Runterscrollen oben sieht nicht gut aus, koennen wir das
                // wieder wegnehmen — dass es nicht durchsichtig wird."
                //
                // Von den zwei angebotenen Wegen — Flaeche plus Strich, oder
                // Verlauf — ist der Verlauf der bessere, und zwar aus einem
                // Grund, den man erst auf Schwarz sieht: `grund` ist seit
                // heute **reines Schwarz**, also laeuft der Verlauf gegen
                // dieselbe Farbe aus, die darunter liegt. Es gibt keine Kante,
                // an der er endet, und deshalb braucht er auch keine
                // Haarlinie, die sie verdeckt. Eine Flaeche mit Strich haette
                // dagegen ueber Plakaten eine sichtbare Abbruchkante — genau
                // das, was auf der Startseite stoert.
                //
                // Eine Bauart, beide Seitenarten, keine Unschaerfe.
                Kopfverlauf()
                    // Ohne Versatz gibt die Aufrufstelle die Staerke vor (die
                    // Startseite laesst ihn mit dem Heldbild aufziehen); mit
                    // Versatz waechst er ueber dieselben 30 Punkt, ueber die
                    // vorher die Haarlinie kam.
                    .opacity(versatz == nil ? verlaufStaerke : kante)
                    .overlay(alignment: .bottom) { if let lage { lage } }
            }
    }
}

/// **Die Wertreihe geht beim Scrollen weg, statt mitzuscrollen.**
///
/// „Alle" und „A–Z" stehen unter dem Seitentitel und sagen, wonach die Liste
/// gerade sortiert ist. Das will man **vor** dem Scrollen wissen, nicht
/// mittendrin: wer schon in der Liste ist, hat sich entschieden. Sie blieben
/// trotzdem stehen, weil sie im Kopf sitzen, und nahmen dort dauerhaft 44
/// Punkt — auf einem iPhone ist das eine halbe Kachelreihe. Paul am 21.09.:
/// „die muessen ja gar nicht, wenn man runterscrollt, noch da sein. Damit
/// haette man viele Probleme geloest."
///
/// **Weggehen, nicht wegscrollen.** Mitzuscrollen hiesse, sie unter den Kopf
/// zu schieben — dann laufen zwei Dinge uebereinander, und der Kopf muesste
/// sie verdecken. Stattdessen klappt die Reihe an Ort und Stelle zu: Hoehe
/// und Deckkraft gehen zugleich auf null, und der Titel darueber sinkt dabei
/// weich auf seine Endlage. Danach steht oben genau das, was auf jeder
/// Wurzelseite oben steht — Titel, Merkliste, Profil.
///
/// **Am Finger, nicht auf Knopfdruck.** Der Wert haengt unmittelbar am
/// Scrollversatz, also laeuft die Reihe mit dem Daumen auf und zu und laesst
/// sich mitten in der Bewegung umkehren. Eine Animation mit fester Dauer
/// haette an derselben Stelle einen Sprung.
///
/// Die 44 sind gerechnet: 30 Punkt Pillenhoehe plus die 14 Abstand darueber,
/// die mit ihr verschwinden. Ueber genau diese Strecke geht sie zu — sie ist
/// also weg, sobald man so weit gescrollt hat, wie sie hoch war.
struct Wertreihe<Inhalt: View>: View {
    /// Wie weit gescrollt wurde. Null im Ruhezustand.
    let versatz: CGFloat
    @ViewBuilder var inhalt: () -> Inhalt

    /// Voll offen bei 1, ganz zu bei 0.
    private var offen: Double {
        1 - Double(min(max(versatz / Stil.wertreihenWeg, 0), 1))
    }

    var body: some View {
        inhalt()
            // **Keine Hoehenaenderung mehr — sie war eine Endlosschleife.**
            //
            // Die Reihe sass im Kopf, und der Kopf ist ein Sicherheitsrand der
            // Scrollflaeche. Aendert sie ihre Hoehe, aendert sich der Rand;
            // aendert sich der Rand, rechnet die Flaeche ihre Geometrie neu;
            // daraus kommt ein neuer Versatz, und der aendert die Hoehe. Beim
            // Hinunterscrollen laeuft das durch, beim Hinaufscrollen kippt es
            // genau an der Kante, an der die Reihe wieder aufgeht — und dort
            // steht die App still, bis das System sie abschiesst. Paul am
            // 22.09.: „ich scroll wieder hoch und immer an derselben Stelle,
            // zack, Standbild."
            //
            // Die Reihe blendet weiter mit dem Scrollen aus; ihren Platz gibt
            // sie nicht mehr frei. Das ist weniger, als gedacht war, und es
            // ist das, was ohne Rueckkopplung geht. Den Platz gaebe es nur,
            // wenn die Reihe in die Scrollflaeche wanderte statt in den Kopf —
            // dann scrollt sie mit, und genau das war nicht gewollt.
            .opacity(offen)
            // Sonst ragen die Pillen waehrend des Zuklappens unten heraus.
            .clipped()
            // Halb zugeklappt trifft man nichts mehr Sinnvolles — und ein
            // Blatt, das aus einer verschwindenden Zeile aufgeht, ist eine
            // Falle.
            .allowsHitTesting(offen > 0.5)
            .accessibilityHidden(offen < 0.5)
            .padding(.top, 14)
    }
}

/// Der Verlauf am oberen Rand scrollbarer Seiten.
///
/// Oben kräftig, unten weich. Mit drei Stützpunkten sah der Übergang wie eine
/// Kante aus: zwischen zwei Werten rechnet SwiftUI geradlinig, und ein gerader
/// Abfall liest sich als Knick. Sieben Punkte, ungleich verteilt — weit am
/// Anfang, dicht am Ende — ergeben den weichen Auslauf.
struct Kopfverlauf: View {
    /// Wie weit er unter die Kopfzeile hinausreicht.
    ///
    /// Knapp bemessen, und das ist der Punkt: der Verlauf soll den Kopf
    /// tragen, nicht den Inhalt darunter einfärben.
    ///
    /// Gerechnet für die engste Seite, die Startseite. Der Kopf endet dort bei
    /// rund 101 Punkt (sicherer Bereich 59 + Wortmarke 30 + Abstand 12), die
    /// erste Zeile — „Weiterschauen" — beginnt bei 117. Dazwischen liegen
    /// 16 Punkt, und in die passt der Ausklang gerade hinein. Mit 60 lag er
    /// 44 Punkt über der Zeile, mit 88 waren es 72; beides hat den Text
    /// sichtbar abgedunkelt.
    ///
    /// Wer hier erhöht, muss die Zahl gegen `contentMargins(.top:)` der
    /// Startseite prüfen — die ist die knappste im Projekt.
    ///
    /// **Von 14 auf 17.** „Wirklich absolut minimal tiefer." Der Ausklang
    /// reicht damit knapp an die erste Reihe der Startseite heran; sichtbar
    /// wird davon nichts, weil er dort schon unter acht Prozent liegt.
    var zugabe: CGFloat = 17

    /// **Kräftiger, aber ohne Knick** (06.09.2026).
    ///
    /// Der erste Versuch hat die alten Werte einfach mit 1,2 multipliziert und
    /// oben bei 0,98 gekappt. Genau das erzeugt den Knick, vor dem der Absatz
    /// oben warnt: die Kappung macht den Anfang flach, und was an Abfall
    /// wegfällt, muss die nächste Strecke mittragen — aus −0,8 je Einheit
    /// wurden −2,4.
    ///
    /// **Nicht der Wert zählt, sondern das Gefälle.** Neun Stützpunkte, deren
    /// Steigung erst zunimmt und am Ende wieder abnimmt — nirgends mehr als
    /// −2,2 je Einheit, und das ist weniger als im alten Verlauf. Kräftiger
    /// ist er trotzdem: bei halber Höhe deckt er 0,84 statt 0,80.
    var body: some View {
        LinearGradient(stops: [
            .init(color: Stil.grund.opacity(0.98), location: 0),
            .init(color: Stil.grund.opacity(0.94), location: 0.30),
            .init(color: Stil.grund.opacity(0.85), location: 0.48),
            .init(color: Stil.grund.opacity(0.70), location: 0.62),
            .init(color: Stil.grund.opacity(0.52), location: 0.73),
            .init(color: Stil.grund.opacity(0.34), location: 0.82),
            .init(color: Stil.grund.opacity(0.19), location: 0.89),
            .init(color: Stil.grund.opacity(0.09), location: 0.95),
            .init(color: Stil.grund.opacity(0),    location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .padding(.bottom, -zugabe)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}


/// Suchfeld im Hausstil. Kein `.searchable` — das bringt Systemhöhe,
/// Systemgrau und Systemecken mit.
struct Suchfeld: View {
    @Binding var text: String
    var platzhalter: LocalizedStringKey = "Filme, Serien, Folgen"
    /// Von aussen gesteuert, damit ein Abbrechen-Knopf die Tastatur schliessen
    /// kann.
    @FocusState.Binding var amTippen: Bool
    /// Was die Suchtaste der Tastatur ausloest.
    var abschicken: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(Stil.schriftSehrLeise)

            TextField("", text: $text, prompt: Text(platzhalter)
                .foregroundColor(Stil.schriftSehrLeise))
                // Suchfeld: Fliesstext, also 15. Vorher 16.
                .font(.system(size: 15))
                .foregroundStyle(Stil.schrift)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($amTippen)
                .onSubmit { abschicken?() }

            if !text.isEmpty {
                Button { text = "" } label: {
                    // **Wieder ein gefuellter Kreis.** Er war einmal einer,
                    // wurde zum blanken Kreuz („mit den vier Aktionskreisen
                    // ist die Kreisform aus der App verschwunden") — und
                    // steht damit als einziges Zeichen ohne Gegenstand in
                    // einem Feld, in dem alles andere eine Flaeche hat.
                    // Apples Suchfelder tragen ihn ausnahmslos gefuellt, vom
                    // Home-Bildschirm bis zur TV-App, und das ist keine Mode:
                    // in einem Feld, das gerade Text traegt, muss ein
                    // Loeschzeichen als Knopf zu erkennen sein und nicht als
                    // weiteres Zeichen im Text.
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        // Zwei Toene: Kreuz in `flaeche`, Scheibe in
                        // `schriftSehrLeise` — so liest sich das Kreuz als
                        // Aussparung und nicht als Strich obendrauf.
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Stil.flaeche, Stil.schriftSehrLeise)
                        // **Das Zeichen bleibt 17, das Ziel wird 44.** Es war
                        // die kleinste Trefferfläche der App — weniger als
                        // die Hälfte von Apples Mindestmaß. Sichtbar ändert
                        // sich nichts; der Rand ragt in den rechten
                        // Innenabstand des Feldes, wo ohnehin nichts liegt.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // **Antwort auf den Finger.** `.plain` heisst keine Reaktion:
                // 44 Punkt Trefferflaeche, und beim Druck passierte sichtbar
                // nichts. Apple laesst die Rueckmeldung beim Aufsetzen
                // beginnen, nicht beim Loslassen.
                .buttonStyle(Stil.Druckknopf())
                .accessibilityLabel("Eingabe löschen")
                // Sonst schöbe das 44er Ziel das Feld auseinander.
                .padding(.trailing, -13)
            }
        }
        .padding(.horizontal, 14)
        // **48 wie jedes andere Feld.** Es stand als einziges auf 44 — in
        // BAUTEILE 6 sogar als Abweichung vermerkt. Dieselbe Rolle, dasselbe
        // Mass: ein Feld ist ein Feld, und neben einem 48er Abbrechen-Knopf
        // sass es vier Punkt zu flach.
        // `minHeight`, damit das Feld mit groesserer Systemschrift wachsen
        // darf, statt die Zeile anzuschneiden.
        .frame(minHeight: 48)
        // Ein Suchfeld ist eine gefuellte Kapsel, kein gezeichneter Rahmen —
        // so steht es auf dem Home-Bildschirm, in der TV-App und ueberall
        // sonst. Der Rand war die letzte gezeichnete Kante der App.
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
    }
}

/// Beschreibung, die einzeilig steht und beim Antippen aufklappt.
///
/// Der volle Text war auf den Detailseiten zu wuchtig.
struct Klapptext: View {
    let text: String
    @State private var offen = false

    var body: some View {
        Button {
            withAnimation(Stil.sprung) { offen.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(text)
                    .mitwachsend(15)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(offen ? nil : 1)
                    .multilineTextAlignment(.leading)
                    // Ohne das meldet der einzeilige Text die Breite des
                    // *ganzen* Satzes als Wunschmaß. Der Stapel drumherum
                    // richtete sich danach, und beim Aufklappen sprang die
                    // ganze Seite um ein, zwei Punkte in der Breite.
                    .fixedSize(horizontal: false, vertical: true)
                    // **`minWidth: 0` — nie breiter als der Platz.** Ohne
                    // Untergrenze nimmt ein Rahmen die Breite seines Inhalts
                    // an, wenn der breiter ist; ein langer Absatz, der sich
                    // nicht umbrechen ließ, zog so beim Aufklappen die ganze
                    // Seite mit.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .rotationEffect(.degrees(offen ? 180 : 0))
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        // Eine Zeile, kein Knopf: `Druckzeile` faerbt die Flaeche, statt den
        // Absatz zu verkleinern. Vorher `.plain`, also gar nichts.
        .buttonStyle(Stil.Druckzeile())
        // VoiceOver liest den ganzen Text ohnehin vor — die Kürzung ist eine
        // rein sichtbare Sache. Deshalb hier nur der Hinweis, was der Tipp tut.
        .accessibilityLabel(text)
        .accessibilityHint(offen ? "Zuklappen" : "Aufklappen")
    }
}

/// Weicher Auslauf am unteren Rand des Heldenbilds.
///
/// Vorher stiess das Bild hart auf die dunkle Fläche darunter.
///
/// **Von 130 auf 190 Punkt** (06.09.2026). Titel und Nebenzeile stehen rund 70
/// Punkt über der Unterkante; bei 130 lag dort erst gut die Hälfte an Deckung,
/// und auf hellen Plakaten stand der Titel damit fast blank auf dem Bild.
///
/// Höher **und** flacher: der Anfang bleibt weit unter dem alten Wert, damit
/// der Verlauf nicht das halbe Bild auffrisst — er beginnt nur früher und
/// erreicht die Textzeile mit mehr Deckung.
struct Heldauslauf: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Stil.grund.opacity(0),    location: 0),
            .init(color: Stil.grund.opacity(0.28), location: 0.32),
            .init(color: Stil.grund.opacity(0.58), location: 0.56),
            .init(color: Stil.grund.opacity(0.85), location: 0.78),
            .init(color: Stil.grund,               location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: 190)
        .allowsHitTesting(false)
    }
}

/// Die Zeile unter dem Abspielknopf: Direct Play, Bewertung, Freigabe.
///
/// Sie stand vorher über dem Knopf und zusammen mit Jahr, Laufzeit und Genres
/// in zwei Zeilen — das war überladen. Jahr und Laufzeit sitzen jetzt im
/// Heldenbild, hier bleibt nur, was die Wiedergabe betrifft.
struct Belegzeile: View {
    var direktplay: Bool = false
    var hinweis: String?
    var bewertung: Double?
    var freigabe: String?
    /// **Ein freier Beleg statt des Wiedergabeplans.**
    ///
    /// Über einen Titel, den der eigene Server gar nicht hat, weiss niemand,
    /// wie er läuft — auf der Seerr-Seite steht an dieser Stelle stattdessen
    /// der Stand. Vorher stand dafür dort dieselbe Zeile ein zweites Mal, mit
    /// denselben Zahlen: Symbol 11 semifett, Wort 13 medium, Abstände 6 und 8.
    /// Ändert jemand einen Grad, laufen zwei Zeilen auseinander, die
    /// nebeneinander gleich aussehen sollen.
    var eigen: (symbol: String, wort: String, farbe: Color)?

    var body: some View {
        // **8 zwischen Huellen, nicht 14.** 14 stammt aus der Zeit, als nur
        // Direct Play eine Huelle trug und die Bewertung nackt daneben stand.
        // Seit alle drei Marken Flaechen haben (7d55a810), stehen sie wie
        // Wertpillen und die Felder der Aktionsreihe: 8 auseinander.
        HStack(spacing: 8) {
            if let eigen {
                marke(eigen.symbol, Text(verbatim: eigen.wort),
                      farbe: eigen.farbe, gewicht: .semibold)
            } else if direktplay {
                // **Halbfett, nicht `.heavy`.** Extrafett war ein vierter
                // Schnitt neben Regular, Medium und Semibold und damit der
                // einzige Verstoss gegen „hoechstens drei Schnitte" (BRAND 2).
                // Das Zeichen ist ein Haken in 11 Punkt — was es lauter macht,
                // ist die Akzentfarbe, nicht das Gewicht.
                marke("checkmark", Text("Direct Play"),
                      farbe: Stil.akzent, gewicht: .semibold)
            } else if let hinweis {
                marke("exclamationmark.triangle.fill", Text(hinweis),
                      farbe: Stil.warnung, gewicht: .regular)
            }

            // In derselben Hülle wie Direct Play (Paul, 23.09.2026): vorher
            // stand die Bewertung als einzige Angabe der Zeile nackt da.
            if let bewertung {
                marke("star.fill",
                      Text(verbatim: String(format: "%.1f", bewertung).replacingOccurrences(of: ".", with: ",")),
                      farbe: Stil.schriftLeise, gewicht: .semibold)
            }

            // **Ecke 8, nicht der Standardwert 3.** Die Skala ist seit
            // heute 10/10/12/16, und eine Marke mit 3 sitzt direkt neben
            // Dingen mit 10 — sie war das eckigste Element der Seite. Hier
            // und nicht am Baustein: `Plakette` steht auch im Mac- und
            // Fernseherziel, und die haben ihre eigene Skala.
            if let freigabe { Plakette(text: freigabe, rundung: 8) }

            Spacer(minLength: 0)
        }
    }

    /// Die Hülle, in der alle drei Belege stecken.
    ///
    /// **Warum eine Marke und kein loser Text.** Vorher standen Zeichen und
    /// Wort nackt auf dem Grund, und direkt daneben lag die Freigabe als
    /// umrandete Plakette — zwei verschiedene Formen für zwei Angaben, die
    /// gleich viel wiegen. Jetzt tragen beide dieselbe Ecke und lesen sich
    /// als Paar; welche Auskunft es ist, sagt die Farbe.
    ///
    /// **Fünfzehn Prozent, keine Füllung.** Der weiße Abspielknopf bleibt
    /// der einzige gefüllte Gegenstand der Seite. Bei dieser Deckkraft liest
    /// die Marke als Angabe; ab etwa einem Drittel wird daraus ein zweiter
    /// Knopf, und der nimmt dem ersten seine Aussage.
    ///
    /// **Eine Hülle, nicht drei.** Genau daran ist diese Zeile schon einmal
    /// auseinandergelaufen: dieselben Zahlen zweimal getippt, und beim
    /// nächsten Anfassen stimmte nur noch eine Hälfte.
    private func marke(_ symbol: String, _ wort: Text,
                       farbe: Color, gewicht: Font.Weight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: gewicht))
            wort.font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(farbe)
        // Links enger als rechts: das Zeichen ist schmaler als seine
        // Zeichenzelle, sonst sitzt das Wort sichtbar aus der Mitte.
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(farbe.opacity(0.15), in: RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous))
    }
}

/// Kopf einer Detailseite: Zurückpfeil, der beim Scrollen zur unscharfen
/// Leiste mit Titel wird.
///
/// Vorher lief der Inhalt beim Scrollen ungebremst unter Uhrzeit und Akku
/// durch, und der Pfeil schwebte ohne Grund über dem Text.
struct Detailkopf: View {
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    let titel: String
    /// Wie weit gescrollt wurde. Ab `ab` steht die Leiste voll.
    let versatz: CGFloat
    var ab: CGFloat = Stil.heldHoehe - 150
    let zurueck: () -> Void
    /// Ein Knopf rechts, etwa Bearbeiten. Ohne ihn haelt ein leeres Feld
    /// von 44 den Titel mittig zwischen den Raendern.
    var rechts: AnyView? = nil

    private var staerke: Double {
        guard ab > 0 else { return 1 }
        return Double(min(max((versatz - ab) / 70, 0), 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            // **44, nicht 40.** Denselben Pfeil gab es mit zwei
            // Trefferflächen — `Unterseitenkopf` mit 44, hier und im
            // `Seitenpfeil` mit 40. Man sieht den Unterschied nicht, man
            // trifft ihn: 40 liegt unter Apples Mindestmaß. Das Symbol
            // bleibt bei 20, sichtbar ändert sich nichts.
            Zurueckknopf(tun: zurueck)

            // **Der Titel kommt, wenn das Heldbild geht.**
            //
            // Er war zwischendurch ganz weg, mit der Begruendung „dieselbe
            // Auskunft zweimal, und eine davon in Bewegung". Das gilt fuer den
            // Seitenkopf, wo der grosse Titel **stehen bleibt** — auf einer
            // Detailseite scrollt er aber weg, und dann steht man in einer
            // Folgenliste, ohne zu wissen, von welcher Serie. Paul am 21.09.:
            // „da sollte oben der Name von der Serie stehen, der ist jetzt
            // weg, das ist eine Regression."
            //
            // Es ist auch keine doppelte Auskunft: er blendet erst ein, wenn
            // der grosse Titel oben aus dem Bild ist — die beiden sind nie
            // zugleich zu sehen. Dieselbe Staerke wie die Leiste dahinter,
            // damit Traeger und Inhalt zusammen kommen.
            Text(verbatim: titel)
                .font(Stil.rubrikGross)
                .tracking(Stil.sperrungRubrik)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .opacity(staerke)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            // Damit der Titel mittig zum Pfeil steht und nicht links daneben
            // klebt: derselbe Platz rechts, den der Pfeil links einnimmt.
            if let rechts { rechts } else { Color.clear.frame(width: 44, height: 1) }
        }
        // 8 wie im Unterseitenkopf: mit 6 sass der Pfeil auf Detailseiten 28
        // von der Kante und auf Unterseiten 30 — beim Navigieren ein Sprung von
        // zwei Punkten.
        .padding(.leading, 8)
        .padding(.trailing, Stil.randAbstand)
        .padding(.top, fensterknoepfe ? Fensterknoepfe.hoehe : 0)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1).opacity(staerke)
        }
        .background {
            ZStack {
                // **Im Ruhezustand ein Verlauf, beim Scrollen Glas.**
                //
                // Auf den Wurzelseiten ist die Unschaerfe weg — dort laufen
                // Kacheln durch, und ein Verlauf gegen reines Schwarz endet
                // ohne Kante. Hier ist die Lage anders, und deshalb ist die
                // Antwort anders: die Leiste traegt einen **Titel**, und unter
                // ihr laufen Folgenbilder und Text hindurch. Etwas, das Text
                // ueber Text lesbar halten muss, braucht mehr als einen
                // Verlauf. Paul am 21.09.: „auf den Detailseiten wuerde ich
                // schon machen, dass beim Runterscrollen das Glaselement oben
                // kommt — das fand ich da sinnvoller."
                //
                // Solange das Heldbild oben steht, nur der Verlauf: er haelt
                // den Rueckweg auf hellem Bild lesbar, ohne eine Leiste zu
                // behaupten, die es noch nicht gibt.
                Kopfverlauf().opacity(0.7 * (1 - staerke))
                // `Leistenglas` und nicht `.ultraThinMaterial`: das Material
                // in einem SwiftUI-`background` verwischt nichts, weil es dort
                // in einer eigenen Zeichenebene liegt — es bleibt nur seine
                // Eigenfarbe, ein grauer Streifen. Die Messung steht bei
                // `Leistenglas`.
                Leistenglas(staerke: staerke, tiefe: 0.28)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// Zeile, die sich nach links ziehen lässt und dabei eine Handlung freigibt.
///
/// **Keine eigene Zuggeste.** Zwei Gesten um dieselbe Bewegung streiten zu
/// lassen geht nicht sauber aus: mit `.gesture` verlor die Liste das
/// senkrechte Scrollen, mit `.simultaneousGesture` blieb der Finger an den
/// Zeilen hängen. Die Entscheidung, ob eine Bewegung waagerecht oder senkrecht
/// gemeint ist, trifft UIKit seit jeher selbst — man muss sie nur stellen.
///
/// Deshalb ist jede Zeile eine waagerechte Scrollfläche mit zwei Feldern:
/// dem Inhalt in voller Breite und der Handlung daneben. Senkrechtes Scrollen
/// gehört damit weiterhin der Liste, das Einrasten übernimmt
/// `scrollTargetBehavior`, und das Nachfedern kommt gratis dazu.
///
/// `.swipeActions` wäre der kürzere Weg, gibt es aber nur in `List` — und die
/// Folgenliste steht auf der Serienseite mitten in einer laufenden Seite.
struct Wischzeile<Inhalt: View>: View {
    let symbol: String
    let beschriftung: LocalizedStringKey
    var farbe: Color = Stil.akzent
    let aktion: () -> Void
    let tippen: () -> Void
    @ViewBuilder var inhalt: () -> Inhalt

    private enum Feld: Hashable { case inhalt, handlung }
    @State private var sichtbar: Feld? = .inhalt
    @State private var weite: CGFloat = 0
    @State private var ausgeloest = false
    /// Zählt hoch, um die Scrollfläche neu aufzubauen.
    @State private var lauf = 0

    private let breite: CGFloat = 96
    /// Ab hier löst das Ziehen von selbst aus, ohne den Knopf zu treffen.
    private let schwelle: CGFloat = 168

    /// Handlung ausführen und die Zeile wieder zufahren.
    private func ausloesen() {
        ausgeloest = true
        aktion()
        // Die Scrollfläche neu aufbauen statt sie zurückzustellen.
        //
        // Über `scrollPosition` ging es nicht zu: sie setzt während des
        // Loslassens ihre eigene Stellung fertig und überschreibt den
        // gesetzten Wert — auch einen Takt später noch. Eine frische Fläche
        // beginnt dagegen immer bei null. Der Preis ist, dass sie zuschnappt
        // statt zuzufahren; da die Zeile im selben Moment ihren Haken
        // wechselt, fällt das nicht auf.
        lauf += 1
        sichtbar = .inhalt
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // **Ein Knopf, keine Tippgeste.** Nur so gibt es einen
                // Druckzustand; die Wischflaeche bleibt davon unberuehrt,
                // weil SwiftUI einen Knopf in einer Scrollflaeche beim
                // Ziehen von selbst wieder freigibt.
                Button { tippen() } label: {
                    inhalt()
                        .containerRelativeFrame(.horizontal)
                        // Deckend, damit die Handlungsfarbe darunter nicht
                        // durchscheint, solange die Zeile zu ist.
                        .background(Stil.grund)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckzeile())
                    #if os(iOS)
                    // Muss **im** Inhalt liegen, nicht als Hintergrund der
                    // Scrollfläche: von dort aus findet die Hilfsansicht sie
                    // beim Hochlaufen der Hierarchie gar nicht.
                    .overlay(alignment: .topLeading) {
                        RandGesteVorrang().frame(width: 0, height: 0)
                    }
                    #endif
                    .id(Feld.inhalt)

                Button { ausloesen() } label: {
                    VStack(spacing: 4) {
                        // Symbol eines Seitenpfeils: 17, die naechste Stufe auf der Leiter. Vorher 18.
                        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                        Text(beschriftung).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Stil.grund)
                    .frame(width: breite)
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(Stil.Druckknopf())
                .id(Feld.handlung)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, neu in
            weite = neu
            // Weit genug gezogen: auslösen, ohne den Knopf zu treffen.
            if neu > schwelle, !ausgeloest { ausloesen() }
            if neu <= 1 { ausgeloest = false }
        }
        // Die Handlungsfarbe liegt unter der ganzen Zeile, nicht nur unter dem
        // Knopf. Zieht man über den Anschlag hinaus, füllt sie mit, statt eine
        // Kante freizugeben — so macht es iOS auch.
        //
        // Nur wenn wirklich gezogen wird: sonst blitzt sie beim Aufbau der
        // Liste kurz auf, etwa beim Wechsel zwischen den Reitern.
        .background(weite > 0.5 ? farbe : Stil.grund)
        // Rastet entweder ganz zu oder ganz auf — nichts bleibt halb offen.
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $sichtbar, anchor: .leading)
        .id(lauf)
    }
}

/// Zurückpfeil oben links auf Unterseiten ohne eigene Kopfzeile.
///
/// Eigener Baustein, weil er sonst auf jeder Seite eine andere Höhe bekommt —
/// genau das war zwischen Profil und Quick Connect zu sehen.
struct Seitenpfeil: View {
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    let zurueck: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Zurueckknopf(tun: zurueck)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.top, 6 + (fensterknoepfe ? Fensterknoepfe.hoehe : 0))
            // Der Verlauf hängt hier, weil ihn alle Unterseiten über den Pfeil
            // bekommen — sonst scrollte dort der Inhalt hart unter die
            // Statusleiste, während er auf den übrigen Seiten weich ausläuft.
            .background { Kopfverlauf() }
            Spacer(minLength: 0)
        }
    }
}

/// Eine Zeile auf der Profilseite: Symbol, Text, Pfeil, Haarlinie darunter.
///
/// Die Linie beginnt erst hinter dem Symbol — so liest sich die Gruppe als
/// zusammengehörig, statt in gleich breite Streifen zu zerfallen.
struct Profilzeile<Ziel: Hashable>: View {
    @Environment(\.breit) private var breit
    let symbol: String
    let titel: LocalizedStringKey
    var unter: LocalizedStringKey?
    /// Die ganze Zeile im Akzent — fuer eine warnende Handlung.
    var akzent = false
    /// **Nur das Zeichen im Akzent.**
    ///
    /// Fuer die eine Zeile einer Seite, die etwas *tut*, waehrend alle
    /// anderen weiterfuehren oder anzeigen. Das Zeichen traegt die Farbe, der
    /// Titel bleibt weiss: die Zeile faellt auf, ohne eine Rangfolge unter
    /// Geschwistern zu behaupten.
    var zeichenAkzent = false
    var letzte = false
    /// Führt die Zeile weiter, trägt sie ein Sprungziel — sonst eine
    /// Handlung an Ort und Stelle.
    var ziel: Ziel?
    var aktion: () -> Void = {}

    var body: some View {
        Group {
            if let ziel {
                NavigationLink(value: ziel) { rumpf }
            } else {
                Button(action: aktion) { rumpf }
            }
        }
        .buttonStyle(Stil.Druckknopf())
    }

    private var rumpf: some View {
        VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(zeichenAkzent ? Stil.akzent
                                                       : (akzent ? Stil.akzent : Stil.schrift))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titel).font(Stil.listentitel)
                        if let unter {
                            Text(unter)
                                .font(Stil.klein)
                                .foregroundStyle(Stil.schriftSehrLeise)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
                .foregroundStyle(akzent ? Stil.akzent : Stil.schrift)
                .padding(.horizontal, Stil.rand(breit: breit))
                // 14, nicht 15: dieselbe Zahl wie in jeder anderen
                // Listenzeile, und 15 liegt neben dem Raster.
                .padding(.vertical, 14)

            if !letzte {
                Blattlinie()
            }
        }
        .contentShape(Rectangle())
    }
}

extension Profilzeile where Ziel == Never {
    init(symbol: String, titel: LocalizedStringKey, unter: LocalizedStringKey? = nil,
         akzent: Bool = false, letzte: Bool = false,
         aktion: @escaping () -> Void) {
        self.init(symbol: symbol, titel: titel, unter: unter, akzent: akzent,
                  letzte: letzte, ziel: nil, aktion: aktion)
    }
}

/// Heldenbild, das beim Überziehen wächst statt wegzurutschen.
///
/// Die Oberkante bleibt an der Oberkante des Bildschirms hängen; gezogen wird
/// nur die Unterkante nach unten. Beim Loslassen federt es zurück.
///
/// Gemessen wird mit `GeometryReader` und **nicht** über den Scrollversatz im
/// Zustand: der kommt einen Bildaufbau zu spät, und genau dieser eine Rahmen
/// war die harte Kante, die oben aufblitzte. Der Leser sitzt hier in einem
/// festen Rahmen, dehnt sich also nicht gierig aus.
struct Heldbild: View {
    let url: URL?
    var hoehe: CGFloat = Stil.heldHoehe
    var raum: String = "blatt"

    var body: some View {
        GeometryReader { rahmen in
            let oben = rahmen.frame(in: .named(raum)).minY
            let dehnung = max(0, oben)
            Bild(url: url, hoehe: hoehe + dehnung, ecke: 0)
                .offset(y: -dehnung)
        }
        .frame(height: hoehe)
    }
}

/// **Eine Pille, die ihren Wert zeigt und ein Blatt öffnet.**
///
/// Der Unterschied zu `Wahlchip` ist die Frage, die sie beantwortet: der Chip
/// ist *eine Möglichkeit unter mehreren offenen* und leuchtet, wenn er gilt;
/// die Pille ist *der geltende Wert selbst*. Eine Reihe Chips liest sich als
/// aufgeklapptes Menü, das jemand offen gelassen hat — eine Reihe Pillen als
/// Werkzeugleiste. Genau daran hing der unfertige Eindruck.
///
/// Sie stand als Aufbau schon einmal da, mitten in der Bibliotheksseite, nur
/// für die Sortierung. Beim zweiten Bedarf wäre sie zweimal dagestanden.
struct Wertpille: View {
    let symbol: String
    let text: String
    let tun: () -> Void

    var body: some View {
        Button(action: tun) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Stil.schriftLeise)
                Text(verbatim: text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Stil.schrift)
            }
            .padding(.horizontal, 11)
            // `minHeight`: die Pille traegt Text, und eine feste Hoehe
            // schneidet ihn ab, sobald die Systemschrift waechst.
            .frame(minHeight: 30)
            // **Fuellung ohne Rand.** Sie trugen als einzige Knoepfe der App
            // eine Umrandung und sahen deshalb aus wie eine fremde Sorte —
            // Paul am 21.09. zu „Alle" und „A–Z": „die sehen optisch so
            // anders aus, die haben so eine Umrandung, die sonst nichts hat."
            // Die Flaeche allein sagt „hier kann man druecken"; der Rand sagt
            // dasselbe ein zweites Mal und zeichnet dabei eine Kante, die
            // kein anderer Knopf hat.
            .background(Stil.flaeche, in: Capsule())
        }
        .buttonStyle(Stil.Druckknopf())
    }
}

/// Wie viele Titel in dieser Bibliothek liegen.
///
/// **Eine Angabe, keine Handlung** — also leise Schrift und kein Kasten. Plex
/// setzt sie als gefüllte Kapsel; dort ist sie ein Knopf. Sie beantwortet
/// „bin ich hier durch?", und ohne sie scrollt man ins Ungewisse.
struct Zaehlmarke: View {
    let anzahl: Int

    var body: some View {
        Text(verbatim: anzahl.formatted())
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Stil.schriftSehrLeise)
            .accessibilityLabel(Text("\(anzahl) Titel"))
    }
}

/// Auswahlchip: eine Möglichkeit aus wenigen, ohne Liste.
///
/// Für Filter und kurze Wertebereiche. Eine Liste wäre hier mehr Aufwand als
/// Nutzen — man sieht ohnehin alles auf einmal.
struct Wahlchip: View {
    let text: String
    /// Ein Zeichen vor dem Wort — der Trichter am gewaehlten Sortierwert,
    /// wie auf dem Mac. `nil` heisst: nur das Wort.
    var symbol: String?
    let an: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            // **Gewaehlt ist weiss, nicht Akzent.**
            //
            // Hier war es der Akzent, und damit sah dieselbe Chipreihe auf
            // dem iPad anders aus als auf dem Mac, wo sie weiss ist. Es passt
            // auch besser zur Regel: der Akzent traegt Zustand, und "dieser
            // Filter gilt gerade" ist eine Auswahl. Auf dem Fernseher ist es
            // aus demselben Grund geaendert worden.
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(text)
                    // **Ein Gewicht, nicht zwei.**
                    //
                    // Hier stand `an ? .semibold : .regular`. Semifett ist
                    // breiter als Regular, und die Chips stehen **waagerecht
                    // nebeneinander**: beim Umschalten verschob sich jeder
                    // Nachbar rechts davon. Beim Akzent gab es das nicht,
                    // Farbe aendert keine Breite. 13 Medium ist die Stufe,
                    // die dazwischen liegt, und sie gilt in beiden Zustaenden.
                    .font(.system(size: 13, weight: .medium))
            }
                .foregroundStyle(an ? Stil.schrift : Stil.schriftLeise)
                .padding(.horizontal, 13)
                // `minHeight`: feste Hoehe plus Text ist die Falle, die schon
                // beim `Schalter` zugeschlagen hat.
                .frame(minHeight: 30)
                // **Kein zweiter Hauptknopf.**
                //
                // Gewaehlt war hier `Stil.schrift` als Flaeche mit `grund` als
                // Schrift — Zeichen fuer Zeichen der Hauptknopf, und auf der
                // Bibliotheksseite stehen mehrere Chips, also mehrere
                // vollflaechig gefuellte Gegenstaende. BRAND 5 laesst genau
                // einen zu. Beim Entfernen des Akzents ist damals statt der
                // Regel die Umkehrung gewaehlt worden.
                //
                // Jetzt traegt die Wahl drei leise Zeichen zugleich — Flaeche
                // `gewaehlt`, voller Rand, volle Schrift — und keines davon
                // aendert ein Mass.
                // **Zwei Fuellungen statt Fuellung und Rand.**
                //
                // Gewaehlt trug bis hierher einen vollen weissen Rand, und
                // damit war der Chip der einzige Knopf der App mit einer
                // gezeichneten Kante. `gewaehlt` (Weiss mit 8 Prozent) kam
                // ausserdem auf der Seite **dunkler** heraus als `flaeche` —
                // die Wahl machte den Chip also dunkler statt heller, genau
                // verkehrt herum.
                //
                // Jetzt eine Stufe der Leiter nach oben und voller Text: zwei
                // Zeichen, die beide in die richtige Richtung gehen, und
                // keines aendert ein Mass.
                .background(an ? Stil.erhoeht : Stil.flaeche, in: Capsule())
        }
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(text)
        .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
    }
}

/// **Ein Blatt von unten — unseres, mit Apples Physik nachgerechnet.**
///
/// Drei Anläufe, und der dritte ist der, der bleibt. Der Reihe nach, weil
/// jeder Anlauf etwas beigetragen hat:
///
/// 1. **Selbst gebaut, ohne Auffahren.** `.transition(.move)` liess beim
/// Schliessen den Hintergrund in der Sicherheitszone stehen — unter dem Blatt
/// blieb ein Streifen. 2. **Selbst gebaut, mit gemessener Karte.** Der
/// Streifen war weg, das Auffahren da. Aber "* Zu Recht: es fehlte alles, was
/// eine Bewegung geschmeidig macht — Gummikante, Wurfgeschwindigkeit, eine
/// Feder, die den Schwung des Fingers uebernimmt. 3. **Apples `sheet`.**
/// Loeste das, brachte aber **iOS 26** mit: dort schwebt ein Blatt mit
/// Teilhoehe, mit Rand links und rechts und Abstand nach unten; an den Rand
/// geht es nur noch bei voller Hoehe. Nachgelesen, nicht geraten — **eine API
/// dagegen gibt es nicht.**
///
/// Also wieder unseres — aber diesmal mit dem, was in Anlauf 2 gefehlt hat,
/// und das ist nachrechenbar und kein Gefuehl:
///
/// - **Gummikante nach oben.** Nach oben gibt es nichts zu sehen, also darf es
/// sich kaum bewegen — aber es muss sich *etwas* bewegen, sonst fuehlt sich
/// der Finger an, als sei er auf Beton. Dieselbe Formel wie `UIScrollView`. -
/// **Der Schwung geht in die Feder.** `DragGesture` liefert seit iOS 17
/// `velocity`; die Geschwindigkeit beim Loslassen wird auf die Restentfernung
/// umgerechnet und als `initialVelocity` uebergeben. Das ist der ganze
/// Unterschied zwischen „springt zurueck" und „gleitet zurueck". - **Ein
/// schneller Wisch schliesst, auch wenn er kurz ist.** Ueber 700 Punkt je
/// Sekunde reicht ein Zentimeter. - **Die Schwelle haengt an der Blatthoehe**,
/// nicht an einer festen Zahl: ein Blatt mit drei Zeilen darf nicht dieselbe
/// Strecke verlangen wie eins mit zwoelf.
struct Blattmodifikator<Blattinhalt: View>: ViewModifier {
    @Binding var offen: Bool
    @ViewBuilder var blattinhalt: () -> Blattinhalt

    /// Wie hoch die Karte ist — bestimmt, wie weit sie hinausfaehrt, wie
    /// stark die Gummikante nachgibt und ab wann ein Zug zum Schliessen
    /// reicht. **Gemessen, nicht angenommen.**
    @State private var kartenhoehe: CGFloat = 400
    /// Wie weit der Finger sie gerade verschoben hat.
    @State private var zug: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay { blatt }
    }

    private var blatt: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                // Der Schleier geht mit dem Zug auf: zieht man das Blatt
                // hinunter, wird die Seite dahinter schon heller.
                .fill(.black.opacity(offen ? 0.55 * (1 - anteil) : 0))
                .ignoresSafeArea()
                // **Dieselbe Kurve wie die Karte.** Sie hing nur an der Karte,
                // nicht am Schleier — und der wurde deshalb hart gesetzt: beim
                // Oeffnen war er sofort da, waehrend die Karte noch heraufkam.
                // Beim Schliessen fiel es nicht auf, weil `schliessen(mit:)`
                // den Wechsel ohnehin in eine Animation packt und der Schleier
                // sie mitnimmt.
                //
                // Am Zug haengt sie nicht: `value: offen` heisst, dass nur das
                // Auf und Zu laeuft. Waehrend der Finger zieht, folgt der
                // Schleier ihm eins zu eins.
                .animation(Stil.blattbewegung, value: offen)
                .onTapGesture { schliessen(mit: 0) }

            VStack(spacing: 0) {
                // **Weiss 18 %, nicht dunkel** (BRAND 7).
                //
                // Der Griff trug `grund` mit 78 % — auf `flaeche` gerechnet
                // etwa #0D0D0F auf #161619, also **dunkler als die Karte, auf
                // der er liegt**. BRAND 4: etwas Dunkleres in eine hellere
                // Karte zu legen kehrt die Richtung um und liest sich als
                // Loch, nicht als Griff. Dass derselbe Wert am
                // Fortschrittsbalken und an der Kachelmarke richtig ist,
                // aendert daran nichts: die liegen ueber einem Plakat, nicht
                // auf einer Flaeche.
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    // Zu schmal zum Treffen, und das macht nichts — gezogen
                    // wird am ganzen Blatt. Fuer VoiceOver ist er nichts.
                    .accessibilityHidden(true)

                blattinhalt()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // **Die Flaeche reicht weiter nach unten, als die Karte je
                // faehrt.** Die Feder schiesst beim Oeffnen ueber — die Karte
                // hebt kurz ab. Endet die Flaeche an ihrer Unterkante, blitzt
                // in dem Moment der Inhalt darunter durch. „Der Bounce beim
                // Oeffnen ist toll."
                UnevenRoundedRectangle(topLeadingRadius: Stil.eckeBlatt,
                                       topTrailingRadius: Stil.eckeBlatt)
                    .fill(Stil.flaeche)
                    .padding(.bottom, -400)
                    .ignoresSafeArea(edges: .bottom)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height }
                action: { kartenhoehe = $0 }
            .offset(y: offen ? zug : kartenhoehe + 400)
            // **Das Auffahren gehört hierher, nicht an die Aufrufstellen.**
            //
            // Es hing an einem `withAnimation` bei jedem Öffner — fünf
            // Stellen, und beim Umbau auf Apples `sheet` fielen alle fünf weg,
            // weil ein Systemblatt sich selbst animiert. Danach war das Blatt
            // beim Öffnen „einfach zack da" und fuhr nur noch hinaus.
            //
            // **In beide Richtungen.** Beim Schliessen stand hier `nil`, damit
            // die Feder aus `schliessen(mit:)` samt Fingerschwung gilt. Das
            // ging nur beim Ziehen auf: wer „Abbrechen" drückt, daneben tippt
            // oder etwas auswaehlt, setzt `offen` ohne jede Animation — und
            // dann war das Blatt schlagartig weg.
            //
            // Der Preis ist klein und die Sicherheit gross: der Fingerschwung
            // wirkt weiter dort, wo man ihn spuert — beim Zurueckfedern, das
            // ueber `zug` laeuft und diese Animation gar nicht beruehrt.
            .animation(Stil.blattbewegung, value: offen)
            .gesture(ziehen)
        }
        // Der Stapel muss den Schirm fuellen; sonst bemisst sich die Auflage
        // am Inhalt und die Karte sitzt oben.
        //
        // **Ohne `ignoresSafeArea` am Stapel**, und das ist der Unterschied
        // zwischen einem Knopf ueber dem Home-Indikator und einem darunter:
        // der Inhalt endet am sicheren Bereich, nur die Flaeche laeuft
        // darueber hinaus.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(offen)
        // **Mit VoiceOver kommt man sonst nicht heraus.** Geschlossen wird
        // durch Ziehen oder durch einen Tipp auf den Schleier — beides gibt
        // es mit VoiceOver nicht, und nicht jedes Blatt traegt eine
        // Abbrechen-Zeile. `.escape` ist die Geste, die das System dafuer
        // kennt; der Player macht es an seinen drei Ebenen schon so.
        .accessibilityAction(.escape) { if offen { schliessen(mit: 0) } }
    }

    /// Wie weit das Blatt auf dem Weg nach draussen ist, 0 bis 1 — daran
    /// haengt der Schleier.
    private var anteil: Double {
        Double(min(max(zug, 0) / max(kartenhoehe, 1), 1))
    }

    private var ziehen: some Gesture {
        DragGesture()
            .onChanged { wert in
                let weg = wert.translation.height
                // Nach unten eins zu eins, nach oben mit Widerstand.
                zug = weg >= 0 ? weg : -gummi(-weg)
            }
            .onEnded { wert in
                let schnell = wert.velocity.height
                // Ein Viertel der Blatthoehe, oder ein schneller Wisch.
                if wert.translation.height > kartenhoehe * 0.25 || schnell > 700 {
                    schliessen(mit: schnell)
                } else {
                    withAnimation(feder(nach: 0, mit: schnell)) { zug = 0 }
                }
            }
    }

    /// Die Gummikante von `UIScrollView`: je weiter man zieht, desto weniger
    /// gibt es nach. `c = 0.55` ist Apples Beiwert.
    private func gummi(_ weg: CGFloat) -> CGFloat {
        let d = max(kartenhoehe, 1)
        return (1 - (1 / (weg * 0.55 / d + 1))) * d
    }

    /// Eine Feder, die den Schwung des Fingers uebernimmt.
    ///
    /// `initialVelocity` zaehlt in **Einheiten der Wertaenderung je Sekunde**,
    /// nicht in Punkten — deshalb durch die Restentfernung teilen. Ohne diese
    /// Umrechnung ist die Zahl entweder wirkungslos oder schleudert.
    private func feder(nach ziel: CGFloat, mit schwung: CGFloat) -> Animation {
        let strecke = max(abs(ziel - zug), 1)
        let anfang = min(max(Double(schwung / strecke), -25), 25)
        return .interpolatingSpring(mass: 1, stiffness: 280, damping: 32,
                                    initialVelocity: anfang)
    }

    private func schliessen(mit schwung: CGFloat) {
        withAnimation(feder(nach: kartenhoehe + 400, mit: schwung)) {
            offen = false
            zug = 0
        }
    }
}

extension View {
    /// Ein Blatt von unten. Siehe ``Blattmodifikator``.
    ///
    /// **Immer anhaengen, nie in ein `if offen`.** In einem `if` steht `offen`
    /// beim Einhaengen schon auf wahr, die Karte sitzt sofort an ihrem Platz,
    /// und das Auffahren faellt aus.
    func blatt<Inhalt: View>(offen: Binding<Bool>,
                             @ViewBuilder inhalt: @escaping () -> Inhalt) -> some View {
        modifier(Blattmodifikator(offen: offen, blattinhalt: inhalt))
    }
}

/// Die Rubrik über dem Inhalt eines Blatts.
///
/// Nimmt `Text` und keinen Schlüssel: mal steht dort ein fester Titel
/// („Sortieren"), mal ein Filmtitel vom Server, der nicht übersetzt werden
/// darf.
///
/// **13 Punkt grau war zu leise.** Der Grad war für ein Blatt mit vier Zeilen
/// gebaut; ein Filterblatt nimmt den halben Schirm ein, und dort las sich
/// derselbe Titel wie eine Fußnote über der Hauptsache. Jetzt 17 halbfett in
/// Weiß, mit einer Kante darunter — Plex' Blätter machen es genauso, nur
/// zentriert. **Das Zentrieren übernehmen wir nicht:** unsere Köpfe sind
/// linksbündig, überall, und E9 sagt das auch für Köpfe.
struct Blattrubrik: View {
    let text: Text

    var body: some View {
        VStack(spacing: 0) {
            text
                .font(Stil.rubrikGross)
                // −0,008 em auf 17 Punkt sind −0,136; −0,2 war geschaetzt.
                .tracking(Stil.sperrungRubrik)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
                // 8 für den Griff, 5 für seine Höhe, 5 hier — zusammen
                // dieselben 18 wie früher, als über dem Titel nichts stand.
                .padding(.top, 5)
                .padding(.bottom, 14)
            // **Keine Linie unter der Rubrik.** Sie stand hier und trennte den
            // Titel von dem, was er ankuendigt — zwei Mittel fuer dieselbe
            // Aussage, und der Abstand macht es schon. Die Vorlage sagt es
            // ausdruecklich: „Rubrik 17 Semibold ohne Linie darunter."
        }
    }
}

/// Die Plakette oben rechts auf einer Kachel.
///
/// **In Weiß auf Dunkel, nicht in Akzent.** Der Akzent trägt Fortschritt und
/// Auswahl; eine Plakette ist eine Angabe. Plex färbt seine gelb
///
/// Welche Auskunft draufsteht, entscheidet `Anzeigeregeln.kachelmarke` im
/// Paket; hier steht nur der Wortlaut und wie sie aussieht.
struct Kachelplakette: View {
    let marke: Kachelmarke

    var body: some View {
        HStack(spacing: 3) {
            if marke == .gesehen {
                // Haken der Kachelmarke: 10, wie ihr Text. Vorher 9.
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            }
            if let text = wortlaut {
                // **Ohne Sperrung.**
                //
                // Die Leiter gibt der Plakettenstufe +0,10 em mit, und das ist
                // richtig — fuer **Versalien**. Gesperrt wird, was sonst als
                // Block zusammenklebt; Grossbuchstaben tun das, Kleinbuchstaben
                // nicht. Diese Marke traegt „3 offen" und „2 Staffeln", also
                // gewoehnliche Woerter, und 1,0 Punkt auf 10 Grad zieht sie
                // sichtbar auseinander. Paul am 22.09.: „mach bei O F F E N
                // die Luecken weg."
                //
                // Das Token bleibt stehen: es gilt weiter fuer die Stufe, nur
                // hat diese Marke keine Versalien.
                Text(verbatim: text)
                    .font(Stil.plakette)
            }
        }
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, wortlaut == nil ? 5 : 6)
        .padding(.vertical, 3)
        .background {
            // 9, nicht 6: die Kachel darunter hat 10, und eine Marke, die
            // eckiger ist als ihr Untergrund, fällt auf.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Stil.grund.opacity(0.78))

        }
        .padding(6)
    }

    private var wortlaut: String? {
        switch marke {
        case .gesehen: nil
        case .offen(let n): String(localized: "\(n) offen")
        case .staffeln(let n): n == 1 ? String(localized: "1 Staffel")
                                      : String(localized: "\(n) Staffeln")
        }
    }
}

/// Die Linie über dem Fuss eines Blatts — **über die volle Breite.**
///
/// `Trennlinie` rückt 18 Punkt ein, weil sie zwischen Zeilen mit Symbol steht.
/// Über einem Knopf, der die ganze Breite einnimmt, sieht dieselbe Linie aus
/// wie ein Fehler;
/// **Die Trennlinie in einem Blatt — und zwar durchgehend.**
///
/// In den Blaettern liefen drei Bauarten nebeneinander: `Trennlinie` mit
/// ihrem Seiteneinzug von 18, dieselbe mit zusaetzlichen 38 fuer eingerueckte
/// Folgen, und eine gerechnete, die hinter dem Zeichen anfing
/// (`trennEinzug - randAbstand`). Drei Anfaenge in einem Blatt, und keiner
/// davon fiel mit einer Kante zusammen. Paul am 21.09.: „die Striche gehen so
/// nicht ganz durch, die hoeren da beim Zeichen auf — das sieht sehr messy
/// aus."
///
/// Ein Einzug ist in einer **Liste** richtig, die am Bildschirmrand steht: er
/// sagt, dass die Zeilen zusammengehoeren und das Zeichen davor die Gruppe
/// fuehrt. In einem Blatt ist die Karte selbst schon die Gruppe — ihre
/// gerundete Kante sagt es lauter, als ein Einzug es koennte. Dann ist der
/// Einzug nur noch eine zweite Kante, die mit keiner anderen fluchtet.
///
/// Durchgehend heisst: von Kartenrand zu Kartenrand, ohne Ausnahme.
struct Blattlinie: View {
    var body: some View {
        Rectangle().fill(Stil.linie).frame(height: 1)
    }
}

/// Die Abbrechen-Zeile am Fuss eines Blatts.
struct Blattabbruch: View {
    let tun: () -> Void

    var body: some View {
        Button(action: tun) {
            Text("Abbrechen")
                // Abbrechen ist ein Nebenknopf: 15 Semifett. Vorher 16.
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Stil.schriftLeise)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(Stil.Druckzeile())
    }
}

/// Liste von Handlungen, die von unten aufgeht.
///
/// Anders als `Auswahlblatt`: dort wählt man einen Wert und sieht, welcher
/// gilt. Hier löst jede Zeile etwas aus und das Blatt schliesst sich.
///
/// Hängt an einer leeren Fläche, weil ein Blatt ein Modifikator ist und
/// keine Ansicht im Stapel — so bleiben die Aufrufstellen, wie sie waren.
struct Handlungsblatt: View {
    @Binding var offen: Bool
    /// Woran das Blatt arbeitet — nicht das Wort „Mehr". Das stand schon auf
    /// dem Knopf, und die Stelle ist zu wertvoll, um sie zu wiederholen.
    let titel: String
    /// Der Typ liegt in `Titelhandlung` und nicht hier: an diesen Baustein
    /// gebunden, konnten die anderen Plattformen dieselben Listen nicht
    /// bauen, obwohl die Handlungen überall dieselben sind.
    let handlungen: [Titelhandlung]

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .blatt(offen: $offen) {
                Blattrubrik(text: Text(verbatim: titel))

                ForEach(Array(handlungen.enumerated()), id: \.element.id) { paar in
                    // Durchgehend — die Begruendung steht bei `Blattlinie`.
                    if paar.offset > 0 { Blattlinie() }
                    Button {
                        offen = false
                        paar.element.tun()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: paar.element.symbol)
                                .font(.system(size: 17))
                                .frame(width: 20)
                            Text(paar.element.text)
                                // 17 wie die Auswahlzeile daneben — die
                                // Begruendung steht dort.
                                .font(.system(size: 17))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(paar.element.warnend ? Stil.warnung : Stil.schrift)
                        .padding(.horizontal, Stil.randAbstand)
                        // `minHeight`, nicht `height`: mit groesserer Schrift
                        // schnitte eine feste Hoehe den Text an. 52 wie jede
                        // andere Zeile in einem Blatt.
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Stil.Druckzeile())
                }

                Blattlinie()
                Blattabbruch { offen = false }
            }
    }
}

/// Kurze Rückmeldung am unteren Rand.
///
/// Für Dinge, die der Server im Hintergrund tut — dort gibt es nichts zu
/// bestätigen, nur zu sagen, dass es angekommen ist.
struct Hinweisstreifen: View {
    let text: String
    let schliessen: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                // Leerzustandstext in einer Tafel: 13, nicht 14 - 14 steht in
                                // keiner Leiter. Vorher 14.
                .font(.system(size: 13))
                .foregroundStyle(Stil.schrift)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                // Fuellung ohne Rand, wie jeder andere Knopf — siehe
                // `Wertpille`.
                .background(Stil.flaeche, in: Capsule())
                .padding(.bottom, 34)
                .padding(.horizontal, 24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .id(text)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            schliessen()
        }
    }
}

// MARK: - Leere und gestörte Ansichten

/// Was zu sehen ist, wenn nichts zu sehen ist.
///
/// Vorher hing so etwas direkt unter der Kopfzeile: ein kleines Systemsymbol,
/// grauer Text, eine graue Pille — darunter zwei Drittel Schwarz. Das liest
/// sich als Absturz, nicht als Hinweis. Hier sitzt der Block mittig im
/// verfügbaren Raum, das Zeichen steht in derselben Kreisfläche, die auch
/// sonst Flächen trägt, und der Text nennt Ross und Reiter.
struct Leerzustand: View {
    let symbol: String
    let kopfzeile: LocalizedStringKey
    let text: LocalizedStringKey
    /// `laedt` laesst das Zeichen atmen — fuer „wird gerade versucht".
    ///
    /// Hier stand „statt des Symbols dreht sich ein Ring", waehrend die
    /// Umsetzung vierzig Zeilen weiter sagt: „Kein Ring, auch hier nicht: das
    /// Zeichen selbst atmet." Zwei Vermerke im selben Typ, die sich
    /// widersprechen; der Code atmet, also stimmt der zweite.
    var laedt = false
    var hauptknopf: (titel: LocalizedStringKey, tun: () -> Void)?
    var stillerKnopf: (titel: LocalizedStringKey, tun: () -> Void)?

    var body: some View {
        // **Die Abstaende stehen in der Vorlage, nicht im Gefuehl:**
        // Zeichen · 22 · Kopfzeile · 7 · Text · 24 · Hauptknopf · 16 · stiller
        // Knopf. Vorher lief alles ueber ein `spacing: 16` plus zwei
        // Handzugaben, und Kopfzeile und Text standen so weit auseinander wie
        // Text und Knopf — obwohl die zwei oben zusammengehoeren.
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Stil.flaeche)
                    .frame(width: 78, height: 78)
                // Kein Ring, auch hier nicht: das Zeichen selbst atmet,
                // solange es laeuft. Ein Ring haette gesagt „warte", das
                // Zeichen sagt weiter, worum es geht.
                // `.light` gibt es nicht mehr: drei Gewichte, und Regular ist
                // das leichteste.
                // 44, nicht 30: „Zeichen **oder** Emoji (44)" — eine Groesse
                // fuer beide, sonst sind es zwei Leerzustaende.
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Stil.schriftLeise)
                    // Eingegrenzt auf die Deckkraft — dieselbe Falle wie in
                    // `Ladefeld`: eine Endlosschleife per `value:` erfasst
                    // alles, was sich im selben Zug an der Ansicht ändert.
                    // Das Atmen faellt bei reduzierter Bewegung weg.
                    .animation(laedt && !Stil.bewegungReduziert
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : Stil.einblenden) {
                        $0.opacity(laedt ? 0.45 : 1)
                    }
            }
            .padding(.bottom, 22)

            Text(kopfzeile)
                .padding(.bottom, 7)
                .mitwachsend(20, .semibold)
                .tracking(Stil.sperrungReihe)
                .foregroundStyle(Stil.schrift)

            Text(text)
                .mitwachsend(15)
                .foregroundStyle(Stil.schriftLeise)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)
                .padding(.bottom, 24)

            // Der Hauptknopf ist sonst so breit wie die Seite. Hier steht er
            // mittig und nur so breit wie sein Text — eine Störung ist kein
            // Formular, das man ausfüllt.
            if let hauptknopf {
                Button(hauptknopf.titel, action: hauptknopf.tun)
                    .buttonStyle(HauptknopfStil())
                    .fixedSize()
                    .padding(.bottom, 16)
            }
            if let stillerKnopf {
                Button(stillerKnopf.titel, action: stillerKnopf.tun)
                    .buttonStyle(Stil.Druckknopf())
                    .font(.system(size: 15, weight: .medium))
                    // Der stille Knopf traegt den Akzent - er ist die zweite
                    // Handlung, und der Akzent markiert sie als eine.
                    .foregroundStyle(Stil.akzent)
                    // **44 hoch** (BRAND 7). Er trug nur 15 Punkt Text, also
                    // gut 20 Punkt Trefferflaeche — und auf der Startseite ist
                    // das „Server wechseln", der Ausweg aus einem
                    // Fehlerzustand. Die Breite bleibt am Text.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
        // **Der Eintritt gehoert ins Bauteil, nicht an die Aufrufer.**
        //
        // Ein Leerzustand ist selten und emotional: der Server antwortet
        // nicht, oder die Bibliothek ist leer. Genau dort liegt das bisschen
        // Budget fuer Bewegung — und bis hierher sprang er hart ins Bild.
        // Steht die Kurve hier, bekommen sie alle Aufrufstellen, und keine
        // kann sich eine eigene ausdenken.
        //
        // Der *Zeitpunkt* bleibt beim Aufrufer: eine `.transition` wirkt nur,
        // wenn das Einfuegen selbst animiert ist. Das ist die Teilung, die
        // SwiftUI vorgibt — hier das Wie, dort das Wann.
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// **Ein gestörter Abschnitt *innerhalb* einer Seite.**
///
/// Das Gegenstück zu `leerhinweis`: dort steht „hier liegt nichts", hier
/// steht „ich weiß es nicht, der Server hat nicht geantwortet". Bis zum
/// 21.09.2026 gab es diesen Unterschied nur auf ganzen Seiten — Startseite,
/// Suche, Merkliste. Abschnitte einer Detailseite sagten bei jedem Netzfehler
/// „Nichts Ähnliches gefunden" oder verschwanden wortlos, und damit log die
/// App an fünfundzwanzig Stellen.
///
/// **Der Wortlaut ist derselbe wie im ganzseitigen `Leerzustand`** — dieselben
/// zwei Katalogschlüssel, nur kleiner gesetzt, weil hier der Seitenkopf schon
/// steht. Ein zweiter Wortlaut für dieselbe Lage wäre eine zweite Antwort auf
/// dieselbe Frage.
struct Stoerhinweis: View {
    let model: AppModel
    /// Wo es etwas zu wiederholen gibt, steht der Knopf da. Wo der Abschnitt
    /// mit der ganzen Seite neu geladen wird, fehlt er — ein Knopf, der die
    /// Seite zweimal lädt, ist schlechter als keiner.
    var erneut: (() -> Void)?
    /// 40 unter einem Leerhinweis, 0 unter einer Reihenüberschrift, die ihren
    /// Abstand schon mitbringt.
    var abstandOben: CGFloat = 40
    /// **Wer nicht geantwortet hat.** Ohne Angabe der eigene Jellyfin-Server.
    /// Auf einer Seerr-Seite ist es Seerr — derselbe Satz, aber die falsche
    /// Adresse darin waere eine falsche Fehlersuche: Paul haette seinen
    /// Jellyfin geprueft, waehrend Jellyseerr aus war.
    var adresse: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 30))
                .foregroundStyle(Stil.schriftLeise)
                .padding(.bottom, 14)

            Text("Server ist abgetaucht")
                .mitwachsend(17, .semibold)
                .foregroundStyle(Stil.schrift)
                .padding(.bottom, 6)

            Text("\(adresse ?? model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?")
                .mitwachsend(14)
                .foregroundStyle(Stil.schriftSehrLeise)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)

            if let erneut {
                Button("Erneut versuchen", action: erneut)
                    .buttonStyle(Stil.Druckknopf())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Stil.akzent)
                    // 44 hoch (BRAND 7), Breite am Text.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
        .padding(.top, abstandOben)
    }
}

// MARK: - Eingabefeld

/// Unser Feld statt `.roundedBorder`.
///
/// Dieselben Werte wie das Suchfeld — Fläche, Haarlinie, Ecke 10 —, nur 48
/// statt 44 hoch, damit es mit dem 48er Hauptknopf darunter eine Zeile bildet.
struct Eingabefeld: View {
    @Binding var text: String
    let symbol: String
    /// Als Schlüssel, nicht als Zeichenkette: sonst bleibt der Platzhalter in
    /// der Ausgangssprache stehen, während die Seite drumherum übersetzt ist.
    /// Genau das war auf der Anmeldeseite zu sehen — „Benutzername" und
    /// „Passwort" deutsch zwischen lauter englischen Beschriftungen.
    var platzhalter: LocalizedStringKey = ""
    var geheim = false
    var tastatur: Weise = .normal
    var abschluss: () -> Void = {}

    enum Weise { case normal, adresse }

    @State private var zeigt = false
    @FocusState private var amTippen: Bool
    /// Gesperrt heisst gedaempfte Schrift — dieselbe Zuordnung wie an den
    /// Knopfstilen, und sie fehlte hier ganz.
    @Environment(\.isEnabled) private var bedienbar

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 20)

            Group {
                if geheim, !zeigt {
                    SecureField("", text: $text, prompt: platz)
                } else {
                    TextField("", text: $text, prompt: platz)
                }
            }
            // Eingabefeld: Fliesstext, also 15. Vorher 16.
            .font(.system(size: 15))
            .foregroundStyle(bedienbar ? Stil.schrift : Stil.schriftSehrLeise)
            .focused($amTippen)
            .onSubmit(abschluss)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(tastatur == .adresse ? .URL : .default)
            .submitLabel(.go)
            #endif

            if geheim, !text.isEmpty {
                Button { zeigt.toggle() } label: {
                    Image(systemName: zeigt ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        // Das Zeichen bleibt 15, das Ziel wird 44.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                .accessibilityLabel(zeigt ? Text("Passwort verbergen")
                                          : Text("Passwort zeigen"))
                // Sonst schoebe das 44er Ziel das Feld auseinander.
                .padding(.trailing, -13)
            }
        }
        .padding(.horizontal, 14)
        // `minHeight`: mit groesserer Systemschrift muss das Feld wachsen
        // duerfen, sonst schneidet es die Zeile an.
        .frame(minHeight: 48)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous)
                // **Kein Fokusring.** Hier stand ein Akzentrand mit 55 Prozent —
                // eine rohe Deckkraft, und der Fokus haette allein an der Farbe
                // gehangen. Jetzt sagt die Strichstaerke, wo man schreibt: 2
                // statt 1, gleiche Farbe.
                // Gesperrt gibt es keinen Fokus, also auch nicht die
                // staerkere Kante.
                .strokeBorder(Stil.rand, lineWidth: amTippen && bedienbar ? 2 : 1)
        }
        .animation(Stil.umschalten, value: amTippen)
    }

    private var platz: Text {
        Text(platzhalter).foregroundColor(Stil.schriftSehrLeise)
    }
}


// MARK: - Platzhalter statt Ladering

/// Eine Fläche in der Form dessen, was gleich kommt.
///
/// Heisst `Ladefeld` und nicht `Platzhalter`, weil `Bild` seinen Gattungsnamen
/// schon so nennt — zwei gleiche Namen in einer Datei liest niemand mehr
/// auseinander, und der Übersetzer erst recht nicht.
///
/// **Warum kein drehender Ring.** Ein Ring sagt „warte"; ein Platzhalter
/// sagt, *was* kommt und wie viel — die Seite steht schon, sie ist nur noch
/// leer. Das ist der Unterschied zwischen „die App hängt" und „gleich da",
/// und er kostet nichts.
///
/// Das Pulsieren läuft über `.opacity` mit `repeatForever`: das übernimmt
/// Core Animation und rechnet auf dem Renderserver weiter, ohne dass SwiftUI
/// je Bild etwas neu bauen muss. Ein `TimelineView` je Kachel wäre bei
/// dreissig Platzhaltern dreissig Uhren.
struct Ladefeld: View {
    var ecke: CGFloat = Stil.eckeKachel
    @State private var hell = false

    var body: some View {
        RoundedRectangle(cornerRadius: ecke, style: .continuous)
            .fill(Stil.flaeche)
            // **Die Endlosschleife gilt nur der Deckkraft.** Vorher startete
            // `onAppear` sie mit `withAnimation(…repeatForever)` — und wer
            // gerade aus der Anmeldung kam, stand dabei mitten im animierten
            // Phasenwechsel (`RootView`, `.animation(value: model.phase)`).
            // Unter iOS 18 nahm die Endlos-Transaktion die Rahmen und Ränder
            // dieses Übergangs mit: die ganze Startseite fuhr in Dauerschleife
            // hoch und runter, gemessen am 15.09.2026 im iOS-18.6-Simulator —
            // oberer Rand 120 ↔ 58, Höhe 654 ↔ 640, der Inhalt still. Nach
            // einem Neustart gab es keinen Übergang, also auch kein Pendeln.
            // Der eingegrenzte `animation(_:body:)` kann nichts ausserhalb
            // seines Blocks erfassen.
            // Dito: ein Platzhalter, der nicht pulsiert, ist noch ein
            // Platzhalter — ein dauerndes Pulsieren gegen die Einstellung nicht.
            .animation(Stil.bewegungReduziert ? nil
                       : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                $0.opacity(hell ? 1 : 0.5)
            }
            // Ohne Transaktion setzen, nicht im Übergang: `task` läuft nach
            // dem Einfügen, nicht in dessen Animation.
            .task { hell = true }
            // Für die Sprachausgabe ist ein Platzhalter nichts — sie soll
            // „Lädt" hören, und das sagt der Rahmen darum.
            .accessibilityHidden(true)
    }
}

/// Ein Plakat mit zwei Textzeilen darunter, alles als Platzhalter.
struct Kachelplatzhalter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Ladefeld()
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: 5) {
                Ladefeld(ecke: 3).frame(height: 11)
                Ladefeld(ecke: 3).frame(width: 42, height: 9)
            }
        }
    }
}

/// Ein Raster aus Plakat-Platzhaltern, so breit wie das echte.
struct Rasterplatzhalter: View {
    let spalten: Int
    /// Wie viele Reihen. Zwei genügen: mehr sieht niemand, bevor die Antwort
    /// da ist, und jede weitere ist Arbeit für nichts.
    var reihen: Int = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
                                 count: spalten),
                  alignment: .leading, spacing: 20) {
            ForEach(0 ..< (spalten * reihen), id: \.self) { _ in
                Kachelplatzhalter()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

/// Eine Reihe aus Plakat-Platzhaltern, für die Startseite.
struct Reihenplatzhalter: View {
    @Environment(\.breit) private var breit
    var quer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Ladefeld(ecke: 4)
                .frame(width: 148, height: 18)
                .padding(.horizontal, Stil.rand(breit: breit))
            HStack(spacing: Stil.kachelAbstand) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    Ladefeld()
                        .frame(width: quer ? Stil.reihenQuerBreite(breit: breit)
                                           : Stil.reihenBreite(breit: breit),
                               height: quer ? Stil.reihenQuerHoehe(breit: breit)
                                            : Stil.reihenHoehe(breit: breit))
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}
