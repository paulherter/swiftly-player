import JellyfinKit
import SwiftUI

/// Profil, Quick Connect, Wiedergabe, Einstellungen, Abmelden.
///
/// Aufbau und Reihenfolge wörtlich von der iPhone-Fassung: mittiger Bildblock,
/// darunter drei Gruppen, getrennt nur durch Leerraum. Keine Karten.
///
/// Die Seite ist im Fenster schmal gehalten — über die volle Breite gezogen
/// stünden Symbol und Wert einen halben Meter auseinander.
struct ProfilView: View {
    let model: AppModel
    let zurueck: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                bildblock

                Zeilengruppe {
                    Button { navigator.oeffne(.quickConnect, in: bereich) } label: {
                        Wertezeile(symbol: "rectangle.and.text.magnifyingglass",
                                   titel: Text("Quick Connect"),
                                   unter: Text("Code vom Fernseher eingeben"),
                                   akzent: true, pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                }

                Color.clear.frame(height: 26)

                Zeilengruppe {
                    Button { navigator.oeffne(.wiedergabe, in: bereich) } label: {
                        Wertezeile(symbol: "play.fill", titel: Text("Wiedergabe"),
                                   unter: Text("Sprache, Untertitel, Tempo"),
                                   pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                    Trennstrich().padding(.leading, 48)
                    Button { navigator.oeffne(.einstellungen, in: bereich) } label: {
                        Wertezeile(symbol: "gearshape", titel: Text("Einstellungen"),
                                   pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                }

                Color.clear.frame(height: 26)

                Zeilengruppe {
                    Wertezeile(symbol: "rectangle.portrait.and.arrow.right",
                               titel: Text("Abmelden")) { model.signOut() }
                }

                Text(verbatim: "Swiftly 1.0")
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 26)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
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
        .overlay(alignment: .topLeading) {
            // Nur der Pfeil, kein Titel — der Bildblock ist der Titel.
            Aktionsknopf(symbol: "chevron.left", titel: "Zurück", auswahl: zurueck)
                .padding(.leading, Stil.randAbstand - 8)
                .padding(.top, 12)
        }
    }

    private var bildblock: some View {
        VStack(spacing: 10) {
            Profilzeichen(name: model.session?.userName ?? "?",
                              bild: model.benutzerbildURL(groesse: 200), groesse: 84)
            VStack(spacing: 3) {
                Text(verbatim: model.session?.userName ?? String(localized: "Angemeldet"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Stil.schrift)
                Text(verbatim: untertitel)
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.schrift.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 42)
        .padding(.bottom, 30)
    }

    private var untertitel: String {
        var teile: [String] = []
        if let name = model.serverName { teile.append(name) }
        if let fassung = model.serverVersion { teile.append("Jellyfin \(fassung)") }
        return teile.joined(separator: " · ")
    }
}

// MARK: - Quick Connect

/// Einen Code freigeben, der auf einem anderen Gerät steht.
struct QuickConnectView: View {
    let model: AppModel
    let zurueck: () -> Void

    @State private var code = ""
    @State private var laeuft = false
    @State private var meldung: String?
    @State private var geschafft = false
    @FocusState private var imFeld: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Unterseitenkopf(titel: "Quick Connect", zurueck: zurueck)

            Text("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an.")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            TextField("", text: $code,
                      prompt: Text(verbatim: "000000").foregroundColor(Stil.schrift.opacity(0.22)))
                .textFieldStyle(.plain)
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .foregroundStyle(Stil.schrift)
                .focused($imFeld)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
                .overlay { RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand) }
                .padding(.top, 26)
                .onSubmit(freigeben)

            if let meldung {
                Text(verbatim: meldung)
                    .font(.system(size: 13))
                    .foregroundStyle(geschafft ? Stil.akzent : Stil.warnung)
                    .padding(.top, 12)
            }

            Hauptknopf(beschriftung: laeuft ? "Moment…" : "Freigeben",
                       symbol: "checkmark", auswahl: freigeben)
                .disabled(laeuft || code.count < 4)
                .opacity(code.count < 4 ? 0.4 : 1)
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Stil.randAbstand)
        .padding(.top, Stil.inhaltOben)
        // Kein Warten auf eine Tastaturanimation wie auf dem iPhone — im
        // Fenster schiebt nichts.
        .onAppear { imFeld = true }
    }

    private func freigeben() {
        guard code.count >= 4, !laeuft else { return }
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
                meldung = model.lesbar(error)
            }
        }
    }
}
