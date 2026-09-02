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
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    /// **Der geteilte Stand, nicht ein eigener.**
    ///
    /// Hier standen vier `@State`-Felder und eine eigene `laden()`. Das war
    /// ein Nachbau von `Startseitenmodell`, und er war schon auseinander
    /// gelaufen: er rief `naechsteFolge()` **ohne** Argument, sodass die
    /// Titel aus „Weiterschauen" gleich noch einmal unter „Nächste Folge"
    /// standen, und er räumte bei einem einzelnen Aussetzer die ganze Reihe
    /// leer — genau der Fehler, vor dem der Kommentar im geteilten Modell
    /// warnt.
    ///
    /// Der Stand liegt jetzt in `HauptView` und überlebt den Leistenwechsel.
    let stand: Startseitenmodell

    private var weiter: [Item] { stand.weiterschauen }
    private var naechste: [Item] { stand.naechsteFolge }
    private var neu: [Item] { stand.zuletzt }
    private var geladen: Bool { stand.geladen }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Stil.reihenAbstand) {

                if !weiter.isEmpty {
                    Reihe(titel: "Weiterschauen", quer: true) {
                        ForEach(weiter, id: \.id) { titel in
                            Querkachel(titel: kopf(titel), zweitzeile: titel.kontextzeile,
                                       bild: model.querbildURL(for: titel),
                                       fortschritt: fortschritt(titel),
                                       auswahl: { steuerung.starte(titel) },
                                       uebersicht: { navigator.oeffne(.titel(titel), in: bereich) },
                                       vorholen: { Seriencache.geteilt.vorholen(titel, mit: model) })
                        }
                    }
                }

                if !naechste.isEmpty {
                    // **Hochkant, und der Klick führt auf die Seite.**
                    //
                    // Hier stand eine Querkachel, die sofort abspielte —
                    // beides falsch, und beides ohne Grund, der mit Eingabe
                    // oder Fenstergröße zu tun hätte.
                    //
                    // A2 im Register: „Nächste Folge **öffnet die
                    // Übersicht**, sie startet nicht. Nur ‚Weiterschauen'
                    // springt direkt in die Wiedergabe." Die iPhone-Fassung
                    // schreibt denselben Satz an dieselbe Stelle. Waagerecht
                    // ist ebenfalls allein „Weiterschauen" — iOS sagt es
                    // wörtlich, tvOS ruft die Reihe mit `quer: false`.
                    Reihe(titel: "Nächste Folge") {
                        ForEach(naechste, id: \.id) { folge in
                            Button { navigator.oeffne(.titel(folge), in: bereich) } label: {
                                Posterkachel(titel: kopf(folge),
                                             zweitzeile: folge.folgenkuerzel,
                                             bild: model.imageURL(for: folge, hochkant: true),
                                             vorholen: { Seriencache.geteilt.vorholen(folge, mit: model) })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !neu.isEmpty {
                    Reihe(titel: "Zuletzt hinzugefügt") {
                        ForEach(neu, id: \.id) { titel in
                            Button { navigator.oeffne(.titel(titel), in: bereich) } label: {
                                Posterkachel(titel: titel.name,
                                             zweitzeile: titel.neuzugangszeile,
                                             bild: model.imageURL(for: titel, hochkant: true),
                                             vorholen: { Seriencache.geteilt.vorholen(titel, mit: model) })
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
            // Nicht `inhaltOben` allein: die Startseite beginnt mit einer
            // kleineren Schrift als die Bibliotheksseiten und stünde sonst
            // zwei Punkt zu hoch. Siehe `Stil.reihenkopfAusgleich`.
            .padding(.top, Stil.inhaltOben + Stil.reihenkopfAusgleich)
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
        guard !stand.geladen else { return }
        await stand.laden(model)
        // Die Serien zu den Folgen im Hintergrund nachziehen: alle drei
        // Reihen bestehen bei Serien aus Folgen, und ein Klick darauf führt
        // auf die Serienseite (A8) — bis dahin fuhr sonst eine leere Seite
        // herein.
        Seriencache.geteilt.vorholen(weiter + naechste + neu, mit: model)
    }

}

/// Eine waagerechte Reihe mit Überschrift.
struct Reihe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    /// Waagerechte Kacheln — nur „Weiterschauen".
    var quer = false
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
            // **Jede Reihe mit ihrem eigenen Maß.** Vorher rechnete auch die
            // Posterreihe mit der Querbreite — dann blättert sie zu weit —
            // und die Pfeile standen auf der Höhe einer Querkachel.
            Blätterreihe(breiteJeStueck: (quer ? Stil.querBreite : Stil.kachelBreite)
                            + Stil.kachelAbstand,
                         bildHoehe: quer ? Stil.querHoehe : Stil.kachelHoehe) { inhalt }
        }
    }
}
