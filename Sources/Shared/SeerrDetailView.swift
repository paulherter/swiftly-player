import JellyfinKit
import SwiftUI

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Kulisse, Titel,
/// Plaketten, Beschreibung — alles steht, wo es immer steht. Getauscht ist
/// nur der grosse Knopf: aus *Abspielen* wird *Anfragen*. Eine zweite
/// Seitenart, die man erst lernen muss, wäre der teurere Weg.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var stand: Seerrstand
    @State private var laeuft = false
    @State private var fehler: String?
    @State private var angefragt = false
    @State private var detail: Seerrdetail?
    /// Welche Staffeln angekreuzt sind. Leer heisst **alle** — so wie beim
    /// ersten Öffnen, wo niemand etwas ausgewählt hat.
    @State private var gewaehlt: Set<Int> = []
    @State private var blattOffen = false

    init(model: AppModel, treffer: Seerrtreffer) {
        self.model = model
        self.treffer = treffer
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            ScrollView { inhalt }.scrollIndicators(.hidden)
            Seitenpfeil { zurueck() }

            // **Unser eigenes Blatt, nicht das des Systems.** Ein `.sheet`
            // bringt seine eigene Sprache mit — abgerundete Ecken oben,
            // Griff, Navigationsleiste — und stand damit neben „Mehr" und
            // den Wiedergabelisten wie aus einer anderen App. Dieselben
            // Werte wie dort: Schleier 0,55, Ecken 12, Titel 13 halbfett.
            if blattOffen { staffelblatt }
        }
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

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Derselbe Kopf wie auf der echten Detailseite.** Vorher stand
            // hier ein eigenes `Bild` mit eigenem Verlauf — daher der schwarze
            // Rand oben und das fehlende Mitziehen beim Scrollen. `Heldbild`
            // und `Heldauslauf` koennen beides, seit Monaten geprueft.
            Heldbild(url: treffer.kulisse())
                .overlay(alignment: .bottom) { Heldauslauf() }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: treffer.titel)
                            .font(Stil.titel).tracking(-0.6)
                            .foregroundStyle(Stil.schrift)
                        Text(verbatim: nebenzeile)
                            .font(.system(size: 14))
                            .foregroundStyle(Stil.schriftLeise)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.bottom, 16)
                }

            VStack(alignment: .leading, spacing: 14) {
                belegzeile
                handlung
                if let text = detail?.beschreibung {
                    Klapptext(text: text)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 14)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: breit ? .center : .leading)
    }

    /// Jahr, Laufzeit und Gattung — genau wie auf der echten Detailseite,
    /// im Bild und nicht in einer eigenen Zeile darunter.
    private var nebenzeile: String {
        var teile: [String] = []
        if let jahr = treffer.jahr { teile.append("\(jahr)") }
        if treffer.istSerie {
            // **Wie auf der echten Seite: Staffeln, nicht Gattungen.** Dort
            // steht „2008 · 2 Staffeln"; identisch heisst identisch.
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

    /// Stand und Bewertung — dieselbe Zeile wie dort, nur ohne Direct Play:
    /// über einen Titel, den es hier nicht gibt, weiss niemand, wie er läuft.
    /// **Dieselbe Zeile wie auf der echten Seite**, nur mit dem Stand statt
    /// „Direct Play": Symbol, Wort, Stern. Vorher stand hier eine dicke Pille,
    /// und genau die machte den Unterschied sichtbar, der keiner sein soll
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

    /// **Ein Stand ist keine Schaltfläche.**
    ///
    /// Was wartet oder lädt, lässt sich nicht noch einmal anfragen — dort
    /// steht eine Auskunft statt eines grauen Knopfes. Ein gesperrter Knopf
    /// wäre die Behauptung, es gäbe etwas zu tun.
    @ViewBuilder
    private var handlung: some View {
        if angefragt {
            auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if stand.anfragbar {
            Button {
                // **Bei einer Serie wird erst gefragt, welche Staffeln.**
                if treffer.istSerie { blattOffen = true }
                else { Task { await anfragen() } }
            } label: {
                Label(laeuft ? "Wird angefragt…" : "Anfragen",
                      systemImage: laeuft ? "hourglass" : "plus")
            }
            // **Derselbe Stil wie „Fortsetzen", nur in Akzent.** Hoehe 48,
            // Ecke Stil.ecke, Schrift 16 halbfett — vorher stand hier ein
            // nachgebauter Knopf mit 16er Ecke und 16 Punkt Innenabstand,
            // und der sass sichtbar tiefer und runder als das Vorbild.
            .buttonStyle(HauptknopfStil(flaeche: Stil.akzent))
            .disabled(laeuft)
        } else {
            auskunft(standhinweis)
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

    /// Welche Staffeln — als Blatt von unten, nicht als Liste auf der Seite.
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
