import JellyfinKit
import SwiftUI

/// **„Erweitert" — eigene Header für einen Dienst vor dem Server.**
///
/// Cloudflare Access, Authelia, Authentik, Pangolin: wer Jellyfin oder Seerr
/// so absichert, lässt die App nur mit bestimmten Headern durch (Issue #4).
/// Alle anderen brauchen das nie — deshalb **zugeklappt und leer**, und wer es
/// nicht aufmacht, bei dem ändert sich nichts.
///
/// Die Werte sind Zugänge und werden wie ein Passwort behandelt: verdeckt
/// eingegeben (`geheim`), im Schlüsselbund abgelegt, nie protokolliert.
///
/// Auf iPhone und iPad. Mac und Fernseher haben ihre eigene Fassung mit
/// ihren eigenen Feldern (`MacErweitert`, `TVErweitert`), dieselbe Zeile
/// darunter: ``Kopfzeile``.
struct Erweitertbereich: View {
    @Binding var zeilen: [Kopfzeile]
    /// Auf der eigenen Seite in den Einstellungen gibt es nichts aufzuklappen.
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
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(offen ? 90 : 0))
                    }
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
            }

            if offen || aufgeklappt { inhalt }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Wer schon Header eingetragen hat, soll sie sehen.
        .onAppear { if !zeilen.isEmpty { offen = true } }
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($zeilen) { $zeile in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Eingabefeld(text: $zeile.name, symbol: "tag",
                                    platzhalter: "Header-Name")
                        Button {
                            withAnimation(Stil.einblenden) { zeilen.removeAll { $0.id == zeile.id } }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 17))
                                .foregroundStyle(Stil.schriftSehrLeise)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Stil.Druckknopf())
                        .accessibilityLabel(Text("Entfernen"))
                    }
                    Eingabefeld(text: $zeile.wert, symbol: "key", platzhalter: "Wert",
                                geheim: true)
                        .padding(.trailing, 52)
                    if zeile.gesperrt {
                        Text("Den setzt Swiftly selbst.")
                            .font(Stil.klein)
                            .foregroundStyle(Stil.warnung)
                    }
                }
                .padding(.top, 4)
            }

            Button {
                withAnimation(Stil.einblenden) { zeilen.append(Kopfzeile()) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                    Text("Header hinzufügen")
                }
            }
            .buttonStyle(NebenknopfStil())
            .padding(.top, 4)
        }
    }
}

/// **Die eigenen Header des Servers, an dem die App gerade hängt.**
///
/// Die Bearbeitung nach der Anmeldung: aus Einstellungen → Server. Sichern
/// gilt sofort für jede weitere Anfrage, auch für Bilder und Downloads.
struct EigeneKoepfeSeite: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var zeilen: [Kopfzeile] = []
    @State private var gesichert: [Eigenkopf] = []

    private var server: URL? { model.session?.serverURL }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Eigene Header")) { zurueck() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Erweitertbereich(zeilen: $zeilen, aufgeklappt: true)
                            .padding(.top, 10)
                        if zeilen.koepfe != gesichert {
                            Button("Sichern") {
                                guard let server else { return }
                                model.eigeneKoepfeSichern(zeilen.koepfe, fuer: server)
                                gesichert = model.eigeneKoepfe(fuer: server)
                            }
                            .buttonStyle(HauptknopfStil())
                            .padding(.top, 22)
                        }
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.bottom, 40)
                    .frame(maxWidth: Stil.formularbreite, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: breit ? .center : .leading)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .onAppear {
            gesichert = model.eigeneKoepfe(fuer: server)
            zeilen = Kopfzeile.aus(gesichert)
        }
    }
}
