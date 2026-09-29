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
    /// Wie oft UIKit je Druck gebeten wurde — ein Deckel, keine Schleife.
    private var versuche = 0

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        schliesst ? .allButUpsideDown : Orientierung.shared.erlaubt
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        // Hält jemand das Telefon schon quer, in dieser Richtung aufgehen.
        // Aus einer Übergabe: hochkant, bis die Karte weg ist.
        if Orientierung.shared.uebergabeHaelt { return .portrait }
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return Orientierung.shared.erlaubt == .landscape ? .landscapeRight : .portrait
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    /// Zeigt den Player über dem obersten Controller.
    /// - Parameter ruhig: ohne Überblenden — aus einer Übergabe, wo der
    ///   Player unter der Karte aufgeht und erst mit ihrem Zoom zu sehen ist.
    static func zeigen(_ inhalt: AnyView, querformatFest: Bool, ruhig: Bool = false,
                       beendet: @escaping () -> Void) {
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
        oben.present(rahmen, animated: !ruhig)
    }

    /// Schließt den Player; die Drehung zurück läuft im selben Übergang.
    ///
    /// **Jeder Aufruf führt zum Ziel, nicht nur der erste.** Vorher legte der
    /// erste Aufruf einen Riegel und bat UIKit einmal um das Wegnehmen. Lief
    /// in dem Moment noch ein Übergang, verwirft UIKit die Bitte still, ohne
    /// Abschluss — der Riegel blieb liegen, und jedes weitere „Schließen"
    /// prallte an ihm ab. Jetzt wartet die Bitte das Ende eines laufenden
    /// Übergangs ab und gilt als erledigt erst, wenn der Rahmen wirklich weg
    /// ist.
    func schliessen() {
        Protokoll.schreib("[Rahmen] Schließen · schon dabei \(schliesst) · Übergang \(transitionCoordinator != nil)")
        if !schliesst {
            schliesst = true
            Orientierung.shared.playerGeschlossen(anfordern: false)
        }
        versuche = 0
        wegnehmen()
    }

    /// Über den, der den Rahmen zeigt: das nimmt ihn samt allem, was er
    /// selbst zeigt. Auf dem Rahmen selbst hätte `dismiss` nur das
    /// Obenliegende genommen, und der Player wäre stehen geblieben.
    private func wegnehmen() {
        guard let darunter = presentingViewController else { fertig(); return }
        if let laufend = transitionCoordinator ?? darunter.transitionCoordinator {
            laufend.animate(alongsideTransition: nil) { [weak self] _ in self?.wegnehmen() }
            return
        }
        guard versuche < 3 else {
            Protokoll.schreib("[Rahmen] nach \(versuche) Versuchen noch da")
            return
        }
        versuche += 1
        darunter.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            // Zu, wenn niemand ihn mehr zeigt — sonst noch einmal.
            if self.presentingViewController == nil { self.fertig() } else { self.wegnehmen() }
        }
    }

    private func fertig() {
        guard let beendet else { return }
        self.beendet = nil
        if Playerrahmen.aktiv === self { Playerrahmen.aktiv = nil }
        beendet()
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
                    Playerrahmen.zeigen(AnyView(inhalt(offen)), querformatFest: querformatFest,
                                        ruhig: Uebergabebuehne.geteilt.aktiv) {
                        wunsch = nil
                    }
                } else {
                    Playerrahmen.aktiv?.schliessen()
                }
            }
        }
    }
}
