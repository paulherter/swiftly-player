import JellyfinKit
import SwiftUI

// MARK: - Fokus in eigenen Knopfstilen

/// Warum `@Environment(\.isFocused)` und nicht `@FocusState`:
///
/// `FocusState` gehört der Ansicht, die es hält — für einen Stil, der auf
/// jeder Seite wiederverwendet wird, müsste jede Seite ihre eigene Marke
/// führen und durchreichen. `isFocused` steht dagegen in der Umgebung des
/// Knopfes selbst, und SwiftUI setzt es genau dort, wo `makeBody` läuft.
/// Der Stil weiß damit von allein Bescheid.
///
/// Der Umweg über eine innere Ansicht ist nötig: `makeBody` ist eine
/// Funktion, keine Ansicht — `@Environment` darin gelesen bliebe leer.

/// Der Knopf: ruhend gedämpfte Fläche, fokussiert weiß.
///
/// Die fokussierte Fassung ist Zeichen für Zeichen der `HauptknopfStil` vom
/// iPhone. Das ist kein Zufall, sondern der Übersetzungsschlüssel: was dort
/// „das ist die Haupthandlung" heißt, heißt hier „hier steht die
/// Fernbedienung".
struct KnopfStil: ButtonStyle {
    /// Ohne Beschriftung, nur ein Symbol — dann quadratisch statt breit.
    var nurSymbol = false
    /// **Niedriger, wo der Knopf nicht die Hauptsache ist.**
    ///
    /// Die Staffelpille steht neben einem Reihentitel, nicht in der Knopfreihe
    /// des Kopfes. Mit den vollen 76 wirkte sie dort wuchtig Die Farben und
    /// das Fokusverhalten bleiben trotzdem dieselben; genau die waren der
    /// Grund, sie ueberhaupt auf diesen Stil zu ziehen.
    var hoehe: CGFloat = Stil.knopfHoehe
    /// **Aktiv traegt nur das Zeichen den Akzent** — wie am iPhone (Merkliste
    /// an): keine eigene Flaeche, die Flaeche bleibt wie bei den Nachbarn.
    /// Im Fokus nicht: auf der weissen Fokusflaeche steht `grund`.
    var aktiv = false

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, nurSymbol: nurSymbol, hoehe: hoehe, aktiv: aktiv)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let nurSymbol: Bool
        let hoehe: CGFloat
        let aktiv: Bool
        @Environment(\.isFocused) private var fokus
        @Environment(\.isEnabled) private var freigegeben

        var body: some View {
            configuration.label
                .font(Stil.knopf)
                // Ein Knopf, der umbricht, wird höher als seine Nachbarn und
                // reißt die ganze Reihe schief. Lieber kurz beschriften.
                .lineLimit(1)
                .foregroundStyle(vordergrund)
                .padding(.horizontal, nurSymbol ? 0 : (hoehe < Stil.knopfHoehe ? 28 : 40))
                .frame(width: nurSymbol ? hoehe : nil, height: hoehe)
                .background(hintergrund, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                // Fokus hebt die Pille heraus — dieselbe Stufe wie die
                // Kachel. Hier stand 1,04 mit der Begruendung, ein Knopf stehe
                // in einer Reihe mit Nachbarn, die ihre Hoehe halten muessen.
                // Das stimmt fuer das Layout nicht: `scaleEffect` rechnet nach
                // dem Setzen und verschiebt keinen Nachbarn. Uebrig blieb ein
                // Knopf, der sich weniger meldete als alles um ihn herum.
                .scaleEffect(configuration.isPressed ? 0.97 : (fokus ? Stil.fokusLupe : 1))
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// Gesperrt heißt gedämpft, nicht durchscheinend — dieselbe Begründung
        /// wie auf iOS: Weiß auf 40 Prozent sieht aus wie ein Knopf, der noch
        /// wartet, statt wie einer, der nicht reagiert.
        private var vordergrund: Color {
            guard freigegeben else { return Stil.schriftSehrLeise }
            if fokus { return Stil.grund }
            return aktiv ? Stil.akzent : Stil.schrift
        }

        private var hintergrund: Color {
            guard freigegeben else { return Stil.flaeche }
            return fokus ? .white : Color.white.opacity(0.10)
        }
    }
}

/// Die Kachel: fokussiert wird sie größer. Sonst nichts.
///
/// Zwei Versuche davor lagen daneben — erst ein Akzentring, dann eine graue
/// Fläche ringsum. Beide taten der Kachel etwas **hinzu**, und beide sahen an
/// zwei Einzelkacheln sauber aus und in einer Reihe mit sechs Nachbarn
/// matschig.
///
/// Was bleibt, ist die Entfernung: die fokussierte Kachel steht näher. Das
/// ist auch das Einzige, was ohne Zierde auskommt — und die Gestaltung sagt,
/// das Bildmaterial soll die einzige Farbe im Raum sein.
///
/// Ausdrücklich nicht `.buttonStyle(.card)`: Apples Karte bringt Schatten,
/// Parallaxe und ein Aufblitzen mit.
struct KachelStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus
        @Environment(\.kachelVorladen) private var vorladen

        var body: some View {
            configuration.label
                .scaleEffect(fokus ? Stil.fokusLupe : 1)
                .animation(Stil.fokusAnimation, value: fokus)
                // **Vor dem Klick den Stand der Serie holen**, entprellt:
                // wer durch eine Reihe wischt, loest nichts aus; wer 150 ms
                // auf einer Kachel steht, hat den Stand meist schon, wenn er
                // drueckt — und der Hauptknopf der Serienseite nennt sofort
                // die richtige Folge.
                .task(id: fokus) {
                    guard fokus, let vorladen else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await vorladen()
                }
        }
    }
}

extension EnvironmentValues {
    /// Was eine Kachel vorlaedt, wenn sie den Fokus haelt — gesetzt von
    /// `Kachelmenue`, gelesen von `KachelStil`.
    @Entry var kachelVorladen: (@MainActor () async -> Void)? = nil
}

/// Reiter der Kopfleiste. Drei Zustände statt zwei: ruhend, gewählt,
/// fokussiert — auf iOS gibt es den mittleren nicht, weil der Finger dort
/// steht, wo er hinzeigt.
struct ReiterStil: ButtonStyle {
    let gewaehlt: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, gewaehlt: gewaehlt)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let gewaehlt: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                // **Der Fokus traegt die Auswahl nicht mit.**
                //
                // Auf dem Fernseher zeigt Farbe, was gewaehlt ist — VoiceOver
                // sieht Farbe nicht. Ohne diese Angabe klingt der offene
                // Reiter wie jeder andere.
                .accessibilityAddTraits(gewaehlt ? [.isButton, .isSelected] : .isButton)
                .font(.system(size: 30, weight: fokus || gewaehlt ? .semibold : .medium))
                .foregroundStyle(vordergrund)
                .padding(.horizontal, 26)
                .padding(.top, 10)
                .padding(.bottom, 18)
                // Leise, nicht laut: weil der Fokus hier selbst umschaltet,
                // sind „fokussiert" und „offen" dasselbe. Für eine einzige
                // Aussage wäre eine volle weiße Fläche zu viel Werkzeug.
                .background {
                    if fokus {
                        RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    }
                }
                .scaleEffect(fokus ? Stil.fokusLupe : 1)
                .overlay(alignment: .bottom) {
                    // Der Akzentstrich kommt unverändert aus `Reiter` in
                    // Stil.swift — dort 2 Punkt, hier 4.
                    if gewaehlt {
                        Capsule().fill(Stil.akzent)
                            .frame(height: 4)
                            .padding(.horizontal, 26)
                            .padding(.bottom, 6)
                    }
                }
                .animation(Stil.fokusAnimation, value: fokus)
        }

        private var vordergrund: Color {
            if fokus || gewaehlt { return Stil.schrift }
            return Stil.schriftSehrLeise
        }
    }
}

/// Filterchip. Der einzige Ort, an dem Fokus und Auswahl aufeinandertreffen —
/// deshalb bekommt der fokussierte, gewählte Chip zusätzlich den Ring.
struct ChipStil: ButtonStyle {
    let an: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, an: an)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                // **Der Fokus traegt die Auswahl nicht mit.**
                //
                // Auf dem Fernseher zeigt Farbe, was gewaehlt ist — VoiceOver
                // sieht Farbe nicht. Ohne diese Angabe klingt der offene
                // Reiter wie jeder andere.
                .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
                // **Ein Gewicht, zwei Fuellungen** — wie auf dem iPhone.
                //
                // Gewaehlt war hier `grund` auf weisser Flaeche, also Zeichen
                // fuer Zeichen der Hauptknopf; auf einer Seite mit mehreren
                // Chips sind das mehrere vollflaechig gefuellte Gegenstaende,
                // und BRAND 5 laesst genau einen zu. Der Gewichtswechsel kam
                // dazu: Semifett ist breiter, und in einer waagerechten Reihe
                // verschiebt das jeden Nachbarn rechts davon.
                //
                // Der Rand faellt mit weg. Eine Flaeche sagt „hier kann man
                // druecken"; der Fokus sagt den Rest.
                .font(Stil.kachel)
                .foregroundStyle(an ? Stil.grund : Stil.schriftLeise)
                .padding(.horizontal, 22)
                .frame(height: Stil.chipHoehe)
                .background(flaeche, in: Capsule())
                .scaleEffect(fokus ? Stil.fokusLupe : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// **Die Wahl traegt hier den Akzent, und das ist eine Ausnahme.**
        ///
        /// Erst stand hier `Stil.schrift`, eine weisse Flaeche — richtig,
        /// solange die Schrift darauf `grund` war. Die Schrift wechselte auf
        /// Weiss, die Zeile blieb stehen: **weiss auf weiss**, der gewaehlte
        /// Filter war nicht mehr zu lesen.
        ///
        /// Dann eine Stufe hoeher, `erhoeht` gegen `flaeche`, wie am iPhone.
        /// Lesbar, aber die beiden Toene liegen #303030 gegen #262626
        /// auseinander — am Schreibtisch erkennbar, auf drei Meter nicht.
        /// „Ich koennte dir nicht sagen, dass das an ist."
        ///
        /// **Die Entfernung ist der Grund, aus dem der Fernseher abweichen
        /// darf** (Abschnitt F). Eine Helligkeitsstufe ueberlebt drei Meter
        /// nicht, ein Farbwechsel schon. Der gewaehlte Chip ist deshalb eine
        /// Akzentkapsel mit `grund` darauf — 10,8:1, und die Farbe kommt in
        /// der Reihe sonst nirgends vor.
        ///
        /// Dem Fokus nimmt das nichts weg: er ist hier keine weisse Flaeche,
        /// sondern ein heller Schleier plus 6 Prozent Groesse. Auf dem
        /// gewaehlten Chip tritt an die Stelle des Schleiers der helle
        /// Akzent, damit auch er im Fokus aufhellt statt stehen zu bleiben.
        private var flaeche: Color {
            if an { return fokus ? Stil.akzentHell : Stil.akzent }
            return fokus ? Stil.fokusflaeche : Stil.flaeche
        }
    }
}

/// **Der Strich zwischen der Wahl und ihren Einstellungen** in einer
/// Kapselreihe — Bibliothek | Filter, Sortierung auf Filme und Serien,
/// Gattung | Sortierung auf der Merkliste. Einmal hier, damit beide Reihen
/// denselben Strich tragen.
struct Kapseltrenner: View {
    var body: some View {
        Rectangle()
            .fill(Stil.rand)
            .frame(width: 2, height: Stil.chipHoehe * 0.6)
            .accessibilityHidden(true)
    }
}

/// **Eine Kapsel, die etwas aufklappt** — Bibliothek und Sortierung in der
/// Chipreihe der Bibliothek.
///
/// Dieselbe Form wie `ChipStil`, damit die Reihe eine Form hat. Was sie vom
/// nicht gewaehlten Filter unterscheidet: halbfette Schrift und der Pfeil.
/// Der Pfeil gehoert deshalb in den Stil und nicht in jedes Etikett.
///
/// Der Pfeil traegt Deckkraft, keine eigene Farbe — er folgt der Schrift.
/// Mit fester Farbe verschwand er im Sortierknopf auf der weissen
/// Fokusflaeche.
struct KapselStil: ButtonStyle {
    /// **Ein Zeichen vorn statt des Pfeils hinten — wie die `Wertpille` am
    /// iPhone.** Filter und Sortierung stehen dort als Pille mit Zeichen und
    /// Wert, ohne Pfeil; der Pfeil gehoert dort nur zur Bibliothekswahl am
    /// Titel. Rückmeldung vom 22.09.: „auch mit diesem Symbol, wie auf dem Handy, so
    /// dass es identisch aussieht." `nil` heisst: der Pfeil wie bisher.
    var symbol: String? = nil
    /// Der Pfeil hinten — nach unten, weil die Kapsel etwas aufklappt. Nach
    /// rechts, wo sie auf eine Seite fuehrt („Teil der Sammlung").
    var pfeil = "chevron.down"

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, symbol: symbol, pfeil: pfeil)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let symbol: String?
        let pfeil: String
        @Environment(\.isFocused) private var fokus

        var body: some View {
            HStack(spacing: 10) {
                if let symbol {
                    // Leiser als der Wert, wie am iPhone (`schriftLeise`
                    // gegen `schrift`) — ueber Deckkraft, damit es der
                    // Schrift auch auf der Fokusflaeche folgt.
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .medium))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
                configuration.label
                    .lineLimit(1)
                if symbol == nil {
                    Image(systemName: pfeil)
                        // Halbfett, nicht fett: Bold steht genau einmal, am
                        // Seitentitel (BRAND 2).
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
            // Dieselbe Stufe wie der `ChipStil` daneben — es ist derselbe Chip.
            .font(Stil.kachel)
            .foregroundStyle(Stil.schrift)
            .padding(.horizontal, 22)
            .frame(height: Stil.chipHoehe)
            .background(fokus ? Stil.fokusflaeche : Stil.erhoeht, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : (fokus ? Stil.fokusLupe : 1))
            .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}

/// **Eine Zeile in der Einstellungsleiste des Players.**
///
/// Wie `ChipStil`, nur ueber die volle Breite und mit eckigen Ecken statt
/// einer Kapsel: die Leiste ist eine Liste, keine Reihe von Marken. Auswahl
/// ist wieder Weiss, Fokus die ruhige Flaeche -- dieselbe Regel wie ueberall,
/// damit die Leiste sich nicht wie ein Fremdkoerper liest.
struct LeistenStil: ButtonStyle {
    let an: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, an: an)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
                .foregroundStyle(an ? Stil.grund : Stil.schrift)
                .background(flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                // Eine Zeile ueber die ganze Leistenbreite: die breite Stufe.
                .scaleEffect(fokus ? Stil.fokusLupeBreit : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// **Hier bleibt die weisse Fuellung**, anders als am Filterchip.
        ///
        /// Die Leiste oben ist auf dem Fernseher, was die Leiste unten am
        /// iPhone ist: die Stelle, an der man sieht, wo man ist. Ihre Schrift
        /// ist `grund` auf Weiss und damit lesbar — der Fehler von gestern
        /// betraf allein den Filterchip, dessen Schrift auf Weiss gewechselt
        /// hat, waehrend seine Flaeche weiss blieb.
        private var flaeche: Color {
            if an { return Stil.schrift }
            return fokus ? Stil.fokusflaeche : .clear
        }
    }
}

/// Zeile in einer Auswahlliste — Spurwahl, Einstellungen.
struct ZeilenStil: ButtonStyle {
    /// **Eine Nebenhandlung — leiser, aber nur solange sie ruht.**
    ///
    /// „Verlauf loeschen" und aehnliche Zeilen faerbten sich bisher an der
    /// Aufrufstelle grau, und zwar auch im Fokus: auf der Fokusflaeche
    /// (Weiss 12 %) stand `schriftSehrLeise` dann mit 3,59:1 da —
    /// ausgerechnet die Zeile, auf der man steht, war die am schlechtesten
    /// lesbare. Hier gehoert es hin, weil nur der Stil den Fokus kennt.
    var leise = false

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, leise: leise)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let leise: Bool
        @Environment(\.isFocused) private var fokus
        @Environment(\.isEnabled) private var freigegeben

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: fokus ? .semibold : .medium))
                .foregroundStyle(vordergrund)
                .padding(.horizontal, 26)
                .frame(height: Stil.zeilenHoehe)
                .frame(maxWidth: .infinity, alignment: .leading)
                // **Erst Abstand und Hoehe, dann die Flaeche.**
                //
                // Andersherum umschliesst sie die Schrift statt die Zeile:
                // die Umrandung klebte am Text und der Abstand lag aussen
                // herum. Auf den breiten Einstellungszeilen fiel es kaum auf,
                // in der schmalen Handlungstafel sofort.
                //
                // Dieselbe ruhige Flaeche wie ueberall sonst, nicht Weiss.
                // Weiss bleibt den Handlungsknoepfen vorbehalten.
                .background(fokus ? Stil.fokusflaeche : Color.clear,
                            in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// **Gesperrt heisst gedaempft** — dieselbe Regel wie am `KnopfStil`
        /// nebenan. Sie fehlte hier: „Immer Direct Play" im Bereich
        /// Wiedergabe und die Bitratenzeile sind gesperrt, sahen aber aus wie
        /// jede andere Zeile. Wer sie anfaehrt, bekommt keinen Fokus und
        /// keine Erklaerung — heute ist genau daran der Startfokus des
        /// Bereichs ins Leere gesprungen.
        private var vordergrund: Color {
            guard freigegeben else { return Stil.schriftSehrLeise }
            if fokus { return Stil.schrift }
            return leise ? Stil.schriftLeise : Stil.schrift
        }
    }
}

// MARK: - Kachel

/// Der Inhalt einer Kachel — Bild, Titel, Nebenzeile.
///
/// Bewusst **kein** Knopf: mal führt eine Kachel auf eine Seite
/// (`NavigationLink`), mal startet sie sofort die Wiedergabe (`Button`). Wer
/// sie benutzt, wählt den Auslöser und legt `KachelStil()` darüber.
struct Kachelinhalt: View {
    let bild: URL?
    let titel: String
    var unterzeile: String?
    /// Waagerecht 16:9 statt hochkant 2:3 — nur für „Weiterschauen".
    var quer = false
    var fortschritt: Double?
    /// Im Gitter trägt die Kachel nur ihren Titel; die Nebenzeile wäre dort
    /// eine Zeile Rauschen mal vierzehn.
    var mitUnterzeile = true
    /// Was oben rechts steht: gesehen, offene Folgen, Staffelzahl.
    ///
    /// **Drei Zustaende, drei Zeichen** (GESTALTUNG, Abschnitt H). Bis
    /// hierher gab es nur den Balken — und bei einer Serie sagt der gar
    /// nichts, weil er den Stand der angefangenen *Folge* zeigt.
    var marke: Kachelmarke?
    /// **Gesehen: Bild abgedunkelt, Titel leise** — dieselbe Bildsprache wie
    /// die Folgenzeile auf dem iPhone. Der Haken kommt über `marke`.
    var gesehen = false
    /// **Ein Ersatz fuer das Bild** — nur an einer Sammlung ohne eigenes
    /// Plakat. Ueberall sonst `nil`, und hier steht genau das Bild wie
    /// vorher.
    ///
    /// Der Typ steht fest, statt `AnyView`: es gibt nur diesen einen Ersatz,
    /// und SwiftUI kann so vergleichen, statt jede Zelle neu aufzubauen.
    var ersatz: Sammlungsmosaik? = nil
    /// Das Zeichen, wenn kein Bild kommt — `Item.kachelzeichen`.
    var zeichen: String? = nil

    private var breite: CGFloat { quer ? Stil.querBreite : Stil.posterBreite }
    private var hoehe: CGFloat { quer ? Stil.querHoehe : Stil.posterHoehe }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let ersatz {
                    ersatz
                } else {
                    Bild(url: bild, breite: breite, hoehe: hoehe, fortschritt: fortschritt,
                         zeichen: zeichen)
                }
            }
                // **Multipliziert, nicht durchsichtig** — wie `Gesehenhaken`
                // auf dem iPhone. Mit `opacity` schien der Grund durch, und
                // auf einer Serienseite in Bildfarbe bekam jedes gesehene
                // Standbild deren Stich. So wird es nur dunkler.
                .colorMultiply(Color(white: gesehen ? 0.45 : 1))
                .overlay(alignment: .topTrailing) {
                    if let marke { Kachelplakette(marke: marke) }
                }

            Text(titel)
                .font(Stil.kachel)
                .foregroundStyle(gesehen ? Stil.schriftLeise : Stil.schrift)
                .lineLimit(1)
                .padding(.top, 14)

            if mitUnterzeile, let unterzeile {
                Text(unterzeile)
                    .font(Stil.klein)
                    .monospacedDigit()
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: breite, alignment: .leading)
        // **Eine Kachel ist eine Aussage, nicht drei.**
        //
        // Ohne das liest VoiceOver Titel und Nebenzeile als getrennte Stuecke
        // vor, und der Fortschrittsbalken faellt ganz heraus — er ist eine
        // Zeichnung im Bild. „Zur Haelfte gesehen" stand also nur da, wer
        // hinsah.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(beschriftung))
        .accessibilityValue(fortschrittText.map(Text.init) ?? Text(""))
    }

    private var beschriftung: String {
        var teile = [titel]
        if mitUnterzeile, let unterzeile { teile.append(unterzeile) }
        // Die Marke ist eine Zeichnung im Bild und fiele fuer die
        // Sprachausgabe sonst heraus — dieselbe Ueberlegung wie beim Balken.
        if let marke {
            switch marke {
            case .gesehen: teile.append(String(localized: "gesehen"))
            case .offen(let n): teile.append(String(localized: "\(n) offen"))
            case .staffeln(let n): teile.append(n == 1 ? String(localized: "1 Staffel")
                                                       : String(localized: "\(n) Staffeln"))
            }
        }
        return teile.joined(separator: ", ")
    }

    /// Der Balken in Worten. Erst ab einem Prozent — darunter hat noch
    /// niemand etwas gesehen, und „null Prozent gesehen" ist keine Auskunft.
    private var fortschrittText: String? {
        guard let fortschritt, fortschritt >= 0.01 else { return nil }
        return String(localized: "\(Int(fortschritt * 100)) Prozent gesehen")
    }
}

// MARK: - Kopfleiste

/// Die vier Bereiche — oben, nicht unten. Auf tvOS führt die Navigation oben,
/// und eine Leiste am unteren Rand wäre unerreichbar weit vom Blick weg.
enum Bereich: Int, CaseIterable, Identifiable {
    case start, filme, serien, merkliste, suche
    var id: Int { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .start:     "Start"
        case .filme:     "Filme"
        case .serien:    "Serien"
        case .merkliste: "Merkliste"
        case .suche:     "Suche"
        }
    }
}

/// Wortmarke links, Reiter daneben, Profil rechts.
///
/// Bewusst linksbündig und nicht mittig wie bei Apple: die ganze App ist
/// linksbündig gesetzt, und die Wortmarke gehört an den Anfang der Zeile.
struct Kopfleiste: View {
    @Binding var bereich: Bereich
    let model: AppModel
    var aufsProfil: () -> Void
    /// Was auf anderen Geräten läuft.
    var uebernahme: [Fremdsitzung] = []
    /// Offene Gruppen, denen man beitreten kann (Entwurf A: dasselbe
    /// Abzeichen, mit Zähler).
    var gruppen: [SyncPlayGruppe] = []
    var abzeichenGedrueckt: () -> Void
    /// Zählt hoch, wenn eine Tafel des Abzeichens zugeht — dann gehört der
    /// Fokus wieder ihm (VERHALTEN E5: eine Tafel ist kein Ortswechsel).
    var abzeichenFokus = 0
    /// Zählt hoch nach einem Kontowechsel aus der Profilauswahl: dann steht
    /// der Fokus auf dem Profilbild, und ein Druck öffnet das Profil wieder
    /// (Entwurf D: „Profil sofort wieder erreichbar").
    var profilFokus = 0

    /// Welcher Reiter gerade den Fokus hat — `nil`, sobald er im Inhalt steht.
    @FocusState private var amReiter: Bereich?
    @FocusState private var amAbzeichen: Bool
    @FocusState private var amProfil: Bool
    @State private var profilNachziehen: Task<Void, Never>?
    /// Gesperrt, sobald wieder eine Seite darüberliegt (`leisteDa`) — dann
    /// holt das Nachfassen den Fokus nicht mehr her.
    @Environment(\.isEnabled) private var freigegeben

    var body: some View {
        HStack(spacing: 56) {
            Wortmarke(hoehe: 48)

            HStack(spacing: 8) {
                // **Die Merkliste ist wieder ein Reiter.** Am 22.09. zog sie
                // fuer eine Stunde als runder Knopf neben das Profilbild;
                // zwei Kreise nebeneinander wirkten „ein bisschen matsch",
                // und sie wurde zurueckgeholt. Als Wort in der Leiste
                // steht sie zwischen den anderen Bereichen, wo man sie sucht.
                ForEach(Bereich.allCases) { b in
                    Button { bereich = b } label: { Text(b.name) }
                        .buttonStyle(ReiterStil(gewaehlt: bereich == b))
                        .focused($amReiter, equals: b)
                }
            }
            .focusSection()
            // **Der Klick schaltet, nicht der Fokus.**
            //
            // Andersherum war es eine Runde lang gebaut, weil es auf tvOS
            // üblich ist — aber es setzt voraus, dass der Fokus von unten
            // verlässlich auf dem offenen Reiter landet. Das tut er nicht:
            // tvOS sucht geometrisch, und drei Anläufe, ihn umzulenken,
            // haben entweder nicht gewirkt, sichtbar geflackert oder die
            // Leiste ganz unerreichbar gemacht.
            //
            // Mit dem Klick als Schalter ist die geometrische Landung
            // harmlos: man steht dann eben auf „Suche", ohne dort zu sein.

            Spacer(minLength: 0)

            // **Links vom Profilbild, und nur wenn es etwas gibt.**
            //
            // Ein Abzeichen, das immer dasteht und meistens nichts sagt, ist
            // Ausstattung. Dieses erscheint, wenn woanders etwas läuft, und
            // verschwindet wieder — deshalb steht es auch nicht im Fokusweg,
            // solange es nichts anzubieten hat.
            //
            // **Eigenes, engeres Raster fuer die beiden rechts.**
            //
            // Die Leiste steht auf 56 Punkt Abstand — richtig zwischen
            // Wortmarke und Reitern, zu viel zwischen Abzeichen und
            // Profilbild. Die zwei gehoeren zusammen; getrennt sah es aus,
            // als haette das Abzeichen keinen Platz gefunden.
            HStack(spacing: 18) {
                if !uebernahme.isEmpty || !gruppen.isEmpty {
                    Angebotsabzeichen(weiterschauen: uebernahme, gruppen: gruppen,
                                      aktion: abzeichenGedrueckt)
                        .focused($amAbzeichen)
                        // Die Auswahl wächst von hier aus (`Abzeichenursprung`).
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            Abzeichenursprung.punkt = CGPoint(x: $0.midX, y: $0.midY)
                        }
                        .focusSection()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Button(action: aufsProfil) {
                    let bild = model.benutzerbildURL()
                    Profilzeichen(name: model.session?.userName ?? "?",
                                  bild: bild,
                                  groesse: 60,
                                  ohneBild: bild.map { Kontowechselflug.geteilt.ohneBild.contains($0) } ?? false)
                        // **Je Bildadresse eine eigene Ansicht** — sonst
                        // stünde bei der Landung kurz das alte Profilbild da
                        // (wie `Profilziel` am iPhone).
                        .id(bild)
                        // Während das neue Profilbild hierher fliegt, steht
                        // hier noch keins.
                        .opacity(Kontowechselflug.geteilt.flug.map { $0.ersetzt } ?? true ? 1 : 0)
                }
                .buttonStyle(ProfilStil())
                .focused($amProfil)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rahmen in
                    Kontowechselflug.geteilt.zielMelden(rahmen)
                }
                // Ein Bild ohne Beschriftung ist eine namenlose Taste.
                .accessibilityLabel(Text("Profil und Einstellungen"))
                .focusSection()
            }
        }
        .padding(.horizontal, Stil.randSeite)
        // Oben und seitlich der sichere Bereich, damit die Abstände
        // zueinander passen. Siehe `Stil.leisteOben`.
        .frame(height: Stil.leisteHoehe)
        .padding(.top, Stil.leisteOben)
        // Waagerecht mit: die Leiste liegt ueber dem Bereichsstapel und
        // bekaeme dessen Randfreiheit sonst nicht ab. Die Wortmarke stuende
        // dann 80 Punkt weiter innen als der Inhalt darunter — genau die
        // Sorte Fehler, die man erst sieht, wenn sie einem auffaellt.
        .ignoresSafeArea(edges: [.top, .horizontal])
        .animation(Stil.bewegung(.easeInOut(duration: 0.25)), value: uebernahme.map(\.id))
        .animation(Stil.bewegung(.easeInOut(duration: 0.25)), value: gruppen.map(\.id))
        .onChange(of: abzeichenFokus) { _, _ in amAbzeichen = true }
        // **Und nachgefasst.** Die Leiste wird im selben Zug erst wieder
        // fokussierbar (`leisteDa`), und SwiftUI verwirft eine Zuweisung in
        // diesem Durchlauf — dieselbe Lehre wie im Player.
        .onChange(of: profilFokus) { _, _ in
            amProfil = true
            profilNachziehen?.cancel()
            profilNachziehen = Task { @MainActor in
                for warten in [80, 250, 600] {
                    try? await Task.sleep(for: .milliseconds(warten))
                    // Sitzt er einmal, oder ist inzwischen das Profil offen,
                    // wird nicht nachgefasst — sonst holte ein später Takt
                    // den Fokus von dort zurück, wohin man gerade ging.
                    guard !Task.isCancelled, freigegeben else { return }
                    if amProfil { break }
                    amProfil = true
                }
                Protokoll.schreib("[Fokus] Profilbild oben nach Kontowechsel: \(amProfil)")
            }
        }
        #if DEBUG
        .onChange(of: amProfil) { _, jetzt in
            if Kontowechsellauf.an { Kontowechselflug.notiz("fokus: profilbild oben \(jetzt) · leiste frei \(freigegeben)") }
        }
        #endif
    }
}

// `Uebernahmeabzeichen` ist seit 1.0.5 `Angebotsabzeichen` in
// `TVGemeinsam.swift`: dasselbe Abzeichen, jetzt auch für offene Gruppen.
//
// **Bewusst mit Gerätenamen und Titel, nicht nur als Zeichen** — das gilt
// weiter. Ein Symbol allein wirft die Frage auf, was es tut; wer es dann
// drückt, hält versehentlich seinen Film auf dem anderen Gerät an.

/// Derselbe Ruhe-zu-Fokus-Sprung wie überall auf dem Fernseher: in Ruhe eine
/// ruhige Fläche, im Fokus die helle.
///
/// **Kühl, wenn es von einem anderen Gerät kommt.** Das Abzeichen stand grau
/// da, im selben Ton wie „Abbrechen" — dabei sagt es als einziges „woanders
/// läuft etwas". Seit dem 10.09.2026 trägt das auf allen Fassungen
/// `Stil.akzent`.
///
/// **Deckend, nicht durchsichtig.** Zuerst lag die Tönung direkt auf dem, was
/// darunter war — auf dunklem Grund stimmte das, über dem Titelbild der
/// Startseite schien das Bild durch, und die Schrift ging darin unter. Jetzt
/// liegt dieselbe Tönung auf dem Seitengrund: kein neuer Farbwert, aber eine
/// Fläche, die über jedem Bild gleich aussieht.
///
/// Rund, als Kapsel. Am 11.09.2026 so entschieden, nachdem eine Runde lang
/// die Ecke des Knopfes daran war.
struct AbzeichenStil: ButtonStyle {
    var anderesGeraet = false

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, anderesGeraet: anderesGeraet)
    }

    private struct Inhalt: View {
        let configuration: Configuration
        let anderesGeraet: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .foregroundStyle(vordergrund)
                .background { grund }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(fokus || anderesGeraet ? 0 : 0.18))
                }
                // Die breite Stufe: dieser Stil traegt das Abzeichen ueber dem
                // Titelbild **und** die 760 Punkt breiten Geraetezeilen. Sechs
                // Prozent waren dort fuenfundvierzig Punkte.
                .scaleEffect(fokus ? Stil.fokusLupeBreit : 1)
                .animation(Stil.bewegung(.easeOut(duration: 0.16)), value: fokus)
        }

        private var vordergrund: Color {
            if fokus { return Stil.grund }
            return anderesGeraet ? Stil.akzent : .white
        }

        @ViewBuilder
        private var grund: some View {
            if fokus {
                Capsule().fill(.white)
            } else if anderesGeraet {
                Capsule().fill(Stil.akzent.opacity(0.18))
                    .background(Stil.grund, in: Capsule())
            } else {
                Capsule().fill(Stil.erhoeht)
            }
        }
    }
}

// `Profilzeichen` steht jetzt in `Sources/Shared/Bausteine.swift` und nimmt
// die Größe als Parameter: `Profilzeichen(name:bild:groesse: 60)`.
//
// **Zwei Dinge sehen dadurch anders aus als vorher**, und beide sind
// Gestaltung, nicht Technik: der Grund ist ein Grünverlauf statt der flachen
// Fläche `Stil.erhoeht`, und der Ring ist 1 statt 2 stark. Der Buchstabe
// rechnet sich aus der Größe (60 × 0,38 = 22,8 statt fest 27). Gemeldet,
// nicht selbst entschieden — soll es beim alten Bild bleiben, gehören die
// drei Werte als Parameter in den geteilten Baustein, so wie es die
// `Plakette` schon vormacht.

// MARK: - Besetzung

/// Ein Darsteller: Bild, Name, Rolle.
struct Besetzungskachel: View {
    let bild: URL?
    let name: String
    let rolle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Halbe Kantenlaenge heisst Kreis — keine Stufe der Eckenleiter,
            // sondern die Form selbst, wie am iPhone bei `ecke: 38` auf 76.
            Bild(url: bild, breite: 208, hoehe: 208, ecke: 208 / 2)

            Text(name)
                .font(Stil.kachel)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .padding(.top, 14)

            if let rolle, !rolle.isEmpty {
                Text(rolle)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .frame(width: 208, alignment: .leading)
    }
}


/// Fokus auf dem Profilbild.
///
/// `KachelStil` allein reicht hier nicht: `fokusLupe` (1,06) auf 60 Punkt sind
/// vier Punkte, das sieht man aus drei Metern nicht. Deshalb `fokusLupeKlein`
/// — und weil ein Bild nicht heller werden kann wie eine Kachel, zusätzlich
/// ein Ring in der Akzentfarbe, dieselbe Rolle wie überall: er zeigt eine
/// Auswahl.
struct ProfilStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .overlay {
                    if fokus {
                        Circle()
                            .strokeBorder(Stil.akzent, lineWidth: 4)
                            .padding(-8)
                    }
                }
                .scaleEffect(fokus ? Stil.fokusLupeKlein : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}

// MARK: - Handlungstafel

/// Die Einträge hinter dem Mehr-Knopf.
///
/// **Klappt am Auslöser auf, nicht von unten.** Auf dem iPhone ist das ein
/// Blatt, das den halben Schirm nimmt — dort ist der Daumen unten und der
/// Weg dorthin kurz. Auf dem Fernseher sitzt der Auslöser mitten im Bild,
/// und eine Tafel, die von unten hereinfährt, hätte mit ihm nichts mehr zu
/// tun. Drei bis fünf Zeilen decken auch keinen Schirm zu; das bleibt ganzen
/// Ansichten vorbehalten.
///
/// Was drinsteht, ist **nicht** Sache dieser Ansicht: die Liste kommt als
/// `[Titelhandlung]` herein und ist überall dieselbe.
struct Handlungstafel: View {
    let handlungen: [Titelhandlung]
    @Binding var offen: Bool
    /// **Welche Zeile gewaehlt ist — sie traegt den Akzent.**
    ///
    /// Die Tafeln mit einer Auswahl (Filter, Sortierung, Bibliothek) zeigten
    /// sie nur ueber das Zeichen: gefuellter Haken gegen leeren Kreis, beide
    /// in Weiss. Das ist eine Formstufe, und die ueberlebt drei Meter so
    /// wenig wie eine Helligkeitsstufe — derselbe Grund, aus dem der
    /// gewaehlte Filterchip den Akzent trug (siehe `ChipStil`). Mit dem Chip
    /// ist die Wahl in diese Tafel gewandert; der Akzent geht mit.
    ///
    /// `nil` heisst: eine Liste von Handlungen, keine Auswahl.
    var gewaehlt: Int? = nil
    /// **Eine Rubrik vor einer Zeile** — Trennstrich, darunter die
    /// Ueberschrift. Im Titelmenue von Filme und Serien steht so
    /// „Bibliotheken" ueber den einzelnen Bibliotheken, abgesetzt von „Alle"
    /// und „Sammlungen", die keine sind. Dieselbe Rubrik wie im
    /// `Auswahlblatt` am iPhone.
    var rubrik: (Int) -> LocalizedStringKey? = { _ in nil }

    /// Der Fokus muss beim Aufklappen hineinwandern. tvOS legt ihn nicht von
    /// selbst um, solange der Auslöser stehen bleibt — und der bleibt.
    @FocusState private var erste: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(handlungen.enumerated()), id: \.element.id) { paar in
                if let ueber = rubrik(paar.offset) {
                    VStack(alignment: .leading, spacing: 0) {
                        Trennlinie()
                        Text(ueber)
                            .font(Stil.gruppe)
                            .tracking(Stil.sperrungGruppe)
                            .textCase(.uppercase)
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Self.rubrikEinzug)
                            .padding(.top, Stil.reihenKopfLuft)
                            .padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Button {
                    // Erst zu, dann tun: mehrere Handlungen öffnen selbst
                    // etwas — ein Blatt über einem offenen Blatt wäre falsch.
                    offen = false
                    paar.element.tun()
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: paar.element.symbol)
                            .foregroundStyle(paar.offset == gewaehlt ? Stil.akzent
                                             : paar.element.warnend ? Stil.warnung : Stil.schrift)
                            .frame(width: 38)
                        paar.element.beschriftung
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(paar.element.warnend ? Stil.warnung : Stil.schrift)
                }
                .buttonStyle(ZeilenStil())
                .accessibilityAddTraits(paar.offset == gewaehlt ? .isSelected : [])
                .focused($erste, equals: paar.offset == 0)
            }
        }
        // **Gar keine Luft mehr.** Erst 14, dann 6 — und beide Male schien
        // oben und unten noch Tafelgrund durch. Die Zeilen bringen ihre
        // eigene Rundung mit, also braucht es keinen Abstand zur Rundung der
        // Tafel; er war nur ein Rand um den Rand.
        //
        // Beschnitten, damit die oberste und unterste Zeile in der Rundung
        // der Tafel enden statt darueber hinauszustehen.
        .frame(width: Self.breite)
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous))
        // **Kein Rand, kein Schatten.** Tiefe kommt aus der
        // Flaechenhelligkeit — `erhoeht` liegt schon eine Stufe ueber dem
        // Grund. Der Schatten war mit Radius 40 der groesste der App und
        // widerspricht BRAND 4 („keine Schatten, nirgends"); auf drei Meter
        // wird er ohnehin zu Schlamm.
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous))
        .focusSection()
        .task { erste = true }
        .onExitCommand { offen = false }
    }

    /// **Die Breite steht fest, die Stelle nicht.**
    ///
    /// Drei bis fuenf Zeilen mit Symbol und Text brauchen sie; schmaler
    /// brechen die laengeren Beschriftungen. Die Platzierung rechnet damit,
    /// deshalb steht sie hier und nicht als Zahl im `frame`.
    static let breite: CGFloat = 620

    /// Luft zwischen Ausloeser und Tafel.
    static let luft: CGFloat = 16

    /// Der Einzug der Rubrik — derselbe wie der Text einer Zeile
    /// (`ZeilenStil`) und die `Trennlinie`, damit alles an einer Kante steht.
    static let rubrikEinzug: CGFloat = 26

    /// **An welcher Kante die Tafel unter ihrem Ausloeser haengt.**
    ///
    /// Sie richtet sich an dessen linker Kante aus. Steht er so weit rechts,
    /// dass die Tafel hinauslaeufe, richtet sie sich an seiner rechten —
    /// genau das tut auch ein Menue auf dem Mac. Zum Schluss in die Flaeche
    /// geklemmt: auf dem Fernseher ist deren Rand der titelsichere Bereich,
    /// und darueber hinaus zeichnet niemand.
    static func links(ausloeser: CGRect, in flaeche: CGSize) -> CGFloat {
        let links = ausloeser.minX + breite <= flaeche.width
            ? ausloeser.minX
            : ausloeser.maxX - breite
        return min(max(0, links), max(0, flaeche.width - breite))
    }
}

// MARK: - Tafeln haengen an ihrem Ausloeser

/// Wo die Ausloeser einer Seite stehen — gemessen, nicht gerechnet.
///
/// **Das war der Fehler, und er steckte an fuenf Stellen gleich.** Jede Tafel
/// hing als `.overlay(alignment:)` an der ganzen Seite, mit einem von Hand
/// gerechneten Abstand: `Stil.randSeite` zur Seite, `Stil.erstesEnde + 16`
/// oder `unterDerKnopfreihe` nach unten. Beide Zahlen sind von der
/// **Bildkante** gedacht — einer Auflage liegt aber der **sichere Bereich**
/// zugrunde, auf tvOS 80 Punkt zur Seite und 60 nach oben. Jede Tafel stand
/// damit um genau diesen Rand versetzt: auf der Filmseite die
/// Bibliothekswahl 80 Punkt zu weit rechts und 60 zu tief, die Sortierung
/// 80 Punkt zu weit links. Am 17.09. am Fernseher gemeldet, im
/// Simulator nachgemessen (Knopf 76…266, Tafel 160…779).
///
/// Dass eine gerechnete Zahl irgendwann nicht mehr stimmt, stand schon in
/// `macOS/BibliothekView`: dort sass der `Rasterplatzhalter` als Auflage mit
/// festem Abstand und legte sich ueber die Chipreihe, sobald die Kopfzone
/// eine Zeile hoeher wurde. Die Lehre ist dieselbe — **die Stelle wird
/// gemessen.**
///
/// `Anchor<CGRect>` traegt das Rechteck des Ausloesers bis zu der Ansicht
/// hinauf, an der die Auflage haengt, und `GeometryProxy` rechnet es dort in
/// deren eigenes Koordinatensystem. Damit ist es gleichgueltig, welcher
/// sichere Bereich wo abgeschaltet ist.
struct Tafelanker: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, neu in neu }
    }
}

extension View {
    /// Dieser Knopf oeffnet eine Tafel — merkt sich, wo er steht.
    func tafelausloeser(_ name: String) -> some View {
        anchorPreference(key: Tafelanker.self, value: .bounds) { [name: $0] }
    }

    /// Legt `inhalt` unter den Ausloeser `name` — auf die **Seite**, nicht auf
    /// den Knopf.
    ///
    /// Auf den Knopf gelegt lag die Tafel schon einmal hinter den Kacheln:
    /// eine Auflage erbt die Zeichenreihenfolge dessen, worauf sie liegt, und
    /// der Streifen unter einem `Section`-Kopf zeichnet nach ihm. Auf der
    /// Seite liegt sie ueber der ganzen Scrollflaeche — nur ihre **Stelle**
    /// kommt jetzt vom Knopf.
    func tafel<Inhalt: View>(unter name: String?,
                             @ViewBuilder inhalt: @escaping () -> Inhalt) -> some View {
        overlayPreferenceValue(Tafelanker.self) { anker in
            GeometryReader { flaeche in
                if let name, let bereich = anker[name] {
                    let ausloeser = flaeche[bereich]
                    inhalt()
                        .offset(x: Handlungstafel.links(ausloeser: ausloeser,
                                                        in: flaeche.size),
                                y: ausloeser.maxY + Handlungstafel.luft)
                }
            }
        }
    }
}

/// Der Mehr-Knopf. Die Tafel dazu legt die Seite selbst auf ihren Kopf —
/// siehe `Handlungstafel`.
struct Mehrknopf: View {
    @Binding var offen: Bool

    var body: some View {
        Button { offen.toggle() } label: {
            Image(systemName: "ellipsis").font(Stil.knopf)
        }
        .buttonStyle(KnopfStil(nurSymbol: true))
        // Ohne Beschriftung waere der Knopf fuer VoiceOver namenlos (E8).
        .accessibilityLabel(Text("Mehr"))
    }
}


/// **Der Kopfblock — einmal, für Startseite und Detailseite.**
///
/// Deshalb steht er hier und nicht zweimal. Vorher hatte jede Seite ihren
/// eigenen Aufbau, und die beiden waren bereits auseinander: die Detailseite
/// führte zusätzlich die Genres, die Startseite dafür die Restzeit. Genau so
/// sind `nachladen()` und `Titelangaben` auseinandergelaufen.
///
/// **Genres sind raus.** Nicht aus Geschmack: die Startseite kann sie gar
/// nicht zeigen. Ihre Titel kommen aus den Kurzlisten des Servers, und dort
/// stehen keine Genres — nur die Detailseite holt den vollen Titel. „Auf
/// beiden dasselbe" heißt hier also zwangsläufig „ohne".
///
/// **Die Höhe ist fest, der Inhalt nicht.** `Stil.auskunftHoehe` gilt, ob eine
/// Beschreibung da ist oder nicht und ob der Titel kurz oder lang ist. Nur so
/// steht die Knopfreihe darunter auf jeder Detailseite an derselben Stelle —
/// und nur so bleibt der Text beim Öffnen einer Seite liegen, statt zu
/// springen.
struct Kopfauskunft<Schluss: View>: View {
    let item: Item
    /// Bei Folgen steht der Folgentitel unter dem Serientitel. Er kostet
    /// eine Zeile, die dann der Beschreibung fehlt — die Gesamthöhe bleibt.
    var zweitzeile: String?
    /// **Bei einer Folge: die Serie, deren Angaben die Zeile traegt.**
    ///
    /// Der grosse Titel ueber der Zeile ist bei einer Folge der Serienname,
    /// und ein Druck auf die Folge fuehrt auf die Serienseite. Also gehoeren
    /// Jahr, Laufzeit, Sterne und Freigabe der Serie — sonst stand auf der
    /// Startseite 5,6 (die Folge) und eine Seite weiter 8,5 (die Serie).
    /// Fehlt sie noch, bleibt die Zeile leer, bis sie da ist, statt kurz die
    /// Werte der Folge zu zeigen.
    var serie: Item?
    /// Nur auf Detailseiten gesetzt: erst damit kann „Titel als Logo" greifen.
    var logoModell: AppModel?
    /// Was hinten steht: „Direct Play" auf der Detailseite, sonst nichts.
    @ViewBuilder var schluss: () -> Schluss

    /// Wessen Angaben in der Zeile stehen — siehe `serie`.
    private var angabenVon: Item? {
        item.type == "Episode" ? serie : item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Seitentitel aus der Leiter; 60 gibt es dort nicht. Ein langer
            // Titel schrumpft, statt die Seite zu verschieben; ein Logo
            // bleibt im Fach von 68. Bei einer Folge steht das Logo der Serie.
            Titelmarke(titel: item.type == "Episode" ? (item.seriesName ?? item.name) : item.name,
                       logo: logoModell.flatMap { $0.logoURL(for: angabenVon ?? item) },
                       zeile: 56, platz: .fach(hoehe: 68))

            if let zweitzeile {
                Text(zweitzeile)
                    // Blattrubrik aus der Leiter, und der Ton als Token —
                    // 78 Prozent Deckkraft aendert ihre Wirkung, sobald etwas
                    // darunter liegt, und hier liegt ein Heldbild darunter.
                    .font(Stil.rubrikGross)
                    .tracking(Stil.sperrungRubrik)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                    .frame(height: 44, alignment: .leading)
                    .padding(.top, 10)
            }

            // Jahr, Laufzeit, Sterne, Freigabe, Beleg — ein Baustein, siehe
            // `Angabenreihe`.
            Angabenreihe(titel: angabenVon, schluss: schluss)
            .frame(height: Stil.markeHoehe)
            .padding(.top, Stil.angabenLuft)

            // **Der bereinigte Text, nicht der rohe.** Jellyfin gibt
            // Beschreibungen aus, wie sie beim Anbieter standen — mit `<br>`,
            // `<p>` und `&amp;`. Auf drei Meter Entfernung stand das wörtlich
            // im Bild.
            Text(item.beschreibung ?? "")
                .font(Stil.koerper)
                .lineSpacing(Stil.beschreibungLuft)
                .foregroundStyle(Stil.schrift.opacity(0.62))
                // **Immer drei Zeilen**, auch wenn der Folgentitel darueber
                // steht. Vorher waren es dort zwei, damit der Block seine
                // feste Hoehe hielt
                .lineLimit(zweitzeile == nil ? 3 : 2)
                .padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // **Fest, aber um die Zweitzeile hoeher, wenn es eine gibt.**
        //
        // 258 traegt Titel, Angaben und drei Zeilen Beschreibung. Der
        // Folgentitel kostet 54 dazu (44 hoch, 10 Abstand), also 312 — und
        // die passen: die Startseite setzt bei 196 an, der Block endet damit
        // bei 508 und bleibt unter der Kopfzone von 510.
        //
        // Die Detailseiten sehen die Zweitzeile nie: eine Folge bekommt keine
        // eigene Seite, jeder Weg zu ihr fuehrt auf die Serienseite (A8).
        // Dort bleibt es also bei 258, und die Knopfreihe steht weiter auf
        // jeder Seite an derselben Stelle.
        .frame(width: 1000,
               height: Stil.auskunftHoehe(zweitzeile: zweitzeile != nil),
               alignment: .topLeading)
    }

}

/// **Die Angabenzeile — ein Baustein, eine Reihenfolge, überall.**
///
/// Jahr · Laufzeit · Sterne · Freigabe · Beleg (Direct Play). Was fehlt,
/// entfällt ohne Lücke. Startseite, Film- und Serienseite setzen sie über
/// `Kopfauskunft`; vorher stand auf der Startseite bei einer Folge zusätzlich
/// „S1 E3" vorn — dieselbe Angabe, die darunter im Folgentitel steht — und die
/// Werte kamen von der Folge statt vom Titel darüber.
///
/// **Alles eine `Belegmarke`, an der Mitte ausgerichtet.** Mit
/// `.firstTextBaseline` meldeten Marken mit Zeichen die Grundlinie des SF
/// Symbols; gemessen (27.09.) lagen die Hüllen bis zu 3 Punkt versetzt.
struct Angabenreihe<Schluss: View>: View {
    /// Der Titel, dessen Angaben hier stehen. `nil`: noch keiner.
    let titel: Item?
    /// Was nach den Angaben kommt — der Beleg auf der Detailseite, die
    /// Restzeit auf der Startseite.
    @ViewBuilder var schluss: () -> Schluss

    var body: some View {
        HStack(alignment: .center, spacing: Stil.angabenAbstand) {
            if let titel, Self.hatAngaben(titel) {
                HStack(alignment: .center, spacing: Stil.angabenAbstand) {
                    if let jahr = titel.productionYear {
                        Belegmarke(wort: Text(verbatim: String(jahr)), farbe: Stil.schriftLeise)
                            .monospacedDigit()
                    }
                    if let sekunden = titel.runtimeSeconds, sekunden > 0 {
                        Belegmarke(wort: Text(verbatim: laufzeit(sekunden)), farbe: Stil.schriftLeise)
                            .monospacedDigit()
                    }
                    Belegmarken(bewertung: titel.communityRating,
                                freigabe: titel.officialRating)
                }
                // **Ein Titelwechsel ist ein Schnitt, keine Bewegung.**
                // Wandert der Fokus auf der Startseite von Titel zu Titel,
                // kam der Wechsel in einer animierten Transaktion an, und die
                // Marken glitten, schoben sich und wuchsen von einer Breite
                // zur anderen — die Zeile, die erst leer war, ebenso. Eine
                // Kennung je Titel macht daraus neue Marken statt
                // verformter alter, und ohne Animation stehen sie sofort da.
                .id(titel.id)
                .transaction { $0.animation = nil }
            }
            // Der Schluss behaelt seine eigene Bewegung: die Direct-Play-Marke
            // der Detailseite blendet weiter ein (`Detailkopf`).
            schluss()
        }
    }

    /// Ob der Titel ueberhaupt etwas fuer die Zeile hat — sonst stuende ein
    /// leerer Stapel da und hielte vor dem Schluss seinen Abstand.
    private static func hatAngaben(_ titel: Item) -> Bool {
        titel.productionYear != nil || (titel.runtimeSeconds ?? 0) > 0
            || titel.communityRating != nil || titel.officialRating != nil
    }
}

/// „Noch 50 Minuten" mit Uhr, „Gesehen" mit Haken — oder nichts.
struct Restzeitmarke: View {
    let item: Item

    @ViewBuilder
    var body: some View {
        if let rest = item.restzeitText {
            Label(rest, systemImage: "clock")
                .font(Stil.kachel)
                .foregroundStyle(Stil.akzent)
                .lineLimit(1)
        } else if item.istGesehen {
            Label("Gesehen", systemImage: "checkmark")
                .font(Stil.kachel)
                .foregroundStyle(Stil.akzent)
                .lineLimit(1)
        }
    }
}

// MARK: - Kulisse

/// Das Bild rechts, 1180 x 700, mit den zwei Verlaeufen davor.
///
/// **Einmal hier, nicht dreimal.** Startseite, Filmseite und Serienseite
/// zeigen dieselbe Kulisse; als Kopie waeren es drei Stellen, an denen sich
/// eine Deckkraft aendern kann, ohne dass es jemand merkt. Genau so sind
/// `nachladen()` und `Titelangaben` auseinandergelaufen.
///
/// **Die Verlaeufe liegen darueber, sie maskieren nicht.** Eine Maske senkt
/// die Deckkraft der ganzen Ebene, den Fokusring eingeschlossen — das sieht
/// wie ein Fehler aus, nicht wie ein Verlauf.
///
/// **Fuer die Kulisse gilt das nicht mehr, und sie maskiert inzwischen.** Sie
/// ist kein Bedienelement und hat keinen Ring; der Satz oben stammt von den
/// Kacheln. Der Grund fuer den Wechsel steht unten am `mask`.
///
/// Nicht beschnitten: das Bild darf nach unten ueberragen, sein eigener
/// Verlauf beendet es. Beschnitten entstand die harte Kante, die als heller
/// Streifen quer ueber dem Schirm stand. **Die schon gezeigten Kulissen,
/// entschluesselt.**
///
/// `AsyncImage` faengt in jeder neuen Ansicht von vorn an: es fragt den
/// Zwischenspeicher, entschluesselt und zeigt erst danach. Auf der Detailseite
/// ist das ein neues `AsyncImage` fuer dasselbe Bild, das eben noch auf der
/// Startseite stand — und dazwischen zeigt es nichts.
///
/// Der Netz-Zwischenspeicher hilft dagegen nicht: er spart den Abruf, nicht
/// das Entschluesseln, und beides passiert asynchron. Was schon einmal auf dem
/// Schirm stand, muss deshalb **hier** liegen, fertig zum Zeichnen.
///
/// Gedeckelt, weil ein Kulissenbild in Fernsehergroesse einige Megabyte
/// belegt: die letzten acht reichen fuer den Weg Startseite → Detailseite →
/// zurueck, und mehr braucht niemand gleichzeitig.
///
/// **Die zuletzt gebrauchten, nicht die zuletzt geholten.** Bis hierher
/// fiel das aelteste *Gemerkte* heraus, auch wenn es eben noch gezeigt
/// wurde — die Startseitenkulisse, zu der man gleich zurueckkehrt, ging so
/// nach acht Detailseiten verloren. Jetzt ruecken Lesen und Merken nach
/// hinten.
@MainActor
final class Kulissenbilder {
    static let geteilt = Kulissenbilder()
    private var bekannt: [URL: Image] = [:]
    private var reihenfolge: [URL] = []
    private static let hoechstens = 8

    func bild(_ url: URL) -> Image? {
        guard let bild = bekannt[url] else { return nil }
        nachHinten(url)
        return bild
    }

    func merken(_ bild: Image, fuer url: URL) {
        bekannt[url] = bild
        nachHinten(url)
        while reihenfolge.count > Self.hoechstens {
            bekannt[reihenfolge.removeFirst()] = nil
        }
    }

    private func nachHinten(_ url: URL) {
        if let stelle = reihenfolge.lastIndex(of: url) { reihenfolge.remove(at: stelle) }
        reihenfolge.append(url)
    }
}

struct Kulisse: View {
    let url: URL?
    @State private var bild: Image?
    /// Was bekannt ist, steht sofort — nicht erst im naechsten Durchgang.
    /// Dieselbe Ueberlegung wie bei `Bildgrund`: ein nachgereichter Wert
    /// kommt zu spaet, der leere Durchgang hat dann schon stattgefunden.
    @MainActor init(url: URL?) {
        self.url = url
        _bild = State(initialValue: url.flatMap { Kulissenbilder.geteilt.bild($0) })
    }

    var body: some View {
        ZStack {
            if let bild {
                bild.resizable().aspectRatio(contentMode: .fill)
            }
        }
        // **Ueber den `Bildspeicher`, nicht ueber `AsyncImage`** — wie `Bild`
        // (siehe `Stil.swift`): `AsyncImage` entschluesselt auf dem Hauptlauf,
        // legt nichts auf die Platte und bricht beim Verschwinden ab; auf der
        // Startseite wechselt die Kulisse mit jedem Fokus-Halt. Der
        // `Bildspeicher` kann ausserdem eigene Kopfzeilen (Vorposten, #4).
        // Das Ergebnis merkt zusaetzlich `Kulissenbilder`, damit die Kulisse
        // der Startseite auch nach mehreren Detailseiten noch steht.
        .task(id: url) {
            guard let url else { return }
            if let da = Kulissenbilder.geteilt.bild(url) { bild = da; return }
            guard let geladen = await Bildspeicher.geteilt.laden(url, vorrang: true) else { return }
            guard !Task.isCancelled else { return }
            Kulissenbilder.geteilt.merken(geladen, fuer: url)
            bild = geladen
        }
        // Eine neue Adresse bei stehender Ansicht: nicht das alte Bild
        // weiterzeigen, sondern nehmen, was fuer die neue bekannt ist.
        .onChange(of: url) { _, neu in
            bild = neu.flatMap { Kulissenbilder.geteilt.bild($0) }
        }
        .frame(width: 1180, height: 700)
        .clipped()
        .kulissenblende()
        .padding(.trailing, -Stil.randSeite)
        .allowsHitTesting(false)
    }
}
/// **Die Blende der Kulisse — einmal, fuer Startseite und Detailseite.**
///
/// Sie stand zweimal, und die beiden waren verschieden: hier maskiert, dort
/// mit Verlaeufen aus `Stil.grund` uebermalt. Beim Wechsel von der Startseite
/// auf eine Detailseite blendete SwiftUI die eine Fassung in die andere — und
/// mitten in der Ueberblendung standen sichtbar harte Kanten, weil die alte
/// Fassung welche hatte.
///
/// Jetzt ist es auf beiden Seiten dasselbe Bild mit derselben Blende. Eine
/// Ueberblendung zwischen zwei gleichen Dingen sieht man nicht.
///
/// **Maskiert, nicht uebermalt.** Uebermalen setzt voraus, dass der
/// Hintergrund genau `#0B0B0D` ist; sobald er sich faerbt, steht die
/// uebermalte Flaeche als Fleck darin. Als Maske faellt die Deckkraft des
/// Bildes selbst, und was dahinterliegt kommt durch — welche Farbe es auch
/// hat.
///
/// **Ein Abfall, nicht zwei.** Davor lagen hier eine waagerechte und eine
/// senkrechte Maske uebereinander. Zusammen ergeben sie einen rechteckigen
/// Abfall: jede fuer sich weich, ihr Produkt zeichnet trotzdem die zwei
/// Geraden nach, und in der Ecke wird es doppelt dunkel. Siehe
/// `Bildton.rundeBlende`.

struct Kulissenblende: ViewModifier {
    func body(content: Content) -> some View {
        content
            // **Die urspruengliche Kurve, nur als Maske statt als Anstrich.**
            //
            // Stimmt — und das Gute daran war nie die Technik, sondern die
            // Kurve. Sie ist hier unveraendert uebernommen.
            //
            // Uebersetzt: die alte Fassung malte `Stil.grund` mit der
            // Deckkraft `o` **ueber** das Bild. Sichtbar blieb also `1 − o`.
            // Genau diese Werte stehen jetzt als Maske da:
            //
            // waagerecht   o 1,00 / 0,78 / 0,16 / 0     bei 0 / 0,26 / 0,62 /
            // 1 sichtbar       0    / 0,22 / 0,84 / 1
            //
            // senkrecht    die unteren 320 von 700, also ab 0,543 o 0 / 0,75 /
            // 1,00  →  sichtbar 1 / 0,25 / 0
            //
            // **Der einzige Unterschied ist, worin es ausblendet.** Anstrich
            // endet in undurchsichtigem #0B0B0D und setzt damit voraus, dass
            // der Hintergrund genau das ist — sobald er sich faerbt, steht die
            // uebermalte Flaeche als Fleck darin. Das war die harte senkrechte
            // Naht. Eine Maske endet in Transparenz, und was dahinterliegt
            // kommt durch, welche Farbe es auch hat.
            //
            // Alles, was ich dazwischen versucht habe — laengere Rampen, ein
            // Kreis in der Ecke, das Minimum zweier Rampen — hat die Kurve
            // veraendert, statt nur ihre Technik. Deshalb war jede Fassung
            // schlechter als diese.
            //
            // **Dieselben Anker, mehr Stuetzstellen.** Das Harte waren nicht
            // die Werte, sondern ihre Zahl: zwischen 0,26 und 0,62 sprang die
            // Sichtbarkeit von 22 auf 84 Prozent, und an beiden Punkten
            // knickte die Steigung. Ein Knick liest sich als Kante.
            //
            // Die vier Anker der urspruenglichen Fassung stehen unveraendert
            // (0 / 0,22 / 0,84 / 1 und 1 / 0,25 / 0); dazwischen liegen jetzt
            // Zwischenpunkte, die den Uebergang tragen, statt ihn in einem Zug
            // zu nehmen. Die Kurve bleibt dieselbe, sie hat nur keine Ecken
            // mehr.
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.00), location: 0),
                    .init(color: .white.opacity(0.05), location: 0.15),
                    .init(color: .white.opacity(0.22), location: 0.29),
                    .init(color: .white.opacity(0.50), location: 0.45),
                    .init(color: .white.opacity(0.75), location: 0.57),
                    .init(color: .white.opacity(0.90), location: 0.70),
                    .init(color: .white.opacity(0.98), location: 0.85),
                    .init(color: .white.opacity(1.00), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1.00), location: 0),
                    .init(color: .white.opacity(1.00), location: 0.50),
                    .init(color: .white.opacity(0.88), location: 0.60),
                    .init(color: .white.opacity(0.62), location: 0.70),
                    .init(color: .white.opacity(0.34), location: 0.80),
                    .init(color: .white.opacity(0.14), location: 0.89),
                    .init(color: .white.opacity(0.04), location: 0.95),
                    .init(color: .white.opacity(0.00), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}

extension View {
    func kulissenblende() -> some View { modifier(Kulissenblende()) }
}

/// **Ein leiser Schatten unter der Kopfleiste.**
///
/// Seit die Startseite denselben gefaerbten Grund traegt wie eine Detailseite,
/// ist ihr alter Kopfverlauf weg — und damit stand die Leiste auf hellen
/// Motiven im Bild.
///
/// **Deutlich weniger als der alte Verlauf.** Der begann bei 72 Prozent und
/// lief ueber 588 Punkte aus; er hat die halbe Kopfzone eingegraut und war
/// genau das, was die Seite anders aussehen liess. Dieser hier deckt die
/// Leiste und ist 90 Punkte darunter zu Ende — gerade so weit, dass er den
/// Titel bei 196 nicht mehr beruehrt.
///
/// Abgetastet wie jeder Verlauf hier, damit er weder oben noch unten einen
/// Knick hat, an dem ein Band entstehen koennte.
struct Kopfschatten: View {
    var body: some View {
        ZStack(alignment: .top) {
            // Der Streifen unter der ganzen Leiste — traegt Wortmarke und
            // Bereichsnamen.
            LinearGradient(gradient: streifen, startPoint: .top, endPoint: .bottom)
                .frame(height: Stil.leisteUnten + 90)

            // **Und ein grosser weicher Fleck hinter dem Profilzeichen.**
            //
            // Es sitzt ganz rechts oben, also genau dort, wo die Kulisse am
            // hellsten ist — der gleichmaessige Streifen reicht dort nicht,
            // und das runde Bild lag plan auf dem Motiv.
            //
            // Riesig ist hier das Mittel, nicht die Uebertreibung: ein kleiner
            // Schatten waere als Scheibe hinter dem Zeichen zu erkennen. Bei
            // 520 Punkt Reichweite sieht man ihn nicht mehr als Form, sondern
            // nur, dass es dort ruhiger ist.
            RadialGradient(gradient: fleck,
                           center: UnitPoint(x: 0.945, y: 0.02),
                           startRadius: 0, endRadius: 520)
                .frame(height: 620)
        }
        .allowsHitTesting(false)
    }

    /// Deckt die Leiste, 90 Punkte darunter zu Ende — gerade so weit, dass
    /// er den Titel bei 196 nicht mehr beruehrt.
    private var streifen: Gradient { verlauf(0.46) }

    /// Kraeftiger als der Streifen, dafuer nur an einer Stelle.
    private var fleck: Gradient { verlauf(0.52) }

    /// Abgetastet statt gestuft: an beiden Enden waagerecht auslaufend, also
    /// weder oben noch unten ein Knick, an dem ein Band entstehen koennte.
    private func verlauf(_ staerke: Double) -> Gradient {
        let stufen = 14
        return Gradient(stops: (0 ... stufen).map { i in
            let t = Double(i) / Double(stufen)
            let weich = t * t * (3 - 2 * t)
            return .init(color: Stil.grund.opacity(staerke * (1 - weich)), location: t)
        })
    }
}

// MARK: - Staffelwahl

/// Die Pille neben „Folgen".
///
/// Aus `Folgen.dc.html` uebernommen: 60 hoch, Rundung 30, `Stil.erhoeht` mit
/// einem leisen Rand. Kein `Menu` — Apples Aufklappmenue bringt seine eigene
/// Gestaltung mit, und die App benutzt an keiner Stelle ein Standardsteuer-
/// element. Die Liste kommt als `Handlungstafel`, dieselbe, die der
/// Mehr-Knopf oeffnet.
struct Staffelpille: View {
    let name: String
    @Binding var offen: Bool

    var body: some View {
        Button { offen.toggle() } label: {
            HStack(spacing: 14) {
                Text(name)
                    .font(Stil.knopf)
                // Deckkraft statt fester Farbe: der Pfeil erbt die Schrift
                // des Knopfs. Fest halbweiss verschwand er auf der weissen
                // Fokusflaeche.
                Image(systemName: "chevron.down")
                    .font(Stil.gruppe)
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
        }
        // **Derselbe Stil wie die Knoepfe im Kopf.**
        //
        // Sie trug einen eigenen: andere Flaeche, anderer Rand, andere
        // Rundung. Stimmt — und es **ist** dasselbe: ein Knopf, der etwas
        // aufklappt, wie der Mehr-Knopf daneben.
        .buttonStyle(KnopfStil(hoehe: 60))
        .accessibilityLabel(Text("Staffel wählen, \(name)"))
    }
}

/// Fokus auf der Staffelpille: die ruhige Flaeche, wie bei Zeilen und Chips.
/// Weiss bleibt den Handlungsknoepfen vorbehalten.

// MARK: - Übernahme: welches Gerät?

/// Läuft auf mehreren Geräten etwas, wird gefragt statt geraten.
///
/// **`TV`-Kürzel, weil es die geteilte Fassung auch gibt.** Die hier ist für
/// zehn Fuß Abstand und den Fokusring gebaut, die in `Bausteine.swift` für
/// den Finger. Gleicher Zweck, verschiedene Entfernung — genau der Fall, in
/// dem CLAUDE.md eigene Ansichten erlaubt.
///
/// **Warum ein eigenes Blatt und keine Liste im Abzeichen.** Das Abzeichen
/// sitzt in der Kopfleiste und hat dort Platz für eine Zeile. Und die Wahl
/// ist folgenreich: was hier gewählt wird, **hält auf dem anderen Gerät an**.
/// Das gehört vor Augen, nicht in ein Aufklappmenü.
struct TVUebernahmeauswahl: View {
    let sitzungen: [Fremdsitzung]
    var waehlen: (Fremdsitzung) -> Void
    var abbrechen: () -> Void
    /// **Der Fokus wird hineingesetzt, nicht gesucht** — das gesperrte
    /// Abzeichen dahinter behielt ihn sonst, und nichts hier war bedienbar
    /// (siehe `TVGemeinsamtafeln.auswahl`).
    @FocusState private var fokus: String?

    /// **Ohne eigenen Grund.** Den Schleier legt `HauptView` darunter, als
    /// eigene Ebene: er blendet nur, die Auswahl wächst aus dem Abzeichen
    /// (``Herkunftsauftritt``, wie am iPhone).
    var body: some View {
        ZStack {
            VStack(spacing: 34) {
                VStack(spacing: 10) {
                    Text("Wo weiterschauen?")
                        .font(Stil.unterseitentitel)
                        .tracking(Stil.sperrungUnterseite)
                    Text("Auf dem anderen Gerät hört die Wiedergabe auf. Hier läuft sie an derselben Stelle weiter.")
                        .font(Stil.klein)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    ForEach(sitzungen) { s in
                        Button { waehlen(s) } label: {
                            HStack(spacing: 20) {
                                Image(systemName: s.geraetezeichen)
                                    .font(.system(size: 28, weight: .medium))
                                    .frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    // Der Rueckfall ist unser Wort, der Name nicht:
                                    // ohne `String(localized:)` stand „Gerät" in
                                    // jeder Sprache deutsch da — dieselbe Falle wie
                                    // am iPhone (`2e43f49`), Form wie in `Bausteine`.
                                    Text(s.geraetename ?? String(localized: "Gerät"))
                                        .font(Stil.listentitel)
                                    Text(s.titelzeile)
                                        .font(Stil.klein)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(Spielzeit.text(s.stand?.stelle ?? 0))
                                    .font(Stil.klein.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 28)
                            .frame(height: 88)
                            .frame(maxWidth: 760)
                        }
                        // Jede Zeile ist ein anderes Gerät — also kühl wie das
                        // Abzeichen, das hierher geführt hat. „Abbrechen"
                        // darunter bleibt grau.
                        .buttonStyle(AbzeichenStil(anderesGeraet: true))
                        .focused($fokus, equals: s.id)
                    }
                }
                .focusSection()

                Button("Abbrechen", action: abbrechen)
                    .buttonStyle(AbzeichenStil())
            }
            .padding(48)
        }
        // Menü schließt, wie überall auf dem Fernseher.
        .onExitCommand(perform: abbrechen)
        .defaultFocus($fokus, sitzungen.first?.id)
        .task { fokus = sitzungen.first?.id }
    }
}


// MARK: - Platzhalter statt Ladering

/// Eine Flaeche in der Form dessen, was gleich kommt.
///
/// **Warum kein drehender Ring.** Ein Ring sagt „warte"; ein Platzhalter
/// sagt, *was* kommt und wie viel — die Seite steht schon, sie ist nur noch
/// leer. Auf drei Meter Entfernung zaehlt das doppelt: ein Ring ist dort ein
/// Punkt, ein Raster ist eine Ankuendigung. GESTALTUNG, Abschnitt G.
struct Ladefeld: View {
    var ecke: CGFloat = Stil.eckeKachel
    @State private var hell = false

    var body: some View {
        RoundedRectangle(cornerRadius: ecke, style: .continuous)
            .fill(Stil.flaeche)
            .opacity(hell ? 1 : 0.5)
            .onAppear {
                // **Kein endloses Pulsieren gegen die Systemeinstellung.**
                // Auf einer leeren Bibliothek pulsiert sonst das ganze
                // Raster, und `accessibilityHidden` hilft dagegen nicht —
                // wer die Bewegung nicht sehen will, sieht sie trotzdem.
                // Die Flaeche steht dann still und hell da; die Form ist die
                // Aussage, nicht die Bewegung. Die iOS-Fassung macht es
                // genauso.
                guard !Stil.bewegungReduziert else { hell = true; return }
                withAnimation(Stil.pulsieren) {
                    hell = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Ein Plakat mit zwei Textzeilen darunter, alles als Platzhalter.
struct Kachelplatzhalter: View {
    var quer = false

    private var breite: CGFloat { quer ? Stil.querBreite : Stil.posterBreite }
    private var hoehe: CGFloat { quer ? Stil.querHoehe : Stil.posterHoehe }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Ladefeld().frame(width: breite, height: hoehe)
            Ladefeld(ecke: Stil.eckeBalken).frame(width: breite * 0.8, height: 20).padding(.top, 14)
            Ladefeld(ecke: Stil.eckeBalken).frame(width: breite * 0.4, height: 16).padding(.top, 6)
        }
        .frame(width: breite, alignment: .leading)
    }
}

/// Ein Raster aus Plakat-Platzhaltern, so breit wie das echte.
struct Rasterplatzhalter: View {
    var spalten: Int = Stil.gitterSpalten
    var reihen: Int = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
                                 count: max(spalten, 1)),
                  alignment: .leading, spacing: Stil.reihenAbstand) {
            ForEach(0 ..< (max(spalten, 1) * reihen), id: \.self) { _ in
                Kachelplatzhalter()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Laedt")
    }
}

/// Eine Reihe aus Plakat-Platzhaltern, fuer die Startseite.
struct Reihenplatzhalter: View {
    var quer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Ladefeld(ecke: Stil.eckeBalken).frame(width: 300, height: 30)
            HStack(spacing: Stil.kachelAbstand) {
                ForEach(0 ..< 5, id: \.self) { _ in Kachelplatzhalter(quer: quer) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Laedt")
    }
}

/// Wie viele Titel in dieser Bibliothek liegen.
///
/// **Eine Angabe, keine Handlung** — leise Schrift, kein Kasten.
struct Zaehlmarke: View {
    let anzahl: Int

    var body: some View {
        Text(verbatim: anzahl.formatted())
            .font(Stil.klein)
            .monospacedDigit()
            .foregroundStyle(Stil.schriftSehrLeise)
            .accessibilityLabel(Text("\(anzahl) Titel"))
    }
}

/// Die Plakette oben rechts auf einer Kachel.
///
/// **In Weiss auf Dunkel, nicht in Akzent** — auf dem Fernseher traegt der
/// Akzent zusaetzlich den Fokusring, und eine zweite Akzentflaeche daneben
/// nimmt ihm seine Aussage. Welche Auskunft draufsteht, entscheidet
/// `Anzeigeregeln.kachelmarke` im Paket.
struct Kachelplakette: View {
    let marke: Kachelmarke

    var body: some View {
        // **Die Masse des iPhones, verdoppelt** — Zeichen 10, Text
        // `Stil.plakette`, Innenabstand 5/6 auf 3, Aussenabstand 6. Hier
        // stand eine halb uebernommene Fassung: 15 fett und 17 halbfett sind
        // weder iPhone-Stufen noch Fernseherstufen, und der Innenabstand war
        // nur nach Augenmass vergroessert.
        HStack(spacing: 6) {
            if marke == .gesehen {
                Image(systemName: "checkmark").font(Stil.plakette)
            }
            if let text = wortlaut {
                // Ohne Sperrung, wie am iPhone: „3 offen" und „2 Staffeln"
                // sind gewoehnliche Woerter, keine Versalien.
                Text(verbatim: text).font(Stil.plakette)
            }
        }
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, wortlaut == nil ? 10 : 12)
        .padding(.vertical, 6)
        .background {
            // `eckeKlein` (14), nicht `eckeKachel`: die Marke ist rund 36 Punkt
            // hoch, die Kachel darunter 208 breit — dasselbe Mass waere an ihr
            // eine ganz andere Rundung. Die 14 stand hier als Zahl und ist
            // genau die kleine Stufe geworden; am iPhone steht an derselben
            // Stelle 9 gegen die 10 der Kachel.
            RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous)
                .fill(Stil.grund.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous)
                        .strokeBorder(Stil.rand)
                }
        }
        .padding(12)
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

/// **Der Quick-Connect-Code, ein Feld je Zeichen.**
///
/// Stand zweimal in der App, und zwar verschieden: auf der Quick-Connect-Seite
/// als Felder in 92 Punkt, beim Aufnehmen eines Servers als eine Zeile in 80
/// mit Sperrung 14. Derselbe Code, dieselbe Aufgabe — jemand tippt ihn auf
/// einem anderen Geraet ab — und zwei Gestalten.
///
/// Die Felder gewinnen, und die Begruendung stand schon da: getrennt gesetzt
/// verzaehlt man sich beim Abtippen nicht. Das gilt am Fernseher doppelt, weil
/// man dabei quer durchs Zimmer liest und die Hand am Telefon hat.
///
/// 92 Punkt steht bewusst ausserhalb der Schriftleiter. Die Leiter ordnet
/// Text; hier geht es nicht um eine Stufe im Gefuege, sondern um Lesbarkeit
/// auf drei Metern — derselbe Grund, aus dem die Leiter auf dem Fernseher
/// ueberhaupt verdoppelt ist, nur eine Stufe weiter gedacht.
struct Codefelder: View {
    let code: String

    var body: some View {
        HStack(spacing: 20) {
            ForEach(Array(code.enumerated()), id: \.offset) { paar in
                Text(String(paar.element))
                    .font(.system(size: 92, weight: .bold).monospacedDigit())
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 120, height: 160)
                    .background(Stil.erhoeht,
                                in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
            }
        }
        // Ein Code ist eine Zeichenfolge, kein Wort — sonst liest VoiceOver
        // „ABCD" als Silbe statt als vier Zeichen.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Code"))
        .accessibilityValue(Text(verbatim: code.map(String.init).joined(separator: " ")))
    }
}
