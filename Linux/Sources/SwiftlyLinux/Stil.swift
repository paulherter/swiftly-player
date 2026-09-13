import CGtk
import CSchriften
import Foundation
import JellyfinKit

/// **Swiftlys Aussehen, in GTKs Sprache übersetzt.**
///
/// Die Zahlen und Farben hier sind keine neuen Entscheidungen — sie stehen so
/// in `Sources/Shared/Farben.swift` und `Sources/macOS/Stil.swift` und gelten
/// auf iPhone, iPad, Apple TV und Mac. Wer eine ändert, ändert sie dort und
/// trägt sie hierher nach; eine zweite Palette wäre der sichere Weg, dass die
/// Plattformen auseinanderlaufen.
///
/// **Der Mac ist die Vorlage, nicht das Gefühl.** Am 04.09.2026 standen hier
/// erst geschätzte Werte, und sie waren zu zweit falsch: die Feldfläche war
/// `erhoeht` (#1E1E22) statt `flaeche` (#161619), und der Hauptknopf trug den
/// Akzent, obwohl er auf dem Mac **weiß mit dunkler Schrift** ist. Beides
/// stand die ganze Zeit in `Macbausteine.swift` — nachgelesen statt geraten
/// wäre billiger gewesen.
///
/// **Warum reines GTK4 und nicht libadwaita.** libadwaita ist GNOMEs
/// Gestaltungsbibliothek: sie sorgt dafür, dass eine App wie eine GNOME-App
/// aussieht. Das arbeitet gegen das Ziel — Swiftly soll auf jedem System wie
/// Swiftly aussehen, nicht wie das System. Dazu kommt, dass libadwaita auf
/// Windows kaum unterstützt wird, und Windows steht auf dem Plan. Alles, was
/// unten steht, ist deshalb einfaches GTK4 mit eigenem Stilblatt.
enum Stil {

    // MARK: Farben, wörtlich aus Farben.swift

    static let grund = "#0B0B0D"
    /// Die Fläche eines Feldes und der Seitenleiste. **Nicht `erhoeht`.**
    static let flaeche = "#161619"
    static let erhoeht = "#1E1E22"
    static let akzent = "#5CD1C2"
    static let markeAkzent = Markenpfade.akzentHex     // #2FDBC0
    static let warnung = "#E8833A"
    /// **Die zweite Farbe des Farbscheins**, und das Zeichen einer Übernahme.
    /// Der Akzent sagt „hier läuft was" — `kuehl` sagt „woanders läuft was".
    static let kuehl = "#7E9BFF"
    /// **Die Mitte des Farbscheins**, zwischen `akzent` und `kuehl`. Ohne sie
    /// steht links Türkis, rechts Blau und dazwischen ein dunkles Loch.
    static let scheinMitte = "#6EB4E1"
    static let schrift = "#FFFFFF"
    static let schriftLeise = "rgba(255,255,255,0.62)"
    /// **0,48, nicht 0,38.** Die 0,38 stehen auf Apple ausdruecklich als
    /// verworfen: „bei 0,38 war es zu blass, um es zu lesen" — 3,5 gegen die
    /// geforderten 4,5 Kontrast (`Sources/Shared/Farben.swift:26-39`). Hier
    /// stand genau der zurueckgewiesene Wert, und er traegt Rubriken,
    /// Zaehlmarken, Platzhalter und die Freigabe-Plakette.
    static let schriftSehrLeise = "rgba(255,255,255,0.48)"
    static let rand = "rgba(255,255,255,0.12)"
    /// **Der Grund jedes Profilzeichens.** Wörtlich die beiden Farben aus
    /// `Sources/Shared/Bausteine.swift`, `Profilzeichen.grund` — dort als
    /// `Color(red:green:blue:)`, hier als Hex: #2C6C66 nach #17403D, von oben
    /// links nach unten rechts.
    static let profilverlauf = "linear-gradient(135deg, #2C6C66, #17403D)"
    static let linie = "rgba(255,255,255,0.07)"

    // MARK: Maße, wörtlich aus macOS/Stil.swift

    /// **Die Eckenskala (E11).** Je größer die Fläche, desto runder.
    ///
    /// | Was | Ecke |
    /// |---|---|
    /// | Knopf, Plakat, Kachel | 10 |
    /// | Feld, Eingabe | 12 |
    /// | Fläche, Blatt, Tafel | 16 |
    /// | Chip, Hinweis | Kapsel |
    ///
    /// **Am 06.09.2026 um vier Punkte aufgerundet.** Vorher stand hier
    /// 6/8/10, und genau daran ist Paul hängengeblieben: zwei Punkte
    /// Unterschied zwischen zwei Dingen, die nebeneinander stehen, liest man
    /// nicht als Rangfolge, sondern als Versehen.
    ///
    /// Die GTK-Fassung stand bis zum 12.09.2026 noch auf den alten Werten —
    /// die Überschrift darüber behauptete „wörtlich aus macOS/Stil.swift",
    /// und das war seit sechs Tagen nicht mehr wahr. Eine Zahl, die
    /// anderswo geändert wird, wandert hier nicht von selbst mit; deshalb
    /// steht jetzt die Regelnummer dabei.
    static let ecke = 10
    /// Plakate und Kacheln — **dieselbe** Ecke wie ein Knopf. Beides sind
    /// kleine Gegenstände, die Rangfolge fängt erst darüber an.
    static let eckeKachel = 10
    /// Such- und Eingabefelder.
    static let eckeFeld = 12
    /// Was eine eigene Fläche ist: Blätter, die Tafel, Auskunftskästen.
    static let eckeFlaeche = 16
    /// Freigabe- und Seerr-Marken. **8, nicht 3** — die 3 ist auf Apple nur
    /// der Vorgabewert von `Plakette`, den dort kein einziger Aufrufer nimmt;
    /// Detailseite, Heldkopf und tvOS setzen alle ausdrücklich 8.
    static let eckeMarke = 8
    /// Chip und Hinweis sind **Kapseln** (E11). Weit über der halben Kante,
    /// damit die Form rund bleibt, wenn jemand später am Maß dreht — eine
    /// feste Zahl wäre beim nächsten Maß wieder falsch, ohne dass es auffällt.
    static let eckeKapsel = 999
    // MARK: Seitenschub

    /// Wie lange eine Seite hereinschiebt — `Stil.zeitSeitenschub` vom Mac,
    /// `easeInOut` über 0,45 s.
    static let zeitSeitenschub = 0.45
    /// Wie lange ein Bereichswechsel ueberblendet. Dieselbe Dauer, die
    /// `GtkStack` fuer seine Kreuzblende nimmt (200 ms) — sonst saehen die
    /// beiden Wege in denselben Bereich verschieden aus.
    /// **Der Bereichswechsel blendet ineinander, nicht gleichzeitig.**
    ///
    /// Der Mac trennt zwei Dauern (`Sources/macOS/Stil.swift:208-210`): das
    /// Alte geht in 0,20 s (`easeInOut`), das Neue kommt in 0,26 s
    /// (`easeOut`) mit 0,04 s Vorlauf. Hier stand **eine** Zahl für beides —
    /// eine gleichzeitige Kreuzblende, bei der die Seite in der Mitte auf
    /// halber Deckung steht.
    ///
    /// **Ohne Skalierung und ohne Unschärfe**, und das ist derselbe Schluss
    /// wie dort: die Vorschrift lässt das Eingehende von 92 % wachsen, und in
    /// einem breiten Fenster verschiebt schon ein Prozent an der Kante acht
    /// Punkte. Der Mac ersetzt sie durch 0,8 Punkt Unschärfe — die GTK nicht
    /// lebend zeichnen kann (E19, dieselbe Grenze wie beim Glas). Bleibt die
    /// Blende, und die trägt die Aussage allein.
    static let zeitBlendeHinaus = 0.20
    static let zeitBlendeHerein = 0.26
    static let zeitBlendeVorlauf = 0.04
    /// Die Kreuzblende des Reiterstapels — dort gibt es nur **eine** Dauer,
    /// weil `GtkStack` keine zwei kennt.
    static let zeitBlende = 0.2
    /// Wie weit die Seite **darunter** mitgeht. Ein knappes Drittel — so hält
    /// es die Systemnavigation, und daher kommt der Eindruck von Ebenen statt
    /// von einem Rechteck, das vorbeischiebt.
    static let schubMitgabe = 0.3
    /// Der Schleier über der Seite darunter. Auf dem Mac liegt dort Schwarz
    /// zu 28 %; über unserem dunklen Grund kommt dasselbe heraus, wenn die
    /// Ebene stattdessen auf 72 % Deckkraft geht — und das ist ein Zug im
    /// Bildbaum statt einer weiteren Fläche.
    static let schubSchleier = 0.28

    static let randAbstand = 24
    static let kachelAbstand = 12
    static let reihenAbstand = 28

    /// Kleinste Fenstergröße, unter der das Raster nicht mehr aufgeht:
    /// Seitenleiste plus zwei Kachelspalten plus Ränder. Vom Mac.
    static let fensterMinBreite = 900
    static let fensterMinHoehe = 560

    static let seitenleisteBreite = 220
    /// Ein Zeiger trifft genauer als ein Finger: Seitenleistenzeilen sind 32
    /// hoch, nicht 44 wie am Telefon.
    static let zeileHoehe = 32
    static let hauptknopfHoehe = 48
    /// **Feste Breite des Hauptknopfes.** Sonst richtet sich der Rest der
    /// Reihe nach der Länge der Beschriftung, und Merkliste und Mehr stehen
    /// auf jeder Seite woanders. 200 trägt „Fortsetzen" wie „Abspielen".
    static let hauptknopfBreite = 200
    /// Die Kopfzone der Detailseite: 150 oben plus 230 Block, keine Restluft.
    static let heldHoehe = 380
    /// Die Kopfzone der **Personenseite**. Kuerzer als die einer Detailseite:
    /// dort stehen 230 Punkt Block, hier ein 104er Kopf und zwei Zeilen.
    /// **Die Kopfzone der Personenseite** — dieselbe Rechnung wie auf dem Mac
    /// (`Sources/macOS/PersonView.swift:60`): derselbe Vorlauf oben wie auf
    /// einer Detailseite, darunter der 88 Punkt hohe Block und sein
    /// Fussabstand von 22. Hier stand eine runde 260, und der Kopf darin war
    /// 130 statt 88 — beides geschaetzt statt gerechnet.
    static let personHoehe = titelHoehe + 98 + personblockHoehe + 22
    /// So hoch wie der runde Kopf, und damit so hoch wie der ganze Block —
    /// der Text daneben ist niedriger (`PersonView.swift:46`).
    static let personblockHoehe = 88
    /// Höhe der Kopfleiste einer Detailseite (Pfeil und einblendender Titel).
    static let titelHoehe = 52
    static let feldHoehe = 38
    /// Die Breite des Anmeldeblocks. Auf dem Mac steht `.frame(width: 360)`
    /// an jedem der beiden Felder.
    static let anmeldeBreite = 360
    /// **Wie breit eine Unterseite wird.** Profil, Wiedergabe und Quick
    /// Connect lesen sich wie Text — 700, die `lesebreite` des Macs. Die
    /// Einstellungen tragen zwei Spalten nebeneinander und duerfen weiter
    /// (`Stil.einstellungBreite` = 1366 auf dem Mac).
    static let lesebreite = 700
    /// **Wie breit ein Formular steht** — Serveraufnahme, Weiteres Konto,
    /// Quick Connect. Der Mac deckelt alle drei auf 460
    /// (`Sources/macOS/ServerAufnahmeView.swift:71`,
    /// `Sources/macOS/ProfilView.swift:205` und `:279`); hier bekamen sie
    /// dieselbe `lesebreite` wie ein Fliesstext, und darin schwebte ein 360
    /// Punkt breites, mittig gesetztes Feld.
    static let formularBreite = 460
    /// **1366, wie `Sources/macOS/Stil.swift:31`.** Hier stand 1100 ohne
    /// Grund aus Abschnitt F — und die Zahl wurde ausserdem nirgends
    /// benutzt, weil GTK kein Hoechstmass kennt. Beides behoben: den Deckel
    /// setzt jetzt `Einstellungsseiten.deckeln(_:in:auf:)`.
    static let einstellungBreite = 1366
    /// Oberer Rand im Inhaltsbereich — auf dem Mac 52, **gemessen ab
    /// Fensteroberkante**: dort gibt es keine Titelzeile, die Ampel schwebt
    /// über der Seitenleiste.
    ///
    /// Unter Wayland gehört die Titelzeile dem Fenster, und ihre Höhe kommt
    /// oben drauf. Genau das war der „viel zu viel Platz über Weiterschauen":
    /// 19 plus 52 statt 52. Abgezogen stimmt der Abstand zur Fensterkante
    /// wieder mit dem Mac überein.
    static let kopfzeileHoehe = 24
    static let inhaltObenMac = 52
    static var inhaltOben: Int { inhaltObenMac - kopfzeileHoehe }

    /// **Optischer Ausgleich für die Startseite.** „Filme" steht als
    /// 28-Punkt-Titel oben, die Startseite beginnt mit „Weiterschauen" in 20.
    /// Bei gleichem Abstand von oben stehen sie nicht gleich hoch: über den
    /// Versalien lässt eine Zeile Platz, und der wächst mit dem Schriftgrad.
    /// Auf dem Mac sind es nachgemessene 2,1 Punkt.
    static let reihenkopfAusgleich = 2
    /// Wie weit der Farbschein reicht — er endet über der ersten
    /// Reihenüberschrift. Der Mac-Wert (`macOS/HomeView.swift:345`).
    static let scheinHoehe = 180

    /// Poster, 2 : 3 — auf dem iPhone 112 × 168, auf dem Mac 150 × 225.
    static let kachelBreite = 150
    static let kachelHoehe = 225
    /// Weiterschauen liegt quer, 16 : 9.
    static let querBreite = 280
    static let querHoehe = 158

    // MARK: Schriftstufen — dieselbe Abstufung wie iPhone und Mac

    static let titelGross = 28
    /// **22, nicht 27 — und die 27 waren ein Fehlgriff.**
    ///
    /// Sie standen hier mit Verweis auf `Sources/Shared/Stil.swift:337`. Das
    /// ist die **iPhone**-Stufe; es gibt zwei gleichnamige Konstanten, und
    /// die für diese Fassung ist `Sources/macOS/Stil.swift:136` — dort steht
    /// seit jeher `22, semibold`. Direkt zu sehen war es an der Serverzeile
    /// beim Anmelden (`macOS/RootView.swift:109` gegen `App.swift:410`): auf
    /// dem Mac 22 halbfett, hier 27 fett.
    static let titel = 22
    static let titelGewicht = 600
    static let reihe = 20
    static let listentitel = 15
    static let koerper = 15
    static let kachelTitel = 14
    static let zweitzeile = 12
    static let rubrik = 11

    // MARK: Stilblatt

    /// Wird einmal beim Start geladen und gilt für das ganze Programm.
    ///
    /// GTKs Stilblätter kennen dieselben Begriffe wie im Netz — Farbe,
    /// Rundung, Abstand —, nur die Auswahl geschieht über Widget-Namen statt
    /// über Marken. `.swiftly-*` sind unsere eigenen Klassen; alles ohne
    /// Punkt ist ein GTK-Typ.
    static var blatt: String {
        """
        /* **Die Schrift ist die groesste einzelne Aehnlichkeit.**
           Apple setzt SF Pro; die darf nicht mitgeliefert werden und liegt
           auf keinem Linux. Inter ist genau dafuer entworfen worden — gleiche
           Bauart, gleiche Strichstaerke, offene Lizenz (SIL OFL), also auch
           beilegbar. Ohne sie faellt es auf Noto Sans zurueck, und das ist
           deutlich runder und breiter als SF.
           Ein ausgelieferter Bau muss Inter mitbringen; hier kommt sie noch
           vom System.

           **Die Kette gilt fuer beide Plattformen, ohne Verzweigung.** Was ein
           System nicht hat, ueberspringt es: Windows kennt weder Noto Sans
           noch DejaVu und landet auf Segoe UI Variable — der dortigen
           Systemschrift, also demselben Verhaeltnis wie SF auf Apple. Linux
           kennt Segoe nicht und faellt auf Noto zurueck. Eine Zeile, kein
           `#if`, und auf jedem System die Schrift, die dort richtig ist. */
        window, .background, scrolledwindow, viewport, stack, entry, button, label {
            font-family: Inter, "Segoe UI Variable Text", "Segoe UI",
                         "Noto Sans", "DejaVu Sans", sans-serif;
        }

        window, .background, stack {
            background-color: \(grund);
            color: \(schrift);
        }
        /* **Scrollflächen malen nicht mit.** Sie standen hier mit `grund` —
           und auf einer eingefärbten Detailseite ist das eine schwarze Ebene
           hinter jeder Reihe. Sie stand unter „Besetzung". Was
           einen Grund braucht, sagt es selbst; alles andere lässt das
           Fenster durchscheinen. */
        scrolledwindow, viewport { background-color: transparent; }
        /* **Und der Reiterstapel malt auch nicht mit.** Die Regel eine Zeile
           höher fasst `stack` mit — und der Wechsler zwischen Folgen,
           Besetzung und Ähnliches liegt mitten im ausklingenden Seitenton.
           Eine deckende `grund`-Fläche schneidet ihn dort ab: genau der harte
           Schnitt, den Paul am 13.09.2026 auf Serienseiten gemeldet hat.
           Filmseiten haben keinen Stapel im Inhalt — deshalb sahen sie
           richtig aus und Serien nicht. */
        .swiftly-reiterstapel { background-color: transparent; }

        label { color: \(schrift); }
        .dim-label { color: \(schriftLeise); }
        .swiftly-leise { color: \(schriftSehrLeise); }
        .swiftly-warnung { color: \(warnung); }

        /* Die Schriftstufen des Macs, eins zu eins. */
        .swiftly-titel-gross { font-size: \(titelGross)px; font-weight: 700; }
        /* Fett wie `Stil.titel` auf Apple (`.bold`, also 700), mit derselben
           leichten Sperrung von -0,6. */
        .swiftly-titel       { font-size: \(titel)px; font-weight: \(titelGewicht); letter-spacing: -0.6px; }
        .swiftly-reihe       { font-size: \(reihe)px; font-weight: 600; letter-spacing: -0.3px; }
        .swiftly-listentitel { font-size: \(listentitel)px; font-weight: 600; }
        .swiftly-koerper     { font-size: \(koerper)px; }
        .swiftly-kacheltitel { font-size: \(kachelTitel)px; font-weight: 500; }
        .swiftly-zweitzeile  { font-size: \(zweitzeile)px; }
        .swiftly-rubrik {
            font-size: \(rubrik)px;
            font-weight: 600;
            letter-spacing: 0.7px;
        }
        /* **Die Ueberschrift ueber einer Einstellungsgruppe ist eine andere.**
           Der Mac hat fuer diese Rolle einen eigenen Baustein
           (`Sources/macOS/Einstellungszeilen.swift:49-53`): 11 medium, 1,2
           Laufweite, Weiss zu 40 % — waehrend die Seitenleistenrubrik
           (`Macbausteine.swift:70-77`) 11 halbfett, 0,7 und 48 % traegt.
           Linux hatte beides auf **eine** Funktion gelegt und dabei die
           Sidebar-Fassung als einzige Wahrheit genommen. */
        .swiftly-gruppenrubrik {
            font-size: \(rubrik)px;
            font-weight: 500;
            letter-spacing: 1.2px;
            color: rgba(255,255,255,0.40);
        }

        /* MARK: Eingabefeld
           Auf dem Mac ein eigener Baustein statt des Systemfeldes: die Fläche
           ist `flaeche`, der Rahmen eine Haarlinie in Weiß 12 %, die Ecke 12
           (`eckeFeld` — Felder sind runder als Knöpfe, E11).
           Im Fokus wird der Rahmen zum Akzent bei halber Deckung. */
        entry {
            background-color: \(flaeche);
            background-image: none;
            color: \(schrift);
            border: 1px solid \(rand);
            border-radius: \(eckeFeld)px;
            min-height: \(feldHoehe)px;
            padding: 0 12px;
            font-size: \(koerper)px;
            caret-color: \(akzent);
            box-shadow: none;
            outline: none;
        }
        /* **`:focus` allein trifft das Feld nicht.** GTK4 setzt den Fokus
           auf den inneren `text`-Knoten, nicht auf das `entry` darum. Der
           Rahmen gehoert aber dem `entry` — also `:focus-within`. Am Mac ist
           er im Fokus der Akzent bei halber Deckung. */
        entry:focus, entry:focus-within {
            border-color: rgba(92,209,194,0.5);
            outline: none;
            box-shadow: none;
        }
        entry placeholder, entry text placeholder { color: \(schriftSehrLeise); }
        /* Das Symbol im Feld: 17 breit, dahinter 9 Luft — die Zahlen der
           `Eingabezeile` auf dem Mac. */
        entry image { color: \(schriftSehrLeise); min-width: 17px; margin-right: 9px; }

        /* MARK: Knöpfe
           **Der Reset gilt nur für unsere eigenen.** Er stand einmal auf
           schlichtem `button` — und traf damit auch Minimieren, Maximieren
           und Schließen, die danach unsichtbar dastanden. Der Versuch, sie
           selbst nachzuzeichnen, sah dann nach nichts aus: die Fensterknöpfe
           gehören dem System, nicht uns. Sie sind hier deshalb gar nicht
           erwähnt und tragen, was das Systemthema ihnen gibt. */
        /* **Jede eigene Knopfklasse gehört in diese Liste.** Wer eine
           vergisst, bekommt vom Systemthema Rahmen und Schatten dazu — und
           genau so standen Schatten unter den Folgenzeilen und um den
           Zurückpfeil, der gar kein Kasten sein soll. */
        button.swiftly-haupt, button.swiftly-flach, button.swiftly-zeile,
        button.swiftly-chip, button.swiftly-profil, button.swiftly-kachel,
        button.swiftly-pfeil, button.swiftly-zurueck, button.swiftly-neben,
        button.swiftly-reiter,
        button.swiftly-einstellzeile, button.swiftly-wertzeile,
        button.swiftly-handlung, button.swiftly-spielrund,
        button.swiftly-spielrund-gross {
            background-image: none;
            background-color: transparent;
            border: none;
            box-shadow: none;
            color: \(schrift);
            border-radius: \(ecke)px;
            padding: 0;
            min-height: 0;
            min-width: 0;
        }
        button.swiftly-haupt {
            background-color: \(schrift);
            color: \(grund);
            border-radius: \(ecke)px;
            min-height: \(hauptknopfHoehe)px;
            padding: 0 30px;
            font-size: 16px;
            font-weight: 600;
        }
        button.swiftly-haupt:hover { background-color: rgba(255,255,255,0.88); }
        /* Der Mac legt `.opacity(0.4)` über den ganzen Knopf. Dieselbe
           Wirkung, nur ausgerechnet: Weiß zu 40 % über dem Grund. */
        button.swiftly-haupt:disabled {
            background-color: rgba(255,255,255,0.40);
            color: rgba(11,11,13,0.55);
        }

        /* **Die Farbe muss am Kind stehen, nicht nur am Knopf.**
           Oben steht `label { color: … }` — eine Regel auf dem Element
           selbst, und die schlägt jede geerbte Farbe. Der Hauptknopf war
           deshalb weiß auf weiß: der Pfeil (ein `image`, von der Regel nicht
           getroffen) stand da, die Beschriftung nicht. Also trägt jeder
           Knopfzustand seine Farbe ausdrücklich bis ans Kind durch. */
        button.swiftly-haupt label, button.swiftly-haupt image { color: \(grund); }
        button.swiftly-haupt:disabled label,
        button.swiftly-haupt:disabled image { color: rgba(11,11,13,0.55); }

        button.swiftly-flach {
            background-color: transparent;
            color: \(schriftLeise);
            font-size: \(koerper)px;
            min-height: \(zeileHoehe)px;
            padding: 0 10px;
        }
        button.swiftly-flach label { color: \(schriftLeise); }
        button.swiftly-flach:hover {
            background-color: rgba(255,255,255,0.06);
        }
        button.swiftly-flach:hover label { color: \(schrift); }

        /* MARK: Seitenleiste
           Fläche wie das Feld, Zeilen 32 hoch. Der Akzent trägt die Auswahl —
           dieselbe Regel wie auf iOS. Der Schwebezustand bekommt bewusst nur
           Weiß: er zeigt „hier steht der Zeiger", keine Wahl. */
        /* **Der Farbschein über der Startseite** (`macOS/HomeView.swift:343`).
           Er kommt von der Webseite, wo hinter der Schlagzeile ein türkiser
           und ein blauer Schein stehen.

           **Zwei Schichten, keine Maske.** Auf Apple läuft die Farbe schräg
           und die Deckkraft senkrecht — dafür gibt es dort `.mask`. GTKs
           Stilblatt kennt keine Maske, aber es kennt gestapelte Verläufe, und
           hier ist das gleichwertig: der Untergrund ist überall `grund`, also
           ergibt eine zweite Schicht aus `grund` mit steigender Deckung
           dieselben Bildpunkte wie das Wegmaskieren der ersten. Die Stufen
           sind die des Macs, nur umgedreht (1 − Maskendeckung).

           **Nicht nachbauen, was dort verworfen wurde:** zwei Kreise statt
           eines Verlaufs (über 900 Punkt Breite steht dann links Türkis,
           rechts Blau und dazwischen ein dunkles Loch), und die oberen 118
           Punkt freilassen (das ist die iPhone-Lösung für eine Kopfleiste,
           die es hier nicht gibt).

           Er liegt als Anstrich am Reihenstapel, also **im** Scrollinhalt:
           damit fährt er beim Scrollen mit, ohne dass jemand den Weg
           mitzählt. Deshalb trägt der Stapel seinen oberen Abstand hier als
           `padding` statt als `margin` — sonst begänne die Farbe erst
           darunter. */
        .swiftly-startschein {
            padding-top: \(inhaltOben + reihenkopfAusgleich)px;
            background-repeat: no-repeat;
            background-position: top left;
            background-size: 100% \(scheinHoehe)px, 100% \(scheinHoehe)px;
            background-image:
              linear-gradient(to bottom,
                rgba(11,11,13,0.00) 0%,   rgba(11,11,13,0.08) 34%,
                rgba(11,11,13,0.34) 58%,  rgba(11,11,13,0.72) 80%,
                rgba(11,11,13,1.00) 100%),
              linear-gradient(to bottom right,
                rgba(92,209,194,0.22) 0%,  rgba(92,209,194,0.17) 26%,
                rgba(110,180,225,0.15) 52%, rgba(126,155,255,0.17) 76%,
                rgba(126,155,255,0.20) 100%);
        }
        .swiftly-seitenleiste { background-color: \(flaeche); }

        button.swiftly-zeile {
            min-height: \(zeileHoehe)px;
            padding: 0 10px;
            border-radius: \(ecke)px;
            font-size: \(koerper)px;
            font-weight: 500;
        }
        button.swiftly-zeile label, button.swiftly-zeile image {
            color: \(schriftLeise);
        }
        button.swiftly-zeile image { min-width: 17px; }
        button.swiftly-zeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-zeile:hover label,
        button.swiftly-zeile:hover image { color: \(schrift); }
        button.swiftly-zeile.swiftly-aktiv {
            background-color: rgba(92,209,194,0.10);
        }
        button.swiftly-zeile.swiftly-aktiv label,
        button.swiftly-zeile.swiftly-aktiv image { color: \(akzent); }

        /* MARK: Chip — 28 hoch, 12 seitlich, vollrund.
           Aktiv weiss mit dunkler Schrift, sonst leise mit Haarlinie. */
        button.swiftly-chip {
            min-height: 28px;
            padding: 0 12px;
            border-radius: \(eckeKapsel)px;
            border: 1px solid \(rand);
            font-size: 13px;
            font-weight: 400;
        }
        button.swiftly-chip label,
        button.swiftly-chip image { color: \(schriftLeise); }
        button.swiftly-chip:hover label,
        button.swiftly-chip:hover image { color: \(schrift); }
        button.swiftly-chip:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-chip:hover label { color: \(schrift); }
        button.swiftly-chip.swiftly-aktiv {
            background-color: \(schrift);
            border-color: transparent;
            font-weight: 600;
        }
        button.swiftly-chip.swiftly-aktiv label { color: \(grund); }

        button.swiftly-profil {
            min-height: 40px;
            padding: 0 10px;
            border-radius: \(ecke)px;
        }
        button.swiftly-profil:hover { background-color: rgba(255,255,255,0.06); }
        /* **Dieselbe Auswahl-Optik wie eine Bereichszeile** (E2: der Akzent
           traegt Auswahl). Der Mac faerbt bei offener Unterseite Name und
           Flaeche der Kontozeile im Akzent
           (`Sources/macOS/HauptView.swift:892,903`); hier leuchtete dann gar
           keine Zeile mehr, weil `bereichszeilenMalen` allen die
           Hervorhebung nimmt und keine sie bekam. */
        button.swiftly-profil.swiftly-aktiv {
            background-color: rgba(92,209,194,0.10);
        }
        button.swiftly-profil.swiftly-aktiv label { color: \(akzent); }

        /* **Ein Ladefeld in der Form des kommenden Inhalts** (E17). Der
           Ladering kommt in der Oberfläche nicht vor — er sagt „warte" und
           sonst nichts: nicht was kommt, nicht wie viel. Hier stand an
           mehreren Stellen ein „Lade …" als Fließtext; das ist eine dritte
           Form, die E17 auch nicht vorsieht.

           `Stil.flaeche`, pulsierend zwischen halber und voller Deckung über
           0,9 s — dieselben Werte wie `Ladefeld` auf Apple
           (`Sources/Shared/Stil.swift:3302`). */
        @keyframes swiftly-pulsen {
            0%   { opacity: 0.5; }
            50%  { opacity: 1.0; }
            100% { opacity: 0.5; }
        }
        .swiftly-ladefeld {
            background-color: \(flaeche);
            border-radius: \(eckeKachel)px;
            animation: swiftly-pulsen 1.8s ease-in-out infinite;
        }
        .swiftly-ladefeld.swiftly-schmal { border-radius: 3px; }
        /* **Eine Rubrik über einer Liste sagt auch, wie viel** (E27). Sie
           beantwortet „bin ich hier durch?"; ohne sie scrollt man ins
           Ungewisse. 13 halbfett in `schriftSehrLeise`, wie `Zaehlmarke` auf
           Apple (`Stil.swift:2682`) — hier stand Körpergröße in `leise`,
           also zwei Stufen zu laut. */
        .swiftly-zaehlmarke {
            font-size: 13px;
            font-weight: 500;
            color: \(schriftSehrLeise);
        }
        /* **Eine Karte je Server** (`macOS/ProfilView.swift:490`). Hier stand
           bis zum 13.09.2026 ein Streifen aus Kreisen — die Fassung, die der
           Mac am 11.09.2026 ersetzt hat. Der Akzentrand markiert den
           verbundenen Server, aber nur wenn es mehr als einen gibt (D10). */
        .swiftly-kontokarte {
            background-color: \(flaeche);
            border-radius: \(eckeFlaeche)px;
        }
        .swiftly-kontokarte.swiftly-aktiv {
            border: 1.5px solid rgba(92,209,194,0.55);
        }
        .swiftly-kontoname { font-size: 19px; font-weight: 600; letter-spacing: -0.2px; }
        /* Ein gestrichelter Kreis — ein Platz, der noch frei ist. */
        .swiftly-kontoplus {
            background: none;
            border: 1.5px dashed \(rand);
            border-radius: \(eckeKapsel)px;
            color: rgba(255,255,255,0.45);
            padding: 0;
            min-width: 40px;
            min-height: 40px;
        }
        .swiftly-kontoplus:hover { background-color: rgba(255,255,255,0.06); }
        /* **Ein Genre-Chip ueber der Startseite.** Eckig, nicht rund: Ecke
           wie ein Knopf, denn rund ist, was ein Bild ist (E26). 34 hoch, 14
           seitlich — die Masse des Macs (`HomeView.swift:274`). */
        button.swiftly-gattungschip {
            min-height: 34px;
            padding: 0 14px;
            border-radius: \(ecke)px;
            background-color: \(flaeche);
            border: 1px solid \(rand);
            font-size: 14px;
            font-weight: 500;
            color: \(schrift);
        }
        button.swiftly-gattungschip:hover { background-color: \(erhoeht); }
        .swiftly-listenpfeil {
            background: none;
            border: none;
            padding: 4px;
            min-width: 28px;
            min-height: 28px;
            color: \(schriftLeise);
        }
        .swiftly-listenpfeil:hover { background-color: rgba(255,255,255,0.06); }
        /* Der Haken auf dem Folgenbild: 20 rund, dunkler Grund, 6 Abstand
           zur Ecke — die Masse des Macs (`SerienView.swift:656`). */
        .swiftly-folgenhaken {
            color: \(schrift);
            background-color: rgba(11,11,13,0.72);
            border-radius: \(eckeKapsel)px;
            min-width: 20px;
            min-height: 20px;
            margin: 6px;
        }
        /* **Die Karte, auf der Einstellungszeilen liegen.** `Stil.flaeche`
           mit `eckeFlaeche` — wortgleich `Karte` auf dem Mac
           (`Einstellungszeilen.swift:30`). Die erste und die letzte Zeile
           bekommen die Ecke mit, sonst stiesse ein rechteckiger Knopf ueber
           die runde Kante. */
        .swiftly-karte {
            background-color: \(flaeche);
            border-radius: \(eckeFlaeche)px;
        }
        .swiftly-trennlinie { background-color: \(linie); min-height: 1px; }

        /* Auf dem Mac schwebt die Titelzeile über dem Grund, ohne Kante.
           Dieselbe Wirkung: gleiche Farbe, keine Linie, kein Schatten. */
        /* **Die Leiste ist so hoch wie ihre Knöpfe, nicht wie ihre Regel.**
           `min-height` allein hat nichts gebracht: die Fensterknöpfe bringen
           vom Systemthema ihre eigene Mindesthöhe samt Innenabstand mit, und
           die gewinnt. Also beides. Auf dem Mac gibt es hier gar keine Leiste
           — die Ampel schwebt über der Seitenleiste; unter Wayland gehört die
           Titelzeile dem Fenster, sie soll nur so wenig Platz nehmen wie
           möglich. */
        headerbar {
            background-color: \(flaeche);
            background-image: none;
            border: none;
            box-shadow: none;
            min-height: 0;
            padding: 0 4px;
        }
        headerbar windowcontrols { margin: 0; min-height: 0; }
        headerbar windowcontrols button {
            min-height: 20px;
            min-width: 20px;
            padding: 0;
            margin: 0 2px;
        }

        /* Der Fortschrittsbalken auf einer „Weiterschauen"-Kachel: dunkle
           Spur über die ganze Breite, darauf der Akzent so weit, wie gesehen
           wurde. Genau wie auf dem Mac. */
        /* **Drei Zustände, drei Zeichen auf einer Kachel** (E16). Balken
           heisst angefangen, Haken heisst gesehen, eine Zahl heisst: so viel
           liegt hier. **In Weiss auf Dunkel, nicht in Akzent** — eine
           Plakette ist eine Angabe, keine Auswahl.

           Radius 9, nicht 3: die Kachel darunter hat 10, und eine Marke, die
           eckiger ist als ihr Untergrund, fällt auf (`Stil.swift:2996`). */
        .swiftly-kachelmarke {
            font-size: 10px;
            font-weight: 600;
            color: \(schrift);
            background-color: rgba(11,11,13,0.78);
            border: 1px solid \(rand);
            border-radius: 9px;
            padding: 3px 6px;
            margin: 6px;
        }
        /* **Beim blossen Haken einen Punkt enger** — `Stil.swift:2990`:
           `padding(.horizontal, wortlaut == nil ? 5 : 6)`. Ein Zeichen ohne
           Wort braucht weniger Luft als eine Zahl, sonst sieht die Marke
           daneben zu breit aus. */
        .swiftly-kachelmarke.swiftly-nurhaken { padding: 3px 5px; }
        .swiftly-balkenspur { background-color: rgba(255,255,255,0.16); }
        .swiftly-balken { background-color: \(akzent); }

        /* Plakate: eigener Grund, solange das Bild noch nicht da ist.
           **Und sie wachsen unter dem Zeiger.** Auf dem Mac steht dafür
           `.scaleEffect(schwebt ? 1.04 : 1)` am Bild — nur am Bild, nicht an
           der Kachel: der Text darunter soll stehen bleiben. GTK4 kennt
           `transform` im Stilblatt, also geht dasselbe hier.
           Die Kachel muss ein Knopf sein, damit `:hover` überhaupt greift —
           auf einer schlichten Box führt GTK den Zustand nicht. */
        .swiftly-plakat {
            background-color: \(flaeche);
            border-radius: \(eckeKachel)px;
            transition: transform 120ms ease-out;
        }
        button.swiftly-kachel { padding: 0; background-color: transparent; }
        button.swiftly-kachel:hover .swiftly-plakat { transform: scale(1.04); }

        /* Der Blätterpfeil: 34 rund, Grund zu 72 %, Haarlinie darum. */
        button.swiftly-pfeil {
            min-width: 34px;
            min-height: 34px;
            padding: 0;
            margin: 0 6px;
            border-radius: 17px;
            background-color: rgba(11,13,13,0.72);
            border: 1px solid \(rand);
        }
        button.swiftly-pfeil { transition: opacity 140ms ease-out; }
        button.swiftly-pfeil image { color: \(schrift); }
        button.swiftly-pfeil:hover { background-color: rgba(11,13,13,0.92); }

        /* Das Raster: GTK malt Auswahl- und Randflächen, die wir nicht
           wollen — es soll nur anordnen. */
        flowbox, flowboxchild {
            background-color: transparent;
            background-image: none;
            padding: 0;
            border: none;
        }
        flowboxchild:selected, flowboxchild:focus { outline: none; box-shadow: none; }

        /* Das Benutzerbild ist rund. 26 Punkt, wie auf dem Mac. */
        .swiftly-profilbild {
            border-radius: 13px;
            background-image: \(profilverlauf);
        }

        /* Bei mehreren Konten stehen unten zwei Kreise. Der zweite traegt
           einen Rand in der Farbe der Leiste — er stanzt die Ueberlappung
           aus, sonst kleben die beiden Kreise zu einer Form zusammen. */
        .swiftly-profilbild-aktiv {
            border-radius: 13px;
            background-image: \(profilverlauf);
            box-shadow: 0 0 0 1.5px \(akzent);
        }
        .swiftly-profilbild-daneben {
            border-radius: 13px;
            background-image: \(profilverlauf);
            box-shadow: 0 0 0 2px \(flaeche);
        }

        /* MARK: Detailseite */

        /* **34, nicht 40.** Auch hier war `Heldkopf.swift` die falsche
           Vorlage — das ist die iPhone-/iPad-Fassung. Der Mac setzt den
           Heldtitel an beiden Stellen, an denen es ihn gibt, auf 34 fett mit
           -0,8 Laufweite: `DetailView.swift:390` und `PersonView.swift:158`.
           Bei 40 stiess die Schrift ausserdem an die Oberkante ihres 42
           Punkt hohen Fachs. */
        .swiftly-heldtitel { font-size: 34px; font-weight: 700; letter-spacing: -0.8px; }
        .swiftly-angaben { font-size: 14px; }
        .swiftly-beschreibung { color: rgba(255,255,255,0.62); font-size: \(koerper)px; }
        .swiftly-leistentitel { font-size: 17px; font-weight: 600; }
        .swiftly-beleg label, .swiftly-beleg image { color: \(akzent); }
        .swiftly-warnung label, .swiftly-warnung image { color: \(warnung); }

        /* **Der Beleg ist eine Marke, kein loser Text.**

           Er stand hier als Zeichen und Wort nackt auf dem Grund, direkt
           neben der umrandeten Freigabe-Plakette: zwei Formen fuer zwei
           Angaben, die gleich viel wiegen. Auf dem Mac tragen beide dieselbe
           Ecke und lesen sich als Paar; welche Auskunft es ist, sagt die
           Farbe (`Sources/macOS/DetailView.swift:446`).

           Fuenfzehn Prozent Toenung, keine Fuellung — der weisse Abspielknopf
           bleibt der einzige gefuellte Gegenstand der Seite. Ab etwa einem
           Drittel wird daraus ein zweiter Knopf.

           Links enger als rechts: das Zeichen ist schmaler als seine
           Zeichenzelle, sonst sitzt das Wort sichtbar aus der Mitte. */
        .swiftly-belegmarke { border-radius: \(eckeMarke)px; padding: 4px 10px 4px 8px; }
        .swiftly-belegmarke.swiftly-beleg   { background-color: alpha(\(akzent), 0.15); }
        .swiftly-belegmarke.swiftly-warnung { background-color: alpha(\(warnung), 0.15); }
        .swiftly-belegmarke label { font-size: 13px; font-weight: 500; }

        /* Die Sterne neben den Angaben: 13 mittel, nicht die Zweitzeile mit
           12 — auf dem Mac steht dort `.font(.system(size: 13, weight:
           .medium))` (`DetailView.swift:433`). */
        .swiftly-bewertung label { font-size: 13px; font-weight: 500; }

        /* **Die Staffelliste klappt im Seitenfluss auf**, nicht als Blatt —
           `Sources/macOS/SerienView.swift:554-566`. Deshalb `eckeFeld` (12)
           und *kein* Schatten: sie liegt in der Seite, nicht darüber. */
        .swiftly-staffelliste {
            background-color: \(erhoeht);
            border: 1px solid \(rand);
            border-radius: \(eckeFeld)px;
            padding: 4px 0;
        }
        button.swiftly-staffelzeile {
            min-height: \(zeileHoehe)px;
            padding: 0 12px;
            border-radius: 0;
        }
        button.swiftly-staffelzeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-staffelzeile.swiftly-aktiv label,
        button.swiftly-staffelzeile.swiftly-aktiv image { color: \(akzent); }

        /* **Die Seerr-Marke auf einer Kachel** — gefuellte Kapsel in der Farbe
           des Standes, dunkle Schrift, 11 halbfett, Innenrand 8 x 3
           (`Sources/macOS/SeerrKachelUndSeite.swift:56-70`). Die Klasse
           `swiftly-marke` stand im Code und gab es hier nicht: alle drei
           Staende sahen gleich aus. Die Farben stehen als `Seerrstand.farbe`
           in `Sources/Shared/Seerrmarke.swift:63-68`. */
        .swiftly-marke {
            font-size: 11px;
            font-weight: 600;
            color: \(grund);
            border-radius: \(eckeKapsel)px;
            padding: 3px 8px;
        }
        .swiftly-marke-akzent { background-color: \(akzent); }
        .swiftly-marke-wartet { background-color: rgb(217,153,43); }
        .swiftly-marke-laedt  { background-color: rgb(74,143,217); }

        .swiftly-plakette {
            font-size: 10px;
            font-weight: 600;
            color: \(schriftLeise);
            border: 1px solid \(rand);
            border-radius: \(eckeMarke)px;
            padding: 2px 5px;
        }

        /* Die Kopfleiste schwebt über der Seite und malt nichts. */
        .swiftly-detailkopf { background-color: transparent; }
        button.swiftly-zurueck {
            min-width: 40px;
            min-height: 40px;
            padding: 0;
            border-radius: \(ecke)px;
            background-color: transparent;
            border: none;
        }
        button.swiftly-zurueck image { color: \(schrift); -gtk-icon-size: 20px; }
        /* **Kein Grund, auch nicht beim Schweben.** Auf dem Mac ist es ein
           blanker Winkel mit `.buttonStyle(.plain)` — kein Rahmen, keine
           Fläche. Ein Kasten, der nur unter dem Zeiger erscheint, ist eine
           Zutat, die dort nicht steht. */
        button.swiftly-zurueck:hover { background-color: transparent; }
        button.swiftly-zurueck:hover image { color: rgba(255,255,255,0.72); }

        /* MARK: Kopfzone der Detailseite
           Der Ton kommt aus ``Tonblatt`` und wechselt mit dem Titel; hier
           steht nur, was ohne Ton gilt. */
        .swiftly-seitenton { background-color: \(grund); }
        /* Malt nichts. Für Widgets, die nur ein Mass beisteuern — die
           Zeichenflaeche der Kulisse malt ihr Bild selbst mit Cairo. */
        .swiftly-blank { background-color: transparent; background-image: none; }
        /* **Ein Knopf bringt bei Breeze eine Kante mit**, und `swiftly-blank`
           nahm ihm nur den Grund. Um den Schalter in der Reihenliste stand
           deshalb ein Rahmen, den es auf dem Mac nicht gibt — dort ist es ein
           `Button(action:)` mit `.buttonStyle(.plain)` um eine `Capsule`.
           Am 13.09.2026 am Bild gefunden. */
        button.swiftly-blank {
            border: none;
            box-shadow: none;
            outline: none;
            padding: 0;
            min-width: 0;
            min-height: 0;
        }
        drawingarea { background-color: transparent; }

        /* MARK: Die Leiste, die beim Scrollen kommt
           Wie auf iPhone, iPad und Mac: unten eine Haarlinie, dahinter Glas —
           und solange das Bild oben steht stattdessen ein weicher Verlauf,
           damit der Pfeil auf hellem Bild lesbar bleibt.
           **Ohne Glas.** GTK hat keine lebende Unschaerfe; was den Inhalt
           darunter verwischt, gibt es hier nicht. An ihre Stelle tritt eine
           dunkle Flaeche — dieselbe Aufgabe, anderes Mittel. */
        .swiftly-kopfverlauf {
            background-image: linear-gradient(to bottom,
                rgba(11,11,13,0.70) 0%, rgba(11,11,13,0) 100%);
        }
        /* **Deckend, nicht durchscheinend.** Auf Apple ist die Leiste beim
           Scrollen `Stil.grund` mit voller Deckung; hier standen 0,86, und
           darunter liefen die Plakate sichtbar durch. Der Grund dort steht
           ausdruecklich dabei: eine Flaeche kann nicht aufblitzen und ist
           genau so dunkel wie die Seite. */
        .swiftly-kopfleiste {
            background-color: \(grund);
            border-bottom: 1px solid \(linie);
        }

        /* Nebenknopf: abgerundetes Quadrat, nur Symbol. */
        button.swiftly-neben {
            border-radius: \(ecke)px;
            background-color: rgba(255,255,255,0.14);
            padding: 0;
            border: none;
        }
        button.swiftly-neben image { color: \(schrift); }
        button.swiftly-neben:hover { background-color: rgba(255,255,255,0.22); }
        button.swiftly-neben.swiftly-aktiv { background-color: \(schrift); }
        button.swiftly-neben.swiftly-aktiv image { color: \(grund); }

        /* Reiter: aktiv halbfett mit Akzentstrich. */
        button.swiftly-reiter {
            background-color: transparent;
            border: none;
            border-radius: 0;
            padding: 0;
            font-size: 15px;
        }
        button.swiftly-reiter label { color: \(schriftLeise); }
        button.swiftly-reiter:hover label { color: \(schrift); }
        button.swiftly-reiter.swiftly-aktiv label { color: \(schrift); font-weight: 600; }
        .swiftly-reiterstrich { background-color: transparent; }
        button.swiftly-reiter.swiftly-aktiv .swiftly-reiterstrich {
            background-color: \(akzent);
        }

        /* **Der Rand steckt im Innenabstand, nicht im aeusseren.**
           So laeuft die Hervorhebung ueber die ganze Breite, wie auf dem Mac,
           und das Vorschaubild steht trotzdem in der Flucht der
           Reiterbeschriftung darueber. Keine Rundung: eine Zeile, die von
           Kante zu Kante geht, hat keine Ecken. */
        .swiftly-folgenzeile {
            background-color: transparent;
            padding: 12px \(randAbstand)px;
            transition: background-color 120ms ease-out;
        }
        /* Weiss zu vier Prozent — der Wert vom Mac. */
        .swiftly-folgenzeile.swiftly-schwebt { background-color: rgba(255,255,255,0.04); }
        /* **Eine Haarlinie zwischen den Folgen** — der Mac hat sie
           (`SerienView.swift:217`). Ohne sie fliessen zwei Zeilen mit langer
           Beschreibung ineinander. */
        .swiftly-folgenzeile { border-bottom: 1px solid \(linie); }
        /* Der Abspielkreis, der beim Schweben ueber dem Bild erscheint. */
        .swiftly-spielkreis {
            background-color: rgba(0,0,0,0.55);
            border-radius: 17px;
            min-width: 34px;
            min-height: 34px;
        }
        .swiftly-spielkreis image { color: \(schrift); }
        /* Rund, nicht abgerundet-eckig: der Mac nimmt hier den kleinen
           Aktionsknopf, kein Nebenknopf der Knopfreihe. */
        button.swiftly-hakenknopf {
            border-radius: 17px;
            padding: 0;
            min-width: 34px;
            min-height: 34px;
            background-color: rgba(255,255,255,0.14);
        }
        button.swiftly-hakenknopf:hover { background-color: rgba(255,255,255,0.22); }

        .swiftly-kopfbild { border-radius: 42px; }

        /* MARK: Einstellungszeilen */

        .swiftly-fuss { color: rgba(255,255,255,0.45); }
        .swiftly-akzentzeile label { color: \(akzent); }
        /* **Die Rolle, ueber die man kam** — im Akzent, halbfett, wie auf
           Apple (`PersonView.swift:190`). `swiftly-akzentzeile` trifft nur
           Kind-Labels; hier ist das Widget selbst das Label. */
        .swiftly-rolle { color: \(akzent); font-size: 14px; font-weight: 500; }
        .swiftly-akzentzeile image { color: \(akzent); }
        .swiftly-zeilenrumpf, button.swiftly-einstellzeile {
            min-height: 44px;
            padding: 0 14px;
            border-radius: 0;
            background-color: transparent;
            border: none;
        }
        /* Erste und letzte Zeile runden mit der Karte ab — sonst stiesse ein
           rechteckiges Schweben ueber die runde Kante. */
        .swiftly-karte > box > :first-child {
            border-top-left-radius: \(eckeFlaeche)px;
            border-top-right-radius: \(eckeFlaeche)px;
        }
        .swiftly-karte > box > :last-child {
            border-bottom-left-radius: \(eckeFlaeche)px;
            border-bottom-right-radius: \(eckeFlaeche)px;
        }
        button.swiftly-einstellzeile:hover { background-color: rgba(255,255,255,0.05); }
        button.swiftly-einstellzeile image { color: \(schriftLeise); }
        button.swiftly-einstellzeile.swiftly-akzentzeile image { color: \(akzent); }

        /* Der Schalter — Kapsel, Akzent wenn an. Kein GtkSwitch: der bringt
           Form, Farbe und Maße des Systems mit (E4). */
        .swiftly-schalter {
            /* Weiss zu 14 % — `Stil.schrift.opacity(0.14)`, die Mac-Zahl aus
               `Sources/macOS/Einstellungszeilen.swift:133`. Die 16 % kamen
               vom iPhone-Blatt, wie auch die Maße. */
            background-color: rgba(255,255,255,0.14);
            border-radius: \(eckeKapsel)px;
            padding: 3px;
        }
        .swiftly-schalter.swiftly-aktiv { background-color: \(akzent); }
        /* Ein Kreis, kein abgerundetes Rechteck — `Circle()` auf dem Mac. */
        .swiftly-knauf { background-color: \(schrift); border-radius: \(eckeKapsel)px; }
        .swiftly-schalter.swiftly-aktiv .swiftly-knauf { background-color: \(grund); }

        .swiftly-werteliste { background-color: rgba(255,255,255,0.03); }
        button.swiftly-wertzeile {
            min-height: 36px;
            padding: 0 12px 0 48px;
            border-radius: 0;
            background-color: transparent;
            border: none;
        }
        button.swiftly-wertzeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-wertzeile label { color: \(schriftLeise); }
        button.swiftly-wertzeile.swiftly-aktiv label { color: \(schrift); }
        button.swiftly-wertzeile.swiftly-aktiv image { color: \(akzent); }

        .swiftly-profilgross { border-radius: \(eckeKapsel)px; background-image: \(profilverlauf); }
        /* **Rund, weil es ein Bild ist** (E26). Hier stand ein fester Radius
           von 42 — auf einem 84er Bild ein Kreis, auf dem 104er Kopf der
           Personenseite ein Quadrat mit weichen Ecken. */
        .swiftly-personkopf { border-radius: \(eckeKapsel)px; background-image: \(profilverlauf); }

        /* **Der Buchstabe, wenn kein Bild kommt.** Die Groesse ist auf Apple
           `groesse * 0.38`; hier steht sie je Kreisgroesse fest, weil GTKs
           Stilblatt nichts rechnen kann. 96 -> 36, 84 -> 32, 72 -> 27,
           26 -> 10. */
        .swiftly-zeichen96 { font-size: 36px; font-weight: 600; color: \(schrift); }
        .swiftly-zeichen84 { font-size: 32px; font-weight: 600; color: \(schrift); }
        .swiftly-zeichen72 { font-size: 27px; font-weight: 600; color: \(schrift); }
        .swiftly-zeichen26 { font-size: 10px; font-weight: 600; color: \(schrift); }

        /* MARK: Weiteres Konto

           Der zweite Weg auf einer Seite: Rand statt Flaeche. Auf dem Mac ist
           das `Umrissknopf` — dort steht er ebenfalls nur an dieser einen
           Stelle. */
        button.swiftly-umriss {
            border: 1px solid \(rand);
            border-radius: \(ecke)px;
            background: none;
            box-shadow: none;
            min-height: 40px;
            color: \(schrift);
            font-size: \(koerper)px;
        }
        button.swiftly-umriss:hover { background-color: rgba(255,255,255,0.06); }

        /* Der Quick-Connect-Code bekommt einen eigenen Teil — nicht die Zeile,
           in der Fehler stehen. Gross, mittig, auf eigener Flaeche. */
        /* **Ueber die volle Breite, mit Rand** — `ProfilView.swift:353-364`:
           `frame(maxWidth: .infinity)`, `Stil.flaeche` mit `Stil.ecke` und
           eine Haarlinie darum. Die Haarlinie fehlte, und ohne sie steht der
           Kasten nur da, wo der Text steht. */
        .swiftly-codegross {
            font-size: 40px;
            font-weight: 600;
            letter-spacing: 6px;
            background-color: \(flaeche);
            border: 1px solid \(rand);
            border-radius: \(ecke)px;
            padding: 18px 0;
        }

        /* MARK: Kontenstreifen im Profil

           Der Ring liegt als Schatten aussen an, nicht als Rand: ein Rand
           zaehlt zur Flaeche und macht das Bild um seine Staerke kleiner —
           96 und 72 waeren dann 93 und 70, und die beiden Groessen stuenden
           nicht mehr im Verhaeltnis des Entwurfs. */
        .swiftly-kontoaktiv {
            border-radius: 48px;
            background-image: \(profilverlauf);
            box-shadow: 0 0 0 1.5px \(akzent);
        }
        .swiftly-kontoandere {
            border-radius: 36px;
            background-image: \(profilverlauf);
            box-shadow: 0 0 0 1px rgba(255,255,255,0.12);
        }
        .swiftly-kontopunkt { border-radius: 3px; background-color: \(akzent); }
        button.swiftly-kontoknopf {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
            min-width: 0;
            min-height: 0;
        }
        button.swiftly-kontoknopf:hover { opacity: 1; }

        /* Der Quick-Connect-Code: gross, mittig, gesperrt. */
        entry.swiftly-code {
            font-size: 34px;
            font-weight: 600;
            min-height: 76px;
            letter-spacing: 6px;
        }
        entry.swiftly-code text { caret-color: \(akzent); }

        /* MARK: Player (E10) */

        /* Der Grund der Startanimation — auf iOS eine eigene Farbe
           („Startgrund"), hier derselbe dunkle Grund wie überall. */
        .swiftly-startgrund { background-color: \(grund); }
        /* Der Dateiauszug: Haarlinie darüber, 14 Punkt Luft. */
        .swiftly-dateizeile {
            border-top: 1px solid \(linie);
            padding-top: 14px;
            margin-top: 8px;
        }

        /* Die Hinweiszeile: drei Sekunden, dann weg. */
        /* Die Übernahmezeile: 40 hoch, Akzent zu 6 % mit Rand zu 18 %,
           schwebend 12 und 35 — die Werte vom Mac. */
        button.swiftly-uebernahme {
            min-height: 40px;
            padding: 0 10px;
            border-radius: \(ecke)px;
            background-color: rgba(92,209,194,0.06);
            border: 1px solid rgba(92,209,194,0.18);
            transition: background-color 120ms ease-out, border-color 120ms ease-out;
        }
        button.swiftly-uebernahme:hover {
            background-color: rgba(92,209,194,0.12);
            border-color: rgba(92,209,194,0.35);
        }
        button.swiftly-uebernahme image { color: \(akzent); }
        .swiftly-uebernahmezeile { font-size: 11px; color: \(schriftSehrLeise); }

        .swiftly-akzentzeichen { color: \(akzent); }
        .swiftly-sehrleise, .swiftly-sehrleise image { color: \(schriftSehrLeise); }

        /* **Eine Kapsel in `erhoeht`, kein Rechteck auf Schwarz.** So steht
           `Hinweisstreifen` auf dem Mac (`Macbausteine.swift:632`): Kapsel,
           Grund `erhoeht`, Haarlinie in `rand`. Hier stand ein eigener
           schwarzer Kasten mit Radius 10 — E11 zählt den Hinweis
           ausdrücklich zu den Kapseln, und ein zweiter Grundton neben
           `erhoeht` ist eine Fläche, die es sonst nirgends gibt. */
        .swiftly-hinweis {
            font-size: 14px;
            color: \(schrift);
            background-color: \(erhoeht);
            border: 1px solid \(rand);
            border-radius: \(eckeKapsel)px;
            padding: 12px 18px;
        }
        .swiftly-spieler { background-color: #000000; }
        /* Die Steuerung liegt über dem Bild und blendet weich weg. */
        /* Zwei Schleier, oben 0,60 über 150 Punkt, unten 0,70 über 230 —
           die Werte vom Mac. In Anteilen ausgedrückt, weil ein Fenster
           anders hoch ist als das nächste; bei rund 800 Punkt Höhe kommt
           dasselbe heraus. */
        /* **Zwei Schleier mit fester Höhe, nicht in Anteilen.**

           In Anteilen wuchsen sie mit dem Fenster mit: bei 1200 Punkt Höhe
           waren die unteren 29 % schon 348 Punkt statt der 230 vom Mac, und
           die Leiste unten sah entsprechend wuchtig aus. Zwei Anstriche mit
           `background-size` treffen die Werte genau, egal wie hoch das
           Fenster ist. */
        .swiftly-steuerung {
            background-image:
                linear-gradient(to bottom, rgba(0,0,0,0.60), rgba(0,0,0,0)),
                linear-gradient(to top, rgba(0,0,0,0.70), rgba(0,0,0,0));
            background-size: 100% 150px, 100% 230px;
            background-position: top, bottom;
            background-repeat: no-repeat;
            transition: opacity 180ms ease-out;
        }
        /* **Die Knöpfe der Mitte tragen keine Fläche.** Auf dem Mac steht
           dort nur das Zeichen (`buttonStyle(.plain)`), darunter das
           Tastenkürzel. Die runden Flächen, die hier standen, waren meine
           Erfindung und haben den Player nach Systemabspieler aussehen
           lassen. */
        button.swiftly-spieltaste {
            background-color: transparent;
            background-image: none;
            border: none;
            box-shadow: none;
            padding: 0;
            min-width: 0;
            min-height: 0;
        }
        button.swiftly-spieltaste image { color: \(schrift); }
        /* Der Zeiger hebt das Zeichen an, statt einen Kasten zu malen. */
        button.swiftly-spieltaste:hover label { color: \(schriftLeise); }
        /* Der Vollbildknopf: so gross wie ein Chip hoch ist, rund, leise. */
        button.swiftly-vollknopf {
            /* Wie bei den Zeichenkapseln daneben: der Radius steht ueber der
               halben Kante, damit die Form rund bleibt und nicht an einem
               spaeteren Mass haengt. Mit dem Rand von einem Punkt war die
               feste 14 ohnehin schon eine Spur zu klein. */
            border-radius: 999px;
            padding: 0;
            min-width: 28px;
            min-height: 28px;
            border: 1px solid \(rand);
            background-color: transparent;
        }
        button.swiftly-vollknopf image { color: \(schriftLeise); }
        button.swiftly-vollknopf:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-vollknopf:hover image { color: \(schrift); }

        .swiftly-kuerzel {
            font-size: 11px;
            color: \(schriftSehrLeise);
        }

        /* Titel und Zeiten unten. 19 halbfett, darunter 14 auf 68 %, und
           die Zeiten 13 mit gleich breiten Ziffern — die Masse des Macs. */
        .swiftly-spielertitel { font-size: 19px; font-weight: 600; color: \(schrift); }
        .swiftly-spielerzeile { font-size: 14px; color: rgba(255,255,255,0.68); }
        .swiftly-spielerzeit {
            font-size: 13px;
            font-feature-settings: "tnum";
            color: rgba(255,255,255,0.68);
        }
        .swiftly-warnung label, .swiftly-warnung image { color: \(warnung); }

        /* **Der Zeitregler — und Breeze wieder mit seinen Rändern.**

           Hier stand nur `min-width` und `min-height`. Das Systemthema legt
           auf `slider` einen Rand, und GTK meldete es sogar wörtlich:
           „slider reported min width −5, but sizes must be >= 0". Ein
           negatives Mass verwirft GTK, und dann malt Breeze seinen eigenen
           Regler — genau der, der unverändert wiederkam.

           Dieselbe Falle wie bei `scrollbar slider` ein paar Zeilen weiter
           oben, und dieselbe Abhilfe: **wer eine Mindestgrösse überschreibt,
           muss Rand und Innenabstand mit überschreiben.** */
        scale.swiftly-regler {
            min-height: 14px;
            padding: 0;
            margin: 0;
        }
        /* **Die Spur wird mit Rand auf 4 gehalten, nicht mit `min-height`.**
           `min-height` ist ein Mindestmass — der Knoten `trough` bekommt
           trotzdem die volle Höhe der Skala und malt seinen Grund über
           vierzehn Punkt. Genau das war die zu dicke Leiste. Fünf Punkt Rand
           oben und unten lassen ihm rechnerisch vier. */
        scale.swiftly-regler trough {
            min-height: 4px;
            margin: 5px 0;
            padding: 0;
            border: none;
            background-image: none;
            background-color: rgba(255,255,255,0.18);
            border-radius: 2px;
            box-shadow: none;
        }
        scale.swiftly-regler highlight {
            margin: 0;
            padding: 0;
            border: none;
            background-image: none;
            background-color: \(akzent);
            border-radius: 2px;
            box-shadow: none;
        }
        /* **Der Griff ragt aus der Spur heraus, er weitet sie nicht.**
           Der Griff ist ein Kind der Spur; ohne negativen Rand zieht er sie
           auf seine dreizehn Punkt auf, und dann malt sie ihren Grund ueber
           die ganze Hoehe — das war die zu dicke Leiste, auch nachdem die
           Warnung weg war. −5 oben und unten lassen der Spur ihre vier.
           Genau so macht es Adwaita selbst. */
        scale.swiftly-regler slider {
            min-width: 13px;
            min-height: 13px;
            margin: -5px 0;
            padding: 0;
            border: none;
            background-image: none;
            background-color: \(schrift);
            border-radius: 7px;
            /* Der Griff liegt über dem Bild und braucht eine Kante, sonst
               verschwindet er auf einer hellen Stelle — auf dem Mac ist es
               derselbe Schatten. */
            box-shadow: 0 1px 5px rgba(0,0,0,0.55);
        }
        scale.swiftly-regler:hover slider {
            min-width: 15px;
            min-height: 15px;
            margin: -6px 0;
        }

        /* Die Spurtafel über dem Bild: 320 breit, erhoeht, Ecke 10. */
        /* **Das Technikschild.** Feste Zeichenbreite, damit die Zahlen
           untereinander stehen und nicht bei jedem Takt springen — dieselbe
           Begruendung wie auf den Apple-Fassungen. Deckend genug, um ueber
           bewegtem Bild lesbar zu bleiben. */
        /* Ein Chip ohne Wort: quadratisch statt breit, Kapsel bleibt. */
        /* **34 breit, 28 hoch — eine Kapsel, kein Kreis.**

           Hier standen 28 x 28 mit der Begruendung, ein Kreis sei so breit
           wie hoch. Das stimmt, nur ist es auf dem Mac keiner: `Chip` setzt
           `frame(width: nurSymbol ? 34 : nil, height: 28)` und zeichnet
           ausdruecklich `Capsule()` — `Sources/macOS/Macbausteine.swift:117`
           und `:121`. Drei Punkt breiter als hoch ist die Vorlage, nicht ein
           Versehen darin.

           Der Radius steht weit ueber der halben Kante. GTK deckelt ihn auf
           das Moegliche, und damit bleibt die Form auch dann richtig, wenn
           jemand spaeter an der Groesse dreht. */
        .swiftly-chip.swiftly-nursymbol {
            padding: 0;
            min-width: 34px;
            min-height: 28px;
            border-radius: \(eckeKapsel)px;
        }
        /* `Stil.ecke` wie auf Apple (`Technikschild.swift:115`), nicht das
           Feldmass. Bis zum 12.09.2026 stand hier `eckeFeld` — und traf,
           solange beide 10 waren, zufaellig das Richtige. */
        .swiftly-technikschild {
            font-family: monospace;
            font-size: 12px;
            color: rgba(255,255,255,0.92);
            background-color: rgba(11,11,13,0.82);
            border: 1px solid \(rand);
            border-radius: \(ecke)px;
            padding: 10px 14px;
        }
        /* **Die Wiedergabetafel — Zahl fuer Zahl aus `macOS/Spurwahl.swift`.**

           Hier stand `erhoeht` mit `eckeFlaeche` (16), mit Verweis auf
           `Handlungstafel` — das ist die iPad-Fassung eines anderen Menues.
           Die Vorlage dieser Tafel ist `Spurwahl` (`:93-100`): `Stil.flaeche`,
           `Stil.eckeFeld` (12), Haarlinie, Schatten 22 bei y 10, 0,45. */
        .swiftly-tafel {
            background-color: \(flaeche);
            border: 1px solid \(rand);
            border-radius: \(eckeFeld)px;
            /* Sie liegt ueber bewegtem Bild und braucht eine Kante. */
            box-shadow: 0 10px 22px rgba(0,0,0,0.45);
        }
        /* **Die Leiste links steht auf halbem Grund** — `Spurwahl.swift:155`
           setzt `Stil.grund.opacity(0.5)` hinter sie. Ohne das sind beide
           Spalten dieselbe Flaeche und die Tafel liest sich als ein Block.
           Die Kante dazwischen ist eine Haarlinie, keine Fuge (`:79`); der
           Kommentar, der hier einmal das Gegenteil behauptete, hat den
           Quelltext nicht gelesen. */
        .swiftly-spurleiste { background-color: rgba(11,11,13,0.5); }
        button.swiftly-spurzeile {
            min-height: 40px;
            padding: 0 12px;
            border-radius: 8px;
            background-color: transparent;
            border: none;
        }
        button.swiftly-spurzeile label:first-child { font-size: 14px; }
        button.swiftly-spurzeile:hover { background-color: rgba(255,255,255,0.06); }
        /* **Eine getoente Flaeche, nicht nur Akzentschrift.** Der Mac legt
           `akzent.opacity(0.14)` mit Ecke 8 unter die gewaehlte Zeile
           (`Spurwahl.swift:124`). */
        button.swiftly-spurzeile.swiftly-aktiv {
            background-color: alpha(\(akzent), 0.14);
        }
        button.swiftly-spurzeile.swiftly-aktiv label,
        button.swiftly-spurzeile.swiftly-aktiv image { color: \(akzent); }
        button.swiftly-spurzeile image, .swiftly-spurzeichen { color: \(akzent); }
        /* **Die gewaehlte Zeile traegt den Akzent**, nicht eine Flaeche —
           so auf dem Mac (`Spurwahl.Wahlzeile`). */
        button.swiftly-wertzeile.swiftly-aktiv label,
        button.swiftly-wertzeile.swiftly-aktiv image { color: \(akzent); }

        /* Die Mehr-Liste. GTKs Popover bringt einen eigenen Grund mit —
           der wird hier überschrieben, sonst stünde Apples… nein: KDEs
           Gestalt darin. */
        /* **Der Popover malt hinter seinem Inhalt noch selbst.** Sein
           eigener Knoten trägt vom Systemthema Grund und Schatten; nur den
           Inhalt zu gestalten ließ eine schwarze Fläche ringsum stehen. */
        popover.swiftly-mehr,
        popover.swiftly-mehr > arrow {
            background-color: transparent;
            background-image: none;
            border: none;
            box-shadow: none;
        }
        /* **`eckeFeld` (12), nicht `eckeFlaeche` (16).** Hier stand der Verweis
           auf `Handlungstafel` (`Sources/Shared/Heldkopf.swift:286`) — das ist
           die iPad-/Fernsehfassung. Die Mac-Detailseite ruft `Handlungsliste`
           (`Sources/macOS/Macbausteine.swift:577-597`): Ecke 12, Breite 260,
           Schatten 18/8 bei 0,4. */
        popover.swiftly-mehr > contents {
            background-color: \(erhoeht);
            border: 1px solid \(rand);
            border-radius: \(eckeFeld)px;
            padding: 6px;
            box-shadow: 0 8px 18px rgba(0,0,0,0.40);
        }
        button.swiftly-handlung {
            min-height: 36px;
            padding: 0 10px;
            border-radius: \(ecke)px;
            background-color: transparent;
            border: none;
        }
        button.swiftly-handlung:hover { background-color: rgba(255,255,255,0.08); }
        button.swiftly-handlung image { color: \(schriftLeise); }

        scrollbar { background-color: transparent; }
        /* **Den Rand des Systemthemas mit zurücksetzen.** Breeze legt auf
           `scrollbar slider` einen Rand von 4; mit unseren 6 Punkt
           Mindestbreite bleiben davon −2 übrig, und GTK meldet genau das:
           „slider reported min width -2, but sizes must be >= 0". Wer eine
           Mindestgröße überschreibt, muss den Rand mit überschreiben. */
        scrollbar slider {
            background-color: rgba(255,255,255,0.22);
            border-radius: 8px;
            min-width: 6px;
            min-height: 6px;
            margin: 0;
            border: none;
        }
        scrollbar slider:hover { background-color: rgba(255,255,255,0.36); }
        """
    }

    /// **Die Schrift kommt mit, sie wird nicht erwartet.**
    ///
    /// Auf dem Mac ist die Oberfläche in SF Pro gesetzt, und die gibt es nur
    /// dort. Inter ist ihr nächster Verwandter und liegt neben der App; auf
    /// Linux ist sie oft schon installiert, unter Windows nie — dort fiele
    /// die Oberfläche sonst auf Segoe UI zurück und sähe anders aus als auf
    /// dem Mac. Da alle Plattformen gleich aussehen sollen, wird sie hier
    /// angemeldet, bevor das erste Stilblatt greift.
    ///
    /// Still im Fehlerfall: findet sich der Ordner nicht, bleibt es bei der
    /// Schrift des Systems.
    private static func schriftMitbringen() {
        guard let ordner = Plattform.mitgeliefert("Schriften") else { return }
        _ = ordner.withCString { schriften_laden($0) }
    }

    /// Lädt das Stilblatt in die Anzeige.
    static func anwenden() {
        schriftMitbringen()
        let anbieter = gtk_css_provider_new()
        meckern(anbieter)
        gtk_css_provider_load_from_string(anbieter, blatt)
        if let anzeige = gdk_display_get_default() {
            // `GtkStyleProvider` ist eine Schnittstelle, kein Typ, den Swift
            // benennen kann — wie `GtkEditable`. Der Anbieter geht deshalb
            // als undurchsichtiger Zeiger hinein.
            gtk_style_context_add_provider_for_display(
                anzeige, OpaquePointer(anbieter),
                800)   // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        }
        g_object_unref(UnsafeMutableRawPointer(anbieter))
    }

    /// **GTK meldet einen Fehler im Stilblatt nicht auf der Fehlerleitung**,
    /// sondern über das Signal `parsing-error` — wer nicht zuhört, merkt
    /// nichts. Eine Schreibweise, die GTK nicht kennt, fällt damit lautlos
    /// aus, und die Suche beginnt beim falschen Widget. Das ist heute schon
    /// einmal passiert.
    static func meckern(_ anbieter: UnsafeMutablePointer<GtkCssProvider>!) {
        g_signal_connect_data(UnsafeMutableRawPointer(anbieter), "parsing-error",
                              unsafeBitCast(stilfehler, to: GCallback.self),
                              nil, nil, GConnectFlags(rawValue: 0))
    }

    // MARK: Wortmarke

    /// Legt die Wortmarke einmal als SVG-Datei ab und gibt den Pfad zurück.
    ///
    /// Der Pfad selbst kommt aus `Markenpfade` im geteilten Paket — dieselbe
    /// Zeichenkette, aus der die Apple-Fassungen ihre Vektorform bauen. GTK
    /// liest SVG über librsvg; fehlt das, gibt es einen Textrückfall.
    static func wortmarkeDatei(hoehe: Int) -> String? {
        let r = Markenpfade.wortmarkeRahmen
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" \
        viewBox="\(r.x) \(r.y) \(r.breite) \(r.hoehe)" \
        width="\(Int(Double(hoehe) * r.breite / r.hoehe))" height="\(hoehe)">
        <path d="\(Markenpfade.wortmarke)" fill="\(schrift)"/>
        <path d="\(Markenpfade.wortmarkeAkzent)" fill="\(markeAkzent)"/>
        </svg>
        """
        let ziel = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftly-wortmarke-\(hoehe).svg")
        do {
            try svg.write(to: ziel, atomically: true, encoding: .utf8)
            return ziel.path
        } catch {
            return nil
        }
    }

    /// Die Wortmarke als Widget, in der gewünschten Höhe.
    ///
    /// **44 auf der Anmeldung, 28 in der Seitenleiste** — beides steht so in
    /// `Sources/macOS/RootView.swift` und `HauptView.swift`. Geraten war sie
    /// vorher 64, und das war eineinhalbmal zu groß.
    ///
    /// **Zwei Fallen liegen hier hintereinander.**
    ///
    /// `GtkImage` nimmt seine Größenangabe nur für Symbole; eine geladene
    /// Datei zeigt es in deren eigener Größe und ignoriert den Wunsch. Also
    /// `GtkPicture`.
    ///
    /// Aber `gtk_widget_set_size_request` setzt nur eine **Mindest**größe.
    /// Ein `GtkPicture` wächst darüber hinaus, sobald Platz da ist — deshalb
    /// stand die Marke danach zweieinhalbmal zu groß im Fenster. Es braucht
    /// zusätzlich `hexpand`/`vexpand` auf null und eine Ausrichtung, sonst
    /// nimmt sie sich, was der Stapel ihr anbietet.
    ///
    /// Die Breite folgt dem Seitenverhältnis des Rahmens (3005 zu 1024, also
    /// knapp 2,94 zu 1) statt geraten zu werden.
    static func wortmarke(hoehe: Int = 44, links: Bool = false) -> Widget! {
        let r = Markenpfade.wortmarkeRahmen
        let breite = Int(Double(hoehe) * r.breite / r.hoehe)
        // Doppelt so fein anlegen, damit es auf feinen Bildschirmen scharf bleibt.
        guard let datei = wortmarkeDatei(hoehe: hoehe * 2) else {
            return beschriftung("swiftly", stil: "swiftly-titel-gross")
        }
        // **Und der doppelt so feine Aufbau war zugleich die Falle.** Die
        // Marke stand doppelt so groß da, weil `set_size_request` nur ein
        // Mindestmaß ist und ein Bild von 164 × 56 genau die verlangt, sobald
        // Platz da ist. Der Überzug misst nur sein Hauptkind — dasselbe
        // Mittel wie bei den Plakaten, siehe ``gerahmtesBild``.
        let huelle: Widget! = gtk_overlay_new()
        let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_set_size_request(mass, Int32(breite), Int32(hoehe))
        gtk_overlay_set_child(OpaquePointer(huelle), mass)

        let bild: Widget! = gtk_picture_new_for_filename(datei)
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
        gtk_overlay_add_overlay(OpaquePointer(huelle), bild)

        gtk_widget_set_hexpand(huelle, 0)
        gtk_widget_set_vexpand(huelle, 0)
        gtk_widget_set_halign(huelle, links ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
        gtk_widget_set_valign(huelle, GTK_ALIGN_CENTER)
        return huelle
    }
}


/// Form: `(GtkCssProvider*, GtkCssSection*, GError*, gpointer)`.
nonisolated(unsafe) let stilfehler: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutablePointer<GError>?, gpointer?
) -> Void = { _, abschnitt, fehler, _ in
    let text = fehler?.pointee.message.map { String(cString: $0) } ?? "unbekannt"
    let stelle = abschnitt.map { String(cString: gtk_css_section_to_string($0)) } ?? "?"
    FileHandle.standardError.write(Data("[Stilblatt] \(stelle): \(text)\n".utf8))
}
