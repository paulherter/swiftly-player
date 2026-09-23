import JellyfinKit
import SwiftUI

/// Trakt verbinden — die Mac-Fassung.
///
/// Derselbe Ablauf wie auf dem iPhone (`Shared/TraktEinstellungenView`):
/// Code holen, bei Trakt eingeben, die Seite merkt es von selbst. „Trakt
/// öffnen" bringt den Browser mit dem Code schon in der Adresse.
///
/// Derselbe Aufbau wie `SeerrEinstellungenView` auf dem Mac — Kopf,
/// Erklärung, dann „Verbunden" oder der Weg dorthin.
struct TraktEinstellungenView: View {
    let trakt: Traktkonto
    let zurueck: () -> Void

    @Environment(\.openURL) private var oeffnen

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Trakt", zurueck: zurueck)

                Text("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                if trakt.verbunden { verbunden } else { anmeldung }

                Text("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt.")
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            .frame(maxWidth: Stil.formularbreite, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .seitenscrollen()
        .onDisappear { trakt.abbrechen() }
    }

    private var verbunden: some View {
        Einstellungsgruppe(titel: "Verbunden") {
            Wertezeile(symbol: "person",
                       titel: Text(verbatim: trakt.benutzer ?? "Trakt"),
                       wert: String(localized: "Aktiv"))
            Blattlinie().padding(.leading, Stil.trennEinzugKarte)
            // **„Trennen", nicht „Abmelden"** — wie bei Seerr.
            Wertezeile(symbol: "xmark.circle", titel: Text("Verbindung trennen"),
                       aktion: { trakt.trennen() })
        }
        .padding(.top, 26)
    }

    @ViewBuilder
    private var anmeldung: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch trakt.anmeldung {
            case .keine:
                Hauptknopf(beschriftung: "Mit Trakt verbinden", symbol: "link") { trakt.verbinden() }
            case .holtCode:
                Text("Hole Code…")
                    .font(Stil.koerper).foregroundStyle(Stil.schriftLeise)
            case let .code(code, bis):
                codeteil(code, bis: bis)
            case let .fehler(text):
                Text(verbatim: text)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.fehler)
                    .fixedSize(horizontal: false, vertical: true)
                Hauptknopf(beschriftung: "Neuer Code", symbol: "arrow.clockwise") { trakt.verbinden() }
                    .padding(.top, 20)
            }
        }
        .padding(.top, 26)
    }

    private func codeteil(_ code: TraktGeraetecode, bis: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Geh auf \(code.adresseKurz) und gib diesen Code ein.")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schrift)
                .fixedSize(horizontal: false, vertical: true)

            // Dieselbe Gestalt wie auf dem iPhone: eine Feldfläche, der Code
            // in der größten Stufe, auswählbar zum Kopieren.
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
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            .padding(.top, 10)

            Hauptknopf(beschriftung: "Trakt öffnen", symbol: "safari") { oeffnen(code.direktadresse) }
                .padding(.top, 20)
        }
    }
}
