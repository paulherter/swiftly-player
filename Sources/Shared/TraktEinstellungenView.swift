import JellyfinKit
import SwiftUI

/// Trakt verbinden — Code holen, bei Trakt eingeben, fertig.
///
/// **Kein Passwort, kein Browser in der App.** Trakt sieht für Geräte den
/// Gerätecode vor: hier steht ein Code, auf trakt.tv/activate wird er
/// eingegeben, und die Seite merkt es von selbst. Auf dem Telefon öffnet
/// „Trakt öffnen" die Adresse mit dem Code schon darin.
///
/// Derselbe Aufbau wie `SeerrEinstellungenView`: Erklärung oben, darunter
/// entweder „Verbunden" oder der Weg dorthin.
struct TraktEinstellungenView: View {
    let trakt: Traktkonto

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @Environment(\.openURL) private var oeffnen

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Trakt")) { zurueck() }
                ScrollView { inhalt }.scrollIndicators(.hidden)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        // Wer die Seite verlässt, bricht das Nachfragen ab — sonst fragte
        // die App zehn Minuten lang im Hintergrund weiter.
        .onDisappear { trakt.abbrechen() }
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen.")
                .mitwachsend(15)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 10)

            if trakt.verbunden { verbundenTeil } else { anmeldeteil }

            // **Der Hinweis gilt für beide Zustände.** Wer schon verbunden
            // ist und das Plugin hat, soll hier lesen, warum alles doppelt
            // bei Trakt steht.
            Text("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt.")
                .mitwachsend(12)
                .foregroundStyle(Stil.schriftSehrLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 14)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: Stil.formularbreite, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: breit ? .center : .leading)
    }

    // MARK: Verbunden

    private var verbundenTeil: some View {
        Einstellungsgruppe(titel: "Verbunden") {
            Wertzeile(symbol: "person",
                      titel: Text(verbatim: trakt.benutzer ?? "Trakt"),
                      wert: String(localized: "Aktiv"))
            Blattlinie()
            // **„Trennen", nicht „Abmelden"** — wie bei Seerr. Bei Trakt
            // bleibt der Verlauf, wie er ist.
            Wertzeile(symbol: "xmark.circle", titel: Text("Verbindung trennen"),
                      aktion: { trakt.trennen() })
        }
        .padding(.top, 26)
    }

    // MARK: Anmelden

    @ViewBuilder
    private var anmeldeteil: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch trakt.anmeldung {
            case .keine:
                Button("Mit Trakt verbinden") { trakt.verbinden() }
                    .buttonStyle(HauptknopfStil())
            case .holtCode:
                Text("Hole Code…")
                    .mitwachsend(15).foregroundStyle(Stil.schriftLeise)
            case let .code(code, bis):
                codeteil(code, bis: bis)
            case let .fehler(text):
                Text(verbatim: text)
                    .mitwachsend(12)
                    .foregroundStyle(Stil.fehler)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Neuer Code") { trakt.verbinden() }
                    .buttonStyle(HauptknopfStil())
                    .padding(.top, 20)
            }
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.top, 26)
    }

    private func codeteil(_ code: TraktGeraetecode, bis: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Geh auf \(code.adresseKurz) und gib diesen Code ein.")
                .mitwachsend(15)
                .foregroundStyle(Stil.schrift)
                .fixedSize(horizontal: false, vertical: true)

            // Dieselbe Gestalt wie das Codefeld bei Quick Connect: dort wird
            // ein Code getippt, hier abgelesen — dieselbe Sache.
            Text(verbatim: code.nutzercode)
                .font(Stil.titelGross.monospacedDigit())
                .foregroundStyle(Stil.schrift)
                .textSelection(.enabled)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                .accessibilityLabel(Text("Code"))
                .accessibilityValue(Text(verbatim: code.nutzercode.map(String.init).joined(separator: " ")))
                .padding(.top, 16)

            TimelineView(.periodic(from: .now, by: 1)) { kontext in
                let rest = max(0, Int(bis.timeIntervalSince(kontext.date)))
                Text("Läuft ab in \(rest / 60):\(String(format: "%02d", rest % 60))")
                    .mitwachsend(12)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            .padding(.top, 10)

            // Mit dem Code in der Adresse — auf dem Telefon, auf dem man
            // ohnehin ist, muss dann nichts abgetippt werden.
            Button("Trakt öffnen") { oeffnen(code.direktadresse) }
                .buttonStyle(HauptknopfStil())
                .padding(.top, 20)
        }
    }
}
