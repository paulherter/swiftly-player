import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
import SwiftUI

// Der Grund der tvOS-Detailseiten nach ihrem Kulissenbild. Welche Toene ein
// Bild hat und wie daraus das Netz wird, steht geteilt in
// `Sources/Shared/Bildton.swift` — das iPhone malt seinen Grund aus derselben
// Rechnung. Hier steht nur, wie der Fernseher ihn unter die Seite legt.

/// Faerbt den Grund einer ganzen Seite nach ihrem Kulissenbild.
///
/// **An der Seite, nicht am Kopf.** Erst sass das im `Detailkopf`, und damit
/// endete die Faerbung an dessen Unterkante — darunter stand wieder reines
/// `#0B0B0D` und quer ueber dem Schirm eine Naht. Der Grund gehoert unter
/// alles, was die Seite zeigt, die Reihen eingeschlossen.
struct Bildgrund: ViewModifier {
    let url: URL?
    @State private var toene: [Double]

    /// **Der Anfangswert kommt aus dem Gedaechtnis, nicht aus dem Nichts.**
    ///
    /// Jede Seite legt ihren eigenen `Bildgrund` an — die Detailseite also
    /// einen neuen, wenn sie aufgeht. Stand der auf `[]`, zeichnete er zuerst
    /// den nackten Grund und fuellte sich erst im naechsten Durchgang. Genau
    /// das sah
    ///
    /// Das nachtraegliche Setzen ohne Animation kam dafuer zu spaet — der
    /// leere Durchgang hatte da schon stattgefunden. Ein Ton, der bekannt ist,
    /// muss deshalb **schon im ersten** Durchgang stehen.
    @MainActor init(url: URL?) {
        self.url = url
        _toene = State(initialValue: url.flatMap { Bildton.geteilt.gemerkt(fuer: $0) } ?? [])
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Bildton.netz(toene).ignoresSafeArea()

                    // Der letzte Rest gegen Baender — siehe `Bildton.rauschen`.
                    if !toene.isEmpty {
                        Bildton.rauschen
                            .resizable(resizingMode: .tile)
                            .opacity(0.008)
                            .ignoresSafeArea()
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(Stil.bewegung(.easeInOut(duration: 0.4)), value: toene)
            .task(id: url) {
                guard let url else { toene = []; return }

                // Schon bekannt? Dann steht es seit dem ersten Durchgang da
                // (siehe `init`) und hier ist nichts mehr zu tun. Ohne diese
                // Rueckkehr wuerde dieselbe Zuweisung eine Animation
                // ausloesen, obwohl sich der Wert gar nicht aendert.
                if let schonDa = Bildton.geteilt.gemerkt(fuer: url) {
                    if schonDa != toene {
                        var ohne = Transaction()
                        ohne.disablesAnimations = true
                        withTransaction(ohne) { toene = schonDa }
                    }
                    return
                }

                // Nur wirklich Neues wird uebergeblendet — etwa ein Titel,
                // den man ueber die Suche direkt oeffnet.
                toene = await Bildton.geteilt.toene(fuer: url)
            }
    }
}

extension View {
    func bildgrund(url: URL?) -> some View { modifier(Bildgrund(url: url)) }
}
