import JellyfinKit
import SwiftUI

// **Was iPhone und Fernseher an der Folgenkarte teilen** (``Folgenkarte``,
// Variante C): der festgehaltene Wechsel, der Rahmen zwischen Karte und
// ganzem Bild, der Countdown-Ring und der Verlauf unten rechts. Die Karte
// selbst zeichnet jede Plattform — Fokus und Maße sind verschieden.

/// Die Karte der nächsten Folge, solange sie ins Bild zoomt — beim Start
/// festgehalten, damit sie nicht mit dem Angebot verschwindet, das der
/// Wechsel wegnimmt.
struct Kartenwechsel: Equatable {
    let folgeID: String
    let beginn = Date()
    /// Seit wann (ab `beginn`) das erste Bild der neuen Folge steht.
    var bildSeit: Double?
    var seit: Double { Date().timeIntervalSince(beginn) }
}

/// **Form der Karte zwischen Karte und ganzem Bild**: Größe, Ecke, Schatten
/// — animierbar, damit die Feder den Zoom Bild für Bild aus dem jetzigen
/// Stand zieht. Sitzt am Inhalt des Knopfes, damit Druck und Fokus die ganze
/// Karte heben statt an ihrer Maske abzuschneiden.
struct Kartenform: ViewModifier, @MainActor Animatable {
    var zoom: Double
    let karte: CGRect
    let ganz: CGSize
    let ecke: CGFloat

    var animatableData: Double {
        get { zoom }
        set { zoom = newValue }
    }

    func body(content: Content) -> some View {
        let r = Folgenkarte.rahmen(karte: (karte.minX, karte.minY, karte.width, karte.height),
                                   ganz: (ganz.width, ganz.height), zoom: zoom)
        let rest = 1 - zoom
        content
            .frame(width: r.b, height: r.h)
            .clipShape(RoundedRectangle(cornerRadius: ecke * rest, style: .continuous))
            .shadow(color: .black.opacity(0.6 * rest), radius: 17 * rest, y: 14 * rest)
    }
}

/// **Lage der Karte** — über Abstände, nicht über `offset`: der Fokus auf
/// dem Fernseher und das Treffen am iPhone richten sich nach der Lage im
/// Aufbau.
struct Kartenlage: ViewModifier, @MainActor Animatable {
    var zoom: Double
    let karte: CGRect
    let ganz: CGSize

    var animatableData: Double {
        get { zoom }
        set { zoom = newValue }
    }

    func body(content: Content) -> some View {
        let r = Folgenkarte.rahmen(karte: (karte.minX, karte.minY, karte.width, karte.height),
                                   ganz: (ganz.width, ganz.height), zoom: zoom)
        content
            .padding(.leading, r.x)
            .padding(.top, r.y)
    }
}

/// Countdown-Ring mit Spielzeichen — die Füllung läuft durchgehend, nicht im
/// Takt (`Fuellungsuhr`). Maße im Verhältnis des Entwurfs (56er Raster).
struct Countdownring: View {
    let fuellung: Fuellungsuhr
    let durchmesser: CGFloat

    var body: some View {
        let d = durchmesser
        let strich = d * 3 / 56
        TimelineView(.animation) { zeit in
            let anteil = fuellung.anteil(jetzt: zeit.date)
            ZStack {
                Circle().fill(.black.opacity(0.5))
                Circle().inset(by: strich)
                    .stroke(Color.white.opacity(0.18), lineWidth: strich)
                Circle().inset(by: strich)
                    .trim(from: 0, to: anteil)
                    .stroke(Stil.akzent, style: StrokeStyle(lineWidth: strich, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "play.fill")
                    .font(.system(size: d * 0.3))
                    .foregroundStyle(Stil.schrift)
                    .offset(x: d * 0.03)
            }
            .frame(width: d, height: d)
        }
    }
}

/// Der dunkle Verlauf unten rechts, unter Karte und Zeilen — damit die
/// Schrift auf jedem Abspann lesbar bleibt.
struct Kartenschleier: View {
    var body: some View {
        EllipticalGradient(stops: [
            .init(color: .black.opacity(0.78), location: 0),
            .init(color: .clear, location: 0.7),
        ], center: UnitPoint(x: 0.88, y: 0.92), startRadiusFraction: 0, endRadiusFraction: 0.75)
        .ignoresSafeArea()
    }
}
