import JellyfinKit
import SwiftUI

/// Suche. Kein `.searchable` — das bringt auf dem Mac eine eigene Leiste,
/// eigene Ecken und eigenes Material mit. Dasselbe Feld wie bei der Anmeldung,
/// nur breiter.
struct SucheView: View {
    let model: AppModel
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    @State private var begriff = ""
    @State private var treffer: [Item] = []
    @State private var gesucht = false
    @FocusState private var imFeld: Bool

    private var spalten: [GridItem] {
        [GridItem(.adaptive(minimum: Stil.kachelBreite, maximum: Stil.kachelBreite),
                  spacing: Stil.kachelAbstand, alignment: .topLeading)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Suche")
                    .font(Stil.titelGross)
                    .tracking(-0.6)
                    .foregroundStyle(Stil.schrift)

                Eingabezeile(text: $begriff, symbol: "magnifyingglass",
                             platzhalter: String(localized: "Titel, Serie, Person"))
                    .frame(maxWidth: 420)
                    .padding(.top, 14)
                    .focused($imFeld)

                if !treffer.isEmpty {
                    LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                        ForEach(treffer, id: \.id) { eintrag in
                            Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                                Posterkachel(titel: eintrag.name,
                                             zweitzeile: eintrag.trefferauskunft,
                                             bild: model.imageURL(for: eintrag, hochkant: true))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 24)
                } else if gesucht, !begriff.isEmpty {
                    Leerzustand(symbol: "tray", titel: "Nichts gefunden")
                        .padding(.top, 120)
                }
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .ohneKanteneffekt()
        .onAppear { imFeld = true }
        .task(id: begriff) {
            guard begriff.count > 1 else { treffer = []; gesucht = false; return }
            // Kurz warten, statt bei jedem Tastendruck zu fragen.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            treffer = await model.suche(begriff)
            gesucht = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Kommandopost.name)) { post in
            if Kommandopost.empfangen(post) == .suche { imFeld = true }
        }
    }
}
