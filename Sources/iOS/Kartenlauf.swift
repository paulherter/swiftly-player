#if DEBUG
import JellyfinKit
import SwiftUI
import UIKit

/// **Selbsttest der Folgenkarte: liegt sie im sicheren Bereich?** Ohne
/// Server, ohne Finger — nur über das Protokoll.
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly -kartenlauf
///
/// Dreht ins Querformat, legt die Karte über das ganze Fenster und schreibt
/// ihren Rahmen neben die Ränder des sicheren Bereichs (`[Karte] Rahmen …`),
/// einmal ohne und einmal mit Steuerung.
@MainActor
enum Kartenlauf {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-kartenlauf") }

    private final class Stand: ObservableObject {
        @Published var steuerung = false
    }

    static func starten() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            Orientierung.shared.setzen(.landscapeRight)
            try? await Task.sleep(for: .seconds(2))
            guard let fenster = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            let stand = Stand()
            let folge = Item(id: "karte", name: "Redbird", type: "Episode",
                             runTimeTicks: 2_600 * 10_000_000, indexNumber: 11, parentIndexNumber: 6)
            let wurzel = UIHostingController(rootView: Buehne(stand: stand, folge: folge))
            wurzel.view.backgroundColor = .black
            wurzel.view.frame = fenster.bounds
            wurzel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            fenster.addSubview(wurzel.view)
            Protokoll.schreib("[Kartenlauf] Gerät \(UIDevice.current.model) · Fenster \(Int(fenster.bounds.width))×\(Int(fenster.bounds.height))")
            try? await Task.sleep(for: .seconds(2))
            stand.steuerung = true
            try? await Task.sleep(for: .seconds(2))
            Protokoll.schreib("[Kartenlauf] Ende")
        }
    }

    private struct Buehne: View {
        @ObservedObject var stand: Stand
        let folge: Item
        private var mass: Playermass { Playermass(pad: Stil.amPad, imFenster: false) }

        var body: some View {
            Folgenkartenansicht(folge: folge, bildAdresse: nil, pad: Stil.amPad,
                                seite: mass.seite, da: !stand.steuerung, zoom: 0, angabenDa: true,
                                bild: 1, fuellung: Fuellungsuhr(), rest: 5,
                                tippen: {}, abbrechen: {})
        }
    }
}
#endif
