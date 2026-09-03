import JellyfinKit
import SwiftUI

/// Einstellungen der App.
///
/// Gleicher Aufbau wie die Profilseite: flache Zeilen mit Haarlinien, Gruppen
/// nur durch Leerraum und einen kleinen gesperrten Titel getrennt.
///
/// Hier steht, was die App betrifft. Alles zur Wiedergabe — Qualität,
/// Sprache, Verhalten — liegt auf einer eigenen Seite; sonst stünde dasselbe
/// an zwei Stellen.
struct EinstellungenView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var pruefung: String?
    @State private var pruefe = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            ScrollView { inhalt }
                .scrollIndicators(.hidden)
            Seitenpfeil { zurueck() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Einstellungen")
                .font(Stil.titel)
                .tracking(-0.6)
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 52)

            // Breit nebeneinander. Beide Gruppen sind kurz; untereinander
            // stünden sie in einer Spalte, neben der zwei Drittel der Seite
            // leer bleiben.
            //
            // Ausdrücklich **nicht** mit Wiedergabe und Profil zu einer Seite
            // zusammengelegt, wie es der Fernseher tut. Dort ist der Grund
            // die Fernbedienung: jeder gesparte Sprung ist ein Weg. Ein Tipp
            // auf dem iPad kostet nichts.
            if breit {
                HStack(alignment: .top, spacing: 56) {
                    darstellung.frame(maxWidth: .infinity, alignment: .leading)
                    server.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                darstellung
                server
            }

            Text("Swiftly 1.0 · VLCKit 4.0.0-a23")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 26)
        }
        .padding(.bottom, 40)
    }

    // MARK: Gruppen

    private var darstellung: some View {
        Einstellungsgruppe(titel: "Darstellung") {
            // Auf dem iPad fehlt diese Zeile, und das ist Absicht: ohne
            // `UIRequiresFullScreen` gilt die App als multitaskingfähig, und
            // eine solche App darf die Drehung nicht erzwingen. Der Schalter
            // hätte dort keine Wirkung — und ein Schalter ohne Wirkung ist
            // schlechter als keiner. Die Frage beantwortet `Orientierung`,
            // nicht diese Ansicht — dort steht auch der Grund.
            if Orientierung.querformatSperreMoeglich {
                Wahlzeile(symbol: "rectangle.on.rectangle",
                            titel: Text("Querformat im Player sperren"),
                            an: Binding(get: { model.querformatFest },
                                        set: { model.querformatFest = $0 }))
                Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            }
            Wahlzeile(symbol: "chart.bar.fill", titel: Text("Fortschritt auf Kacheln"),
                        an: Binding(get: { model.fortschrittAufKacheln },
                                    set: { model.fortschrittAufKacheln = $0 }))
        }
    }

    private var server: some View {
        let anstossen: (() -> Void)? = pruefe ? nil : { pruefen() }

        return Einstellungsgruppe(titel: "Server") {
            Wertzeile(symbol: "externaldrive.connected.to.line.below",
                      titel: Text(verbatim: model.serverName ?? "Server"),
                      wert: model.serverVersion ?? "?")
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wertzeile(symbol: "wifi", titel: Text("Verbindung prüfen"),
                      unter: pruefung.map { Text(verbatim: $0) },
                      wert: pruefe ? String(localized: "Moment…") : nil,
                      aktion: anstossen)
        }
    }

    // MARK: Kleinkram



    private func pruefen() {
        pruefe = true
        Task {
            pruefung = await model.verbindungPruefen()
            pruefe = false
        }
    }
}
