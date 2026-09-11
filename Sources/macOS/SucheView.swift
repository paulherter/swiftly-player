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
    /// Was Seerr kennt und der eigene Server nicht — leer, wenn nichts
    /// angebunden ist.
    @State private var seerrtreffer: [Seerrtreffer] = []
    @State private var gesucht = false
    @FocusState private var imFeld: Bool

    /// **Was zuletzt gesucht wurde.** Auf dem Gerät, nicht am Server: die
    /// Liste ist eine Bequemlichkeit, kein Teil des Kontos.
    ///
    /// Gemerkt wird beim Abschicken, nicht beim Tippen — wer „Ga", „Gam",
    /// „Game" eingibt, hat einmal gesucht und nicht dreimal. Die Regel steht
    /// in `Suchverlauf`; der Fernseher und das iPhone zeigen dieselbe Liste.
    @AppStorage(Suchverlauf.schluessel) private var letzteRoh = ""

    private var letzte: [String] { Suchverlauf.liste(letzteRoh) }

    /// „Zuletzt gesucht" — dieselbe Liste wie auf iPhone und Fernseher, hier
    /// als Zeilen in einer Karte.
    private var zuletzt: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zuletzt gesucht")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Stil.schrift.opacity(0.4))
                Spacer(minLength: 8)
                Button { letzteRoh = "" } label: {
                    Text("Löschen")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 26)
            .padding(.bottom, 8)

            Karte {
                ForEach(Array(letzte.enumerated()), id: \.offset) { stelle, wort in
                    if stelle > 0 { Trennstrich().padding(.leading, 48) }
                    Button { begriff = wort } label: {
                        Wertezeile(symbol: "clock.arrow.circlepath",
                                   titel: Text(verbatim: wort), schwebbar: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: Stil.lesebreite, alignment: .leading)
    }

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
                             platzhalter: String(localized: "Titel, Serie, Person"),
                             abschluss: { letzteRoh = Suchverlauf.merken(begriff, in: letzteRoh) })
                    .frame(maxWidth: 420)
                    .padding(.top, 14)
                    .focused($imFeld)

                // Ohne Wort im Feld: woran man zuletzt war. Ein Klick sucht
                // es noch einmal.
                if begriff.isEmpty, !letzte.isEmpty { zuletzt }

                if !treffer.isEmpty {
                    LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                        ForEach(treffer, id: \.id) { eintrag in
                            Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                                Posterkachel(titel: eintrag.name,
                                             zweitzeile: eintrag.trefferauskunft,
                                             bild: model.imageURL(for: eintrag, hochkant: true),
                                             fortschritt: eintrag.userData?.playedPercentage.map { $0 / 100 },
                                             marke: Anzeigeregeln.kachelmarke(
                                             art: eintrag.type,
                                             staffeln: eintrag.childCount,
                                             gesehen: eintrag.userData?.played,
                                             offeneFolgen: eintrag.userData?.unplayedItemCount),
                                             zeichen: eintrag.type == "Series" ? "tv" : "film")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 24)
                } else if gesucht, !begriff.isEmpty, seerrtreffer.isEmpty {
                    // **Beide leer, nicht nur die Bibliothek.** Stuende hier
                    // `treffer.isEmpty`, gewaenne dieser Zweig, sobald der
                    // eigene Server nichts hat — und der Seerr-Block darunter
                    // wuerde nie erreicht. Genau der Fall, fuer den die ganze
                    // Anbindung gebaut ist.
                    Leerzustand(symbol: "tray", titel: "Nichts gefunden")
                        .padding(.top, 120)
                }

                if !seerrtreffer.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Kann angefragt werden")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(Stil.schriftSehrLeise)
                        Spacer(minLength: 8)
                        Zaehlmarke(anzahl: seerrtreffer.count)
                    }
                    .padding(.top, treffer.isEmpty ? 30 : 40)

                    LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                        ForEach(seerrtreffer) { t in
                            Button { navigator.oeffne(.seerrTitel(t), in: bereich) } label: {
                                Seerrkachel(treffer: t)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 18)
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
            guard begriff.count > 1 else {
                treffer = []; seerrtreffer = []; gesucht = false; return
            }
            // Kurz warten, statt bei jedem Tastendruck zu fragen.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            // **Nebeneinander, nicht nacheinander.** Seerr ist eine Zugabe;
            // kommt von dort nichts oder kommt es spaet, steht trotzdem
            // sofort da, was der eigene Server hat.
            async let eigene = model.suche(begriff)
            async let fremde = model.seerr.suchen(begriff)
            let (a, b) = await (eigene, fremde)
            treffer = a
            // Was schon auf dem Server liegt, gehoert in den oberen Block —
            // sonst staende derselbe Titel zweimal auf der Seite.
            seerrtreffer = b.filter { !$0.stand.schonDa }
            gesucht = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Kommandopost.name)) { post in
            if Kommandopost.empfangen(post) == .suche { imFeld = true }
        }
    }
}
