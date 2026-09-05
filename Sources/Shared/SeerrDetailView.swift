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

                standPlakette.padding(.top, 12)

                handlung.padding(.top, 16)

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

    private var standPlakette: some View {
        Text(verbatim: standtext)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Stil.grund)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(standfarbe, in: Capsule())
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
                Text("Es werden alle Staffeln angefragt.")
                    .font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.top, 8)
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
            try await model.seerr.anfragen(treffer)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = error.localizedDescription
        }
    }
}
