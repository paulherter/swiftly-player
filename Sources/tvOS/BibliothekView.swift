import JellyfinKit
import SwiftUI

/// Eine Bibliothek als Gitter — sieben Spalten auf 1920 Punkt.
///
/// **Eine Chipreihe, nicht zwei.** Die Sortierung stand daneben als zweiter
/// Chipsatz, mit dem Argument, ein Aufklappblatt koste auf der Fernbedienung
/// zwei Wege statt einem. Das stimmt — nur waren es vier Chips, von denen
/// immer genau einer an ist, und das ist eine Auswahl, kein Filter. Zwei
/// Reihen gleich aussehender Kapseln mit verschiedener Bedeutung haben die
/// Seite zugestellt.
///
/// Jetzt: links die Filter, rechts die Anzahl und **ein** Knopf, der den
/// aktuellen Wert nennt und die Wahl dort aufklappt, wo er steht (E5) — wie
/// die Staffelpille auf der Serienseite.
///
/// **Kein Kopfblock.** Startseite und Detailseiten tragen oben Titel,
/// Angabenzeile und Beschreibung des Titels, um den es geht. Eine Bibliothek
/// beschreibt keinen einzelnen Titel, sie zeigt einen Bestand — hier gibt es
/// nichts, was ein Heldenbild tragen muesste. Stattdessen faerbt der Grund
/// sich je Bereich, siehe `grundton`.
struct BibliothekView: View {
    let model: AppModel
    /// Entweder über die Gattung („movies", „tvshows") aus der Kopfleiste …
    var art: String?
    /// … oder als benannte Bibliothek über den Sprungpfad.
    var bibliothek: Item?
    var filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases

    /// Blättern, Filtern und Sortieren stehen in `Bibliotheksmodell` —
    /// geteilt mit der iPhone-Fassung.
    @State private var stand = Bibliotheksmodell()
    @State private var sortierwahlOffen = false
    @FocusState private var amSortierknopf: Bool

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ZStack {
            if stand.laedt {
                Lader.fern
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        chipreihe

                        if stand.items.isEmpty {
                            leer
                        } else {
                            gitter
                        }
                    }
                    // **Die Chipreihe endet bei 264**, wie das oberste
                    // Element jeder anderen Seite — siehe `Stil.erstesEnde`.
                    //
                    // Zurueckgerechnet aus ihrer eigenen Hoehe: 264 − 48 =
                    // 216, davon der obere sichere Rand ab, an dem die
                    // Scrollflaeche beginnt.
                    //
                    // Vorher stand hier der Anfang (190). Bei verschieden
                    // hohen Elementen richtet ein gemeinsamer Anfang nichts
                    // aus — die Chips endeten 26 Punkt hoeher als der Titel
                    // der Startseite.
                    .padding(.top, bibliothek == nil
                             ? Stil.erstesEnde - Stil.chipHoehe - Stil.randOben
                             : Stil.randOben)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(grundton.ignoresSafeArea())
        // Seitlicher Rand: siehe `HomeView` — der Systemrand faellt weg,
        // damit `randSeite` nicht darauf sitzt und sich verdoppelt.
        .ignoresSafeArea(edges: .horizontal)
        // Hinter der offenen Tafel ist nichts fokussierbar — siehe die
        // Detailseiten, dort war es derselbe Fehler.
        .disabled(sortierwahlOffen)
        .overlay(alignment: .topLeading) {
            if sortierwahlOffen {
                Handlungstafel(handlungen: sortierhandlungen, offen: $sortierwahlOffen)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Stil.erstesEnde + 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: sortierwahlOffen)
        .onChange(of: sortierwahlOffen) { _, offen in if !offen { amSortierknopf = true } }
        .task(id: stand.kennung) { await laden() }
    }

    /// **Je Bereich ein eigener Grundton.**
    ///
    /// Ein fester Verlauf aus der rechten oberen Ecke ins Dunkle — nicht aus
    /// einem Bild abgeleitet wie auf den Detailseiten: die Bibliothek hat
    /// keinen Titel, den sie beschreibt, also gibt es nichts abzuleiten.
    ///
    /// Serien tragen den Akzent (Farbton 171 Grad), Filme die Komplementaere
    /// (351 Grad) — gegenueberliegend auf dem Farbkreis, gleiche Saettigung
    /// und Helligkeit. Man sieht am Grund, wo man ist, bevor man die Leiste
    /// liest.
    ///
    /// E2 ist nicht beruehrt: das ist Grund, kein Bedienelement — dieselbe
    /// Begruendung wie beim gefaerbten Grund der Detailseiten.
    private var grundton: some View {
        let ton: Double = art == "movies" ? 351 : 171

        // **Ein Netz, kein radialer Verlauf.**
        //
        // Radial gestapelt hat es gebandet, und aus demselben Grund wie auf
        // den Detailseiten: ein Verlauf von einer Farbe nach durchsichtig
        // bewegt sich in RGB fast auf einer Geraden, die Stufengrenzen der
        // drei Kanaele fallen zusammen und bilden durchgehende Baender.
        //
        // `MeshGradient` interpoliert ueber eine Flaeche statt entlang einer
        // Linie — keine Stopps, an denen etwas knicken kann. 25 Stuetzpunkte,
        // damit die Farbe nicht in Inseln zerfaellt. Dazu dasselbe Rauschen
        // wie dort, gegen die Quantisierung der Flaeche selbst.
        //
        // Der Gipfel sitzt rechts bei 28 Prozent Hoehe, also knapp **unter**
        // dem Kopfverlauf der Leiste. Lag er in der Ecke, deckte der ihn zu
        // und es blieb eine Kante.
        let seite = 5
        var punkte: [SIMD2<Float>] = []
        for zeile in 0 ..< seite {
            for spalte in 0 ..< seite {
                punkte.append([Float(spalte) / Float(seite - 1),
                               Float(zeile) / Float(seite - 1)])
            }
        }
        return ZStack {
            MeshGradient(width: seite, height: seite, points: punkte,
                         colors: punkte.map { netzfarbe($0, ton: ton) })
            Bildton.rauschen
                .resizable(resizingMode: .tile)
                .opacity(0.008)
        }
        .ignoresSafeArea()
    }

    /// Nah am Gipfel farbig, weit weg der Grundton — dieselbe Rechnung wie
    /// bei `Bildgrund`, nur mit festem Farbton statt einem aus dem Bild.
    private func netzfarbe(_ punkt: SIMD2<Float>, ton: Double) -> Color {
        let dx = Double(0.97 - punkt.x), dy = Double(0.28 - punkt.y)
        let naehe = 1 - min(1, (dx * dx + dy * dy).squareRoot() / 1.2)
        return Color(hue: ton / 360,
                     saturation: 0.30 + 0.16 * naehe,
                     brightness: 0.050 + 0.055 * pow(naehe, 1.6))
    }

    /// Die Sortierungen als Handlungstafel — kein zweiter Chipsatz.
    private var sortierhandlungen: [Titelhandlung] {
        Sortierung.allCases.map { s in
            Titelhandlung(symbol: stand.sortierung == s ? "checkmark.circle.fill" : "circle",
                          text: "\(s.beschriftung)") { stand.sortierung = s }
        }
    }

    // MARK: Teile

    private var chipreihe: some View {
        HStack(alignment: .center, spacing: 20) {
            ForEach(filter) { f in
                Button(f.beschriftung) { stand.filter = f }
                    .buttonStyle(ChipStil(an: stand.filter == f))
            }

            Spacer(minLength: 40)

            // Die Anzahl stand bisher nirgends — sie ist die einzige Auskunft,
            // die eine Bibliothek ueber sich selbst geben kann.
            if stand.gesamt > 0 {
                Text("\(stand.gesamt) · sortiert nach")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }

            Button { sortierwahlOffen.toggle() } label: {
                HStack(spacing: 14) {
                    Text(stand.sortierung.beschriftung)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Stil.schrift.opacity(0.6))
                }
            }
            .buttonStyle(KnopfStil(hoehe: Stil.chipHoehe))
            .focused($amSortierknopf)
            .accessibilityLabel(Text("Sortierung, \(stand.sortierung.beschriftung)"))
        }
        .focusSection()
        .padding(.horizontal, Stil.randSeite)
    }

    private var gitter: some View {
        LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
            ForEach(stand.items) { item in
                NavigationLink(value: item) {
                    Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                      hochkant: true),
                                 titel: item.name,
                                 mitUnterzeile: false)
                }
                .buttonStyle(KachelStil())
                // Nachladen, sobald die drittletzte Reihe auftaucht — dann
                // steht der Nachschub, bevor der Fokus unten ankommt.
                .onAppear {
                    guard item.id == stand.nachladenAb(spalten: Stil.gitterSpalten)
                    else { return }
                    Task { await stand.nachladen(model, art: art, bibliothek: bibliothek) }
                }
            }
        }
        .padding(.horizontal, Stil.randSeite)
        // Der Fokusring der äußeren Spalten liegt sonst unter dem Rand.
        .scrollClipDisabled()
    }

    private var leer: some View {
        Leerzustand(
            symbol: stand.filter == .alle ? "tray" : "line.3.horizontal.decrease",
            titel: stand.filter == .alle ? "Hier ist noch nichts" : "Nichts gefunden",
            hinweis: stand.filter == .alle
                ? "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."
                : "Unter diesem Filter liegt gerade nichts.",
            knopf: stand.filter == .alle
                ? ("Aktualisieren", { Task { await laden() } })
                : ("Filter zurücksetzen", { stand.filter = .alle }))
        .frame(height: 500)
    }

    // MARK: Laden

    private func laden() async {
        await stand.laden(model, art: art, bibliothek: bibliothek)
    }
}
