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

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, nurSymbol: nurSymbol)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let nurSymbol: Bool
        @Environment(\.isFocused) private var fokus
        @Environment(\.isEnabled) private var freigegeben

        var body: some View {
            configuration.label
                .font(Stil.knopf)
                // Ein Knopf, der umbricht, wird höher als seine Nachbarn und
                // reißt die ganze Reihe schief. Lieber kurz beschriften.
                .lineLimit(1)
                .foregroundStyle(vordergrund)
                .padding(.horizontal, nurSymbol ? 0 : 40)
                .frame(width: nurSymbol ? Stil.knopfHoehe : nil, height: Stil.knopfHoehe)
                .background(hintergrund, in: RoundedRectangle(cornerRadius: Stil.ecke))
                // Fokus hebt die Pille leicht heraus — 1,04, nicht die 1,08
                // der Kachel. Ein Knopf steht in einer Reihe mit Nachbarn,
                // die dieselbe Hoehe halten muessen; eine Kachel steht frei.
                .scaleEffect(configuration.isPressed ? 0.97 : (fokus ? 1.04 : 1))
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// Gesperrt heißt gedämpft, nicht durchscheinend — dieselbe Begründung
        /// wie auf iOS: Weiß auf 40 Prozent sieht aus wie ein Knopf, der noch
        /// wartet, statt wie einer, der nicht reagiert.
        private var vordergrund: Color {
            guard freigegeben else { return Stil.schriftSehrLeise }
            return fokus ? Stil.grund : Stil.schrift
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

        var body: some View {
            configuration.label
                .scaleEffect(fokus ? Stil.fokusLupe : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
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
                .font(.system(size: 31, weight: fokus || gewaehlt ? .semibold : .medium))
                .foregroundStyle(vordergrund)
                .padding(.horizontal, 26)
                .padding(.top, 10)
                .padding(.bottom, 18)
                // Leise, nicht laut: weil der Fokus hier selbst umschaltet,
                // sind „fokussiert" und „offen" dasselbe. Für eine einzige
                // Aussage wäre eine volle weiße Fläche zu viel Werkzeug.
                .background {
                    if fokus {
                        RoundedRectangle(cornerRadius: Stil.ecke)
                            .fill(Color.white.opacity(0.08))
                    }
                }
                .scaleEffect(fokus ? 1.06 : 1)
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
                .font(.system(size: 23, weight: an ? .semibold : .regular))
                .foregroundStyle(an ? Stil.grund : Stil.schrift)
                .padding(.horizontal, 22)
                .frame(height: Stil.chipHoehe)
                .background(flaeche, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(an ? Stil.akzent : Stil.rand, lineWidth: 2)
                }
                .scaleEffect(fokus ? 1.06 : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }

        /// Auswahl ist Akzent, Fokus ist die ruhige Fläche — und beides
        /// zusammen bleibt Akzent, weil die Auswahl die stärkere Aussage ist.
        private var flaeche: Color {
            if an { return Stil.akzent }
            return fokus ? Stil.fokusflaeche : Stil.erhoeht
        }
    }
}

/// Zeile in einer Auswahlliste — Spurwahl, Einstellungen.
struct ZeilenStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .font(.system(size: 31, weight: fokus ? .semibold : .medium))
                .foregroundStyle(Stil.schrift)
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
                            in: RoundedRectangle(cornerRadius: Stil.ecke))
                .animation(Stil.fokusAnimation, value: fokus)
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

    private var breite: CGFloat { quer ? Stil.querBreite : Stil.posterBreite }
    private var hoehe: CGFloat { quer ? Stil.querHoehe : Stil.posterHoehe }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Bild(url: bild, breite: breite, hoehe: hoehe, fortschritt: fortschritt)

            Text(titel)
                .font(Stil.kachel)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .padding(.top, 14)

            if mitUnterzeile, let unterzeile {
                Text(unterzeile)
                    .font(Stil.klein)
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
        guard mitUnterzeile, let unterzeile else { return titel }
        return "\(titel), \(unterzeile)"
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
    case start, filme, serien, suche
    var id: Int { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .start:  "Start"
        case .filme:  "Filme"
        case .serien: "Serien"
        case .suche:  "Suche"
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

    /// Welcher Reiter gerade den Fokus hat — `nil`, sobald er im Inhalt steht.
    @FocusState private var amReiter: Bereich?

    var body: some View {
        HStack(spacing: 56) {
            Wortmarke(hoehe: 48)

            HStack(spacing: 8) {
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

            Button(action: aufsProfil) {
                Profilzeichen(name: model.session?.userName ?? "?",
                              bild: model.benutzerbildURL(groesse: 180),
                              groesse: 60)
            }
            .buttonStyle(ProfilStil())
            // Ein Bild ohne Beschriftung ist eine namenlose Taste.
            .accessibilityLabel(Text("Profil und Einstellungen"))
            .focusSection()
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
            Bild(url: bild, breite: 208, hoehe: 208, ecke: 104)

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
/// `KachelStil` allein reicht hier nicht: ×1,08 auf 60 Punkt sind fünf
/// Punkte, das sieht man aus drei Metern nicht. Ein Bild kann auch nicht
/// heller werden wie eine Kachel — deshalb hier ein Ring in der Akzentfarbe,
/// dieselbe Rolle wie überall: er zeigt eine Auswahl.
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
                .scaleEffect(fokus ? 1.10 : 1)
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

    /// Der Fokus muss beim Aufklappen hineinwandern. tvOS legt ihn nicht von
    /// selbst um, solange der Auslöser stehen bleibt — und der bleibt.
    @FocusState private var erste: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(handlungen.enumerated()), id: \.element.id) { paar in
                Button {
                    // Erst zu, dann tun: mehrere Handlungen öffnen selbst
                    // etwas — ein Blatt über einem offenen Blatt wäre falsch.
                    offen = false
                    paar.element.tun()
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: paar.element.symbol)
                            .frame(width: 38)
                        Text(paar.element.text)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(paar.element.warnend ? Stil.warnung : Stil.schrift)
                }
                .buttonStyle(ZeilenStil())
                .focused($erste, equals: paar.offset == 0)
            }
        }
        .padding(.vertical, 14)
        .frame(width: 620)
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.ecke + 8))
        .overlay(RoundedRectangle(cornerRadius: Stil.ecke + 8).strokeBorder(Stil.rand))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        .focusSection()
        .task { erste = true }
        .onExitCommand { offen = false }
    }

    /// Wo die Tafel sitzt: links unter der Knopfreihe des Detailkopfs.
    ///
    /// **Fester Platz statt Auflage am Knopf.** Erster Anlauf hing sie als
    /// `overlay` am Mehr-Knopf und schob sich mit einer Ausrichtungshilfe
    /// nach oben. Sie klappte trotzdem nach unten auf und lief rechts aus
    /// dem Bild — der Knopf steht ganz rechts, die Tafel ist breiter als er,
    /// und über den sicheren Bereich hinaus zeichnet niemand mehr.
    ///
    /// Von der Bildkante gerechnet, aus dem Aufbau des Kopfes: 140 oben +
    /// Titel 68 + 14 + Angaben 34 + 22 + Beschreibung 80 + 36 + Knopfhöhe 76
    /// = 470, plus 16 Luft. Alle Werte aus `Film-Neu.dc.html`.
    ///
    /// Vorher 486, gerechnet auf einen Textblock, der bei 140 ansetzte. Der
    /// beginnt jetzt bei 196 — dieselbe Zeile wie auf der Startseite —, und
    /// die Tafel muss mitwandern, sonst klappt sie mitten in die Knöpfe.
    ///
    /// Vorher waren es 210 **von unten**, gerechnet auf einen Kopf, der den
    /// ganzen Schirm füllte. Der ist 510 hoch — von unten gerechnet läge die
    /// Tafel jetzt mitten im Text.
    static let unterDerKnopfreihe: CGFloat = 486

    /// Und hier sitzt die Staffelwahl: unter dem Reihenkopf der ersten Reihe.
    ///
    /// Kopfzone 510 + Luft ueber dem Titel 24 + Titelzeile 46 + 20 Abstand.
    ///
    /// **Nicht als Auflage am Pillenknopf.** Der steht im `Section`-Kopf, und
    /// der Streifen darunter gehoert demselben Abschnitt — er zeichnet nach
    /// dem Kopf und damit ueber ihn. Die Tafel lag hinter den Kacheln und sah
    /// aus wie ein leeres graues Rechteck. Eine Auflage auf der **Seite**
    /// liegt dagegen ueber der ganzen Scrollflaeche.
    static var unterDemReihenkopf: CGFloat { Stil.heldenHoehe + 24 + 46 + 20 }
}

/// Der Mehr-Knopf. Die Tafel dazu legt die Seite selbst auf ihren Kopf —
/// siehe `Handlungstafel`.
struct Mehrknopf: View {
    @Binding var offen: Bool

    var body: some View {
        Button { offen.toggle() } label: {
            Label("Mehr", systemImage: "ellipsis")
        }
        .buttonStyle(KnopfStil())
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
/// Nicht beschnitten: das Bild darf nach unten ueberragen, sein eigener
/// Verlauf beendet es. Beschnitten entstand die harte Kante, die als heller
/// Streifen quer ueber dem Schirm stand.
struct Kulisse: View {
    let url: URL?

    var body: some View {
        ZStack {
            AsyncImage(url: url) { phase in
                if case let .success(bild) = phase {
                    bild.resizable().aspectRatio(contentMode: .fill)
                }
            }
        }
        .frame(width: 1180, height: 700)
        .clipped()
        .overlay {
            LinearGradient(stops: [
                .init(color: Stil.grund, location: 0),
                .init(color: Stil.grund.opacity(0.78), location: 0.26),
                .init(color: Stil.grund.opacity(0.16), location: 0.62),
                .init(color: Stil.grund.opacity(0), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [
                .init(color: Stil.grund.opacity(0), location: 0),
                .init(color: Stil.grund.opacity(0.75), location: 0.55),
                .init(color: Stil.grund, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 320)
        }
        // Bis an die Bildkante, ohne den Text mitzunehmen: der Textblock
        // haelt den Rand, das Bild tritt fuer sich hinaus.
        .padding(.trailing, -Stil.randSeite)
        .allowsHitTesting(false)
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
                    .font(.system(size: 27, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Stil.schrift.opacity(0.6))
            }
        }
        .buttonStyle(Pillenstil())
        .accessibilityLabel(Text("Staffel wählen, \(name)"))
    }
}

/// Fokus auf der Staffelpille: die ruhige Flaeche, wie bei Zeilen und Chips.
/// Weiss bleibt den Handlungsknoepfen vorbehalten.
private struct Pillenstil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, 26)
                .frame(height: 60)
                .background(fokus ? Stil.fokusflaeche : Stil.erhoeht,
                            in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 2))
                .scaleEffect(fokus ? 1.04 : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}
