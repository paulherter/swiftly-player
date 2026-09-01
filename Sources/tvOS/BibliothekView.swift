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
                    // **Die Chipreihe beginnt bei 190.**
                    //
                    // Dieselbe Zeile, in der auf der Startseite der erste
                    // Reihentitel steht und auf den Detailseiten der Titel.
                    // Die Leiste endet bei 128, es bleiben also 62 Punkt
                    // Luft — genug, dass die Seite atmet, ohne dass ein
                    // leerer Kopf entsteht.
                    //
                    // Die Scrollflaeche beginnt beim oberen sicheren Rand,
                    // deshalb nur die Differenz. Ohne Leiste (benannte
                    // Bibliothek ueber den Sprungpfad) reicht der Rand.
                    .padding(.top, bibliothek == nil ? 190 - Stil.randOben : Stil.randOben)
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
                    .padding(.top, 190 + Stil.chipHoehe + 16)
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
        let ton: Color = art == "movies"
            ? Color(hue: 351.0 / 360, saturation: 0.56, brightness: 0.82)
            : Stil.akzent
        return ZStack {
            Stil.grund
            RadialGradient(colors: [ton.opacity(0.16), ton.opacity(0)],
                           center: UnitPoint(x: 1, y: 0),
                           startRadius: 0, endRadius: 1500)
        }
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
