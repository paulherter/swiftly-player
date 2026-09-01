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
    /// Dazu der Versatz, um den die ganze Seite tiefer steht.
    ///
    /// Vorher 486, gerechnet auf einen Textblock, der bei 140 ansetzte. Der
    /// beginnt jetzt bei 196 — dieselbe Zeile wie auf der Startseite —, und
    /// die Tafel muss mitwandern, sonst klappt sie mitten in die Knöpfe.
    ///
    /// Vorher waren es 210 **von unten**, gerechnet auf einen Kopf, der den
    /// ganzen Schirm füllte. Der ist 510 hoch — von unten gerechnet läge die
    /// Tafel jetzt mitten im Text.
    static let unterDerKnopfreihe: CGFloat = 486 + Stil.kopfversatzDetail

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
    /// Was hinten steht: „Direct Play" auf der Detailseite, sonst nichts.
    @ViewBuilder var schluss: () -> Schluss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.type == "Episode" ? (item.seriesName ?? item.name) : item.name)
                .font(.system(size: 60, weight: .bold))
                .tracking(-1.4)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                // Ein langer Titel schrumpft, statt die Seite zu verschieben.
                .minimumScaleFactor(0.62)
                .frame(height: 68, alignment: .leading)

            if let zweitzeile {
                Text(zweitzeile)
                    .font(.system(size: 38, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Stil.schrift.opacity(0.78))
                    .lineLimit(1)
                    .frame(height: 44, alignment: .leading)
                    .padding(.top, 10)
            }

            HStack(spacing: 24) {
                Text(angabenzeile)
                    .font(.system(size: 29))
                    .foregroundStyle(Stil.schrift.opacity(0.62))
                    .lineLimit(1)

                Belegzeile(direktplay: false, hinweis: nil,
                           bewertung: item.communityRating,
                           freigabe: item.officialRating)

                schluss()
            }
            .frame(height: 34)
            .padding(.top, 14)

            Text(item.overview ?? "")
                .font(.system(size: 29))
                .lineSpacing(11)
                .foregroundStyle(Stil.schrift.opacity(0.62))
                .lineLimit(zweitzeile == nil ? 3 : 2)
                .padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 1000, height: Stil.auskunftHoehe, alignment: .topLeading)
    }

    /// Jahr und Laufzeit — **ohne Genres**, siehe oben. Die Formatierung
    /// kommt aus `Titelangaben`, damit „1 Std 52 Min" überall gleich
    /// geschrieben steht.
    private var angabenzeile: String {
        var teile: [String] = []
        if item.type == "Episode", let kuerzel = item.folgenkuerzel { teile.append(kuerzel) }
        if let jahr = item.productionYear { teile.append(String(jahr)) }
        if let sekunden = item.runtimeSeconds, sekunden > 0 { teile.append(laufzeit(sekunden)) }
        return teile.joined(separator: " · ")
    }
}

/// „Noch 50 Minuten" mit Uhr, „Gesehen" mit Haken — oder nichts.
struct Restzeitmarke: View {
    let item: Item

    @ViewBuilder
    var body: some View {
        if let rest = item.restzeitText {
            Label(rest, systemImage: "clock")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(Stil.akzent)
                .lineLimit(1)
        } else if item.istGesehen {
            Label("Gesehen", systemImage: "checkmark")
                .font(.system(size: 27, weight: .medium))
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
/// **Fuer die Kulisse gilt das nicht mehr, und sie maskiert inzwischen.**
/// Sie ist kein Bedienelement und hat keinen Ring; der Satz oben stammt von
/// den Kacheln. Der Grund fuer den Wechsel steht unten am `mask`.
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
        // **Das Bild wird maskiert, nicht uebermalt** — und darin steckt der
        // ganze Unterschied.
        //
        // Vorher lagen zwei Verlaeufe aus `Stil.grund` **darueber**: links
        // deckendes #0B0B0D, nach rechts durchsichtig werdend. Das versteckt
        // das Bild zwar, setzt aber voraus, dass der Hintergrund genau
        // #0B0B0D ist. Sobald er sich faerbt, steht die uebermalte Flaeche
        // als Fleck darin — das war die harte senkrechte Kante.
        //
        // Als Maske faellt die **Deckkraft des Bildes selbst**. Es laeuft in
        // Transparenz aus, und was dahinterliegt, kommt durch, welche Farbe
        // es auch hat. Damit liegt das Bild vorn und der Ton dahinter, statt
        // ueber ihm.
        //
        // Der Einwand weiter oben — eine Maske nimmt den Fokusring mit —
        // gilt hier nicht: die Kulisse ist kein Bedienelement, sie traegt
        // `allowsHitTesting(false)` und hat nichts zu fokussieren.
        //
        .kulissenblende()
        // Bis an die Bildkante, ohne den Text mitzunehmen: der Textblock
        // haelt den Rand, das Bild tritt fuer sich hinaus.
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
            .mask {
                // **Die Mitte sitzt in der oberen rechten Ecke, nicht im
                // Bild.**
                //
                // Ein Kreis mitten im Bild faellt nach **allen** Seiten ab —
                // auch nach rechts und oben, wo nichts abfallen soll. Genau
                // das sah
                //
                // In die Ecke gelegt, hat jeder Schritt nach rechts oder oben
                // einen **kleineren** Abstand zur Mitte, wird also deckender
                // statt blasser. Dort kann nichts ausblenden. Nach links und
                // unten waechst der Abstand, und die Linien gleicher Deckkraft
                // sind Kreisboegen um die Ecke — rund, nicht eckig. Das ist
                // der Unterschied zu zwei Masken, deren Produkt eine Ecke
                // zeichnet.
                //
                // Waagerecht muss er weiter reichen als senkrecht: links liegt
                // der Text, unten nur die Reihe. Deshalb um 1,8 gedehnt, an
                // der Ecke verankert, damit sie liegen bleibt.
                //
                // Gerechnet in Bildkoordinaten (1180 x 700), Abstand von der
                // Ecke (1180 | 0), waagerecht durch 1,8 geteilt:
                //
                // Textende  (420 | 300)  →  √(422² + 300²) = 518   aus
                // Unterkante(1180 | 588) →  √(  0² + 588²) = 588   aus
                // Bildmitte (600 | 300)  →  √(322² + 300²) = 440   halb
                //
                // Mit Ende bei 520 ist der Text frei und die Unterkante
                // laengst aus, bevor die Kopfzone bei 588 endet.
                RadialGradient(gradient: Bildton.rundeBlende(),
                               center: UnitPoint(x: 1, y: 0),
                               startRadius: 200, endRadius: 520)
                    .scaleEffect(x: 1.8, y: 1, anchor: .topTrailing)
            }
    }
}

extension View {
    func kulissenblende() -> some View { modifier(Kulissenblende()) }
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
