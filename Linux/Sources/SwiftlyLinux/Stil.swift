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

    // **Neutral, nicht getoent** — dieselbe Umstellung wie auf Apple.
    //
    // Hier stand die alte Leiter: #0B0B0D, #161619, #1E1E22. Sie trug einen
    // Blaustich, weil die Neutralen damals auf der Akzent-Hue lagen. Drei
    // Anlaeufe spaeter steht in `Sources/Shared/Farben.swift` eine exakt
    // neutrale Leiter (R = G = B), und diese Datei ist deren Abschrift.
    static let grund = "#101010"
    /// Die Fläche eines Feldes und der Seitenleiste. **Nicht `erhoeht`.**
    static let flaeche = "#262626"
    static let erhoeht = "#303030"
    static let akzent = "#50D5DA"
    /// Marke und Oberflaeche tragen seit dem 21.09. denselben Ton; der
    /// Kommentar hier nannte noch das alte Markentuerkis.
    static let markeAkzent = Markenpfade.akzentHex     // #50D5DA
    static let warnung = "#E8833A"
    static let schrift = "#FFFFFF"
    /// **Feste Werte statt Deckkraft.** Weisses Weiss in Prozent ergibt auf
    /// jedem Grund einen anderen Ton, und gerechnet ist der Kontrast dann
    /// nirgends. Die Apple-Fassung hat das verworfen und nennt die beiden
    /// Toene; hier stehen dieselben: #CCCCCC (11,9 : 1 auf `grund`) und
    /// #989898 (6,6 : 1). Beide liegen ueber den geforderten 4,5, auch auf
    /// `erhoeht`.
    static let schriftLeise = "#CCCCCC"
    static let schriftSehrLeise = "#989898"
    static let rand = "rgba(255,255,255,0.12)"
    /// **Der Grund jedes Profilzeichens**, das erste Paar aus
    /// `Farben.profiltoene` — die Reihe beginnt auf der Akzent-Hue und geht
    /// in 45-Grad-Schritten weiter. Linux zeigt bisher nur dieses eine Paar;
    /// wer die Reihe hier nachzieht, nimmt alle acht mit.
    static let profilverlauf = "linear-gradient(135deg, #007A7F, #004A4E)"
    static let linie = "rgba(255,255,255,0.07)"
    /// Der grosse ruhige Block einer Karte — heller als `grund`, dunkler
    /// als ein Knopf (`Farben.gruppenflaeche`, Mac 62b5d194).
    static let gruppenflaeche = "#1E1E1E"
    /// Schrift auf einer gefuellten hellen Flaeche (`Farben.aufAkzent`).
    static let aufAkzent = "#061212"
    /// Der Schwebezustand: weiss 6 % (`Stil.schwebeflaeche` auf dem Mac).
    static let schwebe = "rgba(255,255,255,0.06)"
    /// `akzent` (#50D5DA) als die drei Doubles, die `cairo_set_source_rgba`
    /// erwartet — für eigenes Zeichnen (Ladebalken, Reglerzeichen), wo GTKs
    /// Stilblatt nicht greift.
    static let akzentRGB: (Double, Double, Double) = (0x50 / 255.0, 0xD5 / 255.0, 0xDA / 255.0)
    /// `schrift` (#FFFFFF) in denselben drei Doubles.
    static let weissRGB: (Double, Double, Double) = (1, 1, 1)

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
    /// 6/8/10, und genau daran blieb die Rückmeldung hängen: zwei Punkte
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
    /// Die Karte der Einstellungen — `eckeKarte` 14 auf dem Mac.
    static let eckeKarte = 14
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
    ///
    /// **420 seit dem 22.09.** (Mac cb153e7f/7c6d682f): 360, 460, 520 und 560
    /// waren vier Antworten auf dieselbe Frage; jetzt gilt `formularbreite`
    /// auch fuer Profil, Seerr und jede Spalte der Einstellungen — eine
    /// Liste aus Zeilen ist ein Formular, kein Fliesstext.
    static let formularBreite = 420
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
    /// **Oben so viel Rand wie seitlich** (Mac 8c904f43): `inhaltOben` ist
    /// dort `randAbstand` — derselbe Wert, nicht eine zweite 24. Gemessen
    /// wird hier ab der Unterkante der Titelzeile, denn unter Wayland gehoert
    /// sie dem Fenster; der Abstand zum Inhaltsrand ist damit derselbe wie
    /// seitlich.
    static var inhaltOben: Int { randAbstand }
    /// Die Leiste, die beim Scrollen kommt (`kopfleisteHoehe` auf dem Mac):
    /// sie traegt eine 17er Zeile und den 40 hohen Rueckpfeil.
    static let kopfleisteHoehe = 40
    /// Ueber wie viel Scrollweg die Wertreihe wegblendet (`wertreihenWeg`).
    static let wertreihenWeg = 44.0


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
    /// **13 Medium**, `Stil.kachel` auf dem Mac — 14 steht in keiner Leiter.
    static let kachelTitel = 13
    /// Leistentitel und Hauptknopf: 17 Semifett (`rubrikGross`).
    static let rubrikGross = 17
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
        /* Eine Scheibe faehrt ueber die alte Seite — ohne Grund sah man
           beim Schieben die Seite darunter durch. */
        .swiftly-scheibe { background-color: \(grund); }
        /* **Und der Reiterstapel malt auch nicht mit.** Die Regel eine Zeile
           höher fasst `stack` mit — und der Wechsler zwischen Folgen,
           Besetzung und Ähnliches liegt mitten im ausklingenden Seitenton.
           Eine deckende `grund`-Fläche schneidet ihn dort ab: genau der harte
           Schnitt, den Rückmeldung vom 13.09.2026 auf Serienseiten gemeldet hat.
           Filmseiten haben keinen Stapel im Inhalt — deshalb sahen sie
           richtig aus und Serien nicht. */
        .swiftly-reiterstapel { background-color: transparent; }

        label { color: \(schrift); }
        .dim-label { color: \(schriftLeise); }
        .swiftly-leise { color: \(schriftSehrLeise); }
        .swiftly-warnung { color: \(warnung); }

        /* Die Schriftstufen des Macs, eins zu eins. */
        .swiftly-titel-gross { font-size: \(titelGross)px; font-weight: 700; letter-spacing: -0.6px; }
        /* Fett wie `Stil.titel` auf Apple (`.bold`, also 700), mit derselben
           leichten Sperrung von -0,6. */
        .swiftly-titel       { font-size: \(titel)px; font-weight: \(titelGewicht); letter-spacing: -0.31px; }
        .swiftly-reihe       { font-size: \(reihe)px; font-weight: 600; letter-spacing: -0.24px; }
        .swiftly-listentitel { font-size: \(listentitel)px; font-weight: 600; }
        .swiftly-koerper     { font-size: \(koerper)px; }
        .swiftly-kacheltitel { font-size: \(kachelTitel)px; font-weight: 500; }
        .swiftly-zweitzeile  { font-size: \(zweitzeile)px; }
        /* Seitenleistenrubrik (Mac 984514f2): 11 Semifett in `schriftSehrLeise`,
           **keine Versalien und keine Sperrung** — gesperrt wird nur, was in
           Versalien steht, und die fallen weg. */
        .swiftly-rubrik {
            font-size: \(rubrik)px;
            font-weight: 600;
            color: \(schriftSehrLeise);
        }
        /* **Die Ueberschrift ueber einer Einstellungsgruppe ist eine andere.**
           Der Mac hat fuer diese Rolle einen eigenen Baustein
           (`Sources/macOS/Einstellungszeilen.swift:49-53`): 11 medium, 1,2
           Laufweite, Weiss zu 40 % — waehrend die Seitenleistenrubrik
           (`Macbausteine.swift:70-77`) 11 halbfett, 0,7 und 48 % traegt.
           Linux hatte beides auf **eine** Funktion gelegt und dabei die
           Sidebar-Fassung als einzige Wahrheit genommen. */
        /* **`Gruppentitel` auf dem Mac seit 62b5d194:** 20 Semifett in
           Normalschreibung, `schriftLeise`. Vorher 11 Punkt Versalien in
           weiss 40 % — die Ueberschrift war leiser als das, was sie
           ueberschreibt. */
        .swiftly-gruppenrubrik {
            font-size: \(reihe)px;
            font-weight: 600;
            letter-spacing: -0.24px;
            color: \(schriftLeise);
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
        /* **Der Fokus haengt an der Strichstaerke** (Mac 33be8a7f), nicht an
           einem Akzentrand: `rand` in 2 statt 1. */
        entry:focus, entry:focus-within {
            border: 2px solid \(rand);
            padding: 0 11px;
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
            font-size: \(rubrikGross)px;
            font-weight: 600;
        }
        button.swiftly-haupt:hover { background-color: rgba(255,255,255,0.88); }
        /* Der Mac legt `.opacity(0.4)` über den ganzen Knopf. Dieselbe
           Wirkung, nur ausgerechnet: Weiß zu 40 % über dem Grund. */
        button.swiftly-haupt:disabled {
            background-color: rgba(255,255,255,0.40);
            color: rgba(16,16,16,0.55);
        }

        /* **Die Farbe muss am Kind stehen, nicht nur am Knopf.**
           Oben steht `label { color: … }` — eine Regel auf dem Element
           selbst, und die schlägt jede geerbte Farbe. Der Hauptknopf war
           deshalb weiß auf weiß: der Pfeil (ein `image`, von der Regel nicht
           getroffen) stand da, die Beschriftung nicht. Also trägt jeder
           Knopfzustand seine Farbe ausdrücklich bis ans Kind durch. */
        button.swiftly-haupt label, button.swiftly-haupt image { color: \(aufAkzent); }
        button.swiftly-haupt:disabled label,
        button.swiftly-haupt:disabled image { color: rgba(16,16,16,0.55); }

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
        /* **Kein Farbschein mehr** (Mac 663f1a1b): er war der einzige
           Farbverlauf der App auf einer Seitenflaeche und wich von „Flaechen
           sind flach" ab. Die Startseite beginnt mit ihrem Titel wie jede
           andere Wurzelseite. */
        .swiftly-startschein { padding-top: \(inhaltOben)px; }
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
            background-color: rgba(80,213,218,0.10);
        }
        button.swiftly-zeile.swiftly-aktiv label,
        button.swiftly-zeile.swiftly-aktiv image { color: \(akzent); }

        /* MARK: Chip — 28 hoch, 12 seitlich, vollrund.
           Aktiv weiss mit dunkler Schrift, sonst leise mit Haarlinie. */
        /* **Mac 7202b872/cb153e7f:** 30 hoch, 13 seitlich, Kapsel auf
           `flaeche`, **kein gezeichneter Rand**, ein Gewicht (13 Medium) in
           beiden Zustaenden — Semifett ist breiter und schob die Nachbarn.
           Gewaehlt heisst `erhoeht` plus volle Schrift, nicht weisse Flaeche:
           das waere ein zweiter Hauptknopf. */
        button.swiftly-chip {
            min-height: 30px;
            padding: 0 13px;
            border-radius: \(eckeKapsel)px;
            background-color: \(flaeche);
            border: none;
            font-size: 13px;
            font-weight: 500;
        }
        button.swiftly-chip label,
        button.swiftly-chip image { color: \(schriftLeise); }
        button.swiftly-chip:hover label,
        button.swiftly-chip:hover image { color: \(schrift); }
        button.swiftly-chip:hover { background-color: #333333; }
        button.swiftly-chip:hover label { color: \(schrift); }
        button.swiftly-chip.swiftly-aktiv {
            background-color: \(erhoeht);
        }
        button.swiftly-chip.swiftly-aktiv label { color: \(schrift); }
        /* Das Symbol der Angebotspille (Überspringen/Nächste Folge) ist Teil
           der weissen Fläche, nicht der leisen Grundfarbe — sonst verschwindet
           es fast auf hellem Grund. */
        button.swiftly-chip.swiftly-aktiv image { color: \(schrift); }
        /* Die Angebotspille im Player bleibt, was sie auf dem Mac ist:
           weiss mit dunkler Schrift (`Angebotsknopf`). */
        button.swiftly-chip.swiftly-angebot.swiftly-aktiv { background-color: \(schrift); }
        button.swiftly-chip.swiftly-angebot.swiftly-aktiv label,
        button.swiftly-chip.swiftly-angebot.swiftly-aktiv image { color: \(grund); }
        /* Angebot im Player: Abstand am Inhalt, damit die Countdown-Fuellung
           bis an den Rand reicht — Weiss 16 %, wie `Chip(fuellung:)` am Mac. */
        /* Die Pille selbst, wörtlich der Mac (`Angebotsknopf`): 40 hoch,
           Ecke `eckeFeld`, 15 fett, weiss mit dunkler Schrift. */
        button.swiftly-chip.swiftly-angebot {
            padding: 0;
            min-height: 40px;
            border-radius: \(eckeFeld)px;
        }
        button.swiftly-chip.swiftly-angebot label { font-size: 15px; font-weight: 700; }
        /* Der Countdown als dunkle Füllung, 16 % — wie am Mac
           (`Self.dunkel.opacity(0.16)`): der Akzent gehört im Player allein
           dem Griff der Leiste beim Ziehen. */
        .swiftly-angebotfuellung { background-color: rgba(16,16,16,0.16); }
        /* Dieselbe Blende wie die Steuerung (`.swiftly-steuerung`). */
        .swiftly-angebotblende { transition: opacity 180ms ease-out; }

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
            background-color: rgba(80,213,218,0.10);
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
            background-color: \(gruppenflaeche);
            border-radius: \(eckeKarte)px;
        }
        .swiftly-kontokarte.swiftly-aktiv {
            border: 1.5px solid rgba(80,213,218,0.55);
        }
        .swiftly-kontoname { font-size: \(reihe)px; font-weight: 600; letter-spacing: -0.24px; }
        /* Ein gestrichelter Kreis — ein Platz, der noch frei ist. */
        /* Ein Feld, kein gestrichelter Kreis (Mac 62b5d194). */
        .swiftly-kontoplus {
            background-color: \(flaeche);
            border: none;
            border-radius: \(ecke)px;
            color: \(schriftLeise);
            padding: 0;
            min-width: 40px;
            min-height: 40px;
        }
        .swiftly-kontoplus:hover { background-color: rgba(255,255,255,0.06); }
        /* **Ein Genre-Chip ueber der Startseite.** Eckig, nicht rund: Ecke
           wie ein Knopf, denn rund ist, was ein Bild ist (E26). 34 hoch, 14
           seitlich — die Masse des Macs (`HomeView.swift:274`). */
        /* Woertlich wie Mac und iPhone (33be8a7f): 13 Medium, `flaeche`,
           Ecke 10, **kein Rand**, feste Hoehe 34. */
        button.swiftly-gattungschip {
            min-height: 34px;
            padding: 0 14px;
            border-radius: \(ecke)px;
            background-color: \(flaeche);
            border: none;
            font-size: 13px;
            font-weight: 500;
            color: \(schrift);
        }
        button.swiftly-gattungschip:hover { background-color: #333333; }
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
            background-color: rgba(16,16,16,0.72);
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
            background-color: \(gruppenflaeche);
            border-radius: \(eckeKarte)px;
        }
        .swiftly-trennlinie { background-color: \(linie); min-height: 1px; }
        /* Der Kreis eines Leerzustands: 78 auf `flaeche` (`Leerzustand`). */
        .swiftly-leerkreis { background-color: \(flaeche); border-radius: \(eckeKapsel)px; }
        .swiftly-leerkreis image { color: \(schriftLeise); }
        /* Der stille Knopf: 15 Medium im Akzent, 44 hoch, keine Flaeche. */
        button.swiftly-still {
            background: none; border: none; box-shadow: none;
            min-height: 44px; padding: 0 8px;
        }
        button.swiftly-still label { color: \(akzent); font-size: \(koerper)px; font-weight: 500; }
        button.swiftly-still:hover label { color: #7ADFE3; }
        /* **Die Leiste, die beim Scrollen kommt** (`Bestandsleiste`): Grund
           und Haarlinie erscheinen erst mit dem Scrollweg; ein Dauerverlauf
           steht dort nicht (Mac c584bd70). */
        .swiftly-bestandsgrund {
            background-color: \(grund);
            border-bottom: 1px solid \(linie);
        }

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
            background-color: rgba(16,16,16,0.78);
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
        .swiftly-balkenspur { background-color: rgba(255,255,255,0.30); }
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
        /* Das Mosaik einer Sammlung ohne Bild (Mac `Sammlungsmosaik`): jedes
           Feld auf `flaeche`, die Ecken traegt das Plakat darum. */
        .swiftly-mosaikfeld { background-color: \(flaeche); }

        /* **Der Seitentitel als Menue** (Mac `Titelwahl`): kein Kasten, der
           Winkel leise, unter dem Zeiger und offen weiss. */
        button.swiftly-titelwahl {
            background-image: none; background-color: transparent;
            border: none; box-shadow: none; padding: 0; min-height: 0;
        }
        button.swiftly-titelwahl:hover, button.swiftly-titelwahl:active { background-color: transparent; }
        button.swiftly-titelwahl image { color: \(schriftLeise); transition: color 120ms ease-out; }
        button.swiftly-titelwahl:hover image,
        button.swiftly-titelwahl.swiftly-aktiv image { color: \(schrift); }
        button.swiftly-titelwahl:active { opacity: 0.85; transform: scale(0.97); }
        /* Der Kopf der Reihe „Teil der Sammlung" (Mac `Sammlungsreihe`):
           ein Knopf ohne Kasten, der Winkel sehr leise, unter dem Zeiger weiss. */
        button.swiftly-sammlungskopf {
            background-image: none; background-color: transparent;
            border: none; box-shadow: none; padding: 0; min-height: 0;
        }
        button.swiftly-sammlungskopf:hover { background-color: transparent; }
        button.swiftly-sammlungskopf image { color: \(schriftSehrLeise); transition: color 120ms ease-out; }
        button.swiftly-sammlungskopf:hover image { color: \(schrift); }
        button.swiftly-sammlungskopf:active { opacity: 0.85; transform: scale(0.97); }

        /* Der Blätterpfeil: 34 rund, Grund zu 72 %, Haarlinie darum. */
        /* Der Blaetterpfeil ist ein Feld (Mac cb153e7f): 34 auf `flaeche`,
           Ecke 8, kein Rand. */
        button.swiftly-pfeil {
            min-width: 34px;
            min-height: 34px;
            padding: 0;
            margin: 0 6px;
            border-radius: \(eckeMarke)px;
            background-color: \(flaeche);
            border: none;
        }
        button.swiftly-pfeil { transition: opacity 140ms ease-out; }
        button.swiftly-pfeil image { color: \(schrift); }
        button.swiftly-pfeil:hover { background-color: #333333; }

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
        /* **28 Bold, -0,6** (Mac cd91db75): der Titel ueber einem Heldbild *ist*
           der Seitentitel. Angaben 12 in `schriftLeise`, Beschreibung
           `schriftLeise` statt weiss 62 % — ueber einem Bild aendert Deckkraft
           ihre Wirkung. */
        .swiftly-heldtitel { font-size: \(titelGross)px; font-weight: 700; letter-spacing: -0.6px; }
        .swiftly-angaben { font-size: \(zweitzeile)px; color: \(schriftLeise); }
        .swiftly-beschreibung { color: \(schriftLeise); font-size: \(koerper)px; }
        .swiftly-leistentitel { font-size: \(rubrikGross)px; font-weight: 600; letter-spacing: -0.14px; }
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

        /* Die Bewertung in derselben Marke wie der Beleg (Mac ec0383c8,
           `DetailView.swift` `marke`): `schriftLeise`, Flaeche 15 Prozent. */
        .swiftly-bewertung label, .swiftly-bewertung image { color: \(schriftLeise); }
        .swiftly-belegmarke.swiftly-bewertung { background-color: alpha(\(schriftLeise), 0.15); }

        /* **Die Staffelliste klappt im Seitenfluss auf**, nicht als Blatt —
           `Sources/macOS/SerienView.swift:554-566`. Deshalb `eckeFeld` (12)
           und *kein* Schatten: sie liegt in der Seite, nicht darüber. */
        .swiftly-staffelliste {
            background-color: \(erhoeht);
            border: 1px solid \(rand);
            border-radius: \(eckeFlaeche)px;
            padding: 4px 0;
            transform-origin: top left;
        }
        .swiftly-staffelliste.swiftly-offen {
            animation: swiftly-aufklappen 0.22s cubic-bezier(0.2, 0.9, 0.3, 1.0);
        }
        button.swiftly-staffelzeile {
            min-height: \(zeileHoehe)px;
            padding: 0 12px;
            border-radius: 0;
        }
        button.swiftly-staffelzeile:hover { background-color: rgba(255,255,255,0.06); }
        /* Gewaehlt heisst Weiss (Mac cd91db75) — eine Wahl unter
           Geschwistern ist Rangfolge, und die traegt der Akzent nie. */
        button.swiftly-staffelzeile label { color: \(schriftLeise); }
        button.swiftly-staffelzeile.swiftly-aktiv label,
        button.swiftly-staffelzeile.swiftly-aktiv image { color: \(schrift); }

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

        /* **Eine Flaeche in 15 Prozent, kein Umriss** (`Plakette`,
           Mac 28d314fd): 13 Medium, Ecke 8, 10 × 4 innen — dieselbe Gestalt
           wie der Beleg daneben. */
        .swiftly-plakette {
            font-size: 13px;
            font-weight: 500;
            color: \(schriftLeise);
            background-color: rgba(204,204,204,0.15);
            border: none;
            border-radius: \(eckeMarke)px;
            padding: 4px 10px;
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
        button.swiftly-zurueck image { color: \(schriftLeise); -gtk-icon-size: 20px; }
        /* **Kein Grund, auch nicht beim Schweben.** Auf dem Mac ist es ein
           blanker Winkel mit `.buttonStyle(.plain)` — kein Rahmen, keine
           Fläche. Ein Kasten, der nur unter dem Zeiger erscheint, ist eine
           Zutat, die dort nicht steht. */
        button.swiftly-zurueck:hover { background-color: transparent; }
        button.swiftly-zurueck:hover image { color: \(schrift); }

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
        /* **Der Schein im Ruhezustand ist weg** (Mac 4ee70c46): er hatte auf
           dem iPhone eine Aufgabe, wo das Heldbild bis an beide Kanten reicht.
           Hier steht der Pfeil links auf blankem Grund — was bleibt, ist die
           Leiste, die beim Scrollen kommt. Der Kasten bleibt nur als Mass. */
        .swiftly-kopfverlauf { background: none; }
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
        /* **Aktionsknopf** (Mac cb153e7f): ein quadratisches Feld auf
           `flaeche`, keine weisse Fuellung. Der eine gefuellte Gegenstand der
           Seite bleibt der Hauptknopf; aktiv heisst Akzent am Zeichen. */
        button.swiftly-neben {
            border-radius: \(ecke)px;
            background-color: \(flaeche);
            padding: 0;
            border: none;
        }
        button.swiftly-neben image { color: \(schrift); }
        button.swiftly-neben:hover { background-color: #333333; }
        button.swiftly-neben.swiftly-aktiv { background-color: \(flaeche); }
        button.swiftly-neben.swiftly-aktiv:hover { background-color: #333333; }
        button.swiftly-neben.swiftly-aktiv image { color: \(akzent); }

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
        /* Ein Gewicht (15 Semifett) in beiden Zustaenden, Strich in Weiss
           (Mac cd91db75) — „gewaehlt" ist Rangfolge, die traegt der Akzent
           nie. */
        button.swiftly-reiter label { font-weight: 600; }
        button.swiftly-reiter.swiftly-aktiv label { color: \(schrift); }
        .swiftly-reiterstrich { background-color: transparent; }
        button.swiftly-reiter.swiftly-aktiv .swiftly-reiterstrich {
            background-color: \(schrift);
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
        /* **Die laufende Folge in der Player-Folgenebene** — Weiss zu acht
           Prozent, wörtlich `.background(Color.white.opacity(0.08))` vom Mac
           (`PlayerEbenen.swift:356`). */
        .swiftly-folgenzeile.swiftly-aktiv { background-color: rgba(255,255,255,0.08); }
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

        /* Die Unterzeile: 12 in `schriftSehrLeise` — weiss 45 % lag bei
           3,84 : 1 und steht in BRAND 1 unter den verbotenen Werten. Unter
           dem Zeiger eine Stufe heller (Mac 77af1111). */
        .swiftly-fuss { color: \(schriftSehrLeise); }
        button.swiftly-einstellzeile:hover .swiftly-fuss { color: \(schriftLeise); }
        .swiftly-akzentzeile label { color: \(akzent); }
        /* **Die Rolle, ueber die man kam** — im Akzent, halbfett, wie auf
           Apple (`PersonView.swift:190`). `swiftly-akzentzeile` trifft nur
           Kind-Labels; hier ist das Widget selbst das Label. */
        .swiftly-rolle { color: \(akzent); font-size: 14px; font-weight: 500; }
        .swiftly-akzentzeile image { color: \(akzent); }
        /* **14 + Inhalt + 14** (Mac 8eb1ca13): einzeilig rund 48, mit
           Unterzeile rund 65 — als Innenabstand, damit beide atmen. */
        .swiftly-zeilenrumpf, button.swiftly-einstellzeile {
            min-height: 46px;
            padding: 14px 12px;
            border-radius: 0;
            background-color: transparent;
            border: none;
        }
        /* Erste und letzte Zeile runden mit der Karte ab — sonst stiesse ein
           rechteckiges Schweben ueber die runde Kante. */
        .swiftly-karte > box > :first-child {
            border-top-left-radius: \(eckeKarte)px;
            border-top-right-radius: \(eckeKarte)px;
        }
        .swiftly-karte > box > :last-child {
            border-bottom-left-radius: \(eckeKarte)px;
            border-bottom-right-radius: \(eckeKarte)px;
        }
        button.swiftly-einstellzeile:hover { background-color: \(schwebe); }
        button.swiftly-einstellzeile image { color: \(schriftLeise); }
        button.swiftly-einstellzeile.swiftly-akzentzeile image { color: \(akzent); }

        /* Der Schalter — Kapsel, Akzent wenn an. Kein GtkSwitch: der bringt
           Form, Farbe und Maße des Systems mit (E4). */
        .swiftly-schalter {
            /* Weiss zu 14 % — `Stil.schrift.opacity(0.14)`, die Mac-Zahl aus
               `Sources/macOS/Einstellungszeilen.swift:133`. Die 16 % kamen
               vom iPhone-Blatt, wie auch die Maße. */
            /* Aus: `rand` (weiss 12 %), keine eigene Deckkraft (62b5d194). */
            background-color: \(rand);
            border-radius: \(eckeKapsel)px;
            padding: 3px;
        }
        .swiftly-schalter.swiftly-aktiv { background-color: \(akzent); }
        /* Ein Kreis, kein abgerundetes Rechteck — `Circle()` auf dem Mac. */
        .swiftly-knauf { background-color: \(schrift); border-radius: \(eckeKapsel)px; }
        .swiftly-schalter.swiftly-aktiv .swiftly-knauf { background-color: \(grund); }

        /* `Werteliste` auf dem Mac: 4 oben und unten, 48 eingerueckt, auf
           `flaeche`; Zeilen 32 hoch, 12 seitlich. Gewaehlt heisst Weiss mit
           Haken, nicht Akzent (62b5d194). */
        .swiftly-werteliste { background-color: \(flaeche); padding: 4px 0 4px 48px; }
        button.swiftly-wertzeile {
            min-height: \(zeileHoehe)px;
            padding: 0 12px;
            border-radius: 0;
            background-color: transparent;
            border: none;
        }
        button.swiftly-wertzeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-wertzeile label { color: \(schriftLeise); }
        button.swiftly-wertzeile.swiftly-aktiv label { color: \(schrift); }
        button.swiftly-wertzeile.swiftly-aktiv image { color: \(schrift); }

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
        /* **28 Bold, kein gezeichneter Rahmen** (Mac 62b5d194): der Code
           stand zwei Stufen ueber dem Seitentitel. */
        .swiftly-codegross {
            font-size: \(titelGross)px;
            font-weight: 700;
            letter-spacing: 6px;
            background-color: \(flaeche);
            border: none;
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
            font-size: \(titelGross)px;
            font-weight: 700;
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
            background-color: rgba(80,213,218,0.06);
            border: 1px solid rgba(80,213,218,0.18);
            transition: background-color 120ms ease-out, border-color 120ms ease-out;
        }
        button.swiftly-uebernahme:hover {
            background-color: rgba(80,213,218,0.12);
            border-color: rgba(80,213,218,0.35);
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
        /* **Flache Abdunklung, kein Verlauf** — Schwarz 42 % über dem ganzen
           Bild, wie `Playerschleier` auf iOS und der Mac-Player. Keine
           CSS-Transition: die Blende läuft im Code (`blenden`), mit den
           Mac-Zeiten 0,18 s ein und 0,34 s aus. */
        .swiftly-steuerung { background-color: rgba(0,0,0,0.42); }
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
        /* Der Zeiger hebt das Zeichen an, statt einen Kasten zu malen —
           `scaleEffect(1.06)` am Mac. */
        button.swiftly-spieltaste { transition: transform 150ms ease-out; }
        button.swiftly-spieltaste:hover { transform: scale(1.06); }
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

        /* 11 gibt es nur als Semifett (984514f2). */
        .swiftly-kuerzel {
            font-size: 11px;
            font-weight: 600;
            color: \(schriftSehrLeise);
        }

        /* Titel und Zeiten unten. 19 halbfett, darunter 14 auf 68 %, und
           die Zeiten 13 mit gleich breiten Ziffern — die Masse des Macs. */
        /* 22 halbfett, wie `mass.titel` auf dem Mac (`Playermass.titel`). */
        /* **Dieselbe Leiter wie ueberall** (Mac 984514f2): Titel 20
           Semifett, Angabe 12, Zeit 13. 22 und 14 waren eine zweite
           Schriftleiter nur fuer den Player; Bold steht genau einmal, am
           Seitentitel. */
        .swiftly-spielertitel { font-size: \(reihe)px; font-weight: 600; color: \(schrift); }
        .swiftly-spielerzeile { font-size: \(zweitzeile)px; color: \(schriftLeise); }
        .swiftly-spielerzeit {
            font-size: 13px;
            font-feature-settings: "tnum";
            color: \(schriftLeise);
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
        /* **Der Zeitregler wie am Mac** (`Zeitregler`): 32 hohe
           Trefferfläche, Spur 4 dick (6 beim Ziehen), Grund Weiss 28 %,
           gespielter Teil Weiss. **Kein Griff, solange nicht gezogen wird;**
           beim Ziehen ein Kreis von 18 im Akzent — die einzige Stelle im
           Player, an der er steht.

           Breeze legt Ränder auf `slider` und `trough`; wer eine Mindestgrösse
           überschreibt, muss Rand und Innenabstand mit überschreiben, sonst
           malt es seinen eigenen Regler. Die Spur wird über ihren Rand auf 4
           gehalten, nicht über `min-height` — sie bekäme sonst die volle Höhe. */
        scale.swiftly-regler {
            min-height: 32px;
            padding: 0;
            margin: 0;
        }
        scale.swiftly-regler trough {
            min-height: 4px;
            margin: 14px 0;
            padding: 0;
            border: none;
            background-image: none;
            /* Weiss 18 % wie auf dem iPhone; 28 % steht in BRAND 1 unter den
               gerechnet zu schwachen Werten (984514f2). */
            background-color: rgba(255,255,255,0.18);
            border-radius: 2px;
            box-shadow: none;
        }
        scale.swiftly-regler.swiftly-regler-ziehen trough {
            min-height: 6px;
            margin: 13px 0;
            border-radius: 3px;
        }
        scale.swiftly-regler highlight {
            margin: 0;
            padding: 0;
            border: none;
            background-image: none;
            background-color: \(schrift);
            border-radius: 2px;
            box-shadow: none;
        }
        scale.swiftly-regler slider,
        scale.swiftly-regler:hover slider {
            min-width: 0;
            min-height: 0;
            margin: 0;
            padding: 0;
            border: none;
            background-image: none;
            background-color: transparent;
            box-shadow: none;
            outline: none;
        }
        scale.swiftly-regler.swiftly-regler-ziehen slider {
            min-width: 18px;
            min-height: 18px;
            margin: -6px 0;
            border-radius: 9px;
            background-color: \(akzent);
        }

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
        /* Schrift aus der Leiter (`Stil.klein`, 12) mit gleich breiten
           Ziffern statt Monospace — Mac: `Stil.klein.monospacedDigit()`. */
        .swiftly-technikschild {
            font-size: 12px;
            font-feature-settings: "tnum";
            color: rgba(255,255,255,0.92);
            background-color: rgba(16,16,16,0.82);
            border: 1px solid \(rand);
            border-radius: \(ecke)px;
            padding: 10px 14px;
        }
        /* Die Kopfzeile eine Stufe darüber, halbfett — Mac: `Stil.kachel.weight(.semibold)`. */
        .swiftly-technikschild .swiftly-technikkopf { font-size: \(kachelTitel)px; font-weight: 600; }
        /* Die Haarlinie im Messmodus in `rand` — Mac: `Rectangle().fill(Stil.rand)`. */
        .swiftly-technikschild .swiftly-trennlinie { background-color: \(rand); }
        /* **Die drei Ebenen über dem Bild** (Audio & Untertitel,
           Einstellungen, Folgen) — wörtlich `Sources/macOS/PlayerEbenen.swift`.
           Sie haben die alte Wiedergabetafel (Leiste links, Auswahl rechts)
           ersetzt; deren Klassen (`swiftly-tafel`, `swiftly-spurleiste`,
           `swiftly-spurzeile`) sind mit ihr gegangen. */
        /* 72 % Abdunklung wie auf dem Mac (`Ebenengrund`, rgba(16,16,16,.72)).
           Kein Weichzeichner: GTKs CSS kennt kein `backdrop-filter`. */
        .swiftly-ebenengrund { background-color: rgba(0,0,0,0.78); }
        /* Symbolknöpfe oben rechts, im Player wie auf den Ebenen — 38 × 38,
           durchsichtig, beim Überfahren eine leise weisse Flaeche. Anders als
           `.swiftly-chip`: kein Rahmen, kein Kapselgrund — diese Knöpfe
           stehen nicht in einer Leiste mit Text. */
        button.swiftly-symbolknopf {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
            border-radius: \(eckeFeld)px;
        }
        button.swiftly-symbolknopf image { color: \(schrift); }
        button.swiftly-symbolknopf:hover { background-color: rgba(255,255,255,0.12); }
        /* Spaltentitel einer Ebene — 18 fett, weiss, wörtlich `Wahlspalte`. */
        /* 17 Semifett mit ihrer Sperrung statt 18 Bold (984514f2). */
        .swiftly-spaltentitel { font-size: \(rubrikGross)px; font-weight: 600; letter-spacing: -0.14px; color: \(schrift); }
        /* Eine Zeile einer Ebenenspalte — leise Schrift, gewaehlt weiss
           halbfett (Klasse `swiftly-gewaehlt` am Knopf),
           mit einer leisen Flaeche beim Ueberfahren, die es auf iOS ohne
           Zeiger nicht braucht. */
        button.swiftly-ebenenzeile {
            background: none;
            border: none;
            box-shadow: none;
            min-height: 0;
            padding: 7px 10px;
            border-radius: \(eckeFeld)px;
        }
        button.swiftly-ebenenzeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-ebenenzeile label { font-size: 15px; font-weight: 400; color: \(schriftLeise); }
        /* **Ein Gewicht** — gewaehlt heisst voller Ton, nicht ein zweiter
           Schnitt; der aendert die Breite (984514f2). */
        button.swiftly-ebenenzeile.swiftly-gewaehlt label { color: \(schrift); }
        /* Die Sprungmarke: 108 rund, Schwarz 45 %, „10 s" darunter
           (Mac: `Sprungmarke`). */
        .swiftly-sprungmarke {
            background-color: rgba(0,0,0,0.45);
            border-radius: 54px;
        }
        .swiftly-sprungtext { font-size: 13px; font-weight: 500; color: \(schrift); }
        /* Trickplay-Vorschau über dem Griff — Bild gerundet mit heller Kante,
           wörtlich `vorschauKasten` vom Mac (`PlayerScreen.swift:1292`). */
        .swiftly-vorschaubild {
            border-radius: \(ecke)px;
            border: 1px solid rgba(255,255,255,0.35);
        }
        .swiftly-vorschauzeit {
            font-size: 13px;
            font-weight: 700;
            font-feature-settings: "tnum";
            color: \(schrift);
        }

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
        /* **Ecke 16, kein Schatten** — wie `Handlungsliste` und `Wahlknopf`
           auf dem Mac seit dem 22.09. (cb153e7f): Schatten gibt es nirgends,
           die Tafel trennt sich durch Fläche und die eine Kante in `rand`. */
        popover.swiftly-mehr > contents {
            background-color: \(erhoeht);
            border: 1px solid \(rand);
            border-radius: \(eckeFlaeche)px;
            padding: 4px 0;
            box-shadow: none;
            animation: swiftly-aufklappen 0.22s cubic-bezier(0.2, 0.9, 0.3, 1.0);
        }
        /* **Die Tafel wächst aus ihrem Knopf** (Mac 51c9c8a8,
           `AnyTransition.aufklappen(von:)`): 0,94 und Einblenden, verankert
           an der Ecke, die am Knopf liegt. Sie fliegt nicht von oben herein. */
        popover.swiftly-mehr.swiftly-links > contents { transform-origin: top left; }
        popover.swiftly-mehr.swiftly-rechts > contents { transform-origin: top right; }
        popover.swiftly-mehr.swiftly-mitte > contents { transform-origin: top center; }
        @keyframes swiftly-aufklappen {
            from { opacity: 0; transform: scale(0.94); }
            to   { opacity: 1; transform: none; }
        }
        /* Handlungszeile: 32 hoch (`zeileHoehe`), 12 seitlich, Schweben auf
           `schwebeflaeche` (weiß 6 %), keine eigene Ecke — die Zeile füllt
           die Tafel wie auf dem Mac. */
        button.swiftly-handlung {
            min-height: 32px;
            padding: 0 12px;
            border-radius: 0;
            background-color: transparent;
            border: none;
        }
        button.swiftly-handlung:hover,
        button.swiftly-handlung:focus-visible { background-color: rgba(255,255,255,0.06); }
        button.swiftly-handlung image { color: \(schrift); }
        /* Eine Zeile in der Tafel eines Wahlknopfs (`Wahltafelzeile`):
           gewaehlt heisst Weiss mit Haken, sonst `schriftLeise`. */
        button.swiftly-wahlzeile label { color: \(schriftLeise); }
        button.swiftly-wahlzeile.swiftly-aktiv label,
        button.swiftly-wahlzeile.swiftly-aktiv image { color: \(schrift); }
        /* Gemalte Zeichen im Chip nehmen die Farbe des Stilblatts. */
        button.swiftly-chip .swiftly-malzeichen { color: \(schriftLeise); }
        button.swiftly-chip:hover .swiftly-malzeichen,
        button.swiftly-chip.swiftly-aktiv .swiftly-malzeichen { color: \(schrift); }
        .swiftly-leerkreis .swiftly-malzeichen { color: \(schriftLeise); }
        /* **Die Ladeauswahl** (`MacLadeauswahl`): Karten auf `flaeche` mit
           Ecke 14, der runde Kasten 22 — leer mit Ring in `schriftSehrLeise`,
           teilweise und voll im Akzent mit dunklem Zeichen. */
        .swiftly-auswahlkarte { background-color: \(flaeche); border-radius: \(eckeKarte)px; }
        button.swiftly-kasten {
            background: none; box-shadow: none; padding: 0;
            min-width: 22px; min-height: 22px;
            border: 1.6px solid \(schriftSehrLeise);
            border-radius: \(eckeKapsel)px;
        }
        button.swiftly-kasten.swiftly-aktiv { background-color: \(akzent); border-color: \(akzent); }
        button.swiftly-kasten.swiftly-aktiv image { color: \(aufAkzent); }
        button.swiftly-auswahlzeile {
            background: none; border: none; box-shadow: none; padding: 0; min-height: 0;
        }
        /* [Download-Übernahme, Mac cc4e6e75] **Die Downloadzeile dunkelt ab**
           (`Abdunkeln`): ohne graue Fläche, der Inhalt geht beim Druck auf
           60 % — sofort hinein, in 0,12 s heraus. Eigene Klasse, damit
           `swiftly-zeile` der Seitenleiste bleibt, wie sie ist. Die Marke
           der Tastatur bleibt als `schwebeflaeche`; im Bearbeiten trägt der
           Zeiger `flaeche`, wie auf dem Mac. */
        button.swiftly-dlzeile, button.swiftly-dlzeile:hover,
        button.swiftly-dlzeile:active, button.swiftly-dlzeile:checked {
            background-image: none; background-color: transparent;
            border: none; box-shadow: none; outline: none;
            padding: 0; min-height: 0; min-width: 0;
            border-radius: \(eckeFeld)px;
            color: \(schrift); font-size: \(koerper)px; font-weight: 500;
        }
        button.swiftly-dlzeile > * { opacity: 1; transition: opacity 120ms ease-out; }
        button.swiftly-dlzeile:active > * { opacity: 0.6; transition: none; }
        button.swiftly-dlzeile:focus-visible { background-color: rgba(255,255,255,0.06); }
        button.swiftly-dlzeile.swiftly-bearbeiten:hover { background-color: \(flaeche); }

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
