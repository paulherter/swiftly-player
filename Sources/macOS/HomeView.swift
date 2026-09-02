import JellyfinKit
import SwiftUI

/// Die Startseite: Weiterschauen, Nächste Folge, Zuletzt hinzugefügt.
///
/// **Kein Kopfverlauf.** Auf iPhone und Fernseher liegt oben ein Verlauf,
/// weil dort Uhrzeit, Akku und die Wortmarke über dem scrollenden Inhalt
/// stehen und lesbar bleiben müssen. Im Fenster steht dort nichts — die
/// Wortmarke sitzt in der Seitenleiste. Ein Verlauf über Leerraum wäre eine
/// Verzierung ohne Aufgabe.
///
/// Eine Kachel in „Weiterschauen" startet **sofort** an der gemerkten Stelle,
/// „Nächste Folge" von vorn, „Zuletzt hinzugefügt" führt auf die Übersicht —
/// dort hat man noch nichts angefangen. Wörtlich die Regeln der
/// iPhone-Fassung.
struct HomeView: View {
    let model: AppModel
    @Environment(Abspielsteuerung.self) private var steuerung
    /// Legt ein Ziel auf den Stapel des Bereichs.
    ///
    /// Bewusst durchgereicht und **kein** eigenes `navigationDestination`:
    /// zwei Ziele für denselben Typ im selben Stapel sind eine Falle, und
    /// welches gewinnt, ist nicht festgelegt.
    let oeffne: (Item) -> Void

    @State private var weiter: [Item] = []
    @State private var naechste: [Item] = []
    @State private var neu: [Item] = []
    @State private var geladen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Stil.reihenAbstand) {

                if !weiter.isEmpty {
                    Reihe(titel: "Weiterschauen") {
                        ForEach(weiter, id: \.id) { titel in
                            Querkachel(titel: kopf(titel), zweitzeile: titel.kontextzeile,
                                       bild: model.querbildURL(for: titel),
                                       fortschritt: fortschritt(titel),
                                       auswahl: { steuerung.starte(titel) },
                                       uebersicht: { oeffne(titel) })
                        }
                    }
                }

                if !naechste.isEmpty {
                    Reihe(titel: "Nächste Folge") {
                        ForEach(naechste, id: \.id) { folge in
                            // Von vorn — die Folge hat noch nicht angefangen.
                            Querkachel(titel: kopf(folge), zweitzeile: folge.folgenkuerzel,
                                       bild: model.querbildURL(for: folge),
                                       auswahl: { steuerung.starte(folge, ab: 0) },
                                       uebersicht: { oeffne(folge) })
                        }
                    }
                }

                if !neu.isEmpty {
                    Reihe(titel: "Zuletzt hinzugefügt") {
                        ForEach(neu, id: \.id) { titel in
                            NavigationLink(value: titel) {
                                Posterkachel(titel: titel.name,
                                             zweitzeile: titel.neuzugangszeile,
                                             bild: model.imageURL(for: titel, hochkant: true))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if geladen, weiter.isEmpty, naechste.isEmpty, neu.isEmpty {
                    Leerzustand(symbol: "tray", titel: "Hier ist noch nichts",
                                text: "Sobald der Server Titel hat, stehen sie hier.")
                        .padding(.top, 120)
                }
            }
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .overlay { if !geladen { Lader() } }
        .task { await laden() }
    }

    private func kopf(_ titel: Item) -> String {
        titel.seriesName ?? titel.name
    }

    private func fortschritt(_ titel: Item) -> Double? {
        guard let daten = titel.userData?.playedPercentage else { return nil }
        return daten / 100
    }

    private func laden() async {
        async let a = model.weiterschauen()
        async let b = model.naechsteFolge()
        async let c = model.zuletztHinzugefuegt()
        weiter = await a ?? []
        naechste = await b ?? []
        neu = await c ?? []
        geladen = true
    }
}

/// Eine waagerechte Reihe mit Überschrift.
struct Reihe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Der geteilte `Reihentitel` setzt keinen Rand — `randAbstand`
            // gibt es auf tvOS nicht, also gehört er zum Aufrufer. Auch die
            // Breite: ohne sie rutscht der Titel in die Mitte.
            // Der geteilte `Reihentitel` setzt keinen Rand — `randAbstand`
            // gibt es auf tvOS nicht, also gehört er zum Aufrufer. Auch die
            // Breite: ohne sie rutscht der Titel in die Mitte.
            Reihentitel(text: titel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
            Blätterreihe(breiteJeStueck: Stil.querBreite + Stil.kachelAbstand) { inhalt }
        }
    }
}
