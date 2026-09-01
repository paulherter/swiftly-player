import JellyfinKit
import SwiftUI

/// Einstellungen der App.
///
/// Hier steht, was die App betrifft. Alles zur Wiedergabe liegt auf einer
/// eigenen Seite — sonst stünde dasselbe an zwei Stellen. Diese Trennung ist
/// die der iPhone-Fassung und bleibt auf allen Plattformen gleich
/// (VERHALTEN.md, Abschnitt F).
struct EinstellungenView: View {
    let model: AppModel
    let zurueck: () -> Void

    @State private var pruefung: String?
    @State private var pruefe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Einstellungen", zurueck: zurueck)

                darstellung
                server

                Text(verbatim: "Swiftly 1.0 · VLCKit 4.0.0-a23")
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.3))
                    .padding(.top, 26)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.titelHoehe)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
    }

    private var darstellung: some View {
        Einstellungsgruppe(titel: "Darstellung") {
            // „Querformat im Player sperren" gibt es hier **nicht**: ein
            // Fenster hat keine Ausrichtung, die man sperren könnte. Das ist
            // kein Weglassen, sondern eine Einstellung ohne Gegenstück
            // (VERHALTEN.md F).
            Schalterzeile(symbol: "chart.bar.fill",
                          titel: Text("Fortschritt auf Kacheln"),
                          an: Binding(get: { model.fortschrittAufKacheln },
                                      set: { model.fortschrittAufKacheln = $0 }))
        }
    }

    private var server: some View {
        Einstellungsgruppe(titel: "Server") {
            Wertezeile(symbol: "externaldrive.connected.to.line.below",
                       titel: Text(verbatim: model.serverName ?? String(localized: "Server")),
                       wert: model.serverVersion ?? "?")
            Trennstrich().padding(.leading, 48)
            Wertezeile(symbol: "wifi", titel: Text("Verbindung prüfen"),
                       unter: pruefung.map { Text(verbatim: $0) },
                       wert: pruefe ? String(localized: "Moment…") : nil,
                       aktion: pruefe ? nil : { pruefen() })
        }
    }

    private func pruefen() {
        pruefe = true
        Task {
            pruefung = await model.verbindungPruefen()
            pruefe = false
        }
    }
}
