import SwiftUI

// MARK: - Farbe aus dem Bild (Versuch, Zweig experiment-glas)

/// **Lädt die Töne eines Bildes und zeigt `inhalt`, sobald sie da sind.**
///
/// Die Töne kommen aus `Bildton` — dieselbe Rechnung wie auf dem Fernseher,
/// einmal je Bild, im Hintergrund, gemerkt. Sind sie schon gemerkt (Rückkehr
/// auf eine Seite), stehen sie im ersten Durchgang da — kein Aufblenden,
/// kein Aufblitzen. Neu gerechnet wird überblendet. Ein Bild ohne Farbe
/// (leere Töne) zeigt nichts: dann bleibt `grund`.
struct Stimmungslader<Inhalt: View>: View {
    let url: URL?
    let inhalt: ([Double]) -> Inhalt
    @State private var toene: [Double]

    init(url: URL?, @ViewBuilder inhalt: @escaping ([Double]) -> Inhalt) {
        self.url = url
        self.inhalt = inhalt
        _toene = State(initialValue: url.flatMap { Bildton.geteilt.gemerkt(fuer: $0) } ?? [])
    }

    /// Weich, ohne Nachschwingen — eine Farbe, die kommt, ist kein Knopf.
    private static var einblenden: Animation {
        Stil.bewegungReduziert ? Stil.blendeReduziert : .smooth(duration: 0.55)
    }

    var body: some View {
        ZStack {
            if !toene.isEmpty {
                inhalt(toene).transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { toene = []; return }
            if let schonDa = Bildton.geteilt.gemerkt(fuer: url) {
                if schonDa != toene { toene = schonDa }
                return
            }
            let neu = await Bildton.geteilt.toene(fuer: url)
            #if os(macOS)
            // Ein bildschirmhoher Verlauf, der einblendet, kostet die
            // hereinfahrende Seite Bilder — er kommt, wenn sie steht.
            await Einfahrt.abwarten()
            #endif
            guard !Task.isCancelled else { return }
            withAnimation(Self.einblenden) { toene = neu }
        }
    }
}

/// **Der Grund unter einer Detailseite in der Farbe ihres Kopfbilds** —
/// dasselbe Netz wie auf dem Fernseher (`Bildton.netz`): oben rechts, wo
/// die Kulisse sitzt, am kräftigsten, nach links unten dunkler.
///
/// Liegt als Hintergrund des Scrollinhalts, nicht fest hinter der Seite: so
/// steht die Farbe immer an derselben Stelle zum Kopfbild, und der Auslauf
/// des Kopfbilds (``Heldauslauf``) zeigt genau denselben Ausschnitt des
/// Netzes. Unter der Kante des Kopfbilds läuft die Farbe über `auslauf` in
/// `grund` aus — in OKLab, auf einer Glättkurve, mit dem Rauschen des
/// Fernsehers, damit weder ein Knick noch ein Band eine Kante zeichnet.
struct Stimmungsgrund: View {
    let url: URL?
    /// Höhe des Kopfbilds.
    let ab: CGFloat
    /// Über diese Höhe verteilt sich die Farbe wie auf dem Fernseher — so
    /// stand sie, als sie gefiel (Runde 3, Paul: „10/10").
    static let farbhoehe: CGFloat = 900
    /// **Lang**, damit beim Scrollen nirgends eine Grenze steht: die Farbe
    /// geht über 1300 Punkt in OKLab auf `grund` zurück
    /// (``Bildton/netz(_:hoehe:farbhoehe:ab:auslauf:)``), Helligkeit und
    /// Buntheit gemeinsam, und endet genau auf ihm.
    static let auslauf: CGFloat = 1300

    var body: some View {
        Stimmungslader(url: url) { toene in
            Self.netz(toene, ab: ab)
        }
        .frame(height: ab + Self.auslauf)
    }

    /// Das Netz über die ganze Höhe, mit dem Rauschen gegen Bänder.
    static func netz(_ toene: [Double], ab: CGFloat) -> some View {
        let gesamt = ab + auslauf
        return ZStack {
            Bildton.netz(toene, hoehe: Double(gesamt), farbhoehe: Double(ab + farbhoehe),
                         ab: Double(ab), auslauf: Double(auslauf))
            Bildton.rauschen
                .resizable(resizingMode: .tile)
                .opacity(0.008)
        }
        .frame(height: gesamt)
    }
}
