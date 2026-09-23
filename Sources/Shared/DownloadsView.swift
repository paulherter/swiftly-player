import JellyfinKit
import SwiftUI

// MARK: - Der Ring

/// Ein Zeichen, sechs Lagen — überall dasselbe.
///
/// In der Zeile rechts, auf der Detailseite in einem Feld, in der Folgenliste
/// am Rand. **Zustand und Handlung in einer Form**, wie die Kachelplakette.
///
/// Der Akzent trägt hier ausnahmsweise eine Fläche, aber nur bei *fertig*:
/// das ist die einzige Lage, die keine Handlung mehr anbietet, sondern eine
/// Aussage macht. E2 verbietet dem Akzent Knopfflächen, nicht Marken.
///
/// **Und er dreht sich nicht.** Der Ladering ist im Rest der App verschwunden,
/// ersetzt durch Platzhalter in der Form des Inhalts. Hier bleibt ein Ring,
/// aber er füllt sich und trägt eine echte Zahl — der Unterschied zwischen
/// „ich weiss nicht, wie lange" und „noch sechs Minuten".
struct Downloadring: View {
    /// `nil` heisst: dieser Titel liegt nicht auf dem Gerät.
    let posten: Downloadposten?
    /// Der geschaetzte Stand zwischen zwei Meldungen — derselbe Wert wie
    /// Zahl und Balken daneben. Ohne ihn der gemeldete.
    var anteilJetzt: Double? = nil
    /// **28 in einer Zeile, 22 in einem Feld** — und das sind nicht zwei Masse
    /// fuer dieselbe Sache, sondern dieselbe Regel: das Zeichen waechst mit dem
    /// Ding, in dem es sitzt. Die Zeile ist 65 hoch, das Feld der Aktionsreihe
    /// 48; 28 zu 65 und 22 zu 48 sind dasselbe Verhaeltnis.
    var mass: CGFloat = 28
    let tippen: () -> Void

    var body: some View {
        // **Die Trefferflaeche gehoert in den Knopf, nicht um ihn herum.**
        //
        // `frame` und `contentShape` standen **hinter** dem `Button` — also
        // an der Huelle, nicht an seiner Beschriftung. Ein Knopf nimmt seine
        // Flaeche aber von dem, was er zeichnet, und gezeichnet werden hier
        // **Linien**: `Circle().strokeBorder` trifft nur auf dem Strich, der
        // Bogen ebenso. Zwischen ihnen war nichts.
        //
        // Beim Zustand ohne Download fiel es nicht auf — dort liegt ein
        // Pfeil in der Mitte, und der ist eine Flaeche. Beim Laden liegt dort
        // ein Quadrat von acht Punkt, und alles daneben ging ins Leere: der
        // Ring liess sich starten, aber nicht anhalten.
        Button(action: tippen) {
            zeichen
                .frame(width: max(mass, 44), height: max(mass, 44))
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(Text(ansage))
    }

    @ViewBuilder private var zeichen: some View {
        ZStack {
            switch posten?.stand {
            case nil:
                Circle().strokeBorder(Stil.schriftLeise, lineWidth: 1.5)
                bild("arrow.down", 13, Stil.schrift)
            case .wartet:
                Circle().strokeBorder(Stil.schriftSehrLeise,
                                      style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                bild("pause.fill", 11, Stil.schriftSehrLeise)
            case .laedt:
                bogen(anteil: anteilJetzt ?? posten?.anteil ?? 0, farbe: Stil.akzent)
                // Das Quadrat ist Halt, nicht Abbruch — ein Kreuz hiesse
                // wegwerfen, und weggeworfen wird hier nichts.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Stil.akzent)
                    .frame(width: mass * 0.32, height: mass * 0.32)
            case .angehalten:
                bogen(anteil: posten?.anteil ?? 0, farbe: Stil.schriftLeise)
                bild("play.fill", 11, Stil.schrift)
            case .fertig:
                // **Ein Pfeil, kein Haken.**
                //
                // Der Haken gehoert der Frage „hab ich das gesehen" — und in
                // der Folgenliste steht er zwei Zentimeter weiter links. Zwei
                // Haken nebeneinander, die Verschiedenes meinen, sind keine
                // Auskunft, sondern ein Suchbild.
                //
                // Gefuellt heisst hier fertig, wie ueberall sonst: dieselbe
                // Form wie beim Laden, nur voll statt hohl. Man liest sie als
                // „der Download ist ganz", nicht als „erledigt".
                Circle().fill(Stil.akzent)
                bild("arrow.down", 13, Stil.grund)
            case .fehler:
                // `fehler`, nicht `warnung`: ein abgebrochener Download ist
                // schiefgegangen. Das Zeichen bleibt, damit es nicht allein an
                // der Farbe haengt.
                Circle().strokeBorder(Stil.fehler, lineWidth: 2)
                bild("exclamationmark", 13, Stil.fehler)
            }
        }
        .frame(width: mass, height: mass)
        .animation(Stil.einblenden, value: posten?.stand)
    }

    private func bogen(anteil: Double, farbe: Color) -> some View {
        ZStack {
            // **Dieselbe Spur wie im `Fortschrittsbalken`** — und das war sie
            // einen Tag lang nicht.
            //
            // Hier stand `grund` mit 0,78, mit dem Vermerk „derselbe Ton wie
            // im Fortschrittsbalken, damit Ring und Balken dasselbe sagen".
            // Genau der wurde am 22.09. hell (weiss 30 %), und diese Stelle
            // ist stehen geblieben: zwei Fortschrittsanzeiger derselben App,
            // auf **demselben Bildschirm** — der Ring in der Zeile, der
            // Balken darunter —, einer dunkel und einer hell. Der Vermerk
            // behauptete dabei weiter Gleichheit.
            //
            // Der Grund fuers Helle steht beim `Fortschrittsbalken`: die Spur
            // ist die Laenge des Ganzen, nicht der fehlende Rest.
            Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, anteil))
                .stroke(farbe, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
                // **Der Bogen waechst, er springt nicht.**
                //
                // Ohne eigene Kurve setzt jede Meldung den Bogen hart auf den
                // neuen Wert. Bei einer schnellen Leitung sind das viele
                // kleine Spruenge in Folge, und mit runden Enden sieht das
                // aus, als zittere der Ring. Linear und ueber eine knappe
                // halbe Sekunde laeuft er ruhig — und bleibt trotzdem ehrlich,
                // weil er nie zurueckfaellt.
                .animation(.linear(duration: 0.4), value: anteil)
        }
    }

    private func bild(_ name: String, _ groesse: CGFloat, _ farbe: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: groesse, weight: .semibold))
            .foregroundStyle(farbe)
    }

    private var ansage: LocalizedStringKey {
        switch posten?.stand {
        case nil:          "Laden"
        case .wartet:      "Wartet"
        case .laedt:       "Lädt, anhalten"
        case .angehalten:  "Angehalten, fortsetzen"
        case .fertig:      "Geladen, entfernen"
        case .fehler:      "Fehlgeschlagen, erneut versuchen"
        }
    }
}

/// Was ein Tipp auf den Ring tut — an allen drei Stellen dasselbe.
///
/// Steht hier und nicht dreimal in den Ansichten: die Seite, die Folgenliste
/// und die Aktionsreihe stellen dieselbe Frage, also gibt es eine Antwort.
@MainActor
func ringGetippt(_ posten: Downloadposten?, _ verwaltung: Downloadverwaltung,
                 anlegen: () -> Void) {
    switch posten?.stand {
    case nil:          anlegen()
    case .laedt:       verwaltung.anhalten(posten!.id)
    case .angehalten,
         .fehler,
         .wartet:      verwaltung.fortsetzen(posten!.id)
    case .fertig:      break   // Entfernen läuft über das Blatt, nicht über einen Tipp.
    }
}

/// Das fünfte Feld der Aktionsreihe.
///
/// Heisst **`Downloadfeld`** und nicht `Ladefeld`: das ist seit dem
/// Gestaltungsdurchgang der Platzhalter in der Form des Inhalts, und zwei
/// Bausteine gleichen Namens in einer App sind der Anfang davon, dass jemand
/// den falschen nimmt.
///
/// **Ein eigener Baustein statt eines `Aktionsknopf` mit Auflage.** Zuerst
/// stand hier der Ring als `.overlay` über dem Knopf, mit einem eigenen
/// Grund darunter, damit das Zeichen darunter verschwindet — und dieser
/// Grund war ein Rechteck über einer Fläche mit 10 Punkt Ecke. Die vier
/// Ecken wären quadratisch übermalt gewesen, und zwar nur an diesem einen
/// Feld der Reihe. Ein Feld, das zwei Sachen zeigen kann, zeigt sie im
/// selben Baum, statt eine über die andere zu legen.
///
/// Masse und Fläche sind wörtlich die von ``Aktionsknopf`` — es steht in
/// derselben Reihe, und das darf man nicht sehen.
struct Downloadfeld: View {
    let posten: Downloadposten?
    var dehnt = true
    let tippen: () -> Void

    var body: some View {
        Button(action: tippen) {
            Group {
                if let p = posten, p.stand != .fertig {
                    Downloadring(posten: p, mass: 22) {}
                        .allowsHitTesting(false)
                } else {
                    // Dieselbe Unterscheidung wie am Ring: gefuellt heisst
                    // geladen, und es bleibt ein Pfeil. Der Haken daneben in
                    // derselben Reihe heisst „gesehen".
                    // 19 Medium stand in keiner Leiter; 17 Semibold ist die
                    // Stufe darunter und die, die es wirklich gibt.
                    Image(systemName: posten == nil ? "arrow.down" : "arrow.down.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(posten == nil ? Stil.schrift : Stil.akzent)
                }
            }
            .frame(maxWidth: dehnt ? .infinity : nil)
            // **48 und 48, wie der Nachbar.**
            //
            // Es stand auf 56 breit und 44 hoch, mit Rand, waehrend
            // `Aktionsknopf` unmittelbar daneben 48 im Quadrat ohne Rand
            // traegt. Drei Unterschiede in einer Reihe, in der alle Felder
            // dasselbe tun sollen. Der Vermerk, der hier stand, hat die
            // Kopplung sogar benannt — „bis er nachzieht, sieht man den
            // Unterschied" —, nur ist der Nachbar laengst nachgezogen und
            // dieses Feld stehen geblieben. Paul am 21.09.: „der Download-
            // Button auf der Filmseite ist noch falsch."
            .frame(width: dehnt ? nil : 48, height: 48)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(Text("Laden"))
        .accessibilityAddTraits(posten == nil ? .isButton : [.isButton, .isSelected])
    }
}

// MARK: - Eine Zeile

/// **Zeilen, keine Kacheln.**
///
/// Ein Download muss vier Dinge gleichzeitig zeigen: was, wie weit, wie gross
/// und was man drücken kann. Auf ein Plakat von 104 × 156 passt davon eins.
struct Downloadzeile: View {
    let model: AppModel
    let posten: Downloadposten
    /// Gesetzt, wenn die Zeile für eine ganze Serie steht (H12).
    var gruppe: (titel: String, folgen: [Downloadposten])?
    var bearbeiten = false
    @Binding var gewaehlt: Bool
    /// Was ein Tipp auf eine fertige Zeile tut. `nil` bei einer Gruppe — die
    /// fuehrt weiter, statt zu starten.
    var starten: (() -> Void)?

    private var verwaltung: Downloadverwaltung { model.downloads }
    /// Haelt den Schaetzer ueber die Neuzeichnungen; beobachtet wird er nicht,
    /// die Zeitleiste fragt ihn je Bild.
    @State private var schaetzer = Schaetzerhalter()

    /// **Waehrend geladen wird, zaehlt die Zeile je Bild weiter.**
    ///
    /// Die Verwaltung meldet hoechstens einmal je Sekunde; dazwischen rechnet
    /// `Fortschrittsschaetzer` im Tempo der letzten Sekunden weiter, wie es
    /// App Store und Musik tun. Zahl, Balken und Ring lesen **denselben**
    /// Wert — vorher sprang die Zahl stueckweise, und Balken und Ring
    /// liefen ihr je nach Animation voraus oder hinterher. 30 Bilder je
    /// Sekunde reichen fuer einen Balken; mehr kostet nur Akku.
    ///
    /// **Geschaetzt wird nur, solange wirklich Byte kommen.** Angehalten,
    /// wartend, fehlgeschlagen oder ohne Netz steht die Zahl sofort — und
    /// zwar dort, wo sie stand, nicht auf der letzten Meldung, die dahinter
    /// liegen kann.
    var body: some View {
        Group {
            if kommtWas {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { takt in
                    zeile(geladen: schaetzer.s.wert(um: takt.date))
                }
            } else if posten.stand == .angehalten || posten.stand == .laedt {
                zeile(geladen: max(schaetzer.s.wert(um: Date()), posten.geladen))
            } else {
                zeile(geladen: posten.geladen)
            }
        }
        .onChange(of: posten.geladen, initial: true) { _, neu in
            schaetzer.s.melden(neu, gesamt: posten.bytes, um: Date())
            if !kommtWas { schaetzer.s.anhalten() }
        }
        .onChange(of: kommtWas) { _, an in
            if !an { schaetzer.s.anhalten() }
        }
    }

    private var kommtWas: Bool {
        gruppe == nil && posten.stand == .laedt && !verwaltung.keinNetz
    }

    private func anteil(_ geladen: Int64) -> Double? {
        posten.bytes > 0 ? Double(geladen) / Double(posten.bytes) : posten.anteil
    }

    private func zeile(geladen: Int64) -> some View {
        HStack(spacing: 12) {
            if bearbeiten {
                // 21 war ein Einzelfall zwischen den Stufen; 20 Semibold ist
                // die Reihenueberschrift und damit die naechste echte.
                Image(systemName: gewaehlt ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schriftSehrLeise)
                    // **Der Kreis kommt von links herein und schiebt die
                    // Zeile vor sich her.** Mit `.opacity` stand er sofort
                    // in voller Breite da, und die Zeile rueckte nur um das,
                    // was die Blende noch uebrig liess. Bei reduzierter
                    // Bewegung bleibt es eine Blende.
                    .transition(Stil.bewegungReduziert
                                ? .opacity
                                : .move(edge: .leading).combined(with: .opacity))
            }

            Netzbild(url: bildadresse, zeichen: quer ? "tv" : "film")
                // 116 x 65 statt 104 x 59: dasselbe Standbild wie in der
                // Folgenliste der Serienseite. Zwei Maße fuer dieselbe Rolle
                // waren der Fehler.
                .frame(width: quer ? 116 : 64, height: quer ? 65 : 96)
                .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                // Eine Zeile traegt Semibold, nicht Medium — Medium gehoert
                // dem Titel unter einem Plakat. Der Token haelt beides
                // zusammen, damit es nicht wieder auseinanderlaeuft.
                Text(verbatim: gruppe?.titel ?? posten.titel)
                    .font(Stil.listentitel)
                    .lineLimit(1)
                // 12,5 war eine halbe Stufe zwischen zwei ganzen; die Angabe
                // unter einem Titel ist 12 Regular.
                Text(verbatim: unterzeile(geladen))
                    // **Tabellarisch.** „1,4 GB · 42 Min." steht in einer
                    // Liste untereinander, und BRAND 2 nennt Laufzeiten und
                    // Groessen ausdruecklich: gleich breite Ziffern, sonst
                    // wandern die Komma- und Punktstellen von Zeile zu Zeile.
                    .font(Stil.klein.monospacedDigit())
                    .foregroundStyle(unterfarbe)
                    .lineLimit(1)
                if let anteil = anteil(geladen), posten.stand == .laedt || posten.stand == .angehalten {
                    Fortschrittsbalken(anteil: anteil, rund: true)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if gruppe != nil {
                // 14 steht in keiner Leiter — ein Winkel ist 13 Semibold.
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Stil.schriftSehrLeise)
            } else if !bearbeiten {
                Downloadring(posten: posten, anteilJetzt: anteil(geladen)) {
                    ringGetippt(posten, verwaltung) {}
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .animation(Stil.blattbewegung, value: bearbeiten)
        // **Die Geste darf es nur im Auswahlmodus geben.**
        //
        // Hier stand sie fest, mit einem `if bearbeiten` im Rumpf — und ein
        // `onTapGesture` schluckt den Tipp auch dann, wenn sein Rumpf nichts
        // tut. Die Serienzeile liegt in einem `NavigationLink`, und der kam
        // dadurch nie an: ein Tipp auf „Breaking Bad" passierte einfach
        // nichts. Am Geraet gesehen, nicht im Bau.
        // **Ein Tipp spielt ab.** Das fehlte ganz: die Zeile trug nur die
        // Auswahl im Bearbeitenmodus. Abspielen und nicht die Detailseite —
        // die braucht den Server, und wer hier steht, hat womoeglich keinen.
        .modifier(Auswahltipp(an: bearbeiten || starten != nil) {
            if bearbeiten { gewaehlt.toggle() } else { starten?() }
        })
    }

    /// **Erst die Platte, dann der Server.** Ohne Netz gibt es nur die
    /// Platte, und genau dann wird diese Seite gebraucht.
    ///
    /// Eine Gruppenzeile trägt das Plakat der Serie, eine Folgenzeile ihr
    /// eigenes Querbild — sonst stünde in der Folgenliste dreimal dasselbe.
    private var bildadresse: URL? {
        let gruppig = gruppe != nil
        return verwaltung.bild(fuer: posten, alsGruppe: gruppig)
            ?? model.plakatURL(itemID: gruppig ? (posten.serienId ?? posten.id) : posten.id)
    }

    /// Hochkant für Filme und Serien, quer für eine einzelne Folge — dieselbe
    /// Unterscheidung wie in der Folgenliste der Serienseite.
    private var quer: Bool { gruppe == nil && posten.art == .folge }

    private func unterzeile(_ geladen: Int64) -> String {
        if let g = gruppe {
            let bytes = g.folgen.reduce(Int64(0)) { $0 + $1.bytes }
            return String(localized: "\(g.folgen.count) Folgen") + " · "
                + Downloadregeln.groesse(bytes)
        }
        var teile: [String] = []
        if let s = posten.staffel, let f = posten.folge {
            teile.append("S\(s) F\(f)")
        } else if let ticks = posten.laufzeitTicks, ticks > 0 {
            teile.append(laufzeit(Double(ticks) / 10_000_000))
        }
        switch posten.stand {
        case .laedt:
            // **Feste Einheit, feste Stellen.** `groesse` wechselte mitten
            // im Laden von „845 MB" auf „1 GB" und „1,01 GB" — Komma rein,
            // Komma raus, und die Zeile wurde bei jedem Schritt anders breit.
            // Am schlimmsten bei der ersten Folge, die unter einem Gigabyte
            // anfaengt. Die Gesamtgroesse gibt die Einheit vor.
            let f = Downloadregeln.fortschritt(geladen: geladen, von: posten.bytes)
            teile = [String(localized: "\(f.geladen) von \(f.gesamt)")]
        case .wartet:
            teile.append(String(localized: "wartet"))
        case .angehalten:
            teile.append(String(localized: "angehalten"))
        case .fehler:
            teile = [posten.grund ?? String(localized: "Fehlgeschlagen")]
        case .fertig:
            teile.append(Downloadregeln.groesse(posten.bytes))
            if let c = posten.container { teile.append(c.uppercased()) }
            // **H9.** Die Datei bleibt und bleibt spielbar; der Hinweis steht
            // leise daneben, nicht als Fehler.
            if !posten.nochAufDemServer {
                teile.append(String(localized: "nicht mehr auf dem Server"))
            }
        }
        return teile.joined(separator: " · ")
    }

    private var unterfarbe: Color {
        switch posten.stand {
        case .laedt:  Stil.akzent
        case .fehler: Stil.fehler
        // Ruhend ist die Unterzeile eine Angabe, keine Beschreibung: vorher
        // `schriftLeise`, und damit stand sie fast so laut da wie der Titel
        // darueber.
        default:      Stil.schriftSehrLeise
        }
    }
}

/// Eine Tippgeste, die es nur gibt, wenn sie gebraucht wird.
///
/// Ohne diesen Umweg müsste die Geste fest hängen und im Rumpf prüfen — und
/// dann verschluckt sie den Tipp trotzdem, weil SwiftUI beim Verteilen nicht
/// in den Rumpf sieht.
private struct Auswahltipp: ViewModifier {
    let an: Bool
    let tun: () -> Void

    func body(content: Content) -> some View {
        // **Immer ein Knopf, nur ohne Handlung, wenn keiner gebraucht
        // wird.** Hier stand ein `if an` um den Knopf: schaltete Bearbeiten
        // eine ladende Zeile von „ohne" auf „mit", war sie fuer SwiftUI eine
        // andere Ansicht — sie blendete ueber und rutschte verspaetet nach,
        // waehrend die uebrigen glitten. Ein innerer Knopf (der Ring) bekommt
        // seinen Tipp weiter selbst.
        //
        // **Ohne graue Flaeche.** `Druckzeile` legte Grau hinter die Zeile;
        // hier tippt man nur, um zu waehlen oder abzuspielen. Der Inhalt
        // dunkelt kurz ab — das reicht als Antwort.
        Button { if an { tun() } } label: { content }
            .buttonStyle(Abdunkeln(an: an))
            .accessibilityRemoveTraits(an ? [] : .isButton)
    }

}

private struct Abdunkeln: ButtonStyle {
    var an = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(an && configuration.isPressed ? 0.6 : 1)
            .animation(Stil.druckkurve(configuration.isPressed),
                       value: configuration.isPressed)
    }
}

/// Eine Huelle, damit der Schaetzer die Neuzeichnungen ueberlebt, ohne dass
/// jede Schaetzung eine neue auslöst.
private final class Schaetzerhalter {
    var s = Fortschrittsschaetzer()
}

// MARK: - Die Seite

struct DownloadsView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @State private var versatz: CGFloat = 0
    @State private var bearbeiten = false
    @State private var gewaehlt: Set<String> = []
    @State private var loeschblatt = false
    @State private var offeneSerie: DownloadserieRoute?

    private var verwaltung: Downloadverwaltung { model.downloads }

    private var laufend: [Downloadposten] {
        verwaltung.posten.filter { $0.stand != .fertig }
    }
    private var fertige: [Downloadgruppe] {
        Downloadregeln.gruppiert(verwaltung.posten.filter { $0.stand == .fertig })
    }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !laufend.isEmpty {
                        // **Der Rand wird zurueckgerechnet, nicht addiert.**
                        //
                        // `Gruppentitel` bringt `randAbstand` selbst mit, und
                        // der `VStack` unten legt noch einmal `rand(breit:)`
                        // darum: die Ueberschrift stand sichtbar 18 Punkt
                        // weiter innen als ihre eigene Liste. So macht es
                        // `Einstellungsgruppe` schon, Zeichen fuer Zeichen.
                        Gruppentitel(text: verwaltung.keinNetz ? "Wartet auf Netz" : "Lädt gerade")
                            .padding(.horizontal, Stil.rand(breit: breit) - Stil.randAbstand)
                            .padding(.top, 4)
                        // **Auch was laeuft, laesst sich entfernen.**
                        //
                        // Diese Zeilen bekamen `gewaehlt: .constant(false)`
                        // und kein `bearbeiten` — sie liessen sich also gar
                        // nicht ankreuzen. Wer einen Download versehentlich
                        // angestossen hat, musste warten, bis er fertig war,
                        // um ihn wieder loszuwerden. `entfernen` bricht die
                        // Aufgabe ohnehin ab; es fehlte nur der Weg dorthin.
                        ForEach(laufend) { p in
                            Downloadzeile(model: model, posten: p,
                                          bearbeiten: bearbeiten,
                                          gewaehlt: bindung(fuer: [p.id]))
                            // Keine Trennlinie: die Zeile traegt ein Bild,
                            // und das trennt schon. Steht in BRAND.md,
                            // Abschnitt 7, „Die Zeile mit Bild".
                        }
                    }

                    if !fertige.isEmpty {
                        // **Keine Ueberschrift ueber dem Geladenen.** Hier
                        // stand „Auf dem Gerät" — auf der Downloadseite ist
                        // alles auf dem Geraet, der Satz sagte nichts. Der
                        // Abstand zu „Lädt gerade" darueber bleibt.
                        Color.clear.frame(height: laufend.isEmpty ? 4 : 26)
                        ForEach(fertige) { g in
                            zeileFuer(g)

                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 24)
                // **Volle Breite, wie jede andere Seite.**
                //
                // Hier stand eine Grenze bei 900 Punkt, mit der Begruendung,
                // eine Zeile aus Bild, Titel und Ring habe in der Mitte nichts
                // zu sagen. Das stimmt fuer sich — nur endeten damit
                // Trennlinien und Ringe rund dreihundert Punkt vor dem Rand,
                // waehrend Titel und Balken im Kopf darueber bis nach rechts
                // liefen. Zwei Kanten auf einer Seite, und die Seite sah
                // abgeschnitten aus.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.bottom, bearbeiten ? 84 : 24, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, neu in versatz = neu }
            .animation(Stil.einblenden, value: verwaltung.posten.count)
            // **Nur die Scrollflaeche zieht sich beim Wechsel heran.**
            .bereichsinhalt()
            // **Und der Kopf danach, nicht davor.**
            //
            // Modifikatoren wickeln sich von innen nach aussen: was vor
            // `bereichsinhalt` steht, steckt darin und wird mitbewegt. Der
            // Kopf stand davor, also schob er sich beim Oeffnen der
            // Downloadseite mit herein. Auf Filme und Serien steht er seit der
            // Umstellung dahinter, und genau deshalb liegt er dort fest.
            //
            // Er sitzt als Sicherheitsrand statt als Auflage; die Begruendung
            // dafuer steht ausfuehrlich in `HauptView`.
            .safeAreaInset(edge: .top, spacing: 0) { kopf }


            if verwaltung.posten.isEmpty {
                // **Kein Knopf „Was kann ich laden".** Netflix hat einen, weil
                // dort nicht alles ladbar ist. Bei uns schon — der Knopf
                // führte nur in die Bibliothek zurück. Der Satz sagt
                // stattdessen, **wo** der Anfang ist.
                Leerzustand(symbol: "arrow.down.circle",
                            kopfzeile: "Noch nichts geladen",
                            text: "Lad was runter, bevor der Zug ins Funkloch fährt.")
                    // **Die Navileiste abrechnen**, wie auf der
                    // Bibliotheksseite: der Block sitzt mittig im ganzen
                    // Fenster, und schmal liegen die unteren 54 Punkt davon
                    // unter der Leiste.
                    .padding(.bottom, breit ? 0 : Stil.leisteHoehe)
                    // Das Wann zum Wie aus `Leerzustand`.
                    .animation(Stil.einblenden, value: verwaltung.posten.isEmpty)
                    // Zieht beim Bereichswechsel mit heran, wie die
                    // Scrollflaeche darunter — ohne eigenen Grund, sonst
                    // deckte er den Kopf zu.
                    .bereichsmitzug()
            }
        }
        .safeAreaInset(edge: .bottom) { if bearbeiten { loeschleiste } }
        .navigationDestination(item: $offeneSerie) { route in
            DownloadserieView(model: model, route: route)
        }
        #if os(iOS)
        .playerCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
        .bereichsleiste()
        // **Nach der Leiste, nicht davor.** Auflagen liegen in der
        // Reihenfolge, in der sie angehängt werden; davor angehängt schnitt
        // die Bereichsleiste dem Blatt den unteren Rand ab. Dieselbe
        // Reihenfolge steht seit `e916847` in den anderen Wurzelansichten.
        .overlay(alignment: .topTrailing) {
            Handlungsblatt(offen: $loeschblatt, titel: loeschtitel, handlungen: [
                Titelhandlung(symbol: "trash", text: "Entfernen", warnend: true) {
                    verwaltung.entfernen(Array(gewaehlt))
                    gewaehlt = []
                    withAnimation(Stil.einblenden) { bearbeiten = false }
                }
            ])
        }
    }

    @ViewBuilder
    private func zeileFuer(_ g: Downloadgruppe) -> some View {
        switch g {
        case let .einzeln(p):
            Downloadzeile(model: model, posten: p, bearbeiten: bearbeiten,
                          gewaehlt: bindung(fuer: [p.id]),
                          starten: p.stand == .fertig ? { spiele(p) } : nil)
        case let .serie(id, titel, folgen):
            // **Eine Zeile in beiden Lagen, kein Tausch.** Hier stand ein
            // `NavigationLink` ausserhalb und eine zweite Zeile im
            // Bearbeiten — fuer SwiftUI zwei verschiedene Ansichten, also
            // blendete die Serienzeile beim Umschalten ueber, statt zu
            // gleiten. Jetzt dieselbe Zeile; der Weg zur Serie geht ueber
            // `offeneSerie`.
            Downloadzeile(model: model, posten: folgen[0],
                          gruppe: (titel, folgen), bearbeiten: bearbeiten,
                          gewaehlt: bindung(fuer: folgen.map(\.id)),
                          starten: { offeneSerie = DownloadserieRoute(serienId: id, titel: titel) })
        }
    }

    /// Eine Serie wird als Ganzes gewählt — halb ausgewählte Gruppen gäbe es
    /// sonst nur, um sie danach doch wieder zu erklären.
    private func bindung(fuer ids: [String]) -> Binding<Bool> {
        Binding(
            get: { !ids.isEmpty && ids.allSatisfy { gewaehlt.contains($0) } },
            set: { an in
                if an { gewaehlt.formUnion(ids) } else { gewaehlt.subtract(ids) }
            })
    }

    @State private var abspielen: Abspielwunsch?

    /// **Ohne Server.** `model.plan` nimmt die Datei von der Platte, wenn eine
    /// da ist (H8), und das `Item` dafuer baut sich der Posten selbst — im
    /// Flugzeug gibt es keinen, der eines liefern koennte.
    private func spiele(_ p: Downloadposten) {
        Task {
            guard let plan = await model.plan(for: p.id) else { return }
            abspielen = Abspielwunsch(item: p.alsItem, plan: plan, startAt: 0)
        }
    }

    private var loeschtitel: String { Loeschleiste.titel(gewaehlt, in: verwaltung) }

    // MARK: Kopf

    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            VStack(alignment: .leading, spacing: 12) {
                // Mittig, nicht oben — siehe HauptView: ohne die Zeile unter
                // dem Titel liegt `.top` daneben.
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloads").font(Stil.titelGross).tracking(Stil.sperrungTitel)
                        // **Keine Zeile unter dem Titel.**
                        //
                        // Hier stand die Belegung — Titelzahl, Groesse, freier
                        // Platz. Dieselbe Auskunft steht am Speicherbalken
                        // weiter unten, und ein Seitentitel mit Unterbau sieht
                        // anders aus als jede andere Wurzelseite. Ohne Netz
                        // sagt das der Leerzustand beziehungsweise die
                        // Zustandszeile an der Zeile selbst. Paul am 21.09.
                    }
                    Spacer(minLength: 0)
                    // **Bearbeiten gibt es breit wie schmal.**
                    //
                    // Schmal steht es in der Zeichengruppe oben rechts — an
                    // der Stelle, an der auf der Startseite das Angebot
                    // „hier weiterschauen" steht, links vom Paar aus
                    // Merkliste und Profil. Breit gibt es diese Gruppe nicht,
                    // die wohnt in der Seitenleiste; dann steht es allein.
                    // Es nur schmal zu zeigen hiesse, dass man auf dem iPad
                    // nichts entfernen kann.
                    if breit {
                        bearbeitenknopf
                    } else {
                        Kopfziele(name: model.session?.userName ?? "?",
                                  bild: model.benutzerbildURL()) { bearbeitenknopf }
                    }
                }
                .foregroundStyle(Stil.schrift)

                if !verwaltung.posten.isEmpty { speicherbalken }
            }
        }
    }

    @ViewBuilder
    private var bearbeitenknopf: some View {
        if !verwaltung.posten.isEmpty {
            Bearbeitenknopf(bearbeiten: $bearbeiten, gewaehlt: $gewaehlt)
        }
    }


    /// **Statt einer Obergrenze.** H7: eine Grenze, die man nicht selbst
    /// gesetzt hat, ärgert genau dann, wenn man sie braucht. Ein Balken sagt
    /// dasselbe, ohne etwas zu verbieten.
    private var speicherbalken: some View {
        let unser = Double(Downloadregeln.belegung(verwaltung.posten).bytes)
        let frei = Double(max(verwaltung.frei, 0))
        let ganz = max(unser + frei, 1)
        return GeometryReader { r in
            HStack(spacing: 0) {
                Stil.akzent.frame(width: r.size.width * unser / ganz)
                // Das freie Stueck war weiss 0,22 — ein roher Wert und ein
                // zweiter Farbton neben dem Akzent. `erhoeht` ist die Flaeche,
                // die es dafuer gibt, und sie liegt richtig herum: heller als
                // der Grund, leiser als der eigene Anteil.
                Stil.erhoeht.frame(width: r.size.width * frei / ganz)
                Color.clear
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// **Über der Bereichsleiste, nicht darunter.**
    ///
    /// `bereichsleiste()` legt die Leiste als Auflage über die Seite; ein
    /// `safeAreaInset` steckt dagegen im Inhalt und liegt damit darunter.
    /// Ohne den Abstand ragte vom Knopf nur ein weisser Streifen über der
    /// Leiste hervor — am Gerät gesehen, im Bau nicht zu bemerken.
    ///
    /// Die Leiste bleibt stehen und wird nicht ausgeblendet: wer beim
    /// Aufräumen den Bereich wechseln will, soll das können, ohne erst den
    /// Auswahlmodus zu verlassen.
    private var loeschleiste: some View {
        Loeschleiste(titel: loeschtitel, aktiv: !gewaehlt.isEmpty) { loeschblatt = true }
    }
}

/// Stift und Kreuz oben rechts — auf der Downloadliste und auf der Seite
/// einer geladenen Serie derselbe Knopf.
struct Bearbeitenknopf: View {
    @Binding var bearbeiten: Bool
    @Binding var gewaehlt: Set<String>

    var body: some View {
        Button {
            // Dieselbe Kurve wie die Blaetter: die Zeilen gleiten.
            withAnimation(Stil.blattbewegung) {
                bearbeiten.toggle()
                if !bearbeiten { gewaehlt = [] }
            }
        } label: {
            // 18 Medium war die dritte Groesse fuer dasselbe Zeichen auf
            // dieser Seite; 17 Semibold ist die Stufe der Leiter.
            Image(systemName: bearbeiten ? "xmark" : "pencil")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(bearbeiten ? Stil.akzent : Stil.schrift)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(Text("Bearbeiten"))
    }
}

/// **Über der Bereichsleiste, nicht darunter** — siehe `DownloadsView`.
struct Loeschleiste: View {
    @Environment(\.breit) private var breit
    let titel: String
    let aktiv: Bool
    let tun: () -> Void

    var body: some View {
        Button(action: tun) { Text(verbatim: titel) }
            .buttonStyle(HauptknopfStil(dehnt: true))
            .disabled(!aktiv)
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.bottom, breit ? 8 : Stil.leisteHoehe + 8)
            .background(Stil.grund.ignoresSafeArea())
    }

    /// „3 entfernen · 7,42 GB".
    static func titel(_ gewaehlt: Set<String>, in verwaltung: Downloadverwaltung) -> String {
        let bytes = verwaltung.posten.filter { gewaehlt.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return String(localized: "\(gewaehlt.count) entfernen")
            + " · " + Downloadregeln.groesse(bytes)
    }
}

// MARK: - Die Folgen einer geladenen Serie

struct DownloadserieRoute: Hashable {
    let serienId: String
    let titel: String
}

/// **Die Serie auf dem Geraet, als Detailseite.**
///
/// Hier stand eine blosse Liste unter Serienname und „N Folgen · X GB".
/// Paul wollte, was der Rest der App hat: oben das grosse Bild, der Name,
/// ein Abspielknopf, darunter die Folgen nach Staffel. Gebaut aus den
/// Bausteinen der Serienseite (`Heldbild`, `Heldauslauf`, `HauptknopfStil`,
/// `Detailkopfleser`) — keine eigene Gestaltung.
///
/// **Alles von der Platte.** Wer hier steht, hat womoeglich kein Netz: das
/// Bild ist das gesicherte Querbild der naechsten Folge, sonst das Plakat
/// der Serie, und erst danach eine Serveradresse. Der Knopf spielt die
/// Datei ueber `model.plan`, das die Platte zuerst nimmt (H8).
struct DownloadserieView: View {
    let model: AppModel
    let route: DownloadserieRoute

    @Environment(\.dismiss) private var schliessen
    @Environment(\.breit) private var breit
    /// Siehe `SeriesDetailView.weg` — als `@State`-Zahl baute jeder
    /// Scrollschritt die Seite neu.
    @State private var weg = Scrollweg()
    @State private var abspielen: Abspielwunsch?
    @State private var bearbeiten = false
    @State private var gewaehlt: Set<String> = []
    @State private var loeschblatt = false
    @Environment(\.displayScale) private var pixelmass
    @State private var seitenbreite: CGFloat = 0
    /// Das nachgeholte Kopfbild, sobald es liegt.
    @State private var nachgeholt: URL?

    private func spiele(_ p: Downloadposten) {
        Task {
            guard let plan = await model.plan(for: p.id) else { return }
            abspielen = Abspielwunsch(item: p.alsItem, plan: plan, startAt: 0)
        }
    }

    private var folgen: [Downloadposten] {
        model.downloads.posten
            .filter { $0.serienId == route.serienId }
            .sorted { ($0.staffel ?? 0, $0.folge ?? 0) < ($1.staffel ?? 0, $1.folge ?? 0) }
    }

    /// Nach Staffel, in der Reihenfolge der Staffeln.
    private var staffeln: [(nummer: Int?, folgen: [Downloadposten])] {
        var reihe: [Int?] = []
        var je: [Int?: [Downloadposten]] = [:]
        for p in folgen {
            if je[p.staffel] == nil { reihe.append(p.staffel) }
            je[p.staffel, default: []].append(p)
        }
        return reihe.map { ($0, je[$0] ?? []) }
    }

    private var naechste: Downloadposten? { Downloadregeln.naechsteFolge(aus: folgen) }

    /// **Zuerst das grosse Kopfbild der Serie** — seit dem 22.09. laedt es
    /// mit dem ersten Download in Bildschirmaufloesung mit. Davor stand hier
    /// das Querbild der Folge (220 hoch) oder das Plakat (300 hoch), beide
    /// fuer Zeilen gemessen und im Kopf sichtbar weich.
    private var kopfbild: URL? {
        guard let p = naechste ?? folgen.first else { return nil }
        if let gross = nachgeholt ?? model.downloads.kopfbild(serie: route.serienId, konto: p.konto) {
            return gross
        }
        return model.downloads.bild(fuer: p)
            ?? model.downloads.bild(fuer: p, alsGruppe: true)
            ?? model.plakatURL(itemID: p.serienId ?? p.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **Breit derselbe Kopf wie auf der Serienseite** —
                    // `Heldkopf` mit Plakat neben Name und Knopf. Ein 300
                    // Punkt hoher Streifen über die ganze iPad-Breite ist
                    // kein Heldbild mehr; die Begründung steht dort.
                    if breit {
                        Heldkopf(bild: kopfbild, poster: plakat,
                                 titel: route.titel, nebenzeile: angabe) {
                            hauptknopf
                        }
                        Color.clear.frame(height: 22)
                    } else {
                    Heldbild(url: kopfbild)
                        .overlay(alignment: .bottom) { Heldauslauf() }
                        .overlay(alignment: .bottomLeading) { titelblock }

                    hauptknopf
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 14)
                        .padding(.bottom, 22)
                    }

                    ForEach(staffeln, id: \.nummer) { staffel in
                        if let n = staffel.nummer {
                            Gruppentitel(text: "Staffel \(n)")
                                .padding(.horizontal, Stil.rand(breit: breit) - Stil.randAbstand)
                                .padding(.top, 6)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(staffel.folgen) { p in folgenzeile(p) }
                        }
                        .padding(.bottom, 16)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                weg.setzen(neu)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { seitenbreite = $0 }
            .ignoresSafeArea(edges: .top)

            Detailkopfleser(titel: route.titel, weg: weg, zurueck: { schliessen() }) {
                Bearbeitenknopf(bearbeiten: $bearbeiten, gewaehlt: $gewaehlt)
            }
        }
        .task(id: seitenbreite > 0) { await kopfbildNachholen() }
        .safeAreaInset(edge: .bottom) {
            if bearbeiten {
                Loeschleiste(titel: Loeschleiste.titel(gewaehlt, in: model.downloads),
                             aktiv: !gewaehlt.isEmpty) { loeschblatt = true }
            }
        }
        .overlay(alignment: .topTrailing) {
            Handlungsblatt(offen: $loeschblatt,
                           titel: Loeschleiste.titel(gewaehlt, in: model.downloads),
                           handlungen: [
                Titelhandlung(symbol: "trash", text: "Entfernen", warnend: true) {
                    entfernen(Array(gewaehlt))
                    gewaehlt = []
                    withAnimation(Stil.blattbewegung) { bearbeiten = false }
                }
            ])
        }
        // **Die letzte Folge weg, die Seite weg.** Eine Serienseite ohne
        // Folgen hat nichts mehr zu zeigen; zurueck in die Liste.
        .onChange(of: folgen.isEmpty) { _, leer in if leer { schliessen() } }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        .playerCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
    }

    /// **Drei Wege zum Entfernen, wie in iOS ueblich.** Paul fand den Ring
    /// an jeder Folge nicht als Loeschweg — er ist keiner, er haelt an und
    /// setzt fort. Jetzt: nach links wischen, lange druecken, oder oben
    /// Bearbeiten mit Auswahlkreisen und dem Knopf unten, wie in der Liste.
    ///
    /// Die Wischzeile laeuft ueber die volle Breite, damit das Rot bis an
    /// den Rand geht; den Seitenrand traegt die Zeile selbst. Getippt wird
    /// in der Zeile (`starten`, im Bearbeiten die Auswahl) — die Wischzeile
    /// selbst tut beim Tippen nichts.
    private func folgenzeile(_ p: Downloadposten) -> some View {
        Wischzeile(symbol: "trash", beschriftung: "Entfernen", farbe: Stil.fehler,
                   aktion: { entfernen([p.id]) }, tippen: {}) {
            Downloadzeile(model: model, posten: p, bearbeiten: bearbeiten,
                          gewaehlt: Binding(
                            get: { gewaehlt.contains(p.id) },
                            set: { an in if an { gewaehlt.insert(p.id) } else { gewaehlt.remove(p.id) } }),
                          starten: p.stand == .fertig ? { spiele(p) } : nil)
                .padding(.horizontal, Stil.rand(breit: breit))
        }
        .contextMenu {
            Button(role: .destructive) { entfernen([p.id]) } label: {
                Label("Download entfernen", systemImage: "trash")
            }
        }
    }

    private func entfernen(_ ids: [String]) {
        withAnimation(Stil.einblenden) { model.downloads.entfernen(ids) }
    }

    /// **Downloads von vorher haben kein grosses Kopfbild** — mit Netz wird
    /// es hier einmal nachgeholt. Ohne Netz scheitert die Abfrage still, und
    /// es bleibt beim Bild von der Platte.
    private func kopfbildNachholen() async {
        guard seitenbreite > 0, let p = folgen.first,
              model.downloads.kopfbild(serie: route.serienId, konto: p.konto) == nil,
              let serie = await model.item(id: route.serienId) else { return }
        // Breit ist der Kopf mindestens `heldHoeheBreit` hoch.
        let punkte = max(seitenbreite, (breit ? Stil.heldHoeheBreit : Stil.heldHoehe) * 16 / 9)
        guard let adresse = model.kopfbildURL(for: serie,
                                              breite: Int((punkte * pixelmass).rounded(.up)))
        else { return }
        nachgeholt = await model.downloads.kopfbildNachholen(serie: route.serienId,
                                                             konto: p.konto, von: adresse)
    }

    /// „12 Folgen · 18,4 GB".
    private var angabe: String {
        String(localized: "\(folgen.count) Folgen") + " · "
            + Downloadregeln.groesse(folgen.reduce(0) { $0 + $1.bytes })
    }

    /// Das Plakat der Serie von der Platte — für den breiten Kopf.
    private var plakat: URL? {
        guard let p = folgen.first else { return nil }
        return model.downloads.bild(fuer: p, alsGruppe: true)
            ?? model.plakatURL(itemID: p.serienId ?? p.id)
    }

    /// Name und Angabe unten auf dem Bild — wie auf der Serienseite.
    private var titelblock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: route.titel)
                .font(Stil.titel)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
            Text(verbatim: angabe)
                .font(Stil.klein)
                .monospacedDigit()
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.bottom, 16)
    }

    /// **Die naechste ungesehene Folge**, sonst von vorn — die Regel steht
    /// in `Downloadregeln.naechsteFolge`. Beschriftet wie auf der
    /// Serienseite („Abspielen S2 F6").
    private var hauptknopf: some View {
        Button {
            if let naechste { spiele(naechste) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.system(size: 15))
                    .accessibilityHidden(true)
                Text(verbatim: Item.serienknopf(folge: naechste?.alsItem, laedt: false))
            }
        }
        .buttonStyle(HauptknopfStil(dehnt: !breit))
        .disabled(naechste == nil)
    }
}
