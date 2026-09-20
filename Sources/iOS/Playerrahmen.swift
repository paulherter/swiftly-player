import SwiftUI
import UIKit

/// **Der Player in einem eigenen UIKit-Rahmen — die App bleibt hochkant.**
///
/// Vorher hing der Player als `fullScreenCover` an der Seite, und die Drehung
/// lief über die Maske der ganzen Szene. Damit lag beim Schließen die App
/// dahinter quer und drehte sich erst danach zurück; wer die Drehung vorzog,
/// sah Drehen und Wegschieben gegeneinander ruckeln.
///
/// So machen es Netflix und Co.: Nur der Player-Controller erlaubt Querformat,
/// alles andere hochkant. Beim Zeigen und Schließen dreht UIKit **im selben
/// Übergang** — die App darunter wird nie quer angelegt.
///
/// Auf dem iPad bleibt es beim `fullScreenCover`: dort dreht alles frei.
final class Playerrahmen: UIHostingController<AnyView> {
    /// Der gerade gezeigte Rahmen — `PlayerScreen` schließt über ihn.
    private(set) static weak var aktiv: Playerrahmen?

    private var beendet: (() -> Void)?
    /// Ab dem Schließen darf auch hochkant: sonst hätten Player und App beim
    /// Übergang keine gemeinsame Lage, und UIKit dreht nicht mit.
    private var schliesst = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        schliesst ? .allButUpsideDown : Orientierung.shared.erlaubt
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        // Hält jemand das Telefon schon quer, in dieser Richtung aufgehen.
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return Orientierung.shared.erlaubt == .landscape ? .landscapeRight : .portrait
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    /// Zeigt den Player über dem obersten Controller.
    static func zeigen(_ inhalt: AnyView, querformatFest: Bool, beendet: @escaping () -> Void) {
        guard aktiv == nil,
              let szene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              var oben = szene.keyWindow?.rootViewController else { return }
        while let weiter = oben.presentedViewController { oben = weiter }

        // Erst die Maske öffnen, dann zeigen: UIKit fragt beim Übergang.
        Orientierung.shared.playerGeoeffnet(querformatFest: querformatFest, anfordern: false)
        let rahmen = Playerrahmen(rootView: inhalt)
        rahmen.beendet = beendet
        rahmen.modalPresentationStyle = .fullScreen
        // **Überblenden statt Schieben.** Geschoben wird im Koordinatensystem
        // des Players: rein kam er quer „von unten" — hochkant also von
        // links —, raus ging er hochkant nach unten. Rein und raus in zwei
        // Richtungen ergibt keinen Sinn; eine Blende hat keine Richtung.
        rahmen.modalTransitionStyle = .crossDissolve
        rahmen.overrideUserInterfaceStyle = .dark
        rahmen.view.backgroundColor = .black
        aktiv = rahmen
        oben.present(rahmen, animated: true)
    }

    /// Schließt den Player; die Drehung zurück läuft im selben Übergang.
    func schliessen() {
        guard !schliesst else { return }
        schliesst = true
        Orientierung.shared.playerGeschlossen(anfordern: false)
        dismiss(animated: true) { [beendet] in
            Playerrahmen.aktiv = nil
            beendet?()
        }
    }
}

extension View {
    /// Öffnet den Player — auf dem iPhone im eigenen Rahmen (`Playerrahmen`),
    /// auf dem iPad wie bisher als `fullScreenCover`.
    func playerCover<Inhalt: View>(item wunsch: Binding<Abspielwunsch?>,
                                   @ViewBuilder inhalt: @escaping (Abspielwunsch) -> Inhalt) -> some View {
        modifier(PlayerCover(wunsch: wunsch, inhalt: inhalt))
    }
}

private struct PlayerCover<Inhalt: View>: ViewModifier {
    @Binding var wunsch: Abspielwunsch?
    let inhalt: (Abspielwunsch) -> Inhalt
    @AppStorage("querformatFest") private var querformatFest = true

    func body(content: Content) -> some View {
        if Stil.amPad {
            content.fullScreenCover(item: $wunsch, content: inhalt)
        } else {
            content.onChange(of: wunsch?.id, initial: true) { _, id in
                if let offen = wunsch, id != nil {
                    Playerrahmen.zeigen(AnyView(inhalt(offen)), querformatFest: querformatFest) {
                        wunsch = nil
                    }
                } else {
                    Playerrahmen.aktiv?.schliessen()
                }
            }
        }
    }
}
