import JellyfinKit
import SwiftUI

/// **„Erweitert" auf dem Mac** — eigene Header für einen Dienst vor dem
/// Server (Issue #4). Die Vorlage ist `Shared/Erweitertbereich.swift`; hier
/// dieselben Zeilen (``Kopfzeile``) mit der `Eingabezeile` des Mac.
/// Zugeklappt und leer, damit sich für niemanden sonst etwas ändert. Der
/// Wert ist verdeckt wie ein Passwort.
struct MacErweitert: View {
    @Binding var zeilen: [Kopfzeile]
    var aufgeklappt = false

    @State private var offen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !aufgeklappt {
                Button {
                    withAnimation(Stil.einblenden) { offen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Erweitert")
                        Image(systemName: "chevron.right")
                            .font(Stil.plakette)
                            .rotationEffect(.degrees(offen ? 90 : 0))
                    }
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftLeise)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
            }
            if offen || aufgeklappt { inhalt }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if !zeilen.isEmpty { offen = true } }
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftSehrLeise)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($zeilen) { $zeile in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Eingabezeile(text: $zeile.name, symbol: "tag",
                                     platzhalter: String(localized: "Header-Name"))
                        Eingabezeile(text: $zeile.wert, symbol: "key", geheim: true,
                                     platzhalter: String(localized: "Wert"))
                        Button {
                            zeilen.removeAll { $0.id == zeile.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(Stil.koerper)
                                .foregroundStyle(Stil.schriftSehrLeise)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Stil.Druckknopf())
                        .help(Text("Entfernen"))
                        .accessibilityLabel(Text("Entfernen"))
                    }
                    if zeile.gesperrt {
                        Text("Den setzt Swiftly selbst.")
                            .font(Stil.zweitzeile)
                            .foregroundStyle(Stil.warnung)
                    }
                }
            }

            Button {
                zeilen.append(Kopfzeile())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Header hinzufügen")
                }
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.akzent)
                .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckknopf())
        }
    }
}

/// Die eigenen Header des aktiven Servers, in den Einstellungen unter der
/// Gruppe „Server". **Auf dem Mac ohne eigene Seite:** das Fenster hat den
/// Platz, und eine Unterseite für zwei Felder wäre ein Weg mehr.
struct MacEigeneKoepfe: View {
    let model: AppModel

    @State private var zeilen: [Kopfzeile] = []
    @State private var gesichert: [Eigenkopf] = []

    private var server: URL? { model.session?.serverURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacErweitert(zeilen: $zeilen)
            if zeilen.koepfe != gesichert {
                Hauptknopf(beschriftung: "Sichern", symbol: "checkmark") {
                    guard let server else { return }
                    model.eigeneKoepfeSichern(zeilen.koepfe, fuer: server)
                    gesichert = model.eigeneKoepfe(fuer: server)
                }
                .padding(.top, 14)
            }
        }
        .padding(.top, 14)
        .onAppear {
            gesichert = model.eigeneKoepfe(fuer: server)
            zeilen = Kopfzeile.aus(gesichert)
        }
    }
}
