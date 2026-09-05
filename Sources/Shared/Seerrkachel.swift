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

    /// **Nur was etwas Neues sagt.** „Kann angefragt werden" steht schon als
    /// Überschrift über dem Block; eine Plakette, die es wiederholt, ist
    /// Lärm. Ein Plus dagegen ist eine Einladung, und wartet/lädt sind
    /// Auskünfte, die es sonst nirgends gibt.
    @ViewBuilder
    private var plakette: some View {
        switch treffer.stand {
        case .offen, .geloescht:
            marke("plus", Stil.akzent, Stil.grund)
        case .wartetAufFreigabe:
            marke(nil, Color(red: 0.85, green: 0.60, blue: 0.17), Stil.grund,
                  text: String(localized: "wartet"))
        case .laedt:
            marke(nil, Color(red: 0.29, green: 0.56, blue: 0.85), Stil.grund,
                  text: String(localized: "lädt"))
        case .teilweiseDa:
            marke("plus", Stil.akzent, Stil.grund,
                  text: String(localized: "teilweise"))
        case .da:
            EmptyView()
        }
    }

    private func marke(_ symbol: String?, _ grund: Color, _ schrift: Color,
                       text: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            if let text { Text(verbatim: text).font(.system(size: 10, weight: .semibold)) }
        }
        .foregroundStyle(schrift)
        .padding(.horizontal, text == nil ? 5 : 7)
        .padding(.vertical, 3)
        .background(grund, in: Capsule())
    }

    private var ansage: String {
        switch treffer.stand {
        case .offen, .geloescht: String(localized: "kann angefragt werden")
        case .wartetAufFreigabe: String(localized: "wartet auf Freigabe")
        case .laedt: String(localized: "lädt gerade")
        case .teilweiseDa: String(localized: "teilweise vorhanden")
        case .da: String(localized: "auf deinem Server")
        }
    }
}
