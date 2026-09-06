import JellyfinKit
import SwiftUI

struct MerklisteView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @Environment(\.bereichAktiv) private var bereichAktiv
    @State private var stand = Merklistenmodell()
    @State private var gattung: Merkgattung = .alle
    @State private var gattungslisteOffen = false
    @State private var sortierlisteOffen = false
    /// Wie weit gescrollt wurde — daran hängt die Kante unter dem Kopf.
    ///
    /// **Fehlte hier.** Filme und Serien haben sie seit gestern; diese Seite
    /// ist beim Bauen ohne den Wert entstanden, und damit lief ihr Inhalt
    /// weiter unter einem halben Verlauf durch statt hinter einer Leiste.
    /// Dieselbe Seitenart, zwei Verhalten.
    @State private var versatz: CGFloat = 0

    var body: some View {
        GeometryReader { rahmen in
            inhalt(nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit))
        }
        .overlay(alignment: .topTrailing) {
            Auswahlblatt(offen: $gattungslisteOffen,
                         titel: "Gattung",
                         eintraege: Merkgattung.allCases,
                         beschriftung: { $0.beschriftung },
                         istGewaehlt: { $0 == gattung },
                         waehlen: { gattung = $0; stand.gattung = $0.art })
        }
        .overlay(alignment: .topTrailing) {
            Auswahlblatt(offen: $sortierlisteOffen,
                         titel: "Sortieren",
                         eintraege: Sortierung.allCases,
                         beschriftung: { $0.beschriftung },
                         istGewaehlt: { $0 == stand.sortierung },
                         waehlen: { stand.sortierung = $0 })
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model) }
    }

    @ViewBuilder
    private func inhalt(nutzbar: CGFloat) -> some View {
        let spalten = Stil.spalten(nutzbar: nutzbar, breit: breit)
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                // Erst die Form, dann der Inhalt — wie in der Bibliothek.
                if stand.items.isEmpty, stand.laedt {
                    Rasterplatzhalter(spalten: spalten)
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Stil.kachelAbstand),
                                         count: spalten),
                          alignment: .leading, spacing: 20) {
                    ForEach(stand.items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            guard item.id == stand.nachladenAb(spalten: spalten) else { return }
                            Task { await stand.nachladen(model) }
                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 8)
                .opacity(stand.items.isEmpty ? 0 : 1)
            }
            .scrollIndicators(.hidden)
            .animation(Stil.einblenden, value: stand.items.isEmpty)
            // Null im Ruhezustand — wie in der Bibliothek.
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y + $0.contentInsets.top
            } action: { _, neu in
                // Wie dort: eine Messung aus dem Hintergrund waere ein
                // voll gescrollter Kopf fuer ein, zwei Bilder.
                guard bereichAktiv else { return }
                versatz = neu
            }
            // **Das Heranziehen beim Bereichswechsel — es fehlte hier.**
            //
            // Filme und Serien tragen es seit dem Umbau, die Merkliste ist
            // ohne es entstanden: breit ist sie ein Bereich wie die beiden,
            // sprang aber hart herein. Nur die Scrollflaeche, nicht der Kopf
            // darueber.
            .bereichsinhalt()
            // Der Kopf sitzt als Sicherheitsrand, nicht als Auflage — die
            // Begruendung steht ausfuehrlich in `HauptView`. Kurz: sein
            // oberer Rand kam aus einer eigenen Messung, die als
            // `contentMargins` in dieselbe Flaeche zurueckging, und dieser
            // Kreis schwang. `safeAreaInset` misst nichts.
            .safeAreaInset(edge: .top, spacing: 0) { kopf }
            .contentMargins(.bottom, 24, for: .scrollContent)


            if stand.items.isEmpty, !stand.laedt {
                // **Der Leerzustand sagt, wie man hineinkommt.** Sonst steht
                // dort eine Sackgasse: eine leere Liste, die nicht verrät,
                // woher ihr Inhalt käme.
                Leerzustand(symbol: "bookmark",
                            kopfzeile: "Noch nichts gemerkt",
                            text: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier.")
            }
        }
    }


    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            VStack(alignment: .leading, spacing: 14) {
                // **Breit ist die Merkliste eine Wurzel, schmal ein Weg** —
                // und die beiden tragen verschiedene Koepfe.
                //
                // Breit steht sie als Bereich in der Seitenleiste, neben
                // Filme und Serien; dort gehoert derselbe Kopf hin wie dort:
                // grosser Titel, buendig am Rand, kein Pfeil. Ein
                // `Unterseitenkopf` ohne Pfeil sieht zwar aehnlich aus, setzt
                // den Titel aber um eine Knopfbreite anders — nebeneinander
                // in derselben Leiste faellt genau das auf.
                //
                // Schmal haengt sie am Zeichen oben rechts und faehrt als
                // Seite herein; dann ist der Pfeil richtig.
                if breit {
                    // Die Zahl steht neben dem Titel und nicht hinter den
                    // Chips — sonst teilen sich zwei Zwischenraeume den
                    // Platz, und die Sortierchips landen in der Mitte statt
                    // rechts. Dieselbe Stelle wie in der Bibliothek und auf
                    // dem Mac.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Merkliste")
                            .font(Stil.titelGross)
                            .tracking(-0.6)
                            .foregroundStyle(Stil.schrift)
                        Spacer(minLength: 0)
                        if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                    }
                } else {
                    Unterseitenkopf(titel: String(localized: "Merkliste"),
                                    zurueck: { zurueck() }) { EmptyView() }
                        // Der Kopf bringt seinen eigenen Rand mit; hier steht
                        // er schon in einem.
                        .padding(.horizontal, -Stil.rand(breit: breit))
                }

                // **Schmal zeigt Werte, breit zeigt Moeglichkeiten** — E15,
                // dieselbe Regel wie in der Bibliothek. Auf dem iPad ist
                // Platz, und ein Blatt fuer etwas, das daneben hinpasst, ist
                // ein Umweg.
                //
                // Das Zeichen unterscheidet die beiden Pillen: ein Trichter
                // engt ein, ein Raster waehlt aus — und die Pille der
                // Bibliothek steht auf der Nachbarseite an derselben Stelle.
                HStack(spacing: 8) {
                    if breit {
                        ForEach(Merkgattung.allCases) { fall in
                            Wahlchip(text: fall.beschriftung, an: gattung == fall) {
                                gattung = fall
                                stand.gattung = fall.art
                            }
                        }
                        // Rechts aussen wie in der Bibliothek und auf dem Mac.
                        Spacer(minLength: 12)
                        ForEach(Sortierung.allCases) { fall in
                            Wahlchip(text: fall.beschriftung,
                                     symbol: fall == stand.sortierung
                                             ? "line.3.horizontal.decrease" : nil,
                                     an: stand.sortierung == fall) {
                                stand.sortierung = fall
                            }
                        }
                    } else {
                        Wertpille(symbol: "square.grid.2x2",
                                  text: gattung.beschriftung) { gattungslisteOffen = true }
                        Wertpille(symbol: "arrow.up.arrow.down",
                                  text: stand.sortierung.beschriftung) { sortierlisteOffen = true }

                        Spacer(minLength: 8)
                        if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                    }
                }
            }
        }
    }

    @Environment(\.dismiss) private var schliessen
    private func zurueck() { schliessen() }
}
