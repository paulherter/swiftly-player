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
    /// **Die Farbe ist ein Parameter, kein fester Wert.** Der Dateiauszug
    /// faerbt die Warnung orange, wenn der Server doch transkodiert — das ist
    /// die eine Stelle, an der eine Plakette nicht nur beschriftet, sondern
    /// alarmiert. Waere sie fest, haette tvOS beim Uebernehmen der geteilten
    /// Fassung genau diese Auskunft verloren.
    var farbe: Color = Stil.schriftLeise
    /// Getrennt von `farbe`: sonst haette das Einfaerben der Schrift den Rand
    /// mitgezogen und die Plakette auf dem iPhone sichtbar heller gemacht.
    var randfarbe: Color = Stil.rand
    /// Masse als Parameter: auf dem Fernseher sind die iPhone-Werte zu klein.
    /// So kommt jede Plattform ohne eigene Kopie aus.
    var innenWaagerecht: CGFloat = 5
    var innenSenkrecht: CGFloat = 2
    var rundung: CGFloat = 3
    var strichstaerke: CGFloat = 1

    var body: some View {
        Text(text)
            .font(Stil.plakette)
            .foregroundStyle(farbe)
            .padding(.horizontal, innenWaagerecht)
            .padding(.vertical, innenSenkrecht)
            .overlay(RoundedRectangle(cornerRadius: rundung)
                .strokeBorder(randfarbe, lineWidth: strichstaerke))
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
        ZStack {
            // Der Verlauf traegt immer: er steht hinter dem Bild und faellt
            // nicht auf, wenn eines da ist.
            grund

            // **Der Buchstabe ist Rueckfall, nicht Untergrund.** Frueher lag
            // er immer darunter und das Bild darueber — waehrend dessen
            // Aufblende schien er hindurch, und wer ein Profilbild hatte, sah
            // fuer einen Moment ein grosses „P" darin. Er gehoert deshalb in
            // den Zweig, in dem kein Bild ankommt.
            AsyncImage(url: bild) { stand in
                if case let .success(b) = stand {
                    b.resizable().aspectRatio(contentMode: .fill)
                } else {
                    buchstabe
                }
            }
        }
        .frame(width: groesse, height: groesse)
        .clipShape(Circle())
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
    }

    private var buchstabe: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: groesse * 0.38, weight: .semibold))
            .foregroundStyle(Stil.schrift)
    }
}
