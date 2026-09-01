import JellyfinKit
import SwiftUI

/// Profil, Quick Connect, Einstellungen, Abmelden.
///
/// Eigene Seite statt Aufklappmenü. Das Menü stand als einziges seiner Art in
/// der App und wirkte wie ein Fremdkörper; dazu hing es an einem 34-pt-Ziel
/// oben in der Ecke, obwohl alles darin ohnehin weiterführt.
///
/// Aufbau aus drei Vorbildern zusammengelegt: der mittige Bildblock von
/// Netflix und Disney+, die flachen Zeilen mit Haarlinien und die nur durch
/// Leerraum getrennten Gruppen von Disney+ und Prime Video. Karten wären
/// Netflix pur und stehen neben unseren flachen Flächen fremd da.
struct ProfilView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    bildblock

                    gruppe {
                        Profilzeile(symbol: "rectangle.and.text.magnifyingglass",
                                    titel: "Quick Connect",
                                    unter: "Code vom Fernseher eingeben",
                                    akzent: true, letzte: true, ziel: QuickConnectRoute())
                    }

                    Color.clear.frame(height: 26)

                    gruppe {
                        Profilzeile(symbol: "play.fill", titel: "Wiedergabe",
                                    unter: "Sprache, Untertitel, Tempo",
                                    ziel: WiedergabeRoute())
                        Profilzeile(symbol: "gearshape", titel: "Einstellungen",
                                    letzte: true, ziel: EinstellungenRoute())
                    }

                    Color.clear.frame(height: 26)

                    gruppe {
                        Profilzeile(symbol: "rectangle.portrait.and.arrow.right",
                                    titel: "Abmelden", letzte: true) { model.signOut() }
                    }

                    Text("Swiftly 1.0")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 26)
                }
                .padding(.bottom, 40)
                // Breit ein Maß: über die volle iPad-Breite stünde der Pfeil
                // einen halben Meter neben seiner Beschriftung. Mittig, weil
                // der Bildblock darüber es auch ist.
                .frame(maxWidth: breit ? Stil.lesebreite : .infinity)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            // Nur der Pfeil, kein Titel — der Bildblock ist der Titel.
            Seitenpfeil { zurueck() }
        }
        #if os(iOS)
        // Ohne das steht Apples Leiste mit eigenem Zurueckpfeil darueber —
        // dann sind es zwei, einer davon aus Glas.
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    private var bildblock: some View {
        VStack(spacing: 10) {
            Profilzeichen(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL(groesse: 200),
                          groesse: 84)
            VStack(spacing: 3) {
                Text(model.session?.userName ?? "Angemeldet")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Stil.schrift)
                Text(untertitel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 30)
    }

    private var untertitel: String {
        var teile: [String] = []
        if let name = model.serverName { teile.append(name) }
        if let fassung = model.serverVersion { teile.append("Jellyfin \(fassung)") }
        return teile.joined(separator: " · ")
    }

    /// Haarlinie oben und unten, dazwischen die Zeilen. Keine Karte, keine
    /// Überschrift — getrennt wird nur durch Leerraum.
    private func gruppe<Inhalt: View>(@ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        VStack(spacing: 0) { inhalt() }
            .background(alignment: .top) { Trennlinie() }
            .background(alignment: .bottom) { Trennlinie() }
    }
}

/// Quick Connect: einen Code freigeben, der auf einem anderen Gerät steht.
///
/// Eigene Seite im selben Aufbau wie die Profilseite — Pfeil oben links,
/// Inhalt darunter. Vorher war es ein Blatt mitten im Bild, das seine eigene
/// Gestalt mitbrachte.
struct QuickConnectView: View {
    @Environment(\.breit) private var breit
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @FocusState private var imFeld: Bool

    @State private var code = ""
    @State private var laeuft = false
    @State private var meldung: String?
    @State private var geschafft = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Quick Connect")
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Stil.schrift)
                    .padding(.top, 8)

                Text("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an.")
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, 10)

                TextField("", text: $code, prompt: Text("000000")
                    .foregroundColor(Color.white.opacity(0.22)))
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .foregroundStyle(Stil.schrift)
                    .focused($imFeld)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
                    .overlay { RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand) }
                    .padding(.top, 26)

                if let meldung {
                    Text(meldung)
                        .font(.system(size: 13))
                        .foregroundStyle(geschafft ? Stil.akzent : Stil.warnung)
                        .padding(.top, 12)
                }

                Button(laeuft ? "Moment…" : "Freigeben") { freigeben() }
                    .buttonStyle(HauptknopfStil())
                    .disabled(laeuft || code.count < 4)
                    .padding(.top, 22)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 96)
            // Dasselbe Maß wie Anmeldung und Server: ein sechsstelliger Code
            // in einem 1036 Punkt breiten Feld ist absurd.
            .frame(maxWidth: Stil.formularbreite)
            .frame(maxWidth: .infinity)

            Seitenpfeil { zurueck() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            // Erst nach dem Übergang: holt man den Fokus sofort, schiebt die
            // aufziehende Tastatur die Seite mitten in der Animation und es
            // zuckt einmal.
            try? await Task.sleep(for: .milliseconds(420))
            imFeld = true
        }
    }

    private func freigeben() {
        laeuft = true
        meldung = nil
        Task {
            defer { laeuft = false }
            do {
                try await model.quickConnectFreigeben(code: code)
                geschafft = true
                meldung = String(localized: "Freigegeben. Das andere Gerät ist gleich angemeldet.")
                try? await Task.sleep(for: .seconds(2))
                zurueck()
            } catch {
                geschafft = false
                meldung = error.localizedDescription
            }
        }
    }
}
