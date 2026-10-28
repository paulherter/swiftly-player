import CGtk
import CFonts
import Foundation
import JellyfinKit

/// **Swiftly's look, translated into GTK terms.**
///
/// The numbers and colors here are not new decisions. They come from
/// `Sources/Shared/Colors.swift` and `Sources/macOS/Style.swift` and apply on
/// iPhone, iPad, Apple TV and Mac. To change one, change it there and copy it
/// here; a second palette would make the platforms drift apart.
///
/// **The Mac is the reference, not a guess.** Estimated values here were once wrong
/// in two places: the field surface was `erhoeht` (#1E1E22) instead of `area`
/// (#161619), and the primary button used the accent although on the Mac it is
/// **white with dark text**. Both were in `MacComponents.swift` all along; read the
/// source instead of guessing.
///
/// **Why plain GTK4 and not libadwaita.** libadwaita is GNOME's design library and
/// makes an app look like a GNOME app. That works against the goal: Swiftly should
/// look like Swiftly on every system, not like the system. Also, libadwaita is
/// barely supported on Windows, which is a target. Everything below is therefore
/// plain GTK4 with its own stylesheet.
enum Theme {

    // MARK: Colors, copied verbatim from Colors.swift

    // **Neutral, not tinted**, same change as on Apple.
    //
    // The old ladder was #0B0B0D, #161619, #1E1E22. It had a blue cast because the
    // neutrals sat on the accent hue. `Sources/Shared/Colors.swift` now has an exactly
    // neutral ladder (R = G = B), and this file copies it.
    static let reason = "#101010"
    /// The surface of a field and of the sidebar. **Not `erhoeht`.**
    static let area = "#262626"
    static let raised = "#303030"
    /// **The four values a look changes** (accent, play mark, warning, text on accent) are
    /// variables: ``wear(_:)`` sets them from the look's palette and reloads the stylesheet.
    /// Everything that draws reads them when it draws, so a rebuilt page picks them up.
    nonisolated(unsafe) static var accent = "#50D5DA"
    /// Brand and UI share the same tone now; the old brand turquoise is gone.
    nonisolated(unsafe) static var markAccent = MarksPaths.accentHex     // #50D5DA
    nonisolated(unsafe) static var warning = "#E8833A"
    static let font = "#FFFFFF"
    /// **Fixed values instead of opacity.** White at a percentage gives a different tone
    /// on every background, so the contrast is never actually computed. The Apple version
    /// dropped that and names the two tones; the same are used here: #CCCCCC (11.9 : 1 on
    /// `reason`) and #989898 (6.6 : 1). Both are above the required 4.5, also on `erhoeht`.
    static let fontQuiet = "#CCCCCC"
    static let fontVeryQuiet = "#989898"
    static let margin = "rgba(255,255,255,0.12)"
    /// The corner of the handover card in whole steps 0...12 (``Uebergabelauf``).
    static let handoffCorners = (0...12)
        .map { ".swiftly-uebergabeecke-\($0) { border-radius: \($0)px; }" }
        .joined(separator: "\n")
    /// **The background of each profile symbol**, the first pair from `Farben.profileAudio`.
    /// The row starts at the accent hue and continues in 45-degree steps. Linux so far shows
    /// only this one pair; whoever adds the rest here takes all eight.
    static let profileHistory = "linear-gradient(135deg, #007A7F, #004A4E)"
    static let line = "rgba(255,255,255,0.07)"
    /// The large calm block of a card: lighter than `reason`, darker than a button
    /// (`Farben.groupsArea`).
    static let groupsArea = "#1E1E1E"
    /// Text on a filled light surface (`Farben.aufAkzent`).
    nonisolated(unsafe) static var onAccent = "#061212"
    /// The hover state: white at 6 % (`Theme.schwebeflaeche` on the Mac).
    static let hover = "rgba(255,255,255,0.06)"
    /// `accent` (#50D5DA) as the three doubles `cairo_set_source_rgba` expects, for custom
    /// drawing (progress bar, slider symbol) where GTK's stylesheet does not apply.
    nonisolated(unsafe) static var accentRGB: (Double, Double, Double) = (0x50 / 255.0, 0xD5 / 255.0, 0xDA / 255.0)
    /// `font` (#FFFFFF) as the same three doubles.
    static let whiteRGB: (Double, Double, Double) = (1, 1, 1)

    // MARK: Dimensions, copied verbatim from macOS/Style.swift

    /// **The corner scale.** The larger the surface, the rounder.
    ///
    /// | What | Corner |
    /// |---|---|
    /// | Button, poster, tile | 10 |
    /// | Field, input | 12 |
    /// | Surface, sheet, panel | 16 |
    /// | Chip, notice | Capsule |
    ///
    /// **Rounded up by four points.** It used to be 6/8/10, and that was the problem: a
    /// two-point difference between two neighboring things reads as a mistake, not as a
    /// ranking.
    ///
    /// The GTK version lagged behind with the old values while the heading claimed
    /// "verbatim from macOS/Style.swift". A number changed elsewhere does not follow by
    /// itself, hence the rule number here.
    static let corner = 10
    /// Posters and tiles use **the same** corner as a button. Both are small objects;
    /// the ranking only starts above them.
    static let cornerTile = 10
    /// Search and input fields.
    static let cornerField = 12
    /// What counts as its own surface: sheets, the panel, info boxes.
    static let cornerArea = 16
    /// The settings card (`cornerCard` is 14 on the Mac).
    static let cornerCard = 14
    /// Release and Seerr badges. **8, not 3**: 3 is only the default of `Badge` on Apple,
    /// which no caller uses; the detail page, hero header and tvOS all set 8 explicitly.
    static let cornerMark = 8
    /// Chip and notice are **capsules**. Far above half the edge so the shape stays
    /// round if the dimension changes later; a fixed number would silently be wrong again.
    static let cornerCapsule = 999
    /// **The "Continue watching" badge**: height and distance from every edge it touches
    /// (left, right, bottom). Mac `Theme.abzeichenRand`.
    static let badgeHeight = 40
    static let badgeEdge: Int32 = 12
    // MARK: Page slide

    /// How long a page slides in: `Theme.timePagesPush` from the Mac, `easeInOut` over 0.45 s.
    static let timePagesPush = 0.45
    /// How long a section change cross-fades. The same duration `GtkStack` uses for its
    /// cross-fade (200 ms), otherwise the two ways into the same section would look different.
    /// **A page change does not cross-fade**: first the old page leaves (short, `easeIn`),
    /// then the new one arrives (`easeOut`), never both at once. A cross-fade used to leave
    /// two half pages on top of each other. The numbers now apply to Mac, Linux and Windows
    /// and live in the package (`FadeTimes`). Opacity only, no scaling, no blur.
    static let timeFadeToOut = FadeTimes.pageToOut
    static let timeFadeFromIn = FadeTimes.pageFromIn
    /// What replaces every fade with reduced motion: 0.14 s linear, like
    /// `Theme.linearReduced` on the Mac (`Sources/macOS/Style.swift`).
    static let timeReduced = 0.14
    /// The tab stack's cross-fade: there is only **one** duration because `GtkStack` does
    /// not support two.
    static let timeFade = 0.2
    /// The "Direct Play" badge fades in at the end of the info row: opacity only, 0.2 s.
    /// It moves nothing, so it needs no curve.
    static let timeProof = 0.2
    /// **The hover state**: 0.12 s `easeOut`, Mac `Theme.zeitSchweben`. One value for every
    /// place where the pointer shows or changes something: in the stylesheet as ``float``,
    /// in code via ``blenden``.
    static let timeFloat = 0.12
    static let float = "\(Int(timeFloat * 1000))ms ease-out"
    /// How far the page **underneath** moves along. A little under a third, as in system
    /// navigation; that gives the impression of layers instead of one rectangle sliding by.
    static let pushWithGift = 0.3
    /// The scrim over the page underneath. On the Mac it is black at 28 %; over our dark
    /// background the same result comes from fading the layer to 72 % opacity, which is one
    /// step in the render tree instead of another surface.
    static let pushScrim = 0.28

    static let edgeSpacing = 24
    static let tileSpacing = 12
    static let railsSpacing = 28

    /// Smallest window size at which the grid still works: sidebar plus two tile columns
    /// plus margins. From the Mac.
    static let windowMinWidth = 900
    static let windowMinHeight = 560

    static let sidebarWidth = 220
    /// A pointer is more precise than a finger: sidebar rows are 32 high, not 44 as on a phone.
    static let rowHeight = 32
    static let primaryButtonHeight = 48
    /// **Fixed width of the primary button.** Otherwise the rest of the row follows the
    /// label length, and Watchlist and More sit in a different place on every page.
    /// 200 fits "Fortsetzen" as well as "Abspielen".
    static let primaryButtonWidth = 200
    /// The detail page's header zone: 150 on top plus a 230 block, no slack.
    static let heroHeightValue = 380
    /// **The person page's header zone**, the same calculation as on the Mac
    /// (`Sources/macOS/PersonView.swift`): the same lead-in on top as on a detail page,
    /// then the 88-point block and its bottom gap of 22. It is shorter than a detail page's
    /// (230 block) because it holds a 104 head and two rows.
    static let personHeight = titleHeight + 98 + personBlockHeight + 22
    /// As tall as the round head, and so as tall as the whole block; the text next to it
    /// is shorter (`PersonView.swift`).
    static let personBlockHeight = 88
    /// Height of a detail page's header bar (arrow and fading-in title).
    static let titleHeight = 52
    static let fieldHeight = 38
    /// Width of the sign-in block. On the Mac `.frame(width: 360)` sits on each of the two fields.
    static let loginWidth = 360
    /// **How wide a subpage gets.** Profile, playback and Quick Connect read like text:
    /// 700, the Mac's `readWidth`. Settings hold two columns side by side and may be
    /// wider (`Theme.settingWidth` = 1366 on the Mac).
    static let readWidth = 700
    /// **How wide a form is**: server entry, additional account, Quick Connect. The Mac caps
    /// all three at 460 (`Sources/macOS/ServerOnboardingView.swift`, `Sources/macOS/ProfileView.swift`).
    /// Here they used the same `readWidth` as running text, with a 360-point centered field
    /// floating in it.
    ///
    /// **420.** 360, 460, 520 and 560 were four answers to the same question; now
    /// `formWidth` applies to profile, Seerr and every settings column too. A list of
    /// rows is a form, not running text.
    static let formWidth = 420
    /// **1366, as in `Sources/macOS/Style.swift`.** This used to be 1100 for no reason, and
    /// the number was never used because GTK has no maximum size. The cap is now set by
    /// `Einstellungsseiten.cap(_:in:on:)`.
    static let settingWidth = 1366
    /// Top margin in the content area: 52 on the Mac, **measured from the window's top edge**.
    /// There is no title bar there; the traffic lights float above the sidebar.
    ///
    /// Under Wayland the title bar belongs to the window and its height is added on top.
    /// That caused "far too much space above Continue Watching": 19 plus 52 instead of 52.
    /// With it subtracted, the distance to the window edge matches the Mac again.
    static let headerRowHeight = 24
    /// **The same top margin as the side margin**: `contentTop` is `edgeSpacing` on the Mac,
    /// the same value, not a second 24. It is measured from the bottom edge of the title bar,
    /// since under Wayland that belongs to the window, so the distance to the content edge
    /// equals the side distance.
    static var contentTop: Int { edgeSpacing }
    /// The bar that appears on scrolling (`headerBarHeight` on the Mac): it holds a 17-point
    /// row and the 40-high back arrow.
    static let headerBarHeight = 40
    /// Over how much scroll distance the value row fades out (`valueRailsDistance`).
    static let valueRailsDistance = 44.0


    /// Poster, 2 : 3: 112 x 168 on iPhone, 150 x 225 on the Mac.
    static let tileWidth = 150
    static let tileHeight = 225
    /// Continue Watching is landscape, 16 : 9.
    static let landscapeWidth = 280
    static let landscapeHeight = 158

    // MARK: Type sizes, same scale as iPhone and Mac

    static let titleLarge = 28
    /// **22, not 27.**
    ///
    /// 27 is the **iPhone** size from `Sources/Shared/Style.swift`. There are two constants
    /// with the same name; the one for this version is in `Sources/macOS/Style.swift`, which
    /// has always been `22, semibold`. It was visible on the server row at sign-in: 22
    /// semibold on the Mac, 27 bold here.
    static let title = 22
    static let titleWeight = 600
    static let rail = 20
    static let listTitle = 15
    static let body = 15
    /// **13 medium**, `Theme.tile` on the Mac. 14 is on no scale.
    static let tileTitleText = 13
    /// Bar titles and primary button: 17 semibold (`categoryLarge`).
    static let categoryLarge = 17
    static let secondLine = 12
    static let category = 11

    // MARK: Stylesheet

    /// Loaded once at startup and applies to the whole program.
    ///
    /// GTK stylesheets know the same concepts as the web (color, radius, spacing); selection
    /// is by widget name instead of by brand. `.swiftly-*` are our own classes; anything
    /// without a dot is a GTK type.
    static var sheet: String {
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

        /* **Unter dem Zeiger blendet alles, nichts springt** (`zeitSchweben`).
           Einmal hier fuer jeden Knopf und was in ihm steht — Reiter der
           Seitenleiste, Chips, Neben- und Aktionsknoepfe, Kacheln. Eine Regel
           weiter unten mit eigenem `transition` gilt vor dieser. */
        button, button > *, button image, button label {
            transition: background-color \(float), color \(float),
                        border-color \(float), box-shadow \(float),
                        opacity \(float), transform \(float);
        }

        window, .background, stack {
            background-color: \(reason);
            color: \(font);
        }
        /* **Scrollflächen malen nicht mit.** Sie standen hier mit `reason` —
           und auf einer eingefärbten Detailseite ist das eine schwarze Ebene
           hinter jeder Reihe. Sie stand unter „Besetzung". Was
           einen Grund braucht, sagt es selbst; alles andere lässt das
           Fenster durchscheinen. */
        scrolledwindow, viewport { background-color: transparent; }
        /* Eine Scheibe faehrt ueber die alte Seite — ohne Grund sah man
           beim Schieben die Seite darunter durch. */
        .swiftly-scheibe { background-color: \(reason); }
        /* **Und der Reiterstapel malt auch nicht mit.** Die Regel eine Zeile
           höher fasst `stack` mit — und der Wechsler zwischen Folgen,
           Besetzung und Ähnliches liegt mitten im ausklingenden Seitenton.
           Eine deckende `reason`-Fläche schneidet ihn dort ab: genau der harte
           Schnitt, den Rückmeldung vom 13.09.2026 auf Serienseiten gemeldet hat.
           Filmseiten haben keinen Stapel im Inhalt — deshalb sahen sie
           richtig aus und Serien nicht. */
        .swiftly-reiterstapel { background-color: transparent; }

        label { color: \(font); }
        .dim-label { color: \(fontQuiet); }
        .swiftly-leise { color: \(fontVeryQuiet); }
        .swiftly-warnung { color: \(warning); }

        /* Die Schriftstufen des Macs, eins zu eins. */
        .swiftly-titel-gross { font-size: \(titleLarge)px; font-weight: 700; letter-spacing: -0.6px; }
        /* Fett wie `Theme.title` auf Apple (`.bold`, also 700), mit derselben
           leichten Sperrung von -0,6. */
        .swiftly-titel       { font-size: \(title)px; font-weight: \(titleWeight); letter-spacing: -0.31px; }
        .swiftly-reihe       { font-size: \(rail)px; font-weight: 600; letter-spacing: -0.24px; }
        .swiftly-listentitel { font-size: \(listTitle)px; font-weight: 600; }
        /* Der Discord-Hinweis (Mac `Discordhinweis`): erhoeht, Haarlinie,
           Ecke der Flaeche, 16 innen. Kein Schatten — nirgends (BRAND 4). */
        .swiftly-discordkarte {
            background-color: \(raised);
            border: 1px solid \(margin);
            border-radius: \(cornerArea)px;
            padding: 16px;
        }
        .swiftly-koerper     { font-size: \(body)px; }
        .swiftly-kacheltitel { font-size: \(tileTitleText)px; font-weight: 500; }
        /* Ziffern gleich breit (iOS `Tile`: `.monospacedDigit()`), damit „noch
           12 Min." beim Nachladen nicht springt. */
        .swiftly-zweitzeile  { font-size: \(secondLine)px; font-feature-settings: "tnum"; }
        /* Seitenleistenrubrik (Mac 984514f2): 11 Semifett in `schriftSehrLeise`,
           **keine Versalien und keine Sperrung** — gesperrt wird nur, was in
           Versalien steht, und die fallen weg. */
        .swiftly-rubrik {
            font-size: \(category)px;
            font-weight: 600;
            color: \(fontVeryQuiet);
        }
        /* **Die Ueberschrift ueber einer Einstellungsgruppe ist eine andere.**
           Der Mac hat fuer diese Rolle einen eigenen Baustein
           (`Sources/macOS/SettingRows.swift:49-53`): 11 medium, 1,2
           Laufweite, Weiss zu 40 % — waehrend die Seitenleistenrubrik
           (`MacComponents.swift:70-77`) 11 halbfett, 0,7 und 48 % traegt.
           Linux hatte beides auf **eine** Funktion gelegt und dabei die
           Sidebar-Fassung als einzige Wahrheit genommen. */
        /* **`Gruppentitel` auf dem Mac seit 62b5d194:** 20 Semifett in
           Normalschreibung, `schriftLeise`. Vorher 11 Punkt Versalien in
           weiss 40 % — die Ueberschrift war leiser als das, was sie
           ueberschreibt. */
        .swiftly-gruppenrubrik {
            font-size: \(rail)px;
            font-weight: 600;
            letter-spacing: -0.24px;
            color: \(fontQuiet);
        }

        /* MARK: Eingabefeld
           Auf dem Mac ein eigener Baustein statt des Systemfeldes: die Fläche
           ist `area`, der Rahmen eine Haarlinie in Weiß 12 %, die Ecke 12
           (`eckeFeld` — Felder sind runder als Knöpfe, E11).
           Im Fokus wird der Rahmen zum Akzent bei halber Deckung. */
        entry {
            background-color: \(area);
            background-image: none;
            color: \(font);
            border: 1px solid \(margin);
            border-radius: \(cornerField)px;
            min-height: \(fieldHeight)px;
            padding: 0 12px;
            font-size: \(body)px;
            caret-color: \(accent);
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
            border: 2px solid \(margin);
            padding: 0 11px;
            outline: none;
            box-shadow: none;
        }
        entry placeholder, entry text placeholder { color: \(fontVeryQuiet); }
        /* Das Symbol im Feld: 17 breit, dahinter 9 Luft — die Zahlen der
           `Eingabezeile` auf dem Mac. */
        entry image { color: \(fontVeryQuiet); min-width: 17px; margin-right: 9px; }

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
        button.swiftly-reiter, button.swiftly-reihenkopf,
        button.swiftly-einstellzeile, button.swiftly-wertzeile,
        button.swiftly-handlung, button.swiftly-spielrund,
        button.swiftly-spielrund-gross {
            background-image: none;
            background-color: transparent;
            border: none;
            box-shadow: none;
            color: \(font);
            border-radius: \(corner)px;
            padding: 0;
            min-height: 0;
            min-width: 0;
        }
        button.swiftly-haupt {
            background-color: \(font);
            color: \(reason);
            border-radius: \(corner)px;
            min-height: \(primaryButtonHeight)px;
            padding: 0 30px;
            font-size: \(categoryLarge)px;
            font-weight: 600;
        }
        button.swiftly-reihenkopf:hover label { color: \(fontQuiet); }
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
        button.swiftly-haupt label, button.swiftly-haupt image { color: \(onAccent); }
        button.swiftly-haupt:disabled label,
        button.swiftly-haupt:disabled image { color: rgba(16,16,16,0.55); }

        button.swiftly-flach {
            background-color: transparent;
            color: \(fontQuiet);
            font-size: \(body)px;
            min-height: \(rowHeight)px;
            padding: 0 10px;
        }
        button.swiftly-flach label { color: \(fontQuiet); }
        button.swiftly-flach:hover {
            background-color: rgba(255,255,255,0.06);
        }
        button.swiftly-flach:hover label { color: \(font); }

        /* MARK: Seitenleiste
           Fläche wie das Feld, Zeilen 32 hoch. Der Akzent trägt die Auswahl —
           dieselbe Regel wie auf iOS. Der Schwebezustand bekommt bewusst nur
           Weiß: er zeigt „hier steht der Zeiger", keine Wahl. */
        /* **Kein Farbschein mehr** (Mac 663f1a1b): er war der einzige
           Farbverlauf der App auf einer Seitenflaeche und wich von „Flaechen
           sind flach" ab. Die Startseite beginnt mit ihrem Titel wie jede
           andere Wurzelseite. */
        .swiftly-startschein { padding-top: \(contentTop)px; }
        .swiftly-seitenleiste { background-color: \(area); }

        button.swiftly-zeile {
            min-height: \(rowHeight)px;
            padding: 0 10px;
            border-radius: \(corner)px;
            font-size: \(body)px;
            font-weight: 500;
        }
        button.swiftly-zeile label, button.swiftly-zeile image {
            color: \(fontQuiet);
        }
        button.swiftly-zeile image { min-width: 17px; }
        button.swiftly-zeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-zeile:hover label,
        button.swiftly-zeile:hover image { color: \(font); }
        button.swiftly-zeile.swiftly-aktiv {
            background-color: \(accentAlpha(0.10));
        }
        button.swiftly-zeile.swiftly-aktiv label,
        button.swiftly-zeile.swiftly-aktiv image { color: \(accent); }

        /* MARK: Chip — 28 hoch, 12 seitlich, vollrund.
           Aktiv weiss mit dunkler Schrift, sonst leise mit Haarlinie. */
        /* **Mac 7202b872/cb153e7f:** 30 hoch, 13 seitlich, Kapsel auf
           `area`, **kein gezeichneter Rand**, ein Gewicht (13 Medium) in
           beiden Zustaenden — Semifett ist breiter und schob die Nachbarn.
           Gewaehlt heisst `erhoeht` plus volle Schrift, nicht weisse Flaeche:
           das waere ein zweiter Hauptknopf. */
        button.swiftly-chip {
            min-height: 30px;
            padding: 0 13px;
            border-radius: \(cornerCapsule)px;
            background-color: \(area);
            border: none;
            font-size: 13px;
            font-weight: 500;
        }
        button.swiftly-chip label,
        button.swiftly-chip image { color: \(fontQuiet); }
        button.swiftly-chip:hover label,
        button.swiftly-chip:hover image { color: \(font); }
        button.swiftly-chip:hover { background-color: #333333; }
        button.swiftly-chip:hover label { color: \(font); }
        button.swiftly-chip.swiftly-aktiv {
            background-color: \(raised);
        }
        button.swiftly-chip.swiftly-aktiv label { color: \(font); }
        /* Das Symbol der Angebotspille (Überspringen/Nächste Folge) ist Teil
           der weissen Fläche, nicht der leisen Grundfarbe — sonst verschwindet
           es fast auf hellem Grund. */
        button.swiftly-chip.swiftly-aktiv image { color: \(font); }
        /* Die Angebotspille im Player bleibt, was sie auf dem Mac ist:
           weiss mit dunkler Schrift (`Angebotsknopf`). */
        button.swiftly-chip.swiftly-angebot.swiftly-aktiv { background-color: \(font); }
        button.swiftly-chip.swiftly-angebot.swiftly-aktiv label,
        button.swiftly-chip.swiftly-angebot.swiftly-aktiv image { color: \(reason); }
        /* Angebot im Player: Abstand am Inhalt, damit die Countdown-Fuellung
           bis an den Rand reicht — Weiss 16 %, wie `Chip(fuellung:)` am Mac. */
        /* Die Pille selbst, wörtlich der Mac (`Angebotsknopf`): 40 hoch,
           Ecke `eckeFeld`, 15 fett, weiss mit dunkler Schrift. */
        button.swiftly-chip.swiftly-angebot {
            padding: 0;
            min-height: 40px;
            border-radius: \(cornerField)px;
        }
        button.swiftly-chip.swiftly-angebot label { font-size: 15px; font-weight: 700; }
        /* Der Countdown als dunkle Füllung, 16 % — wie am Mac
           (`Self.dunkel.opacity(0.16)`): der Akzent gehört im Player allein
           dem Griff der Leiste beim Ziehen. */
        .swiftly-angebotfuellung { background-color: rgba(16,16,16,0.16); }
        /* Dieselbe Blende wie die Steuerung (`.swiftly-steuerung`). */
        .swiftly-angebotblende { transition: opacity 180ms ease-out; }

        /* **Die Karte der nächsten Folge** (Variante C, iOS
           `EpisodeCardsView`, Maße `EpisodeCard.iPhone`): herein von
           rechts um 40 aus 94 %, hinaus schneller. Die Kurve ersetzt die
           kritisch gedämpfte Feder ω 9 (≈ 0,5 s bis zur Ruhe). */
        .swiftly-folgenkarte {
            transition: opacity 260ms ease-out,
                        transform 480ms cubic-bezier(0.2, 0.9, 0.3, 1);
        }
        .swiftly-folgenkarte.swiftly-folgenkarte-weg {
            opacity: 0;
            transform: translateX(40px) scale(0.94);
            transition: opacity 200ms ease-in,
                        transform 320ms cubic-bezier(0.4, 0, 0.6, 1);
        }
        button.swiftly-kartenbild {
            padding: 0;
            border: none;
            min-width: 0;
            min-height: 0;
            border-radius: 12px;
            background-color: #000000;
            background-image: none;
            box-shadow: 0 14px 34px rgba(0,0,0,0.6);
            transition: transform 150ms ease-out;
        }
        button.swiftly-kartenbild:hover { transform: scale(1.02); }
        button.swiftly-kartenbild:active { transform: scale(0.97); }
        /* Das runde X: 24 rund auf `area` 85 %, 6 von der Ecke. */
        button.swiftly-kartenzu {
            min-width: 24px;
            min-height: 24px;
            padding: 0;
            margin: 6px;
            border: none;
            border-radius: \(cornerCapsule)px;
            background-color: rgba(38,38,38,0.85);
            background-image: none;
            box-shadow: none;
        }
        button.swiftly-kartenzu:hover { background-color: rgba(64,64,64,0.92); }
        .swiftly-kartenklein { font-size: 12px; font-weight: 600; color: \(fontVeryQuiet); }
        .swiftly-kartentitel { font-size: 17px; font-weight: 600; color: \(font); }
        .swiftly-tnum { font-feature-settings: "tnum"; }
        /* Unter der Karte: abgedunkelt wie die offene Steuerung (0,42) — bei
           offener Steuerung nicht doppelt —, dazu der Verlauf unten rechts
           (`Kartenschleier`: Schwarz 78 % bis 0 bei 70 %). */
        .swiftly-kartenschleier {
            background-color: rgba(0,0,0,0.42);
            transition: background-color 180ms ease-out;
        }
        .swiftly-kartenschleier.swiftly-kartenschleier-hell { background-color: transparent; }
        .swiftly-kartenverlauf {
            background-image: radial-gradient(ellipse farthest-corner at 88% 92%,
                rgba(0,0,0,0.78) 0%, rgba(0,0,0,0) 70%);
        }

        button.swiftly-profil {
            min-height: 40px;
            padding: 0 10px;
            border-radius: \(corner)px;
        }
        button.swiftly-profil:hover { background-color: rgba(255,255,255,0.06); }
        /* **Dieselbe Auswahl-Optik wie eine Bereichszeile** (E2: der Akzent
           traegt Auswahl). Der Mac faerbt bei offener Unterseite Name und
           Flaeche der Kontozeile im Akzent
           (`Sources/macOS/MainView.swift:892,903`); hier leuchtete dann gar
           keine Zeile mehr, weil `bereichszeilenMalen` allen die
           Hervorhebung nimmt und keine sie bekam. */
        button.swiftly-profil.swiftly-aktiv {
            background-color: \(accentAlpha(0.10));
        }
        button.swiftly-profil.swiftly-aktiv label { color: \(accent); }

        /* **Ein Ladefeld in der Form des kommenden Inhalts** (E17). Der
           Ladering kommt in der Oberfläche nicht vor — er sagt „warte" und
           sonst nichts: nicht was kommt, nicht wie viel. Hier stand an
           mehreren Stellen ein „Lade …" als Fließtext; das ist eine dritte
           Form, die E17 auch nicht vorsieht.

           `Theme.area`, pulsierend zwischen halber und voller Deckung über
           0,9 s — dieselben Werte wie `Ladefeld` auf Apple
           (`Sources/Shared/Style.swift:3302`). */
        @keyframes swiftly-pulsen {
            0%   { opacity: 0.5; }
            50%  { opacity: 1.0; }
            100% { opacity: 0.5; }
        }
        .swiftly-ladefeld {
            background-color: \(area);
            border-radius: \(cornerTile)px;
            animation: swiftly-pulsen 1.8s ease-in-out infinite;
        }
        .swiftly-ladefeld.swiftly-schmal { border-radius: 3px; }
        /* **Eine Rubrik über einer Liste sagt auch, wie viel** (E27). Sie
           beantwortet „bin ich hier durch?"; ohne sie scrollt man ins
           Ungewisse. 13 halbfett in `schriftSehrLeise`, wie `Zaehlmarke` auf
           Apple (`Style.swift:2682`) — hier stand Körpergröße in `quiet`,
           also zwei Stufen zu laut. */
        .swiftly-zaehlmarke {
            font-size: 13px;
            font-weight: 500;
            color: \(fontVeryQuiet);
        }
        /* **Eine Karte je Server** (`macOS/ProfileView.swift:490`). Hier stand
           bis zum 13.09.2026 ein Streifen aus Kreisen — die Fassung, die der
           Mac am 11.09.2026 ersetzt hat. Der Akzentrand markiert den
           verbundenen Server, aber nur wenn es mehr als einen gibt (D10). */
        .swiftly-kontokarte {
            background-color: \(groupsArea);
            border-radius: \(cornerCard)px;
        }
        .swiftly-kontokarte.swiftly-aktiv {
            border: 1.5px solid \(accentAlpha(0.55));
        }
        .swiftly-kontoname { font-size: \(rail)px; font-weight: 600; letter-spacing: -0.24px; }
        /* Ein gestrichelter Kreis — ein Platz, der noch frei ist. */
        /* Ein Feld, kein gestrichelter Kreis (Mac 62b5d194). */
        .swiftly-kontoplus {
            background-color: \(area);
            border: none;
            border-radius: \(corner)px;
            color: \(fontQuiet);
            padding: 0;
            min-width: 40px;
            min-height: 40px;
        }
        .swiftly-kontoplus:hover { background-color: rgba(255,255,255,0.06); }
        /* **Ein Genre-Chip ueber der Startseite.** Eckig, nicht rund: Ecke
           wie ein Knopf, denn rund ist, was ein Bild ist (E26). 34 hoch, 14
           seitlich — die Masse des Macs (`HomeView.swift:274`). */
        /* Woertlich wie Mac und iPhone (33be8a7f): 13 Medium, `area`,
           Ecke 10, **kein Rand**, feste Hoehe 34. */
        button.swiftly-gattungschip {
            min-height: 34px;
            padding: 0 14px;
            border-radius: \(corner)px;
            background-color: \(area);
            border: none;
            font-size: 13px;
            font-weight: 500;
            color: \(font);
        }
        button.swiftly-gattungschip:hover { background-color: #333333; }
        .swiftly-listenpfeil {
            background: none;
            border: none;
            padding: 4px;
            min-width: 28px;
            min-height: 28px;
            color: \(fontQuiet);
        }
        .swiftly-listenpfeil:hover { background-color: rgba(255,255,255,0.06); }
        /* Der Haken auf dem Folgenbild: 20 rund, dunkler Grund, 6 Abstand
           zur Ecke — die Masse des Macs (`SeriesView.swift:656`). */
        /* Gesehen: nur dunkler (iOS `Gesehenhaken`, `colorMultiply` 0,45). */
        picture.swiftly-abgedunkelt { filter: brightness(0.45); }
        .swiftly-folgenhaken {
            color: \(font);
            background-color: rgba(16,16,16,0.72);
            border-radius: \(cornerCapsule)px;
            min-width: 20px;
            min-height: 20px;
            margin: 6px;
        }
        /* **Die Karte, auf der Einstellungszeilen liegen.** `Theme.area`
           mit `eckeFlaeche` — wortgleich `CardView` auf dem Mac
           (`SettingRows.swift:30`). Die erste und die letzte Zeile
           bekommen die Ecke mit, sonst stiesse ein rechteckiger Knopf ueber
           die runde Kante. */
        .swiftly-karte {
            background-color: \(groupsArea);
            border-radius: \(cornerCard)px;
        }
        .swiftly-trennlinie { background-color: \(line); min-height: 1px; }
        /* Der Kreis eines Leerzustands: 78 auf `area` (`Leerzustand`). */
        .swiftly-leerkreis { background-color: \(area); border-radius: \(cornerCapsule)px; }
        .swiftly-leerkreis image { color: \(fontQuiet); }
        /* Der stille Knopf: 15 Medium im Akzent, 44 hoch, keine Flaeche. */
        button.swiftly-still {
            background: none; border: none; box-shadow: none;
            min-height: 44px; padding: 0 8px;
        }
        button.swiftly-still label { color: \(accent); font-size: \(body)px; font-weight: 500; }
        button.swiftly-still:hover label { color: #7ADFE3; }
        /* **Die Leiste, die beim Scrollen kommt** (`Bestandsleiste`): Grund
           und Haarlinie erscheinen erst mit dem Scrollweg; ein Dauerverlauf
           steht dort nicht (Mac c584bd70). */
        .swiftly-bestandsgrund {
            background-color: \(reason);
            border-bottom: 1px solid \(line);
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
            background-color: \(area);
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
           eckiger ist als ihr Untergrund, fällt auf (`Style.swift:2996`). */
        .swiftly-kachelmarke {
            font-size: 10px;
            font-weight: 600;
            color: \(font);
            background-color: rgba(16,16,16,0.78);
            border: 1px solid \(margin);
            border-radius: 9px;
            padding: 3px 6px;
            margin: 6px;
        }
        /* **Beim blossen Haken einen Punkt enger** — `Style.swift:2990`:
           `padding(.horizontal, wortlaut == nil ? 5 : 6)`. Ein Zeichen ohne
           Wort braucht weniger Luft als eine Zahl, sonst sieht die Marke
           daneben zu breit aus. */
        .swiftly-kachelmarke.swiftly-nurhaken { padding: 3px 5px; }
        .swiftly-balkenspur { background-color: rgba(255,255,255,0.30); }
        .swiftly-balken { background-color: \(accent); }

        /* Plakate: eigener Grund, solange das Bild noch nicht da ist.
           **Und sie wachsen unter dem Zeiger.** Auf dem Mac steht dafür
           `.scaleEffect(hovers ? 1.04 : 1)` am Bild — nur am Bild, nicht an
           der Kachel: der Text darunter soll stehen bleiben. GTK4 kennt
           `transform` im Stilblatt, also geht dasselbe hier.
           Die Kachel muss ein Knopf sein, damit `:hover` überhaupt greift —
           auf einer schlichten Box führt GTK den Zustand nicht. */
        .swiftly-plakat {
            background-color: \(area);
            border-radius: \(cornerTile)px;
            transition: transform \(float);
        }
        button.swiftly-kachel { padding: 0; background-color: transparent; }
        button.swiftly-kachel:hover .swiftly-plakat { transform: scale(1.04); }
        /* Das Mosaik einer Sammlung ohne Bild (Mac `Sammlungsmosaik`): jedes
           Feld auf `area`, die Ecken traegt das Plakat darum. */
        .swiftly-mosaikfeld { background-color: \(area); }

        /* **Der Seitentitel als Menue** (Mac `Titelwahl`): kein Kasten, der
           Winkel leise, unter dem Zeiger und offen weiss. */
        button.swiftly-titelwahl {
            background-image: none; background-color: transparent;
            border: none; box-shadow: none; padding: 0; min-height: 0;
        }
        button.swiftly-titelwahl:hover, button.swiftly-titelwahl:active { background-color: transparent; }
        button.swiftly-titelwahl image { color: \(fontQuiet); transition: color \(float); }
        button.swiftly-titelwahl:hover image,
        button.swiftly-titelwahl.swiftly-aktiv image { color: \(font); }
        button.swiftly-titelwahl:active { opacity: 0.85; transform: scale(0.97); }
        /* Der Kopf der Reihe „Teil der Sammlung" (Mac `Sammlungsreihe`):
           ein Knopf ohne Kasten, der Winkel sehr leise, unter dem Zeiger weiss. */
        button.swiftly-sammlungskopf {
            background-image: none; background-color: transparent;
            border: none; box-shadow: none; padding: 0; min-height: 0;
        }
        button.swiftly-sammlungskopf:hover { background-color: transparent; }
        button.swiftly-sammlungskopf image { color: \(fontVeryQuiet); transition: color \(float); }
        button.swiftly-sammlungskopf:hover image { color: \(font); }
        button.swiftly-sammlungskopf:active { opacity: 0.85; transform: scale(0.97); }

        /* Der Blätterpfeil: 34 rund, Grund zu 72 %, Haarlinie darum. */
        /* Der Blaetterpfeil ist ein Feld (Mac cb153e7f): 34 auf `area`,
           Ecke 8, kein Rand. */
        button.swiftly-pfeil {
            min-width: 34px;
            min-height: 34px;
            padding: 0;
            margin: 0 6px;
            border-radius: \(cornerMark)px;
            background-color: \(area);
            border: none;
        }
        button.swiftly-pfeil {
            opacity: 0;
            transition: opacity \(Int(FadeTimes.arrows * 1000))ms ease-in-out,
                        background-color \(Int(FadeTimes.arrows * 1000))ms ease-in-out;
        }
        button.swiftly-pfeil.swiftly-da { opacity: 1; }
        button.swiftly-pfeil image { color: \(font); }
        button.swiftly-pfeil:hover { background-color: #333333; }

        /* Das Raster: GTK malt Auswahl- und Randflächen, die wir nicht
           wollen — es soll nur anordnen. */
        flowbox, flowboxchild {
            background-color: transparent;
            background-image: none;
            padding: 0;
            border: none;
        }
        flowboxchild:selected, flowboxchild:focus:not(:focus-visible) { outline: none; box-shadow: none; }

        /* Das Benutzerbild ist rund. 26 Punkt, wie auf dem Mac. */
        .swiftly-profilbild {
            border-radius: 13px;
            background-image: \(profileHistory);
        }

        /* Bei mehreren Konten stehen unten zwei Kreise. Der zweite traegt
           einen Rand in der Farbe der Leiste — er stanzt die Ueberlappung
           aus, sonst kleben die beiden Kreise zu einer Form zusammen. */
        .swiftly-profilbild-aktiv {
            border-radius: 13px;
            background-image: \(profileHistory);
            box-shadow: 0 0 0 1.5px \(accent);
        }
        .swiftly-profilbild-daneben {
            border-radius: 13px;
            background-image: \(profileHistory);
            box-shadow: 0 0 0 2px \(area);
        }

        /* MARK: Detailseite */

        /* **34, nicht 40.** Auch hier war `HeroHeader.swift` die falsche
           Vorlage — das ist die iPhone-/iPad-Fassung. Der Mac setzt den
           Heldtitel an beiden Stellen, an denen es ihn gibt, auf 34 fett mit
           -0,8 Laufweite: `DetailView.swift:390` und `PersonView.swift:158`.
           Bei 40 stiess die Schrift ausserdem an die Oberkante ihres 42
           Punkt hohen Fachs. */
        /* **28 Bold, -0,6** (Mac cd91db75): der Titel ueber einem Heldbild *ist*
           der Seitentitel. Angaben 12 in `schriftLeise`, Beschreibung
           `schriftLeise` statt weiss 62 % — ueber einem Bild aendert Deckkraft
           ihre Wirkung. */
        .swiftly-heldtitel { font-size: \(titleLarge)px; font-weight: 700; letter-spacing: -0.6px; }
        .swiftly-angaben { font-size: \(secondLine)px; color: \(fontQuiet); }
        .swiftly-beschreibung { color: \(fontQuiet); font-size: \(body)px; }
        .swiftly-leistentitel { font-size: \(categoryLarge)px; font-weight: 600; letter-spacing: -0.14px; }
        .swiftly-beleg label, .swiftly-beleg image { color: \(accent); }
        /* The letter strip beside a "By name" grid (`AlphabetStrip`): quiet letters, the
           current one in the accent. */
        .swiftly-buchstabe { font-size: 11px; font-weight: 600; color: \(fontQuiet); }
        .swiftly-buchstabe-aktiv { color: \(accent); }
        .swiftly-warnung label, .swiftly-warnung image { color: \(warning); }

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
        .swiftly-belegmarke { border-radius: \(cornerMark)px; padding: 4px 10px 4px 8px; }
        .swiftly-belegmarke.swiftly-beleg   { background-color: alpha(\(accent), 0.15); }
        .swiftly-belegmarke.swiftly-warnung { background-color: alpha(\(warning), 0.15); }
        .swiftly-belegmarke label { font-size: 13px; font-weight: 500; }

        /* Die Bewertung in derselben Marke wie der Beleg (Mac ec0383c8,
           `DetailView.swift` `mark`): `schriftLeise`, Flaeche 15 Prozent. */
        .swiftly-bewertung label, .swiftly-bewertung image { color: \(fontQuiet); }
        .swiftly-belegmarke.swiftly-bewertung { background-color: alpha(\(fontQuiet), 0.15); }

        /* **Die Staffelliste klappt im Seitenfluss auf**, nicht als Blatt —
           `Sources/macOS/SeriesView.swift:554-566`. Deshalb `eckeFeld` (12)
           und *kein* Schatten: sie liegt in der Seite, nicht darüber. */
        .swiftly-staffelliste {
            background-color: \(raised);
            border: 1px solid \(margin);
            border-radius: \(cornerArea)px;
            padding: 4px 0;
            transform-origin: top left;
        }
        .swiftly-staffelliste.swiftly-offen {
            animation: swiftly-aufklappen 0.22s cubic-bezier(0.2, 0.9, 0.3, 1.0);
        }
        button.swiftly-staffelzeile {
            min-height: \(rowHeight)px;
            padding: 0 12px;
            border-radius: 0;
        }
        button.swiftly-staffelzeile:hover { background-color: rgba(255,255,255,0.06); }
        /* Gewaehlt heisst Weiss (Mac cd91db75) — eine Wahl unter
           Geschwistern ist Rangfolge, und die traegt der Akzent nie. */
        button.swiftly-staffelzeile label { color: \(fontQuiet); }
        button.swiftly-staffelzeile.swiftly-aktiv label,
        button.swiftly-staffelzeile.swiftly-aktiv image { color: \(font); }

        /* **Die Seerr-Marke auf einer Kachel** — gefuellte Kapsel in der Farbe
           des Standes, dunkle Schrift, 11 halbfett, Innenrand 8 x 3
           (`Sources/macOS/SeerrTileAndPage.swift:56-70`). Die Klasse
           `swiftly-marke` stand im Code und gab es hier nicht: alle drei
           Staende sahen gleich aus. Die Farben stehen als `Seerrstand.farbe`
           in `Sources/Shared/SeerrMark.swift:63-68`. */
        .swiftly-marke {
            font-size: 11px;
            font-weight: 600;
            color: \(reason);
            border-radius: \(cornerCapsule)px;
            padding: 3px 8px;
        }
        .swiftly-marke-akzent { background-color: \(accent); }
        .swiftly-marke-wartet { background-color: rgb(217,153,43); }
        .swiftly-marke-laedt  { background-color: rgb(74,143,217); }

        /* **Eine Flaeche in 15 Prozent, kein Umriss** (`Badge`,
           Mac 28d314fd): 13 Medium, Ecke 8, 10 × 4 innen — dieselbe Gestalt
           wie der Beleg daneben. */
        .swiftly-plakette {
            font-size: 13px;
            font-weight: 500;
            color: \(fontQuiet);
            background-color: rgba(204,204,204,0.15);
            border: none;
            border-radius: \(cornerMark)px;
            padding: 4px 10px;
        }

        /* Die Kopfleiste schwebt über der Seite und malt nichts. */
        .swiftly-detailkopf { background-color: transparent; }
        button.swiftly-zurueck {
            min-width: 40px;
            min-height: 40px;
            padding: 0;
            border-radius: \(corner)px;
            background-color: transparent;
            border: none;
        }
        button.swiftly-zurueck image { color: \(fontQuiet); -gtk-icon-size: 20px; }
        /* **Kein Grund, auch nicht beim Schweben.** Auf dem Mac ist es ein
           blanker Winkel mit `.buttonStyle(.plain)` — kein Rahmen, keine
           Fläche. Ein Kasten, der nur unter dem Zeiger erscheint, ist eine
           Zutat, die dort nicht steht. */
        button.swiftly-zurueck:hover { background-color: transparent; }
        button.swiftly-zurueck:hover image { color: \(font); }

        /* MARK: Kopfzone der Detailseite
           Der Ton kommt aus ``Tonblatt`` und wechselt mit dem Titel; hier
           steht nur, was ohne Ton gilt. */
        .swiftly-seitenton { background-color: \(reason); }
        /* **Über Bildfarbe durchsichtig statt `area`** (1.0.5,
           `Theme.flaecheDurchsichtig`, iPhone und Mac): Nebenknöpfe und Chips
           der Detailseite weiß 8 %, aktiv ändert die Fläche nicht — den
           Zustand trägt das Zeichen. Ein festes Grau stand auf der
           gefärbten Seite wie ein fremder Block. */
        /* Neu gerechnet blendet die Farbe ein (Tonlage, `Tonblatt.einblenden`);
           schon gemerkt steht sie im ersten Bild. */
        .swiftly-bildton button.swiftly-neben,
        .swiftly-bildton button.swiftly-neben.swiftly-aktiv,
        .swiftly-bildton button.swiftly-chip,
        .swiftly-bildton button.swiftly-chip.swiftly-aktiv { background-color: rgba(255,255,255,0.08); }
        /* **Auch aktiv dieselbe Schwebefarbe.** Ohne die beiden `.active`-Zeilen
           gewann `button.swiftly-beside.swiftly-aktiv:hover` (#333333, gleich
           spezifisch, weiter unten) — die Merkliste leuchtete unter dem
           Zeiger anders als Laden und „…". Den Zustand trägt das Zeichen. */
        .swiftly-bildton button.swiftly-neben:hover,
        .swiftly-bildton button.swiftly-neben.swiftly-aktiv:hover,
        .swiftly-bildton button.swiftly-chip:hover,
        .swiftly-bildton button.swiftly-chip.swiftly-aktiv:hover { background-color: rgba(255,255,255,0.14); }
        /* Die Staffelliste deckend, im Ton der Seite (``Tonblatt``), ohne
           Ton `reason` plus Weiß 8 %. */
        .swiftly-bildton .swiftly-staffelliste { background-color: #232323; }
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
           Scrollen `Theme.reason` mit voller Deckung; hier standen 0,86, und
           darunter liefen die Plakate sichtbar durch. Der Grund dort steht
           ausdruecklich dabei: eine Flaeche kann nicht aufblitzen und ist
           genau so dunkel wie die Seite. */
        .swiftly-kopfleiste {
            background-color: \(reason);
            border-bottom: 1px solid \(line);
        }

        /* Nebenknopf: abgerundetes Quadrat, nur Symbol. */
        /* **Aktionsknopf** (Mac cb153e7f): ein quadratisches Feld auf
           `area`, keine weisse Fuellung. Der eine gefuellte Gegenstand der
           Seite bleibt der Hauptknopf; aktiv heisst Akzent am Zeichen. */
        button.swiftly-neben {
            border-radius: \(corner)px;
            background-color: \(area);
            padding: 0;
            border: none;
        }
        button.swiftly-neben image { color: \(font); }
        button.swiftly-neben:hover { background-color: #333333; }
        button.swiftly-neben.swiftly-aktiv { background-color: \(area); }
        button.swiftly-neben.swiftly-aktiv:hover { background-color: #333333; }
        button.swiftly-neben.swiftly-aktiv image { color: \(accent); }

        /* Reiter: aktiv halbfett mit Akzentstrich. */
        button.swiftly-reiter {
            background-color: transparent;
            border: none;
            border-radius: 0;
            padding: 0;
            font-size: 15px;
        }
        button.swiftly-reiter label { color: \(fontQuiet); }
        button.swiftly-reiter:hover label { color: \(font); }
        /* Ein Gewicht (15 Semifett) in beiden Zustaenden, Strich in Weiss
           (Mac cd91db75) — „gewaehlt" ist Rangfolge, die traegt der Akzent
           nie. */
        button.swiftly-reiter label { font-weight: 600; }
        button.swiftly-reiter.swiftly-aktiv label { color: \(font); }
        .swiftly-reiterstrich { background-color: transparent; }
        button.swiftly-reiter.swiftly-aktiv .swiftly-reiterstrich {
            background-color: \(font);
        }

        /* **Der Rand steckt im Innenabstand, nicht im aeusseren.**
           So laeuft die Hervorhebung ueber die ganze Breite, wie auf dem Mac,
           und das Vorschaubild steht trotzdem in der Flucht der
           Reiterbeschriftung darueber. Keine Rundung: eine Zeile, die von
           Kante zu Kante geht, hat keine Ecken. */
        .swiftly-folgenzeile {
            background-color: transparent;
            padding: 12px \(edgeSpacing)px;
        }
        /* **Unter dem Zeiger waechst das Standbild, die Zeile leuchtet
           nicht** — wie jede Kachel (`scale(1.04)`, 120 ms, `zeitSchweben`).
           Der volle helle Streifen war fuer eine Liste zu laut; am Mac
           genauso geaendert. */
        .swiftly-folgenzeile .swiftly-plakat { transition: transform \(float); }
        .swiftly-folgenzeile.swiftly-schwebt .swiftly-plakat { transform: scale(1.04); }
        /* **Die laufende Folge in der Player-Folgenebene** — Weiss zu acht
           Prozent, wörtlich `.background(Color.white.opacity(0.08))` vom Mac
           (`PlayerLayers.swift:356`). */
        .swiftly-folgenzeile.swiftly-aktiv { background-color: rgba(255,255,255,0.08); }
        /* Keine Haarlinie zwischen den Folgen — das iPhone trennt sie nur
           durch Luft, der Mac jetzt auch. */
        /* Der Abspielkreis, der beim Schweben ueber dem Bild erscheint. */
        .swiftly-spielkreis {
            background-color: rgba(0,0,0,0.55);
            border-radius: 17px;
            min-width: 34px;
            min-height: 34px;
        }
        .swiftly-spielkreis image { color: \(font); }

        .swiftly-kopfbild { border-radius: 42px; }

        /* MARK: Einstellungszeilen */

        /* Die Unterzeile: 12 in `schriftSehrLeise` — weiss 45 % lag bei
           3,84 : 1 und steht in BRAND 1 unter den verbotenen Werten. Unter
           dem Zeiger eine Stufe heller (Mac 77af1111). */
        .swiftly-fuss { color: \(fontVeryQuiet); }
        button.swiftly-einstellzeile:hover .swiftly-fuss { color: \(fontQuiet); }
        .swiftly-akzentzeile label { color: \(accent); }
        /* **Die Rolle, ueber die man kam** — im Akzent, halbfett, wie auf
           Apple (`PersonView.swift:190`). `swiftly-akzentzeile` trifft nur
           Kind-Labels; hier ist das Widget selbst das Label. */
        .swiftly-rolle { color: \(accent); font-size: 14px; font-weight: 500; }
        .swiftly-akzentzeile image { color: \(accent); }
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
            border-top-left-radius: \(cornerCard)px;
            border-top-right-radius: \(cornerCard)px;
        }
        .swiftly-karte > box > :last-child {
            border-bottom-left-radius: \(cornerCard)px;
            border-bottom-right-radius: \(cornerCard)px;
        }
        button.swiftly-einstellzeile:hover { background-color: \(hover); }
        button.swiftly-einstellzeile image { color: \(fontQuiet); }
        button.swiftly-einstellzeile.swiftly-akzentzeile image { color: \(accent); }

        /* Der Schalter — Kapsel, Akzent wenn an. Kein GtkSwitch: der bringt
           Form, Farbe und Maße des Systems mit (E4). */
        .swiftly-schalter {
            /* Weiss zu 14 % — `Theme.font.opacity(0.14)`, die Mac-Zahl aus
               `Sources/macOS/SettingRows.swift:133`. Die 16 % kamen
               vom iPhone-Blatt, wie auch die Maße. */
            /* Aus: `rand` (weiss 12 %), keine eigene Deckkraft (62b5d194). */
            background-color: \(margin);
            border-radius: \(cornerCapsule)px;
            padding: 3px;
            transition: background-color 220ms ease-out;
        }
        .swiftly-schalter.swiftly-aktiv { background-color: \(accent); }
        /* Ein Kreis, kein abgerundetes Rechteck — `Circle()` auf dem Mac. */
        .swiftly-knauf {
            background-color: \(font); border-radius: \(cornerCapsule)px;
            margin-left: 0px;
            transition: margin-left 220ms ease-out, background-color 220ms ease-out;
        }
        /* 38 - 2x3 Innenrand - 16 Knauf = 16 Weg nach rechts. */
        .swiftly-schalter.swiftly-aktiv .swiftly-knauf {
            background-color: \(reason); margin-left: 16px;
        }

        /* `Werteliste` auf dem Mac: 4 oben und unten, 48 eingerueckt, auf
           `area`; Zeilen 32 hoch, 12 seitlich. Gewaehlt heisst Weiss mit
           Haken, nicht Akzent (62b5d194). */
        .swiftly-werteliste { background-color: \(area); padding: 4px 0 4px 48px; }
        button.swiftly-wertzeile {
            min-height: \(rowHeight)px;
            padding: 0 12px;
            border-radius: 0;
            background-color: transparent;
            border: none;
        }
        button.swiftly-wertzeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-wertzeile label { color: \(fontQuiet); }
        button.swiftly-wertzeile.swiftly-aktiv label { color: \(font); }
        button.swiftly-wertzeile.swiftly-aktiv image { color: \(font); }

        .swiftly-profilgross { border-radius: \(cornerCapsule)px; background-image: \(profileHistory); }
        /* **Rund, weil es ein Bild ist** (E26). Hier stand ein fester Radius
           von 42 — auf einem 84er Bild ein Kreis, auf dem 104er Kopf der
           Personenseite ein Quadrat mit weichen Ecken. */
        .swiftly-personkopf { border-radius: \(cornerCapsule)px; background-image: \(profileHistory); }

        /* **Der Buchstabe, wenn kein Bild kommt.** Die Groesse ist auf Apple
           `size * 0.38`; hier steht sie je Kreisgroesse fest, weil GTKs
           Stilblatt nichts rechnen kann. 96 -> 36, 84 -> 32, 72 -> 27,
           26 -> 10. */
        .swiftly-zeichen96 { font-size: 36px; font-weight: 600; color: \(font); }
        .swiftly-zeichen84 { font-size: 32px; font-weight: 600; color: \(font); }
        .swiftly-zeichen72 { font-size: 27px; font-weight: 600; color: \(font); }
        .swiftly-zeichen26 { font-size: 10px; font-weight: 600; color: \(font); }

        /* MARK: Weiteres Konto

           Der zweite Weg auf einer Seite: Rand statt Flaeche. Auf dem Mac ist
           das `Umrissknopf` — dort steht er ebenfalls nur an dieser einen
           Stelle. */
        button.swiftly-umriss {
            border: 1px solid \(margin);
            border-radius: \(corner)px;
            background: none;
            box-shadow: none;
            min-height: 40px;
            color: \(font);
            font-size: \(body)px;
        }
        button.swiftly-umriss:hover { background-color: rgba(255,255,255,0.06); }

        /* Der Quick-Connect-Code bekommt einen eigenen Teil — nicht die Zeile,
           in der Fehler stehen. Gross, mittig, auf eigener Flaeche. */
        /* **Ueber die volle Breite, mit Rand** — `ProfileView.swift:353-364`:
           `frame(maxWidth: .infinity)`, `Theme.area` mit `Theme.corner` und
           eine Haarlinie darum. Die Haarlinie fehlte, und ohne sie steht der
           Kasten nur da, wo der Text steht. */
        /* **28 Bold, kein gezeichneter Rahmen** (Mac 62b5d194): der Code
           stand zwei Stufen ueber dem Seitentitel. */
        .swiftly-codegross {
            font-size: \(titleLarge)px;
            font-weight: 700;
            letter-spacing: 6px;
            background-color: \(area);
            border: none;
            border-radius: \(corner)px;
            padding: 18px 0;
        }

        /* MARK: Kontenstreifen im Profil

           Der Ring liegt als Schatten aussen an, nicht als Rand: ein Rand
           zaehlt zur Flaeche und macht das Bild um seine Staerke kleiner —
           96 und 72 waeren dann 93 und 70, und die beiden Groessen stuenden
           nicht mehr im Verhaeltnis des Entwurfs. */
        .swiftly-kontoaktiv {
            border-radius: 48px;
            background-image: \(profileHistory);
            box-shadow: 0 0 0 1.5px \(accent);
        }
        .swiftly-kontoandere {
            border-radius: 36px;
            background-image: \(profileHistory);
            box-shadow: 0 0 0 1px rgba(255,255,255,0.12);
        }
        .swiftly-kontopunkt { border-radius: 3px; background-color: \(accent); }
        /* **Der Kontowechsel als Bewegung** (Entwurf D, ``Kontoflug``): das
           fliegende Bild rund und ohne Ring, der Ring ploppt erst bei der
           Landung am Kreis in der Leiste (0,8 s, wie am iPhone). */
        /* **Die Übergabe als Karte** (``Uebergabelauf``): Grund über der
           Seite, Schwarz wie der Grund des Players, die Karte in `area`
           mit ihrer Ecke (die Stufe setzt der Bildtakt), darunter Titel und
           Folge wie am Mac (17 halbfett, 13 leise) und die Ladelinie. */
        .swiftly-uebergabegrund { background-color: \(reason); }
        .swiftly-uebergabeschwarz { background-color: #000000; }
        .swiftly-uebergabekarte { background-color: \(area); }
        .swiftly-uebergabetitel { font-size: 17px; font-weight: 600; color: \(font); }
        .swiftly-uebergabeunter { font-size: 13px; color: \(fontQuiet); }
        .swiftly-uebergabelinie { background-color: \(margin); border-radius: 1px; }
        .swiftly-uebergabebalken { background-color: \(accent); border-radius: 1px; }
        \(handoffCorners)
        .swiftly-kontoflug {
            border-radius: \(cornerCapsule)px;
            background-image: \(profileHistory);
        }
        @keyframes swiftly-ringpop {
            0%   { box-shadow: 0 0 0 1.5px \(accent); }
            35%  { box-shadow: 0 0 0 5px alpha(\(accent), 0.55); }
            100% { box-shadow: 0 0 0 1.5px \(accent); }
        }
        .swiftly-ringpop { animation: swiftly-ringpop 0.8s cubic-bezier(0.2, 0.9, 0.3, 1.0); }
        /* Die Reihen der Startseite nach dem Wechsel (`Reihenauftritt`):
           Deckkraft linear in 0,22 s, von 14 tiefer und 96 % mit einem
           kleinen Nachfedern. */
        .swiftly-reihenauftritt {
            transition: opacity \(Int(AccountSwitchCurve.railsFade * 1000))ms linear,
                        transform 520ms cubic-bezier(0.25, 1.25, 0.4, 1.0);
        }
        .swiftly-reihenauftritt.swiftly-reihe-vor {
            opacity: 0;
            transform: translateY(\(Int(AccountSwitchCurve.railsOffset))px) scale(\(AccountSwitchCurve.railsMass));
        }
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
            font-size: \(titleLarge)px;
            font-weight: 700;
            min-height: 76px;
            letter-spacing: 6px;
        }
        entry.swiftly-code text { caret-color: \(accent); }

        /* MARK: Player (E10) */

        /* Der Grund der Startanimation — auf iOS eine eigene Farbe
           („StartBackground"), hier derselbe dunkle Grund wie überall. */
        .swiftly-startgrund { background-color: \(reason); }
        /* Der Dateiauszug: Haarlinie darüber, 14 Punkt Luft. */
        .swiftly-dateizeile {
            border-top: 1px solid \(line);
            padding-top: 14px;
            margin-top: 8px;
        }

        /* Die Hinweiszeile: drei Sekunden, dann weg. */
        /* **Das Abzeichen in der Form des Fernsehers** (tvOS
           `AbzeichenStil`, Mac `Angebotszeile`): eine Kapsel, Akzent zu 18 %
           ueber `reason`, kein Rand; Zeichen und Titel im Akzent. Schwebend
           legt sich Weiss zu 6 % darueber (BRAND: Schweben ist Weiss).
           Hoehe `abzeichenHoehe`, der Abstand zu den Kanten steht als
           `abzeichenRand` an der Zeile. */
        button.swiftly-uebernahme {
            min-height: \(badgeHeight)px;
            padding: 0 14px;
            border-radius: \(cornerCapsule)px;
            border: none;
            box-shadow: none;
            background-color: \(reason);
            background-image: linear-gradient(alpha(\(accent), 0.18), alpha(\(accent), 0.18));
            transition: background-image \(float);
        }
        button.swiftly-uebernahme:hover {
            background-image: linear-gradient(rgba(255,255,255,0.06), rgba(255,255,255,0.06)),
                              linear-gradient(alpha(\(accent), 0.18), alpha(\(accent), 0.18));
        }
        button.swiftly-uebernahme image,
        button.swiftly-uebernahme .swiftly-kacheltitel { color: \(accent); }
        .swiftly-uebernahmezeile { font-size: 11px; color: \(fontVeryQuiet); }

        /* **Gemeinsam schauen** — Werte aus `SharedViews.swift` (iOS).
           Der Zähler am Abzeichen: 11 halbfett, Ziffern gleich breit,
           `aufAkzent` auf dem Akzent, mindestens 16 × 16, Kapsel. */
        .swiftly-zaehler {
            font-size: 11px;
            font-weight: 600;
            font-feature-settings: "tnum";
            color: \(onAccent);
            background-color: \(accent);
            border-radius: \(cornerCapsule)px;
            min-width: 16px;
            min-height: 16px;
            padding: 0 4px;
        }
        .swiftly-akzentschrift { color: \(accent); }
        /* Eine Zeile der Auswahl „Läuft gerade": 58 hoch wie im Blatt. */
        button.swiftly-handlung.swiftly-angebotszeile { min-height: 58px; padding: 0 14px; }
        /* **Das mittige Fenster** (Mac `SharedPanel`): „Senden an …",
           „Übergeben an …" und die Frage vor dem Übernehmen. Fläche `area`,
           Ecke 16, die eine Kante in `rand` wie die Tafeln; die Zeilen 20
           seitlich wie `SelectionRow`, bündig mit der Überschrift. */
        .swiftly-wahlfenster {
            background-color: \(area);
            border: 1px solid \(margin);
            border-radius: \(cornerArea)px;
        }
        .swiftly-wahlfenster button.swiftly-angebotszeile { padding: 0 20px; }
        /* Der Hinweis oben im Player: Kapsel auf `area`, 44 hoch, 16 innen. */
        .swiftly-gruppenereignis {
            background-color: \(area);
            border-radius: \(cornerCapsule)px;
            min-height: 44px;
            padding: 0 16px;
        }
        .swiftly-gruppenereignis label { color: \(font); }
        /* Die Gruppe in der Metazeile: der Name halbfett im Akzent. */
        .swiftly-spielerzeile.swiftly-gruppenname { color: \(accent); font-weight: 600; }
        /* Spalte „Gemeinsam": Namen sind Auskunft, kein Knopf; der Ausgang
           steht im Akzent. */
        .swiftly-teilnehmer { padding: 8px 10px; }
        .swiftly-teilnehmer label { font-size: \(listTitle)px; color: \(fontQuiet); }
        button.swiftly-ebenenzeile.swiftly-verlassen label,
        button.swiftly-ebenenzeile.swiftly-verlassen image { color: \(accent); }
        /* „Filmabend verlassen · Wieder beitreten": Kapsel auf `area`,
           18 links, 12 rechts, Text 13, Knopf 13 halbfett im Akzent. */
        .swiftly-rueckweg {
            background-color: \(area);
            border: 1px solid \(margin);
            border-radius: \(cornerCapsule)px;
            padding: 0 12px 0 18px;
        }
        .swiftly-rueckwegtext { font-size: 13px; color: \(font); }
        button.swiftly-rueckwegknopf {
            min-height: 44px;
            padding: 0 4px;
            background-color: transparent;
            border: none;
        }
        button.swiftly-rueckwegknopf label { font-size: 13px; font-weight: 600; color: \(accent); }

        .swiftly-akzentzeichen { color: \(accent); }
        .swiftly-sehrleise, .swiftly-sehrleise image { color: \(fontVeryQuiet); }

        /* **Eine Kapsel in `erhoeht`, kein Rechteck auf Schwarz.** So steht
           `Hinweisstreifen` auf dem Mac (`MacComponents.swift:632`): Kapsel,
           Grund `erhoeht`, Haarlinie in `rand`. Hier stand ein eigener
           schwarzer Kasten mit Radius 10 — E11 zählt den Hinweis
           ausdrücklich zu den Kapseln, und ein zweiter Grundton neben
           `erhoeht` ist eine Fläche, die es sonst nirgends gibt. */
        .swiftly-hinweis {
            font-size: 14px;
            color: \(font);
            background-color: \(raised);
            border: 1px solid \(margin);
            border-radius: \(cornerCapsule)px;
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
            border: 1px solid \(margin);
            background-color: transparent;
        }
        button.swiftly-vollknopf image { color: \(fontQuiet); }
        button.swiftly-vollknopf:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-vollknopf:hover image { color: \(font); }

        /* 11 gibt es nur als Semifett (984514f2). */
        .swiftly-kuerzel {
            font-size: 11px;
            font-weight: 600;
            color: \(fontVeryQuiet);
        }

        /* Titel und Zeiten unten. 19 halbfett, darunter 14 auf 68 %, und
           die Zeiten 13 mit gleich breiten Ziffern — die Masse des Macs. */
        /* 22 halbfett, wie `mass.title` auf dem Mac (`Playermass.title`). */
        /* **Dieselbe Leiter wie ueberall** (Mac 984514f2): Titel 20
           Semifett, Angabe 12, Zeit 13. 22 und 14 waren eine zweite
           Schriftleiter nur fuer den Player; Bold steht genau einmal, am
           Seitentitel. */
        .swiftly-spielertitel { font-size: \(rail)px; font-weight: 600; color: \(font); }
        .swiftly-spielerzeile { font-size: \(secondLine)px; color: \(fontQuiet); }
        .swiftly-spielerzeit {
            font-size: 13px;
            font-feature-settings: "tnum";
            color: \(fontQuiet);
        }
        .swiftly-warnung label, .swiftly-warnung image { color: \(warning); }

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
        /* **Mit Kapiteln malt die Ueberlagerung Spur und Balken** (ein Stueck je
           Kapitel); hier bleibt nur der Griff. */
        scale.swiftly-regler.swiftly-regler-kapitel trough,
        scale.swiftly-regler.swiftly-regler-kapitel highlight {
            background-color: transparent;
        }
        scale.swiftly-regler highlight {
            margin: 0;
            padding: 0;
            border: none;
            background-image: none;
            background-color: \(font);
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
            background-color: \(accent);
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
           ausdruecklich `Capsule()` — `Sources/macOS/MacComponents.swift:117`
           und `:121`. Drei Punkt breiter als hoch ist die Vorlage, nicht ein
           Versehen darin.

           Der Radius steht weit ueber der halben Kante. GTK deckelt ihn auf
           das Moegliche, und damit bleibt die Form auch dann richtig, wenn
           jemand spaeter an der Groesse dreht. */
        .swiftly-chip.swiftly-nursymbol {
            padding: 0;
            min-width: 34px;
            min-height: 28px;
            border-radius: \(cornerCapsule)px;
        }
        /* `Theme.corner` wie auf Apple (`TechBadge.swift:115`), nicht das
           Feldmass. Bis zum 12.09.2026 stand hier `eckeFeld` — und traf,
           solange beide 10 waren, zufaellig das Richtige. */
        /* Schrift aus der Leiter (`Theme.small`, 12) mit gleich breiten
           Ziffern statt Monospace — Mac: `Theme.small.monospacedDigit()`. */
        .swiftly-technikschild {
            font-size: 12px;
            font-feature-settings: "tnum";
            color: rgba(255,255,255,0.92);
            background-color: rgba(16,16,16,0.82);
            border: 1px solid \(margin);
            border-radius: \(corner)px;
            padding: 10px 14px;
        }
        /* Die Kopfzeile eine Stufe darüber, halbfett — Mac: `Theme.tile.weight(.semibold)`. */
        .swiftly-technikschild .swiftly-technikkopf { font-size: \(tileTitleText)px; font-weight: 600; }
        /* Die Haarlinie im Messmodus in `rand` — Mac: `Rectangle().fill(Theme.rand)`. */
        .swiftly-technikschild .swiftly-trennlinie { background-color: \(margin); }
        /* **Die drei Ebenen über dem Bild** (Audio & Untertitel,
           Einstellungen, Folgen) — wörtlich `Sources/macOS/PlayerLayers.swift`.
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
            border-radius: \(cornerField)px;
        }
        button.swiftly-symbolknopf image { color: \(font); }
        button.swiftly-symbolknopf:hover { background-color: rgba(255,255,255,0.12); }
        /* Spaltentitel einer Ebene — 18 fett, weiss, wörtlich `Wahlspalte`. */
        /* 17 Semifett mit ihrer Sperrung statt 18 Bold (984514f2). */
        .swiftly-spaltentitel { font-size: \(categoryLarge)px; font-weight: 600; letter-spacing: -0.14px; color: \(font); }
        /* Verzoegerungszeile (Mac: `Verzoegerungszeile`): Beschriftung
           `Theme.small` in `schriftSehrLeise`, der Wert `Theme.body` mit
           gleich breiten Ziffern, bei null leise. */
        .swiftly-verzugstitel { font-size: 12px; color: \(fontVeryQuiet); }
        .swiftly-verzugswert { font-size: \(body)px; font-feature-settings: "tnum"; color: \(font); }
        .swiftly-verzugswert.swiftly-null { color: \(fontQuiet); }
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
            border-radius: \(cornerField)px;
        }
        button.swiftly-ebenenzeile:hover { background-color: rgba(255,255,255,0.06); }
        button.swiftly-ebenenzeile label { font-size: 15px; font-weight: 400; color: \(fontQuiet); }
        /* **Ein Gewicht** — gewaehlt heisst voller Ton, nicht ein zweiter
           Schnitt; der aendert die Breite (984514f2). */
        button.swiftly-ebenenzeile.swiftly-gewaehlt label { color: \(font); }
        /* Die Sprungmarke: 108 rund, Schwarz 45 %, „10 s" darunter
           (Mac: `Sprungmarke`). */
        .swiftly-sprungmarke {
            background-color: rgba(0,0,0,0.45);
            border-radius: 54px;
        }
        .swiftly-sprungtext { font-size: 13px; font-weight: 500; color: \(font); }
        /* Trickplay-Vorschau über dem Griff — Bild gerundet mit heller Kante,
           wörtlich `vorschauKasten` vom Mac (`PlayerScreen.swift:1292`). */
        .swiftly-vorschaubild {
            border-radius: \(corner)px;
            border: 1px solid rgba(255,255,255,0.35);
        }
        .swiftly-vorschauname {
            font-size: 13px;
            color: \(font);
        }
        .swiftly-vorschauzeit {
            font-size: 13px;
            font-weight: 700;
            font-feature-settings: "tnum";
            color: \(font);
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
           auf `Handlungstafel` (`Sources/Shared/HeroHeader.swift:286`) — das ist
           die iPad-/Fernsehfassung. Die Mac-Detailseite ruft `Handlungsliste`
           (`Sources/macOS/MacComponents.swift:577-597`): Ecke 12, Breite 260,
           Schatten 18/8 bei 0,4. */
        /* **Ecke 16, kein Schatten** — wie `Handlungsliste` und `Wahlknopf`
           auf dem Mac seit dem 22.09. (cb153e7f): Schatten gibt es nirgends,
           die Tafel trennt sich durch Fläche und die eine Kante in `rand`. */
        /* **Das Kachelmenü mit Vorschau** (iOS `Kachelvorschau`): oben das
           Bild ohne Rand und ohne Innenabstand, bündig mit der Tafel, darunter
           Titel 15 halbfett und die Zeile leise mit gleich breiten Ziffern,
           14 × 12 Innenrand, auf `reason`. */
        popover.swiftly-mehr.swiftly-kachelmenue > contents { padding: 0 0 4px 0; }
        .swiftly-kachelvorschau {
            border-radius: \(cornerArea)px \(cornerArea)px 0 0;
            background-color: \(area);
        }
        .swiftly-kachelvorschautext { padding: 12px 14px; background-color: \(reason); }
        .swiftly-kachelvorschautitel { font-size: \(listTitle)px; font-weight: 600; color: \(font); }
        .swiftly-kachelvorschauzeile {
            font-size: \(secondLine)px;
            font-feature-settings: "tnum";
            color: \(fontQuiet);
        }
        popover.swiftly-mehr > contents {
            background-color: \(raised);
            border: 1px solid \(margin);
            border-radius: \(cornerArea)px;
            padding: 4px 0;
            box-shadow: none;
            animation: swiftly-aufklappen 0.22s cubic-bezier(0.2, 0.9, 0.3, 1.0);
        }
        /* **Die Tafel wächst aus ihrem Knopf** (Mac 51c9c8a8,
           `AnyTransition.expand(from:)`): 0,94 und Einblenden, verankert
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
        button.swiftly-handlung image { color: \(font); }
        /* Eine Zeile in der Tafel eines Wahlknopfs (`Wahltafelzeile`):
           gewaehlt heisst Weiss mit Haken, sonst `schriftLeise`. */
        button.swiftly-wahlzeile label { color: \(fontQuiet); }
        button.swiftly-wahlzeile.swiftly-aktiv label,
        button.swiftly-wahlzeile.swiftly-aktiv image { color: \(font); }
        /* Gemalte Zeichen im Chip nehmen die Farbe des Stilblatts. */
        button.swiftly-chip .swiftly-malzeichen { color: \(fontQuiet); }
        button.swiftly-chip:hover .swiftly-malzeichen,
        button.swiftly-chip.swiftly-aktiv .swiftly-malzeichen { color: \(font); }
        .swiftly-leerkreis .swiftly-malzeichen { color: \(fontQuiet); }
        /* **Die Ladeauswahl** (`MacLadeauswahl`): Karten auf `area` mit
           Ecke 14, der runde Kasten 22 — leer mit Ring in `schriftSehrLeise`,
           teilweise und voll im Akzent mit dunklem Zeichen. */
        .swiftly-auswahlkarte { background-color: \(area); border-radius: \(cornerCard)px; }
        button.swiftly-kasten {
            background: none; box-shadow: none; padding: 0;
            min-width: 22px; min-height: 22px;
            border: 1.6px solid \(fontVeryQuiet);
            border-radius: \(cornerCapsule)px;
        }
        button.swiftly-kasten.swiftly-aktiv { background-color: \(accent); border-color: \(accent); }
        button.swiftly-kasten.swiftly-aktiv image { color: \(onAccent); }
        button.swiftly-auswahlzeile {
            background: none; border: none; box-shadow: none; padding: 0; min-height: 0;
        }
        /* [Download-Übernahme, Mac cc4e6e75] **Die Downloadzeile dunkelt ab**
           (`Abdunkeln`): ohne graue Fläche, der Inhalt geht beim Druck auf
           60 % — sofort hinein, in 0,12 s heraus. Eigene Klasse, damit
           `swiftly-zeile` der Seitenleiste bleibt, wie sie ist. Die Marke
           der Tastatur bleibt als `schwebeflaeche`; im Bearbeiten trägt der
           Zeiger `area`, wie auf dem Mac. */
        button.swiftly-dlzeile, button.swiftly-dlzeile:hover,
        button.swiftly-dlzeile:active, button.swiftly-dlzeile:checked {
            background-image: none; background-color: transparent;
            border: none; box-shadow: none; outline: none;
            padding: 0; min-height: 0; min-width: 0;
            border-radius: \(cornerField)px;
            color: \(font); font-size: \(body)px; font-weight: 500;
        }
        button.swiftly-dlzeile > * { opacity: 1; transition: opacity \(float); }
        button.swiftly-dlzeile:active > * { opacity: 0.6; transition: none; }
        button.swiftly-dlzeile:focus-visible { background-color: rgba(255,255,255,0.06); }
        button.swiftly-dlzeile.swiftly-bearbeiten:hover { background-color: \(area); }

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

        /* **Der Fokusring — ganz am Ende, damit ihn keine Knopfklasse
           wieder abschaltet** (UX-Audit 27.09.). Der Reset oben nimmt jedem
           eigenen Knopf Rahmen und Schatten, und mehrere Klassen setzen
           `outline: none` ausdruecklich; wer mit Tab durch die App ging, sah
           deshalb nirgends, wo er stand — im Raster gar nicht, dort stand
           `flowboxchild:focus` auf nichts. `:focus-visible` heisst: nur bei
           Tastatur, nie nach einem Mausklick. Akzent in 2 Punkt mit 2 Luft,
           wie der Fokusring auf dem Mac. */
        button:focus-visible, flowboxchild:focus-visible {
            outline: 2px solid \(accent);
            outline-offset: 2px;
        }
        flowboxchild:focus-visible { border-radius: \(cornerTile)px; }
        .swiftly-groessenregler:focus-visible {
            outline: 2px solid \(accent);
            outline-offset: 0;
            border-radius: 8px;
        }

        /* MARK: Swiftly unterstuetzen (Direkt-Fassung)

           Blatt und Karte folgen dem Entwurf: Flaeche `area`, Ecke 16, drei
           Stufen als `raised`-Kacheln, der Knopf weiss wie jeder Hauptknopf.
           Kein Schatten (BRAND 4); die Abdunklung hinter dem Blatt ist der
           einzige Hinweis, dass es obenauf liegt. */
        .swiftly-stuetzgrund { background-color: rgba(0,0,0,0.62); }
        .swiftly-stuetzblatt {
            background-color: \(area);
            border: 1px solid \(margin);
            border-radius: \(cornerArea)px;
            padding: 24px;
        }
        .swiftly-stuetzmarke {
            background-color: \(raised);
            border-radius: \(cornerCapsule)px;
            color: \(font);
            font-size: 22px;
        }
        .swiftly-stufe {
            background-color: \(raised);
            border-radius: \(cornerCard)px;
            padding: 16px 8px;
        }
        .swiftly-stufe-zeichen { font-size: 30px; }
        .swiftly-stufe-name { font-size: \(body)px; font-weight: 600; }
        button.swiftly-sekundaer {
            background-image: none;
            background-color: \(raised);
            border: none;
            box-shadow: none;
            color: \(font);
            border-radius: \(corner)px;
            min-height: 44px;
            padding: 0 18px;
            font-size: \(body)px;
            font-weight: 600;
        }
        button.swiftly-sekundaer:hover { background-color: #3A3A3A; }
        button.swiftly-sekundaer:disabled label { color: \(fontVeryQuiet); }
        entry.swiftly-schluessel {
            font-family: "DejaVu Sans Mono", "Cascadia Mono", monospace;
            letter-spacing: 1px;
            min-height: 44px;
            background-color: \(raised);
        }
        entry.swiftly-gueltig, entry.swiftly-gueltig:focus-within { border: 2px solid \(accent); padding: 0 11px; }
        entry.swiftly-ungueltig, entry.swiftly-ungueltig:focus-within { border: 2px solid \(warning); padding: 0 11px; }
        .swiftly-schluesselmeldung { font-size: 13px; }
        .swiftly-schluesselmeldung.swiftly-gueltig { color: \(accent); }
        .swiftly-schluesselmeldung.swiftly-ungueltig { color: \(warning); }
        /* Das Herz in der Kopfzeile und neben der Fassung: ein Zeichen, kein
           Bildsatz — das Zeichen gibt es auf jedem System. */
        button.swiftly-herz {
            background-image: none;
            background-color: transparent;
            border: none;
            box-shadow: none;
            min-width: 40px;
            min-height: 40px;
            padding: 0;
            border-radius: \(corner)px;
        }
        label.swiftly-herz-klein { color: \(accent); }
        """
    }

    /// **The font ships with the app; it is not expected to exist.**
    ///
    /// On the Mac the UI is set in SF Pro, which exists only there. Inter is its closest
    /// relative and sits next to the app. On Linux it is often installed already, on Windows
    /// never; there the UI would fall back to Segoe UI and look different from the Mac.
    /// Since all platforms should look the same, it is registered here before the first
    /// stylesheet applies.
    ///
    /// Silent on failure: if the folder is not found, the system font stays.
    private static func bringFont() {
        guard let folder = Platform.bundled("Fonts") else { return }
        _ = folder.withCString { fonts_load($0) }
    }

    /// **What sits next to the enlarged shell grows here too.**
    ///
    /// ``Skalierung`` draws the content of the window and panels larger; the frame of a panel
    /// and the tooltip under the pointer belong to GTK itself and sit outside. Without these
    /// rules the panel would have a corner of 16 around content of 24 at 150 %. The numbers
    /// are those of the rules above (`popover.swiftly-mehr > contents`).
    /// Without a factor (the default on Linux) it stays empty.
    private static var outsideWrapper: String {
        let f = Scaling.factor
        guard f != 1 else { return "" }
        func m(_ points: Int) -> String {
            String(format: "%.1fpx", locale: Locale(identifier: "en_US_POSIX"), Double(points) * f)
        }
        return """

        popover.swiftly-mehr > contents { border-radius: \(m(cornerArea)); padding: \(m(4)) 0; }
        popover.swiftly-mehr.swiftly-kachelmenue > contents { padding: 0 0 \(m(4)) 0; }
        tooltip { padding: \(m(6)) \(m(10)); border-radius: \(m(6)); }
        tooltip label { font-size: \(m(secondLine)); }
        """
    }

    /// Loads the stylesheet into the display.
    static func apply() {
        bringFont()
        let provider = gtk_css_provider_new()
        logCssErrors(provider)
        gtk_css_provider_load_from_string(provider, sheet + lookSheet)
        if let display = gdk_display_get_default() {
            // `GtkStyleProvider` is an interface, not a type Swift can name, like `GtkEditable`.
            // So the provider is passed in as an opaque pointer.
            gtk_style_context_add_provider_for_display(
                display, OpaquePointer(provider),
                800)   // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        }
        // Kept (not released): a look change reloads this one provider.
        mainProvider = provider
        outsideLoad()
    }

    nonisolated(unsafe) private static var mainProvider: UnsafeMutablePointer<GtkCssProvider>?

    // MARK: Looks

    /// The palette the window is drawn with now.
    nonisolated(unsafe) static var palette = LookPalette.original

    /// `accent` as an `rgba()` with the given opacity, for the few places that need a
    /// translucent accent (the active sidebar row, the active account).
    static func accentAlpha(_ opacity: Double) -> String {
        String(format: "rgba(%d,%d,%d,%.2f)", locale: Locale(identifier: "en_US_POSIX"), Int((accentRGB.0 * 255).rounded()),
               Int((accentRGB.1 * 255).rounded()), Int((accentRGB.2 * 255).rounded()), opacity)
    }

    /// **Puts a look on the whole window.** The same four values the Apple versions take
    /// from `LookPalette` (accent, warning, text on accent, the play mark) and the glow;
    /// the stylesheet is rebuilt and the wordmarks redrawn. Cheap enough to run on every
    /// choice in the looks panel, which is what makes the try-on visible at once.
    static func wear(_ palette: LookPalette) {
        guard palette != Theme.palette else { return }
        Theme.palette = palette
        let accent = palette.accent
        Theme.accent = accent.main.css
        Theme.markAccent = palette.markColor.css
        Theme.warning = accent.warning?.css ?? "#E8833A"
        Theme.onAccent = accent.on.css
        Theme.accentRGB = (accent.main.red, accent.main.green, accent.main.blue)
        if let provider = mainProvider {
            gtk_css_provider_load_from_string(provider, sheet + lookSheet)
        }
        wordmarksRedraw()
    }

    private static func rgba(_ color: LookColor, _ opacity: Double) -> String {
        String(format: "rgba(%d,%d,%d,%.3f)", locale: Locale(identifier: "en_US_POSIX"), Int(color.hex >> 16) & 0xFF, Int(color.hex >> 8) & 0xFF,
               Int(color.hex) & 0xFF, opacity)
    }

    /// The glow at the top of a page, as the background of its content box, so it scrolls
    /// away with the content. The Apple layer is an elliptical gradient 1.5 times as wide
    /// as the screen, 20 % at the top edge, gone after a quarter of the height; here the
    /// reach is a fixed 280 px (a quarter of a 1080 px window), the rest is the same:
    /// one tone, and a faint second one to the right when the mark has a gradient.
    static var glowRule: String {
        let strength = palette.glow.opacity
        guard strength > 0 else { return ".swiftly-schein { background-image: none; }" }
        let tone = palette.glowColor
        var layers = [String]()
        var sizes = [String]()
        if let tint = palette.glowTint {
            layers.append("""
            radial-gradient(ellipse 60% 100% at 100% 0%, \(rgba(tint, strength * 0.36)) 0%, \
            \(rgba(tint, strength * 0.16)) 50%, \(rgba(tint, 0)) 100%)
            """)
            sizes.append("150% 280px")
        }
        layers.append("""
        radial-gradient(ellipse farthest-side at 50% 0%, \(rgba(tone, strength)) 0%, \
        \(rgba(tone, strength * 0.62)) 35%, \(rgba(tone, strength * 0.22)) 70%, \
        \(rgba(tone, 0)) 100%)
        """)
        sizes.append("150% 280px")
        return """
        .swiftly-schein {
            background-image: \(layers.joined(separator: ", "));
            background-size: \(sizes.joined(separator: ", "));
            background-position: 50% 0%;
            background-repeat: no-repeat;
        }
        """
    }

    /// Everything that depends on the look: the glow, and the supporter screens (looks
    /// panel, purchase page, thank-you, profile cards), whose light follows the look.
    static var lookSheet: String {
        func rgba(_ color: LookColor, _ opacity: Double) -> String {
            String(format: "rgba(%d,%d,%d,%.2f)", locale: Locale(identifier: "en_US_POSIX"), Int((color.red * 255).rounded()),
                   Int((color.green * 255).rounded()), Int((color.blue * 255).rounded()), opacity)
        }
        let tone = palette.glowColor
        let tint = palette.glowTint ?? tone
        let a = accentAlpha
        // The light of the looks panel (`SheetLight`): a tone ellipse at the top, a tint in
        // the top right corner, 260 high. The purchase page and the thank-you have the soft
        // glow of the home page over `reason`.
        let panel = """
        .swiftly-blatt { border-radius: \(cornerArea)px; padding: 0; border: none; }
        .swiftly-lookblatt {
            background-color: \(area);
            background-image:
                radial-gradient(ellipse 288px 156px at 100% 0%, \(rgba(tint, 0.11)) 0%, \(rgba(tint, 0.05)) 50%, transparent 100%),
                radial-gradient(ellipse 240px 130px at 50% 0%, \(rgba(tone, 0.30)) 0%, \(rgba(tone, 0.12)) 45%, \(rgba(tone, 0.03)) 75%, transparent 100%);
            background-repeat: no-repeat;
        }
        .swiftly-wachsenblatt, .swiftly-dankblatt {
            background-color: \(reason);
            background-image: radial-gradient(ellipse 360px 300px at 50% 0%, \(rgba(tone, 0.20)) 0%, \(rgba(tone, 0.07)) 55%, transparent 100%);
            background-repeat: no-repeat;
        }
        button.swiftly-blattzu, button.swiftly-pillenknopf, button.swiftly-lookspalte, button.swiftly-akzentpunkt {
            background: none; border: none; box-shadow: none; padding: 0; min-height: 0; min-width: 0;
        }
        .swiftly-lookblatt button.swiftly-blattzu { margin: 14px 10px 0 0; }
        .swiftly-wachsenblatt button.swiftly-blattzu { margin: 4px 8px 0 0; }
        .swiftly-blattzu-kreis { background-color: \(raised); border-radius: \(cornerCapsule)px; }
        .swiftly-blattzu-dunkel { background-color: rgba(0,0,0,0.4); border-radius: \(cornerCapsule)px; }
        button.swiftly-blattzu:hover .swiftly-blattzu-kreis { background-color: #3A3A3A; }

        .swiftly-s12-sehrleise { font-size: 12px; color: \(fontVeryQuiet); }
        .swiftly-s12-leise { font-size: 12px; color: \(fontQuiet); }
        .swiftly-s13-leise { font-size: 13px; color: \(fontQuiet); }
        .swiftly-s13-sehrleise { font-size: 13px; color: \(fontVeryQuiet); }
        .swiftly-s15-fett { font-size: 15px; font-weight: 600; color: \(font); }
        .swiftly-s15-leise { font-size: 15px; color: \(fontQuiet); }
        .swiftly-s17 { font-size: 17px; }
        .swiftly-s17-fett { font-size: 17px; font-weight: 600; color: \(font); }
        .swiftly-s17-hell { font-size: 17px; color: rgba(255,255,255,0.9); }
        .swiftly-s20-fett { font-size: 20px; font-weight: 600; letter-spacing: -0.2px; color: \(font); }
        .swiftly-s22-fett { font-size: 22px; font-weight: 700; color: \(font); }
        .swiftly-s28-titel { font-size: 28px; font-weight: 700; letter-spacing: -0.56px; color: \(font); }
        .swiftly-s30-titel { font-size: 30px; font-weight: 700; letter-spacing: -0.6px; color: \(font); }
        .swiftly-s15-fett.swiftly-akzentschrift { color: \(accent); }

        .swiftly-schrift { color: \(font); }
        .swiftly-leisefarbe { color: \(fontQuiet); }
        .swiftly-akzentfarbe { color: \(accent); }
        .swiftly-herzfarbe { color: \(fontQuiet); }
        button.swiftly-herz:hover .swiftly-herzfarbe { color: \(font); }

        .swiftly-glaspille {
            background-color: rgba(255,255,255,0.147);
            border: 1px solid rgba(255,255,255,0.14);
            border-radius: \(cornerCapsule)px;
            padding: 0 14px;
            min-height: 32px;
        }
        .swiftly-glaspille-text { font-size: 14px; font-weight: 600; color: \(font); }
        .swiftly-glaspille-klein { min-height: 28px; }
        .swiftly-glaspille-klein .swiftly-glaspille-text { font-size: 13px; }
        button.swiftly-pillenknopf:hover .swiftly-glaspille { background-color: rgba(255,255,255,0.22); }

        button.swiftly-lookkarte {
            background-image: none; background-color: \(groupsArea); border: none; box-shadow: none;
            border-radius: \(cornerArea)px; padding: 14px 16px; min-height: 48px;
        }
        button.swiftly-lookkarte:hover { background-color: #242424; }
        button.swiftly-lookteaser {
            background-color: transparent;
            background-image: linear-gradient(to bottom, rgba(255,255,255,0.062), rgba(255,255,255,0.063));
            border: 1px solid rgba(255,255,255,0.09);
            box-shadow: none;
            border-radius: \(cornerArea)px;
            padding: 0;
        }
        button.swiftly-lookteaser:hover { background-image: linear-gradient(to bottom, rgba(255,255,255,0.085), rgba(255,255,255,0.08)); }
        .swiftly-statuskarte {
            background-color: \(groupsArea);
            background-image: radial-gradient(circle 220px at 0% 0%, \(a(0.16)) 0%, transparent 100%);
            border-radius: \(cornerArea)px;
            padding: 14px;
        }
        .swiftly-statusherz {
            background-image: radial-gradient(circle 22px at 50% 50%, \(a(0.28)) 0%, \(a(0.06)) 100%);
            border-radius: \(cornerCapsule)px;
        }

        .swiftly-lookname { font-size: 12px; color: \(fontQuiet); }
        .swiftly-lookname-gewaehlt { font-weight: 600; color: \(font); }
        .swiftly-lookblock { background-color: rgba(48,48,48,0.6); border-radius: \(cornerArea)px; }
        .swiftly-lookblock-zeile { min-height: 52px; padding: 0 16px; }
        .swiftly-segmente { background-color: rgba(118,118,128,0.24); border-radius: 8px; padding: 2px; }
        button.swiftly-segment {
            padding: 3px 8px; border-radius: 6px; border: none; box-shadow: none;
            background: none; min-height: 0; font-size: 13px; color: \(font);
        }
        button.swiftly-segment.swiftly-aktiv { background-color: #5A5A5E; }
        button.swiftly-kapselknopf {
            background-image: none; background-color: \(area); border: none; box-shadow: none;
            border-radius: \(cornerCapsule)px; padding: 0 12px; min-height: 32px;
            font-size: 13px; font-weight: 600; color: \(font);
        }
        button.swiftly-kapselknopf:hover { background-color: #2E2E2E; }

        button.swiftly-weissknopf {
            background-image: none; background-color: #FFFFFF; border: none; box-shadow: none;
            border-radius: \(corner)px; min-height: 44px; padding: 0 16px;
            font-size: 15px; font-weight: 600;
        }
        button.swiftly-weissknopf label { color: #000000; }
        button.swiftly-weissknopf:hover { background-color: #E6E6E6; }
        button.swiftly-weissknopf:disabled { background-color: \(raised); }
        button.swiftly-weissknopf:disabled label { color: \(fontVeryQuiet); }
        button.swiftly-weissknopf-gross { min-height: 50px; font-size: 17px; }
        button.swiftly-flaechenknopf {
            background-image: none; background-color: \(area); border: none; box-shadow: none;
            border-radius: \(corner)px; min-height: 44px; font-size: 14px; font-weight: 500; color: \(font);
        }
        button.swiftly-flaechenknopf:hover { background-color: #2E2E2E; }

        button.swiftly-plankachel {
            background-image: none; background-color: \(area); box-shadow: none;
            border: 2px solid transparent; border-radius: 12px; padding: 12px; min-height: 56px;
        }
        button.swiftly-plankachel:hover { background-color: #2B2B2B; }
        button.swiftly-plankachel.swiftly-gewaehlt { border-color: \(accent); }
        .swiftly-plakette {
            font-size: 10px; font-weight: 700; letter-spacing: 0.4px;
            padding: 0 8px; min-height: 20px; border-radius: \(cornerCapsule)px;
            background-color: #FFFFFF; color: #0A0A0A;
        }
        .swiftly-plakette-dunkel { background-color: #3A3A3A; color: #FFFFFF; }
        button.swiftly-trinkgeld {
            background-image: none; background-color: \(area); box-shadow: none;
            border: 2px solid transparent; border-radius: \(cornerCapsule)px; min-height: 36px;
            font-size: 13px; font-weight: 600; color: \(font); padding: 0 8px;
        }
        button.swiftly-trinkgeld:hover { background-color: #2B2B2B; }
        button.swiftly-trinkgeld.swiftly-gewaehlt { border-color: \(accent); }
        """
        return "\n" + glowRule + "\n" + panel + "\n"
    }

    /// The provider for ``outsideWrapper``: a separate one, because its content changes
    /// when the user changes the UI size. The large sheet stays in place.
    nonisolated(unsafe) private static var outsideProvider: UnsafeMutablePointer<GtkCssProvider>?

    /// At startup and after every change of the factor.
    static func outsideLoad() {
        if outsideProvider == nil, let display = gdk_display_get_default() {
            let new = gtk_css_provider_new()
            logCssErrors(new)
            // One above the large sheet: with equal specificity the rule from here wins.
            gtk_style_context_add_provider_for_display(display, OpaquePointer(new), 801)
            outsideProvider = new
        }
        guard let provider = outsideProvider else { return }
        gtk_css_provider_load_from_string(provider, outsideWrapper)
    }

    /// **GTK does not report a stylesheet error on the error stream** but via the
    /// `parsing-error` signal; without a listener nothing is noticed. A syntax GTK does not
    /// know silently has no effect, and the search starts at the wrong widget.
    static func logCssErrors(_ provider: UnsafeMutablePointer<GtkCssProvider>!) {
        g_signal_connect_data(UnsafeMutableRawPointer(provider), "parsing-error",
                              unsafeBitCast(styleError, to: GCallback.self),
                              nil, nil, GConnectFlags(rawValue: 0))
    }

    // MARK: Wordmark

    static func wordmarkForget(_ handle: Int) { wordmarkPictures[handle] = nil }

    /// Writes the wordmark once as an SVG file and returns the path.
    ///
    /// The path itself comes from `MarksPaths` in the shared package, the same string the
    /// Apple versions build their vector shape from. GTK reads SVG through librsvg; if that
    /// is missing, there is a text fallback.
    static func wordmarkFile(height: Int) -> String? {
        let r = MarksPaths.wordmarkFrame
        // The play mark takes the look's gradient (the whole palette's list, flat for one).
        let tones = palette.logoGradient.map { $0.css }
        var defs = ""
        var fill = markAccent
        if tones.count > 1 {
            let step = 100.0 / Double(tones.count - 1)
            let stops = tones.enumerated().map { spot, tone in
                "<stop offset=\"\(Int(Double(spot) * step))%\" stop-color=\"\(tone)\"/>"
            }.joined()
            defs = "<defs><linearGradient id=\"m\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">\(stops)</linearGradient></defs>"
            fill = "url(#m)"
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" \
        viewBox="\(r.x) \(r.y) \(r.width) \(r.height)" \
        width="\(Int(Double(height) * r.width / r.height))" height="\(height)">
        \(defs)
        <path d="\(MarksPaths.wordmark)" fill="\(font)"/>
        <path d="\(MarksPaths.wordmarkAccent)" fill="\(fill)"/>
        </svg>
        """
        // One file per look, so a look change never reads a stale picture from the loader.
        let key = tones.joined().replacingOccurrences(of: "#", with: "")
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftly-wortmarke-\(height)-\(key).svg")
        do {
            try svg.write(to: target, atomically: true, encoding: .utf8)
            return target.path
        } catch {
            return nil
        }
    }

    /// The wordmark pictures alive now, with the height they were built at, so a look
    /// change can swap their file.
    nonisolated(unsafe) private static var wordmarkPictures: [Int: (Widget, Int)] = [:]

    private static func wordmarksRedraw() {
        for (_, entry) in wordmarkPictures {
            if let file = wordmarkFile(height: entry.1) { gtk_picture_set_filename(OpaquePointer(entry.0), file) }
        }
    }

    /// The wordmark as a widget, at the requested height.
    ///
    /// **44 on sign-in, 28 in the sidebar**, as in `Sources/macOS/RootView.swift` and
    /// `MainView.swift`.
    ///
    /// **Two traps in a row.**
    ///
    /// `GtkImage` honors its size only for symbols; a loaded file is shown at its own size.
    /// So `GtkPicture`.
    ///
    /// But `gtk_widget_set_size_request` sets only a **minimum** size. A `GtkPicture` grows
    /// beyond it when space is available, which made the mark 2.5 times too large. It also
    /// needs `hexpand`/`vexpand` off and an alignment, otherwise it takes whatever the stack
    /// offers.
    ///
    /// The width follows the aspect ratio of the frame (3005 to 1024, about 2.94 to 1).
    static func wordmark(height: Int = 44, left: Bool = false) -> Widget! {
        let r = MarksPaths.wordmarkFrame
        let width = Int(Double(height) * r.width / r.height)
        // Built at double resolution so it stays sharp on high-density screens.
        guard let file = wordmarkFile(height: height * 2) else {
            return label("swiftly", style: "swiftly-titel-gross")
        }
        // **The double-resolution build was also the trap.** The mark appeared twice as large
        // because `set_size_request` is only a minimum and a 164 x 56 image claims exactly that
        // once space is available. The overlay measures only its main child, the same remedy as
        // for posters, see ``framedImage``.
        let wrapper: Widget! = gtk_overlay_new()
        let mass: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_set_size_request(mass, Int32(width), Int32(height))
        gtk_overlay_set_child(OpaquePointer(wrapper), mass)

        let image: Widget! = gtk_picture_new_for_filename(file)
        let handle = Int(bitPattern: image)
        wordmarkPictures[handle] = (image, height * 2)
        g_signal_connect_data(UnsafeMutableRawPointer(image), "destroy",
                              unsafeBitCast(wordmarkGone, to: GCallback.self),
                              UnsafeMutableRawPointer(bitPattern: handle), nil, GConnectFlags(rawValue: 0))
        gtk_picture_set_content_fit(OpaquePointer(image), GTK_CONTENT_FIT_CONTAIN)
        gtk_picture_set_can_shrink(OpaquePointer(image), 1)
        gtk_overlay_add_overlay(OpaquePointer(wrapper), image)

        gtk_widget_set_hexpand(wrapper, 0)
        gtk_widget_set_vexpand(wrapper, 0)
        gtk_widget_set_halign(wrapper, left ? GTK_ALIGN_START : GTK_ALIGN_CENTER)
        gtk_widget_set_valign(wrapper, GTK_ALIGN_CENTER)
        return wrapper
    }
}


/// Signature: `(GtkCssProvider*, GtkCssSection*, GError*, gpointer)`.
nonisolated(unsafe) let styleError: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutablePointer<GError>?, gpointer?
) -> Void = { _, segment, error, _ in
    let text = error?.pointee.message.map { String(cString: $0) } ?? "unbekannt"
    let spot = segment.map { String(cString: gtk_css_section_to_string($0)) } ?? "?"
    FileHandle.standardError.write(Data("[Stilblatt] \(spot): \(text)\n".utf8))
}

/// `destroy` of a wordmark picture: forget it. Signature `(GtkWidget*, gpointer)`.
nonisolated(unsafe) let wordmarkGone: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    Theme.wordmarkForget(Int(bitPattern: data))
}
