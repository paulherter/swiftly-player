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
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            detail = await model.seerr.detail(treffer)
            // Vorgabe: alles, was noch fehlt. Was schon da ist, kreuzt
            // niemand an — und wer alles will, muss nichts tun.
            gewaehlt = Set((detail?.staffeln ?? [])
                .filter { $0.stand.anfragbar }.map(\.nummer))
        }
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Bild(url: treffer.plakat(breite: 780), hoehe: 220)
                .frame(maxWidth: .infinity)
                .opacity(0.5)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, Stil.grund],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: treffer.titel)
                    .font(Stil.titel).tracking(-0.5).foregroundStyle(Stil.schrift)
                Text(verbatim: untertitel)
                    .font(Stil.koerper).foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 3)

                plaketten.padding(.top, 12)

                handlung.padding(.top, 16)

                if let text = detail?.beschreibung {
                    Text(verbatim: text)
                        .font(Stil.koerper)
                        .lineSpacing(3)
                        .foregroundStyle(Stil.schriftLeise)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                }

                if let fehler {
                    Text(verbatim: fehler)
                        .font(Stil.klein).foregroundStyle(Stil.warnung)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, -24)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: breit ? .center : .leading)
    }

    private var untertitel: String {
        let art = treffer.istSerie ? String(localized: "Serie") : String(localized: "Film")
        return treffer.jahr.map { "\($0) · \(art)" } ?? art
    }

    /// Der Stand zuerst, dann was der Titel sonst hergibt.
    ///
    /// **Ohne diese Zeile sah die Seite leer aus.** Bei einem Film gibt es
    /// keine Staffelliste, und dann standen dort nur Titel, Jahr und ein Knopf
    /// Bewertung und Laufzeit kosten einen Abruf, den wir ohnehin machen.
    private var plaketten: some View {
        HStack(spacing: 7) {
            Text(verbatim: standtext)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Stil.grund)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(standfarbe, in: Capsule())
            if let b = detail?.bewertung, b > 0 {
                nebenplakette(String(format: "TMDB %.1f", b))
            }
            if let m = detail?.laufzeit, m > 0 {
                nebenplakette(treffer.istSerie
                    ? String(localized: "\(m) Min. je Folge")
                    : String(localized: "\(m) Min."))
            }
        }
    }

    private func nebenplakette(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(Stil.schriftLeise)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Stil.flaeche, in: Capsule())
    }

    /// Die Staffeln zum Ankreuzen.
    ///
    /// **Was schon da ist, lässt sich nicht ankreuzen** — und sagt daneben,
    /// dass es da ist. Ein Kästchen, das man drücken darf und das nichts
    /// bewirkt, ist schlimmer als keines.
    @ViewBuilder
    private var staffelliste: some View {
        if let staffeln = detail?.staffeln, !staffeln.isEmpty {
            VStack(spacing: 6) {
                ForEach(staffeln) { st in
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
                                    .font(.system(size: 17))
                                    .foregroundStyle(gewaehlt.contains(st.nummer)
                                        ? Stil.akzent : Stil.schriftSehrLeise)
                            } else {
                                Text(st.stand == .da ? "vorhanden" : "unterwegs")
                                    .font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
                            }
                        }
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
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
        case .wartetAufFreigabe: Color(red: 0.85, green: 0.60, blue: 0.17)
        case .laedt: Color(red: 0.29, green: 0.56, blue: 0.85)
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
            Button { Task { await anfragen() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: laeuft ? "hourglass" : "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text(laeuft ? "Wird angefragt…" : "Anfragen")
                        .font(Stil.koerper.weight(.semibold))
                }
                .foregroundStyle(Stil.grund)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Stil.akzent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(laeuft)
            if treffer.istSerie {
                staffelliste.padding(.top, 12)
            }
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
