import JellyfinKit
import SwiftUI

/// Ein Titel, den der eigene Server noch nicht hat — die Mac-Kachel.
///
/// **Blass, und das ist die ganze Auskunft.** Wer schnell scrollt, soll ohne
/// ein Wort zu lesen sehen, dass hier nichts abzuspielen ist. Die Überschrift
/// darüber bestätigt es nur; sie ist nicht die Erklärung.
struct Seerrkachel: View {
    let treffer: Seerrtreffer
    @State private var schwebt = false
    @State private var da = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Bildflaeche(bild: treffer.plakat(breite: 342),
                            breite: Stil.kachelBreite, hoehe: Stil.kachelHoehe,
                            zeichen: treffer.istSerie ? "tv" : "film")
                    .opacity(0.45)
                marke.padding(8)
            }
            .scaleEffect(schwebt ? 1.04 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: treffer.titel)
                    .font(Stil.kachelTitel)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)
                Text(verbatim: untertitel)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
        }
        .frame(width: Stil.kachelBreite, alignment: .leading)
        .opacity(da ? 1 : 0)
        .onAppear {
            guard !da else { return }
            withAnimation(Stil.einblenden) { da = true }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(treffer.titel), \(treffer.stand.ansage)"))
    }

    private var untertitel: String {
        let art = treffer.istSerie ? String(localized: "Serie") : String(localized: "Film")
        return treffer.jahr.map { "\($0) · \(art)" } ?? art
    }

    /// **Nur was etwas Neues sagt.** „Kann angefragt werden" steht schon als
    /// Überschrift über dem Block; eine Marke, die es wiederholt, ist Lärm.
    @ViewBuilder
    private var marke: some View {
        if treffer.stand != .da {
            HStack(spacing: 4) {
                Image(systemName: treffer.stand.symbol)
                    .font(.system(size: 10, weight: .bold))
                if let wort = treffer.stand.kurzwort {
                    Text(verbatim: wort).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Stil.grund)
            .padding(.horizontal, treffer.stand.kurzwort == nil ? 6 : 8)
            .padding(.vertical, 3)
            .background(treffer.stand.farbe, in: Capsule())
        }
    }
}

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Abspielen* wird *Anfragen* — und die Reihen: es gibt
/// keine Folgen zu zeigen, wohl aber Besetzung und Vorschläge.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer
    let zurueck: () -> Void

    @State private var stand: Seerrstand
    @State private var detail: Seerrdetail?
    @State private var laeuft = false
    @State private var angefragt = false
    @State private var fehler: String?
    /// Welche Staffeln angekreuzt sind. Leer heisst **alle**.
    @State private var gewaehlt: Set<Int> = []
    @State private var staffelnOffen = false
    /// **Hat der Nutzer schon einmal gedrückt?** Bei einem Film ist die
    /// Anfrage sonst einen Klick entfernt.
    @State private var bestaetigt = false

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    init(model: AppModel, treffer: Seerrtreffer, zurueck: @escaping () -> Void) {
        self.model = model
        self.treffer = treffer
        self.zurueck = zurueck
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // **Der Titel kommt von TMDB und ist kein Schlüssel.** Der
                // gemeinsame Kopf nimmt einen `LocalizedStringKey`; „The
                // Mentalist" würde dort nachgeschlagen. Deshalb hier die
                // Zeile selbst, mit denselben Werten.
                HStack(spacing: 14) {
                    Aktionsknopf(symbol: "chevron.left", titel: "Zurück",
                                 auswahl: zurueck)
                    Text(verbatim: treffer.titel)
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                    Spacer(minLength: 0)
                }

                Text(verbatim: nebenzeile)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 6)

                belegzeile.padding(.top, 18)

                handlung.padding(.top, 18)

                if let text = detail?.beschreibung {
                    Text(verbatim: text)
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schrift.opacity(0.78))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 700, alignment: .leading)
                        .padding(.top, 22)
                }

                besetzung
                aehnliches
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
        .task { detail = await model.seerr.detail(treffer) }
    }

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

    /// Symbol, Wort, Stern — dieselbe Zeile wie auf einer echten Seite, nur
    /// mit dem Stand statt „Direct Play": über einen Titel, den es hier nicht
    /// gibt, weiss niemand, wie er läuft.
    private var belegzeile: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: stand.symbol).font(.system(size: 12, weight: .heavy))
                Text(verbatim: stand.wort).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(stand.farbe)

            if let b = detail?.bewertung, b > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 12))
                    Text(verbatim: String(format: "%.1f", b)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 14))
                }
                .foregroundStyle(Stil.schrift.opacity(0.8))
            }
        }
    }

    /// **Ein Stand ist keine Schaltfläche.** Was wartet oder lädt, lässt sich
    /// nicht noch einmal anfragen; dort steht eine Auskunft statt eines
    /// grauen Knopfes.
    @ViewBuilder
    private var handlung: some View {
        if angefragt {
            auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if stand.anfragbar {
            VStack(alignment: .leading, spacing: 12) {
                Hauptknopf(beschriftung: knopftext,
                           symbol: bestaetigt ? "checkmark" : "plus") { gedrueckt() }
                    .frame(maxWidth: 320)

                if treffer.istSerie, staffelnOffen { staffelliste }
                if let fehler {
                    Text(verbatim: fehler)
                        .font(Stil.zweitzeile).foregroundStyle(Stil.warnung)
                }
            }
        } else {
            auskunft(stand.hinweis)
        }
    }

    private var knopftext: LocalizedStringKey {
        if laeuft { return "Wird angefragt…" }
        if treffer.istSerie { return staffelnOffen ? "Anfragen" : "Staffeln wählen" }
        return bestaetigt ? "Wirklich anfragen?" : "Anfragen"
    }

    /// **Zwei Stufen, und die zweite ist der eigentliche Auftrag.** Bei einer
    /// Serie übernimmt die Staffelliste die zweite Stufe; ein Film hat nichts
    /// auszuwählen, deshalb fragt dort der Knopf selbst nach.
    private func gedrueckt() {
        guard !laeuft else { return }
        if treffer.istSerie {
            if staffelnOffen { Task { await anfragen() } }
            else { withAnimation(Stil.zeitSprung) { staffelnOffen = true } }
            return
        }
        guard bestaetigt else { bestaetigt = true; return }
        Task { await anfragen() }
    }

    /// **Was schon da ist, lässt sich nicht ankreuzen** — und sagt daneben,
    /// dass es da ist.
    private var staffelliste: some View {
        VStack(spacing: 0) {
            ForEach(detail?.staffeln ?? []) { st in
                Button {
                    guard st.stand.anfragbar else { return }
                    if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                    else { gewaehlt.insert(st.nummer) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: st.stand.anfragbar
                              ? (gewaehlt.contains(st.nummer) ? "checkmark.square.fill" : "square")
                              : "checkmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(gewaehlt.contains(st.nummer) ? Stil.akzent
                                                                          : Stil.schriftSehrLeise)
                        Text("Staffel \(st.nummer)")
                            .font(Stil.koerper)
                            .foregroundStyle(st.stand.anfragbar ? Stil.schrift
                                                                : Stil.schriftSehrLeise)
                        if st.folgen > 0 {
                            Text("· \(st.folgen) Folgen")
                                .font(Stil.zweitzeile).foregroundStyle(Stil.schriftSehrLeise)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFlaeche).strokeBorder(Stil.rand))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if !leute.isEmpty {
            Text("Besetzung")
                .font(Stil.reihe).foregroundStyle(Stil.schrift)
                .padding(.top, 34)
            // Derselbe Baustein wie auf einer echten Detailseite — die
            // Koepfe kommen nur von TMDB statt vom eigenen Server.
            Blätterreihe(rand: 0, breiteJeStueck: 84 + 18, bildHoehe: 84) {
                ForEach(leute.prefix(12)) { person in
                    Kopfbild(name: person.name, rolle: person.rolle,
                             bild: person.bild())
                }
            }
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private var aehnliches: some View {
        let andere = detail?.aehnliches ?? []
        if !andere.isEmpty {
            Text("Ähnliche Titel")
                .font(Stil.reihe).foregroundStyle(Stil.schrift)
                .padding(.top, 34)
            Blätterreihe(rand: 0) {
                ForEach(andere) { t in
                    Button { navigator.oeffne(.seerrTitel(t), in: bereich) } label: {
                        Seerrkachel(treffer: t)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
        }
    }

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche))
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
