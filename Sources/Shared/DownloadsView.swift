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
    var mass: CGFloat = 28
    let tippen: () -> Void

    var body: some View {
        Button(action: tippen) { zeichen }
            .buttonStyle(.plain)
            .frame(width: max(mass, 44), height: max(mass, 44))
            .contentShape(Rectangle())
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
                bogen(anteil: posten?.anteil ?? 0, farbe: Stil.akzent)
                // Das Quadrat ist Halt, nicht Abbruch — ein Kreuz hiesse
                // wegwerfen, und weggeworfen wird hier nichts.
                RoundedRectangle(cornerRadius: 1.5)
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
                Circle().strokeBorder(Stil.warnung, lineWidth: 2)
                bild("exclamationmark", 13, Stil.warnung)
            }
        }
        .frame(width: mass, height: mass)
        .animation(Stil.einblenden, value: posten?.stand)
    }

    private func bogen(anteil: Double, farbe: Color) -> some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, anteil))
                .stroke(farbe, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
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
                    Image(systemName: posten == nil ? "arrow.down" : "arrow.down.circle.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(posten == nil ? Stil.schrift : Stil.akzent)
                }
            }
            .frame(maxWidth: dehnt ? .infinity : nil)
            .frame(width: dehnt ? nil : 56, height: 44)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        HStack(spacing: 12) {
            if bearbeiten {
                Image(systemName: gewaehlt ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schriftSehrLeise)
                    .transition(.opacity)
            }

            Netzbild(url: bildadresse, zeichen: quer ? "tv" : "film")
                .frame(width: quer ? 104 : 64, height: quer ? 59 : 96)
                .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel))

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: gruppe?.titel ?? posten.titel)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: unterzeile)
                    .font(.system(size: 12.5))
                    .foregroundStyle(unterfarbe)
                    .lineLimit(1)
                if let anteil = posten.anteil, posten.stand == .laedt || posten.stand == .angehalten {
                    Fortschrittsbalken(anteil: anteil)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if gruppe != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Stil.schriftSehrLeise)
            } else if !bearbeiten {
                Downloadring(posten: posten) {
                    ringGetippt(posten, verwaltung) {}
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .animation(Stil.einblenden, value: bearbeiten)
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

    private var unterzeile: String {
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
            teile = [Downloadregeln.groesse(posten.geladen) + " "
                     + String(localized: "von") + " "
                     + Downloadregeln.groesse(posten.bytes)]
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
        case .fehler: Stil.warnung
        default:      Stil.schriftLeise
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
        if an {
            content.onTapGesture(perform: tun)
        } else {
            content
        }
    }
}

// MARK: - Die Seite

struct DownloadsView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @State private var versatz: CGFloat = 0
    @State private var kopfhoehe: CGFloat = 112
    @State private var bearbeiten = false
    @State private var gewaehlt: Set<String> = []
    @State private var loeschblatt = false

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
                        Gruppentitel(text: verwaltung.keinNetz ? "Wartet auf Netz" : "Lädt gerade")
                            .padding(.top, 4)
                        ForEach(laufend) { p in
                            Downloadzeile(model: model, posten: p, gewaehlt: .constant(false))
                            if p.id != laufend.last?.id { Trennlinie() }
                        }
                    }

                    if !fertige.isEmpty {
                        Gruppentitel(text: "Auf dem Gerät")
                            .padding(.top, laufend.isEmpty ? 4 : 26)
                        ForEach(fertige) { g in
                            zeileFuer(g)
                            if g.id != fertige.last?.id { Trennlinie() }
                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 24)
                // **Lesemaß, nicht Fensterbreite.** Breit läuft eine Zeile
                // aus Bild, Titel und einem Ring sonst über die ganze Seite
                // und hat in der Mitte nichts zu sagen. Dieselbe Grenze wie
                // auf dem Mac.
                .frame(maxWidth: breit ? 900 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, kopfhoehe + 12, for: .scrollContent)
            .contentMargins(.bottom, bearbeiten ? 84 : 24, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, neu in versatz = neu }
            .animation(Stil.einblenden, value: verwaltung.posten.count)

            kopf
                // **Nur bei einer echten Aenderung uebernehmen.**
                //
                // Die gemessene Kopfhoehe geht als `contentMargins(.top,)` in
                // dieselbe Scrollflaeche zurueck, die sie misst — das ist ein
                // Kreis. Solange die Hoehe steht, ruht er; wackelt sie um
                // Bruchteile eines Punktes, schaukelt er sich auf, und die
                // ganze Seite faehrt sichtbar auf und ab.
                //
                // Ein Punkt Schwelle bricht den Kreis, ohne etwas zu kosten:
                // um weniger als einen Punkt darf sich der obere Rand ruhig
                // irren, sehen kann man es nicht.
                .onGeometryChange(for: CGFloat.self) { $0.size.height }
                    action: { neu in
                        if abs(neu - kopfhoehe) >= 1 { kopfhoehe = neu }
                    }

            if verwaltung.posten.isEmpty {
                // **Kein Knopf „Was kann ich laden".** Netflix hat einen, weil
                // dort nicht alles ladbar ist. Bei uns schon — der Knopf
                // führte nur in die Bibliothek zurück. Der Satz sagt
                // stattdessen, **wo** der Anfang ist.
                Leerzustand(symbol: "arrow.down.circle",
                            kopfzeile: "Noch nichts geladen",
                            text: "Auf jeder Film- und Serienseite gibt es ein Feld zum Laden. Geladene Titel laufen auch ohne Netz — in voller Qualität, weil Swiftly nie umrechnet.")
            }
        }
        .safeAreaInset(edge: .bottom) { if bearbeiten { loeschleiste } }
        #if os(iOS)
        .fullScreenCover(item: $abspielen) { wunsch in
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
        .bereichsinhalt()
    }

    @ViewBuilder
    private func zeileFuer(_ g: Downloadgruppe) -> some View {
        switch g {
        case let .einzeln(p):
            Downloadzeile(model: model, posten: p, bearbeiten: bearbeiten,
                          gewaehlt: bindung(fuer: [p.id]),
                          starten: p.stand == .fertig ? { spiele(p) } : nil)
        case let .serie(id, titel, folgen):
            if bearbeiten {
                Downloadzeile(model: model, posten: folgen[0],
                              gruppe: (titel, folgen), bearbeiten: true,
                              gewaehlt: bindung(fuer: folgen.map(\.id)))
            } else {
                NavigationLink(value: DownloadserieRoute(serienId: id, titel: titel)) {
                    Downloadzeile(model: model, posten: folgen[0],
                                  gruppe: (titel, folgen),
                                  gewaehlt: .constant(false))
                }
                .buttonStyle(.plain)
            }
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

    private var loeschtitel: String {
        let bytes = verwaltung.posten.filter { gewaehlt.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return String(localized: "\(gewaehlt.count) entfernen")
            + " · " + Downloadregeln.groesse(bytes)
    }

    // MARK: Kopf

    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloads").font(Stil.titelGross).tracking(-0.6)
                        // **Der Tag, für den das Ganze gebaut ist.** Ohne Netz
                        // wechselt die Zeile auf Warnfarbe und sagt eine
                        // nützliche Zahl, nicht das Wort „offline".
                        Text(verbatim: belegungszeile)
                            .font(.system(size: 13))
                            .foregroundStyle(verwaltung.keinNetz ? Stil.warnung : Stil.schriftSehrLeise)
                            .lineLimit(1)
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
            Button {
                withAnimation(Stil.einblenden) {
                    bearbeiten.toggle()
                    if !bearbeiten { gewaehlt = [] }
                }
            } label: {
                Image(systemName: bearbeiten ? "xmark" : "pencil")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(bearbeiten ? Stil.akzent : Stil.schrift)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Bearbeiten"))
        }
    }

    private var belegungszeile: String {
        let b = Downloadregeln.belegung(verwaltung.posten)
        if verwaltung.keinNetz {
            return String(localized: "Kein Netz") + " · "
                + String(localized: "\(b.anzahl) Titel spielbar")
        }
        guard b.anzahl > 0 || !laufend.isEmpty else {
            return String(localized: "Nichts auf dem Gerät")
        }
        return String(localized: "\(b.anzahl) Titel") + " · "
            + Downloadregeln.groesse(b.bytes) + " · "
            + Downloadregeln.groesse(verwaltung.frei) + " " + String(localized: "frei")
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
                Color.white.opacity(0.22).frame(width: r.size.width * frei / ganz)
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
        Button { loeschblatt = true } label: {
            Text(verbatim: loeschtitel)
        }
        .buttonStyle(HauptknopfStil(dehnt: true))
        .disabled(gewaehlt.isEmpty)
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.bottom, breit ? 8 : Stil.leisteHoehe + 8)
        .background(Stil.grund.ignoresSafeArea())
    }
}

// MARK: - Die Folgen einer geladenen Serie

struct DownloadserieRoute: Hashable {
    let serienId: String
    let titel: String
}

struct DownloadserieView: View {
    let model: AppModel
    let route: DownloadserieRoute

    @Environment(\.dismiss) private var schliessen

    @Environment(\.breit) private var breit
    @State private var versatz: CGFloat = 0
    @State private var kopfhoehe: CGFloat = 96

    @State private var abspielen: Abspielwunsch?

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

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folgen) { p in
                        Downloadzeile(model: model, posten: p, gewaehlt: .constant(false),
                                      starten: p.stand == .fertig ? { spiele(p) } : nil)
                        if p.id != folgen.last?.id { Trennlinie() }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, kopfhoehe + 12, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, neu in versatz = neu }

            Unschaerfekopf(versatz: versatz) {
                VStack(alignment: .leading, spacing: 10) {
                    Unterseitenkopf(titel: route.titel, zurueck: { schliessen() }) { EmptyView() }
                        .padding(.horizontal, -Stil.rand(breit: breit))
                    Text(verbatim: String(localized: "\(folgen.count) Folgen") + " · "
                         + Downloadregeln.groesse(folgen.reduce(0) { $0 + $1.bytes }))
                        .font(.system(size: 13))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { kopfhoehe = $0 }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        .fullScreenCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
    }
}
