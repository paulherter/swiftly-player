import JellyfinKit
import SwiftUI

/// Was gemerkt ist, quer über alle Bibliotheken — die Fernseherfassung.
///
/// **Eine Bibliothek wie jede andere, nur ist ihre Grenze der Haken.** Nicht
/// ein Ordner auf der Platte, sondern was der Nutzer angetippt hat; deshalb
/// sind Filme und Serien hier gemischt. Aufbau und Bausteine sind die der
/// Bibliotheksseite — Chipreihe, Anzahl, Gitter, Kachelmarken, Platzhalter
/// statt Ring.
///
/// **Und hier ist sie ein eigener Bereich**, kein Ziel aus einer Ecke. Auf
/// dem iPhone gehört der vierte Platz unten den Downloads, und die gibt es
/// auf einem Fernseher nicht — dort steckt kein Speicher, den man füllen
/// will, und die Kiste steht ohnehin am Netz. Der Platz in der Kopfleiste ist
/// also frei, und ein Reiter ist mit einer Fernbedienung der kürzeste Weg.
/// Der Grund ist Eingabeart und Gerät; damit erlaubt ihn Abschnitt F.
struct MerklisteView: View {
    let model: AppModel

    @State private var stand: Merklistenmodell

    init(model: AppModel) {
        self.model = model
        let frisch = Merklistenmodell()
        _stand = State(initialValue: frisch)
        _gattung = State(initialValue: Merkgattung.zu(art: frisch.gattung))
    }
    /// Die Pille der Ansicht und die Gattung im Modell muessen beim Start
    /// dasselbe sagen — das Modell holt sie aus der Ablage, die Ansicht
    /// liest sie von dort ab.
    @State private var gattung: Merkgattung
    /// **Wie in der Bibliothek, nicht anders** — und das gilt jetzt fuer
    /// beide Fragen dieser Seite.
    ///
    /// Die Sortierung stand hier als zweite Chipreihe neben der Gattung — auf
    /// Filme und Serien ist sie ein Knopf, der eine Tafel unter sich
    /// aufklappt. Zwei Fassungen derselben Frage auf Nachbarseiten; und die
    /// Chipreihe hatte einen zweiten Nachteil: sie faengt die Menue-Taste
    /// nicht, also verliess Zurueck die Seite, statt die Auswahl zu
    /// schliessen.
    ///
    /// **Die Gattung ist jetzt ebenso eine Kapsel.** Als Chipsatz stand sie
    /// mit drei Marken in der Reihe, obwohl immer genau eine an ist — das ist
    /// eine Auswahl, kein Filter, derselbe Grund wie bei der
    /// Bibliothekswahl. Auf dem iPhone steht sie seit je hinter einem Knopf
    /// (`Auswahlblatt`, Gattung); der Fernseher hatte den Schritt nur nicht
    /// mitgemacht.
    @State private var offeneTafel: Tafel?
    @FocusState private var amAusloeser: Tafel?

    /// Hoechstens eine Tafel ist offen. Dieselbe Kennung sagt beim
    /// Schliessen, auf welche Kapsel der Fokus zurueck muss — wie in
    /// `BibliothekView`.
    private enum Tafel: Hashable {
        case gattung, sortierung

        /// Der Name des Knopfs, an dem die Tafel haengt — siehe `Tafelanker`.
        var ausloeser: String { self == .gattung ? "gattung" : "sortierung" }
    }
    @Environment(\.tafelOffen) private var tafelOffen

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ZStack {
            if stand.items.isEmpty, stand.laedt {
                Rasterplatzhalter()
                    .padding(.horizontal, Stil.randSeite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Stil.leisteUnten + 90)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        chipreihe
                        if stand.gestoert, stand.items.isEmpty {
                            // **Gestoert ist nicht leer.** `stand.gestoert`
                            // stand im Modell und wurde nicht gelesen: bei
                            // einer vollen Merkliste und einem stummen
                            // Server stand „Noch nichts gemerkt" da, und das
                            // ist schlicht falsch. Derselbe Text wie in der
                            // Bibliothek — eine Ursache, eine Diagnose.
                            Leerzustand(
                                symbol: "externaldrive.badge.xmark",
                                titel: "Server ist abgetaucht",
                                hinweis: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                                knopf: ("Erneut versuchen", { Task { await stand.laden(model) } }))
                                .frame(height: 460)
                        } else if stand.items.isEmpty {
                            // **Der Leerzustand sagt, wie man hineinkommt.**
                            // Sonst steht dort eine Sackgasse — und auf der
                            // Fernbedienung noch unangenehmer als am Finger.
                            Leerzustand(symbol: "bookmark",
                                        titel: "Noch nichts gemerkt",
                                        hinweis: "Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort auswählst, sammelt sich hier.",
                                        knopf: ("Aktualisieren", { Task { await stand.laden(model) } }))
                                .frame(height: 460)
                        } else {
                            gitter
                        }
                    }
                    .padding(.top, Stil.erstesEnde - Stil.chipHoehe - Stil.randOben)
                    .padding(.bottom, 60)
                    .padding(.horizontal, Stil.randSeite)
                }
            }
        }
        // **Der seitliche Systemrand faellt weg** — wie in der Bibliothek und
        // auf der Startseite. Ohne das sitzt `randSeite` auf dem Rand, den
        // tvOS ohnehin freihaelt, und der Abstand liegt doppelt an: die
        // Chipreihe stand rund sechzig Punkt weiter rechts als dieselbe Reihe
        // auf Filme und Serien.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .horizontal)
        // Hinter der offenen Tafel ist nichts fokussierbar — wie in der
        // Bibliothek; sonst steigt der Fokus aus der Tafel heraus.
        .disabled(offeneTafel != nil)
        // Unter ihrem Knopf, an seiner Kante — siehe `Tafelanker`. Vorher
        // feste Abstaende von der Kante, und damit um den sicheren Rand
        // daneben; dieselbe Stelle wie auf der Filmseite.
        .tafel(unter: offeneTafel?.ausloeser) {
            Handlungstafel(handlungen: offeneTafel == .gattung
                                       ? gattungshandlungen : sortierhandlungen,
                           offen: tafelBindung)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: offeneTafel)
        // Die Seite schaltet sich selbst ab, die Kopfleiste gehoert ihr aber
        // nicht — die muss `HauptView` stilllegen.
        .onChange(of: offeneTafel) { alt, neu in
            tafelOffen.wrappedValue = neu != nil
            if neu == nil, let alt { amAusloeser = alt }
        }
        .onDisappear { tafelOffen.wrappedValue = false }
        .animation(Stil.einblenden, value: stand.items.isEmpty)
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model) }
    }

    private var chipreihe: some View {
        HStack(alignment: .center, spacing: 20) {
            Button { offeneTafel = .gattung } label: {
                Text(gattung.beschriftung)
            }
            .buttonStyle(KapselStil())
            .focused($amAusloeser, equals: .gattung)
            .tafelausloeser(Tafel.gattung.ausloeser)
            .accessibilityLabel(Text("Gattung, \(gattung.beschriftung)"))

            // Der Strich, der hier stand, trennte die Gattung von einer
            // zweiten Chipreihe. Die ist zur Tafel geworden und steht rechts
            // — jetzt trennt der Abstand, und ein Strich mitten im Nichts
            // bliebe stehen.
            Spacer(minLength: 40)

            if stand.gesamt > 0 {
                Text("\(stand.gesamt) · sortiert nach")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }

            // **Derselbe Stil wie auf Filme und Serien, nicht ein eigener.**
            // Hier stand ein `KnopfStil` mit selbst gesetztem Pfeil: andere
            // Ecke, andere Schriftgroesse, anderer Abstand als die Kapsel
            // eine Seite weiter — bei gleicher Aufgabe. Den Pfeil bringt
            // `KapselStil` mit.
            Button { offeneTafel = .sortierung } label: {
                Text(stand.sortierung.beschriftung)
            }
            .buttonStyle(KapselStil())
            .focused($amAusloeser, equals: .sortierung)
            .tafelausloeser(Tafel.sortierung.ausloeser)
            .accessibilityLabel(Text("Sortierung, \(stand.sortierung.beschriftung)"))
        }
        .focusSection()
    }

    /// `Handlungstafel` kennt nur offen oder zu; zu heisst hier: keine Tafel.
    private var tafelBindung: Binding<Bool> {
        Binding(get: { offeneTafel != nil },
                set: { if !$0 { offeneTafel = nil } })
    }

    /// Die Gattungen als Tafel — dieselben Zeichen wie die Bibliothekswahl.
    private var gattungshandlungen: [Titelhandlung] {
        Merkgattung.allCases.map { fall in
            Titelhandlung(symbol: gattung == fall ? "checkmark.circle.fill" : "circle",
                          text: LocalizedStringKey(fall.beschriftung)) {
                gattung = fall
                stand.gattung = fall.art
            }
        }
    }

    private var sortierhandlungen: [Titelhandlung] {
        Sortierung.allCases.map { fall in
            // Haken und leerer Kreis, wie in `BibliothekView` — hier stand
            // ein Haken gegen ein Sortierzeichen, also zwei Bedeutungen in
            // einer Spalte.
            Titelhandlung(symbol: stand.sortierung == fall ? "checkmark.circle.fill" : "circle",
                          // `beschriftung` ist eine fertige Zeichenkette —
                          // sie wird im Modell uebersetzt, nicht hier.
                          text: LocalizedStringKey(fall.beschriftung)) {
                stand.sortierung = fall
            }
        }
    }

    private var gitter: some View {
        LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
            ForEach(stand.items) { item in
                NavigationLink(value: item) {
                    Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                      hochkant: true),
                                 titel: item.name,
                                 fortschritt: item.userData?.playedPercentage
                                     .map { $0 / 100 },
                                 mitUnterzeile: false,
                                 marke: Anzeigeregeln.kachelmarke(
                                    art: item.type,
                                    staffeln: item.childCount,
                                    gesehen: item.userData?.played,
                                    offeneFolgen: item.userData?.unplayedItemCount))
                }
                .buttonStyle(KachelStil())
                .onAppear {
                    guard stand.loestNachladenAus(item.id, spalten: Stil.gitterSpalten)
                    else { return }
                    Task { await stand.nachladen(model) }
                }
            }
        }
    }
}
