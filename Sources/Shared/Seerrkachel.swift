import JellyfinKit
import SwiftUI

/// Ein Titel, den der eigene Server noch nicht hat.
///
/// **Blass, und das ist die ganze Auskunft.** Wer schnell scrollt, soll ohne
/// ein Wort zu lesen sehen, dass hier nichts abzuspielen ist. Die Überschrift
/// darüber bestätigt es nur — sie ist nicht die Erklärung, sondern die
/// Bestätigung.
struct Seerrkachel: View {
    let treffer: Seerrtreffer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Bild(url: treffer.plakat(), ecke: Stil.eckeKachel)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .opacity(0.45)
                plakette
                    .padding(6)
            }
            Text(verbatim: treffer.titel)
                .font(Stil.kachel)
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
            Text(verbatim: untertitel)
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(treffer.titel), \(ansage)"))
    }

    private var untertitel: String {
        let art = treffer.istSerie ? String(localized: "Serie") : String(localized: "Film")
        return treffer.jahr.map { "\($0) · \(art)" } ?? art
    }

    /// **Dieselben Symbole wie auf der Seite dahinter.** Die Tabelle steht
    /// in `Seerrmarke.swift`; hier steht nur, wie sie aussieht — Symbol
    /// und, wo es etwas Neues sagt, ein Wort dazu.
    @ViewBuilder
    private var plakette: some View {
        if treffer.stand != .da {
            HStack(spacing: 3) {
                Image(systemName: treffer.stand.symbol)
                    .font(.system(size: 9, weight: .bold))
                if let wort = treffer.stand.kurzwort {
                    Text(verbatim: wort).font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(Stil.grund)
            .padding(.horizontal, treffer.stand.kurzwort == nil ? 5 : 7)
            .padding(.vertical, 3)
            .background(treffer.stand.farbe, in: Capsule())
        }
    }

    private var ansage: String { treffer.stand.ansage }
}
