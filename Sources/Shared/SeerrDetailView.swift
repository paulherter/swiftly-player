import JellyfinKit
import SwiftUI

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Fortsetzen* wird *Anfragen* — und die Reiter: es gibt
/// keine Folgen zu zeigen, wohl aber Besetzung und Vorschlaege.
///
/// **Der Aufbau ist der der Serienseite, Zeile fuer Zeile**, und das ist
/// keine Bequemlichkeit, sondern die Lehre aus drei Runden. Wer die Seite
/// nachbaut, trifft die Abstaende nicht: der Kopf sass tiefer, das Bild hing
/// beim Scrollen fest, oben stand ein Verlauf, den es dort nie gab. Jede
/// dieser drei Abweichungen war ein Baustein, der schon dalag und nicht
/// benutzt wurde — `Heldbild` misst sich im Raum „blatt", `Detailkopf`
/// bringt seinen eigenen, sehr viel schwaecheren Verlauf mit, und
/// `.ignoresSafeArea(edges: .top)` ist der Grund, warum das Bild ueberhaupt
/// bis nach oben laeuft.
///
/// Was hier abweicht, weicht mit Absicht ab und steht als Kommentar dabei.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit

    /// Wie weit gescrollt wurde — der Kopf blendet danach ein. Wie dort.
    @State private var versatz: CGFloat = 0

    @State private var stand: Seerrstand
    @State private var laeuft = false
    @State private var fehler: String?
    @State private var angefragt = false
    @State private var detail: Seerrdetail?
    @State private var reiter = 0
    /// Welche Staffeln angekreuzt sind. Leer heisst **alle** — so wie beim
    /// ersten Oeffnen, wo niemand etwas ausgewaehlt hat.
    @State private var gewaehlt: Set<Int> = []
    @State private var blattOffen = false

    init(model: AppModel, treffer: Seerrtreffer) {
        self.model = model
        self.treffer = treffer
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    VStack(alignment: .leading, spacing: 14) {
                        belegzeile
                        hauptknopf
                        beschreibung
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 14)
                    .padding(.bottom, 22)

                    // **Zwei statt drei.** „Folgen" gehoert zu einem Titel,
                    // den man abspielen kann; hier gibt es nichts abzuspielen.
                    // Welche Staffeln es gibt, beantwortet das Blatt am Knopf.
                    Reiter(titel: ["Besetzung", "Ähnliches"], gewaehlt: $reiter)

                    switch reiter {
                    case 0: besetzung
                    default: aehnlichesbereich
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            // Der Raum, in dem `Heldbild` seine Dehnung misst. Fehlte er,
            // blieb das Bild beim Scrollen stehen, statt mitzugehen.
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                versatz = neu
            }
            // Ohne das steht ueber dem Bild der schwarze Streifen des
            // sicheren Bereichs.
            .ignoresSafeArea(edges: .top)

            // **Unser eigenes Blatt, nicht das des Systems.** Ein `.sheet`
            // bringt seine eigene Sprache mit — abgerundete Ecken oben,
            // Griff, Navigationsleiste — und stand damit neben „Mehr" und
            // den Wiedergabelisten wie aus einer anderen App.
            if blattOffen { staffelblatt.zIndex(20) }
            if let fehler {
                Hinweisstreifen(text: fehler) { self.fehler = nil }
                    .zIndex(21)
            }

            Detailkopf(titel: treffer.titel, versatz: versatz) { zurueck() }
        }
        .animation(.easeInOut(duration: 0.16), value: reiter)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            detail = await model.seerr.detail(treffer)
            // **Nichts vorausgewaehlt.** „Man laedt ja nie alle runter im
            // Normalfall" — wer alles will, kreuzt alles an; wer eine will,
            // muss nicht erst acht abwaehlen.
        }
    }

    // MARK: Teile

    /// Wortgleich mit `SeriesDetailView.hero`, nur mit dem Querbild von TMDB
    /// statt dem des eigenen Servers.
    private var hero: some View {
        Heldbild(url: treffer.kulisse())
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: treffer.titel)
                        .font(Stil.titel)
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                    Text(verbatim: nebenzeile)
                        .font(.system(size: 14))
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 16)
            }
    }

    /// Jahr, Staffeln oder Laufzeit, Gattungen — dieselbe Reihenfolge wie
    /// dort.
    private var nebenzeile: String {
        var teile: [String] = []
        if let jahr = treffer.jahr { teile.append("\(jahr)") }
        if treffer.istSerie {
            let n = detail?.staffeln.count ?? 0
            if n > 0 { teile.append(n == 1 ? String(localized: "1 Staffel")
                                           : String(localized: "\(n) Staffeln")) }
        } else if let m = detail?.laufzeit, m > 0 {
            teile.append(String(localized: "\(m) Min."))
        }
        let gattungen = detail?.genres ?? []
        if !gattungen.isEmpty { teile.append(gattungen.joined(separator: ", ")) }
        if teile.isEmpty {
            teile.append(treffer.istSerie ? String(localized: "Serie")
                                          : String(localized: "Film"))
        }
        return teile.joined(separator: " · ")
    }

    /// **Dieselbe Zeile wie dort**, nur mit dem Stand statt „Direct Play":
    /// ueber einen Titel, den es hier nicht gibt, weiss niemand, wie er
    /// laeuft. Symbol, Wort, Stern — in denselben Groessen und Abstaenden;
    /// deshalb steht der Aufbau hier und nicht in `Belegzeile`, die den
    /// Wiedergabeplan als Eingabe hat.
    private var belegzeile: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: standsymbol)
                    .font(.system(size: 11, weight: .heavy))
                Text(verbatim: standtext)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(standfarbe)

            if let b = detail?.bewertung, b > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 11))
                    Text(verbatim: String(format: "%.1f", b)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 13))
                }
                .foregroundStyle(Color.white.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
    }

    /// **Ein Stand ist keine Schaltflaeche.**
    ///
    /// Was wartet oder laedt, laesst sich nicht noch einmal anfragen; dort
    /// steht eine Auskunft statt eines grauen Knopfes.
    ///
    /// Der Stapel ringsum ist der von `SeriesDetailView.hauptknopf` —
    /// derselbe `VStack(spacing: 9)`, damit die Zeile darunter auf derselben
    /// Hoehe sitzt wie dort „Noch 25 Minuten".
    @ViewBuilder
    private var hauptknopf: some View {
        VStack(alignment: .leading, spacing: 9) {
            if angefragt {
                auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
            } else if stand.anfragbar {
                Button {
                    // **Bei einer Serie wird erst gefragt, welche Staffeln.**
                    if treffer.istSerie { blattOffen = true }
                    else { Task { await anfragen() } }
                } label: {
                    HStack(spacing: 8) {
                        if laeuft {
                            Lader(groesse: 18, staerke: 2)
                        } else {
                            Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        }
                        Text(laeuft ? "Wird angefragt…" : "Anfragen")
                    }
                }
                // **Derselbe Stil wie „Fortsetzen", nur in Akzent.** Hoehe,
                // Ecke und Schriftgrad stehen dort und nicht hier — ein
                // nachgebauter Knopf sass sichtbar tiefer und runder.
                .buttonStyle(HauptknopfStil(dehnt: !breit, flaeche: Stil.akzent))
                .disabled(laeuft)
            } else {
                auskunft(standhinweis)
            }
        }
    }

    @ViewBuilder
    private var beschreibung: some View {
        if let text = detail?.beschreibung {
            Klapptext(text: text)
        }
    }

    /// Wortgleich mit `SeriesDetailView.besetzung`, nur mit den Koepfen von
    /// TMDB statt denen des eigenen Servers.
    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if leute.isEmpty {
            leerhinweis("Keine Besetzung hinterlegt.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 14)],
                      spacing: 20) {
                ForEach(leute) { person in
                    Besetzungskachel(bild: person.bild(), name: person.name,
                                     rolle: person.rolle)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 20)
        }
    }

    /// Dasselbe Raster wie dort — mit `Seerrkachel` statt `PosterTile`,
    /// weil auch das Vorgeschlagene nicht auf dem Server liegt und blass
    /// gehoert.
    @ViewBuilder
    private var aehnlichesbereich: some View {
        let andere = detail?.aehnliches ?? []
        if andere.isEmpty {
            leerhinweis("Nichts Ähnliches gefunden.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Stil.kachelBreite,
                                                   maximum: Stil.kachelBreite + 30),
                                         spacing: Stil.kachelAbstand)],
                      alignment: .leading, spacing: 20) {
                ForEach(andere) { t in
                    NavigationLink(value: t) { Seerrkachel(treffer: t) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 20)
        }
    }

    private func leerhinweis(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftSehrLeise)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: Stand in Worten

    private var standsymbol: String {
        switch stand {
        case .da: "checkmark"
        case .wartetAufFreigabe: "clock"
        case .laedt: "arrow.down.circle"
        case .teilweiseDa: "circle.lefthalf.filled"
        case .offen, .geloescht: "plus.circle"
        }
    }

    private var standtext: String {
        switch stand {
        case .offen, .geloescht: String(localized: "Nicht auf deinem Server")
        case .wartetAufFreigabe: String(localized: "Wartet auf Freigabe")
        case .laedt: String(localized: "Lädt gerade")
        case .teilweiseDa: String(localized: "Teilweise vorhanden")
        case .da: String(localized: "Auf deinem Server")
        }
    }

    private var standfarbe: Color {
        switch stand {
        case .wartetAufFreigabe, .laedt: Color.white.opacity(0.8)
        default: Stil.akzent
        }
    }

    private var standhinweis: String {
        switch stand {
        case .wartetAufFreigabe:
            String(localized: "Deine Anfrage liegt beim Verwalter des Servers. Du musst nichts weiter tun.")
        case .laedt:
            String(localized: "Der Titel wird gerade geholt. Er erscheint von selbst in deiner Bibliothek.")
        default:
            String(localized: "Dieser Titel liegt bereits auf deinem Server.")
        }
    }

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Staffeln

    /// Die Staffeln zum Ankreuzen.
    ///
    /// **Was schon da ist, laesst sich nicht ankreuzen** — und sagt daneben,
    /// dass es da ist. Ein Kaestchen, das man druecken darf und das nichts
    /// bewirkt, ist schlimmer als keines.
    @ViewBuilder
    private var staffelliste: some View {
        ForEach(detail?.staffeln ?? []) { st in
            Button {
                guard st.stand.anfragbar else { return }
                if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                else { gewaehlt.insert(st.nummer) }
            } label: {
                HStack(spacing: 10) {
                    Text("Staffel \(st.nummer)")
                        .font(Stil.koerper)
                        .foregroundStyle(st.stand.anfragbar ? Stil.schrift
                                                            : Stil.schriftSehrLeise)
                    if st.folgen > 0 {
                        Text("· \(st.folgen) Folgen")
                            .font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
                    }
                    Spacer(minLength: 8)
                    if st.stand.anfragbar {
                        Image(systemName: gewaehlt.contains(st.nummer)
                                ? "checkmark.square.fill" : "square")
                            .font(.system(size: 19))
                            .foregroundStyle(gewaehlt.contains(st.nummer)
                                ? Stil.akzent : Stil.schriftSehrLeise)
                    } else {
                        Text(st.stand == .da ? "vorhanden" : "unterwegs")
                            .font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
                .padding(.horizontal, Stil.randAbstand)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Welche Staffeln — als Blatt von unten. Dieselben Werte wie beim
    /// „Mehr"-Blatt: Schleier 0,55, Ecken 12, Titel 13 halbfett.
    private var staffelblatt: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { blattOffen = false }

            VStack(spacing: 0) {
                Text("Welche Staffeln?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 0) { staffelliste }
                }
                .frame(maxHeight: 320)

                Trennlinie()

                Button {
                    blattOffen = false
                    Task { await anfragen() }
                } label: {
                    Text(gewaehlt.isEmpty ? "Staffel wählen"
                                          : "\(gewaehlt.count) anfragen")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(gewaehlt.isEmpty ? Stil.schriftSehrLeise : Stil.akzent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.plain)
                .disabled(gewaehlt.isEmpty)
            }
            .background(Stil.flaeche)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12,
                                              topTrailingRadius: 12))
            .ignoresSafeArea(edges: .bottom)
        }
        .transition(.opacity)
    }

    private func anfragen() async {
        fehler = nil
        laeuft = true
        defer { laeuft = false }
        do {
            // Leer heisst alle — Seerr versteht das Wort `all`, und wer
            // nichts angekreuzt hat, will nicht nichts.
            let staffeln = gewaehlt.isEmpty ? nil : Array(gewaehlt).sorted()
            try await model.seerr.anfragen(treffer, staffeln: staffeln)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = error.localizedDescription
        }
    }
}
