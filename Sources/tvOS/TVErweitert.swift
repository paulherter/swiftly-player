import JellyfinKit
import SwiftUI

/// **„Erweitert" auf dem Fernseher** — eigene Header für einen Dienst vor dem
/// Server (Issue #4). Die Vorlage ist `Shared/Erweitertbereich.swift`; hier
/// dieselben Zeilen (``Kopfzeile``) mit den Feldern und Knöpfen des
/// Fernsehers. Zugeklappt und leer, damit sich für niemanden sonst etwas
/// ändert. Der Wert ist verdeckt wie ein Passwort.
struct TVErweitert: View {
    @Binding var zeilen: [Kopfzeile]
    var aufgeklappt = false

    @State private var offen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !aufgeklappt {
                Button {
                    withAnimation(Stil.einblenden) { offen.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Text("Erweitert")
                        Image(systemName: offen ? "chevron.down" : "chevron.right")
                    }
                }
                .buttonStyle(KnopfStil())
            }
            if offen || aufgeklappt { inhalt }
        }
        .onAppear { if !zeilen.isEmpty { offen = true } }
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($zeilen) { $zeile in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 20) {
                        Eingabefeld(platzhalter: "Header-Name", text: $zeile.name)
                        Eingabefeld(platzhalter: "Wert", text: $zeile.wert, sicher: true)
                        Button {
                            zeilen.removeAll { $0.id == zeile.id }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(KnopfStil(nurSymbol: true))
                        .accessibilityLabel(Text("Entfernen"))
                    }
                    if zeile.gesperrt {
                        Text("Den setzt Swiftly selbst.")
                            .font(Stil.klein)
                            .foregroundStyle(Stil.warnung)
                    }
                }
            }

            Button {
                zeilen.append(Kopfzeile())
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                    Text("Header hinzufügen")
                }
            }
            .buttonStyle(KnopfStil())
        }
    }
}

/// Die eigenen Header des aktiven Servers bearbeiten — aus Profil → Server.
struct TVEigeneKoepfeSeite: View {
    let model: AppModel
    let schliessen: () -> Void

    @State private var zeilen: [Kopfzeile] = []
    @State private var gesichert: [Eigenkopf] = []

    private var server: URL? { model.session?.serverURL }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Eigene Header")
                        .font(Stil.titelGross)
                        .foregroundStyle(Stil.schrift)
                    TVErweitert(zeilen: $zeilen, aufgeklappt: true)
                        .padding(.top, 44)
                    HStack(spacing: 20) {
                        if zeilen.koepfe != gesichert {
                            Button("Sichern") {
                                guard let server else { return }
                                model.eigeneKoepfeSichern(zeilen.koepfe, fuer: server)
                                gesichert = model.eigeneKoepfe(fuer: server)
                                schliessen()
                            }
                            .buttonStyle(KnopfStil())
                        }
                        Button(zeilen.koepfe != gesichert ? "Abbrechen" : "Fertig", action: schliessen)
                            .buttonStyle(KnopfStil())
                    }
                    .padding(.top, 44)
                }
                .frame(width: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
            }
        }
        .onAppear {
            gesichert = model.eigeneKoepfe(fuer: server)
            zeilen = Kopfzeile.aus(gesichert)
        }
    }
}
