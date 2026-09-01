//  Bausteine.swift
//  Swiftly
//
//  **Bausteine, die auf jeder Plattform dieselben sind.**
//
//  Sie standen dreimal da — einmal hier, einmal in `Sources/tvOS`, einmal in
//  `Sources/macOS` —, weil `Stil.swift` iPhone-Masse und neutrale Bausteine in
//  einer Datei mischte und die anderen Ziele sie deshalb nicht einbinden
//  konnten. Kopien laufen auseinander: bei `nachladen()`, `trefferauskunft`
//  und `Spielzeit` ist es passiert.
//
//  **Die Naht ist `Stil`.** Farben kommen aus `Farben.swift` und sind ohnehin
//  geteilt; Groessen kommen aus dem `Stil` des jeweiligen Ziels. Ein Baustein
//  hier darf deshalb nur benutzen, was **alle** Ziele haben:
//
//      Farben      akzent, rand, schrift, schriftLeise, flaeche
//      Stil        plakette, reihe
//
//  `Stil.randAbstand` gehoert nicht dazu — tvOS hat es nicht. Abstaende setzt
//  darum der Aufrufer, nicht der Baustein.

import SwiftUI

/// Überschrift über einer Reihe.
struct Reihentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Stil.reihe)
            .tracking(-0.3)
            .foregroundStyle(Stil.schrift)
    }
}

/// Kleine Angabe wie „FSK 16" oder „4K".
struct Plakette: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Stil.plakette)
            .foregroundStyle(Stil.schriftLeise)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Stil.rand))
    }
}

struct Lader: View {
    var groesse: CGFloat = 34
    var staerke: CGFloat = 3

    @State private var dreht = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(Stil.akzent, style: StrokeStyle(lineWidth: staerke, lineCap: .round))
            .frame(width: groesse, height: groesse)
            .rotationEffect(.degrees(dreht ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: dreht)
            .background {
                Circle()
                    .stroke(Stil.akzent.opacity(0.18), lineWidth: staerke)
                    .frame(width: groesse, height: groesse)
            }
            .onAppear { dreht = true }
    }
}

/// Rundes Profilzeichen mit dem Anfangsbuchstaben.
struct Profilzeichen: View {
    let name: String
    var bild: URL?
    var groesse: CGFloat = 34
    var hervorgehoben = false

    var body: some View {
        grund
            .overlay {
                // Das Bild legt sich darüber. Fehlt es, bleibt der Buchstabe
                // stehen — Jellyfin antwortet dann schlicht mit 404.
                AsyncImage(url: bild) { stand in
                    if case let .success(b) = stand {
                        b.resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: groesse, height: groesse)
                .clipShape(Circle())
            }
            .overlay {
                Circle().strokeBorder(hervorgehoben ? Stil.akzent : Stil.rand,
                                      lineWidth: hervorgehoben ? 1.5 : 1)
            }
            .accessibilityElement()
            .accessibilityLabel("Profil von \(name)")
    }

    private var grund: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.173, green: 0.424, blue: 0.400),
                                          Color(red: 0.090, green: 0.251, blue: 0.239)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: groesse, height: groesse)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: groesse * 0.38, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
            }
    }
}
