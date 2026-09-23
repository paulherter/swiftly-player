import JellyfinKit
import SwiftUI

/// Trakt verbinden — die Fernseherfassung.
///
/// **Hier ist der Gerätecode zu Hause.** Ein Passwort mit der Fernbedienung
/// zu tippen ist eine Zumutung; Trakt sieht für Fernseher genau diesen Weg
/// vor. Der Code steht groß in Feldern wie bei Quick Connect, daneben die
/// Adresse zum Abtippen und ein QR-Code, der sie samt Code aufs Telefon
/// bringt.
///
/// Als eigene Seite über allem, wie `SeerrAnbindenView`. Sie holt den Code
/// beim Öffnen selbst — wer hier ist, will verbinden.
struct TraktAnbindenView: View {
    let trakt: Traktkonto
    let schliessen: () -> Void

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(spacing: 0) {
                Text(verbatim: "Trakt")
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)

                Text("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 16)

                if trakt.verbunden { verbunden } else { anmeldung }

                Text("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt.")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .multilineTextAlignment(.center)
                    .frame(width: 1100)
                    .padding(.top, 40)
            }
        }
        .task { if !trakt.verbunden, trakt.anmeldung == .keine { trakt.verbinden() } }
        .onDisappear { trakt.abbrechen() }
        .onExitCommand(perform: schliessen)
    }

    // MARK: Verbunden

    private var verbunden: some View {
        VStack(spacing: 18) {
            Text(verbatim: trakt.benutzer ?? "Trakt")
                .font(Stil.koerper).foregroundStyle(Stil.schrift)
            Text("Aktiv")
                .font(Stil.klein).foregroundStyle(Stil.schriftLeise)
            HStack(spacing: 24) {
                // **„Trennen", nicht „Abmelden"** — wie bei Seerr.
                Button("Verbindung trennen") { trakt.trennen() }
                    .buttonStyle(KnopfStil())
                Button("Fertig", action: schliessen)
                    .buttonStyle(KnopfStil())
            }
            .padding(.top, 26)
        }
        .padding(.top, 56)
    }

    // MARK: Anmelden

    @ViewBuilder
    private var anmeldung: some View {
        switch trakt.anmeldung {
        case let .code(code, bis):
            codeteil(code, bis: bis)
        case let .fehler(text):
            Text(verbatim: text)
                .font(Stil.koerper)
                .foregroundStyle(Stil.fehler)
                .multilineTextAlignment(.center)
                .frame(width: 1100)
                .padding(.top, 56)
            knoepfe
        case .keine, .holtCode:
            // Der Code kommt gleich; solange steht seine Form da.
            Ladefeld(ecke: Stil.ecke)
                .frame(width: 560, height: 120)
                .padding(.top, 72)
            knoepfe
        }
    }

    private func codeteil(_ code: TraktGeraetecode, bis: Date) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 56) {
                if let bild = Codeblatt.code(code.direktadresse) {
                    Image(decorative: bild, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        // Weisser Rand gehört zum Code, siehe `Codeblatt`.
                        .padding(18)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text("Geh auf \(code.adresseKurz) und gib diesen Code ein.")
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schrift)
                    Codefelder(code: code.nutzercode)
                        // Acht Zeichen statt sechs: eine Stufe kleiner, damit
                        // die Felder neben dem QR-Code Platz haben.
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 128, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 1)) { kontext in
                        let rest = max(0, Int(bis.timeIntervalSince(kontext.date)))
                        Text("Läuft ab in \(rest / 60):\(String(format: "%02d", rest % 60))")
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
            }
            .padding(.top, 56)
            knoepfe
        }
    }

    private var knoepfe: some View {
        HStack(spacing: 24) {
            Button("Neuer Code") { trakt.verbinden() }
                .buttonStyle(KnopfStil())
            Button("Zurück", action: schliessen)
                .buttonStyle(KnopfStil())
        }
        .padding(.top, 52)
    }
}
