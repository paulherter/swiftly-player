import JellyfinKit
import SwiftUI

struct MerklisteView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @Environment(\.bereichAktiv) private var bereichAktiv
    @State private var stand: Merklistenmodell
    /// Die Pille der Ansicht und die Gattung im Modell muessen beim Start
    /// dasselbe sagen — das Modell holt sie aus der Ablage, die Ansicht
    /// liest sie von dort ab.
    @State private var gattung: Merkgattung
    @State private var gattungslisteOffen = false
    @State private var sortierlisteOffen = false
    /// Wie weit gescrollt wurde — daran hängt die Kante unter dem Kopf.
    ///
    /// **Fehlte hier.** Filme und Serien haben sie seit gestern; diese Seite
    /// ist beim Bauen ohne den Wert entstanden, und damit lief ihr Inhalt
    /// weiter unter einem halben Verlauf durch statt hinter einer Leiste.
    /// Dieselbe Seitenart, zwei Verhalten.
    @State private var versatz: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        let frisch = Merklistenmodell()
        _stand = State(initialValue: frisch)
        _gattung = State(initialValue: Merkgattung.zu(art: frisch.gattung))
    }

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
                        .buttonStyle(Stil.Druckknopf())
                        .onAppear {
                            guard stand.loestNachladenAus(item.id, spalten: spalten) else { return }
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
            // **Der rohe Versatz, nicht der um den Sicherheitsrand bereinigte.**
            //
            // Hier stand `contentOffset.y + contentInsets.top`, und das war
            // richtig, solange der Kopf immer gleich hoch war. Seit die
            // Wertreihe beim Scrollen zuklappt, ist er es nicht mehr — und
            // damit misst die Zeile ihr eigenes Ergebnis: Kopf schrumpft um
            // zehn, Sicherheitsrand schrumpft um zehn, der gemessene Versatz
            // faellt um zehn zurueck auf null, Kopf waechst wieder. Ein
            // Zweitakter, der nie zur Ruhe kommt.
            //
            // **Die Summe ist schon der Scrollweg.** Gemessen am 22.09.:
            //
            //     rand 130,8  versatz −130,3  ->  Summe 0,5
            //     rand 115,0  versatz −114,7  ->  Summe 0,3
            //
            // Dazwischen ist die Wertreihe von 28 auf 44 Punkt zugeklappt.
            // Der obere Rand faellt dabei um 15,8 — und der rohe Versatz
            // steigt um genau 15,6. **Beide wandern gemeinsam:** die
            // Scrollflaeche haelt den Inhalt fest, wenn sich ihr Rand aendert.
            // Die Summe bleibt davon unberuehrt und misst allein, was der
            // Finger getan hat.
            //
            // Drei Anlaeufe sind an der gegenteiligen Annahme gescheitert —
            // der Rand schrumpfe, der Versatz bleibe stehen, also muesse man
            // das Eingeklappte wieder draufrechnen. Genau dieses Draufrechnen
            // war der Fehler: es zaehlte den Weg ein zweites Mal, in jedem
            // Bild, und die Reihe klappte von selbst zu, ohne dass jemand
            // gescrollt hat. Zwei Vermutungen ueber die Ursache und eine
            // Messung: die Messung hat es in zwei Minuten entschieden.
            .onScrollGeometryChange(for: CGPoint.self) {
                CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y)
            } action: { _, neu in
                // Waehrend des Bereichswechsels rechnet die Scrollflaeche
                // ihre Geometrie neu; erst wenn dieser Bereich vorn ist, ist
                // die Messung etwas wert.
                guard bereichAktiv else { return }
                // **Der eine Zwischenstand, der auch dann noch kommt.**
                //
                // Die Messung zeigt, wie ein echter Wert aussieht: der rohe
                // Versatz ist **minus** dem oberen Rand (−130,3 bei Rand
                // 130,8), die Summe also nahe null. Waehrend die Flaeche ihre
                // Geometrie neu rechnet, meldet sie dagegen einmal Versatz
                // null bei schon gesetztem Rand — daraus wird rechnerisch die
                // ganze Kopfhoehe, die Reihe klappt fuer ein, zwei Bilder zu
                // und wieder auf, und genau das ruckelt mitten im Aufziehen.
                //
                // Echt vorkommen kann die Paarung nur an einer Stelle: wenn
                // man zufaellig um exakt die Randhoehe gescrollt hat. Dort
                // kostet ein uebersprungenes Bild nichts, das naechste kommt
                // sofort.
                guard !(abs(neu.y) < 1 && neu.x > 1) else { return }
                versatz = neu.y + neu.x
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


            if stand.gestoert, stand.items.isEmpty, !stand.laedt {
                // Derselbe Text wie in der Bibliothek, samt Serveradresse —
                // eine Ursache, eine Diagnose. Vorher stand auch hier „Noch
                // nichts gemerkt", und das ist bei einer vollen Merkliste
                // schlicht falsch.
                Leerzustand(
                    symbol: "externaldrive.badge.xmark",
                    kopfzeile: "Server ist abgetaucht",
                    text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    hauptknopf: ("Erneut versuchen", { Task { await stand.laden(model) } }))
            } else if stand.items.isEmpty, !stand.laedt {
                // **Der Leerzustand sagt, wie man hineinkommt.** Sonst steht
                // dort eine Sackgasse: eine leere Liste, die nicht verrät,
                // woher ihr Inhalt käme.
                Leerzustand(symbol: "bookmark",
                            kopfzeile: "Noch nichts gemerkt",
                            text: "Tippe irgendwo auf das Lesezeichen. Dein Zukunfts-Ich freut sich.")
            }
        }
    }


    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            // **Vier, nicht vierzehn.** Der `Unterseitenkopf` bringt unten
            // schon 18 Punkt mit; zusammen mit 14 standen die Pillen 32 Punkt
            // unter dem Titel und wirkten abgehaengt. Paul am 21.09.: „viel zu
            // weit unten". Breit gibt es keinen solchen Unterbau, dort bleibt
            // es bei 14 — deshalb haengt die Zahl an `breit`.
            // Eine Zahl fuer „Kopf zu Wertreihe", wie in Bibliothek und
            // Downloads: 14 — und sie steht seit dem 21.09. in `Wertreihe`,
            // damit sie mit den Pillen verschwindet.
            VStack(alignment: .leading, spacing: 0) {
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
                            .tracking(Stil.sperrungTitel)
                            .foregroundStyle(Stil.schrift)
                        Spacer(minLength: 0)
                        if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                    }
                } else {
                    // **Die Zählmarke steht bei den Pillen, nicht im Kopf.**
                    //
                    // Sie war einen Tag lang oben rechts neben „Merkliste" —
                    // und stand dort auf einer anderen Ebene als die Werte,
                    // auf die sie sich bezieht. Paul am 21.09.: „die müsste
                    // rechts von den zwei Buttons sein und nicht von dem
                    // Namen". Sie zählt, was die zwei Pillen gefiltert haben,
                    // also gehört sie in deren Zeile.
                    Unterseitenkopf(titel: String(localized: "Merkliste"),
                                    zurueck: { zurueck() },
                                    // Der Abstand zur Pillenzeile kommt vom
                                    // Stapel, nicht zweimal.
                                    unten: 0) { EmptyView() }
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
                // Dieselbe Zeile wie in der Bibliothek, dasselbe Verhalten:
                // schmal klappt sie beim Scrollen zu, breit bleibt sie stehen.
                // Die Begruendung steht bei `Wertreihe`.
                pillenzeile
            }
        }
    }

    @ViewBuilder
    private var pillenzeile: some View {
        if breit {
            werte.padding(.top, 14)
        } else {
            Wertreihe(versatz: versatz) { werte }
        }
    }

    private var werte: some View {
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

                        Spacer(minLength: 12)
                        if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                    }
                }
    }

    @Environment(\.dismiss) private var schliessen
    private func zurueck() { schliessen() }
}
