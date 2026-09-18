import Lottie
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Die Startanimation: Dreieck fährt auf, dann fahren die Buchstaben aus.
///
/// Die Vorlage kommt als Lottie aus After Effects. Nachgebaut wird sie nicht —
/// jeder Keyframe trägt eigene Bezier-Anläufe, und die von Hand nachzurechnen
/// führt zu einer Bewegung, die *fast* stimmt. Das fällt mehr auf als ein
/// zusätzliches Paket.
/// **Zwei Arme, ein Ablauf.**
///
/// Der Mac hatte lange keinen — in `macOS/RootView` stand als Notiz, die
/// Animation brauche „eine Zeichenfläche, die heute nur als
/// `UIViewRepresentable` vorliegt". Das war richtig und ist jetzt behoben:
/// unten steht derselbe Ablauf noch einmal für AppKit.
///
/// **Warum nicht ein gemeinsamer Rumpf mit zwei Hüllen:** `makeUIView` und
/// `makeNSView` sind verschiedene Anforderungen zweier verschiedener
/// Protokolle, und die Ansichtsklassen darunter teilen keinen Vorfahren.
/// Ein Zwischenstück, das beide bedient, wäre länger als die zweite Fassung
/// und würde bei jeder Änderung an einer Seite mitgedacht werden müssen.
/// Die Bewegung selbst steckt ohnehin in der Vorlage, nicht im Code.
#if canImport(UIKit)
struct Startanimation: UIViewRepresentable {
    var nachlauf: TimeInterval = 0.5
    /// Spätestens dann geht es weiter, egal was die Animation macht.
    var spaetestens: TimeInterval = 3.5
    let fertig: () -> Void

    /// Hülle ohne eigenes Wunschmaß.
    ///
    /// `LottieAnimationView` meldet die Größe der Vorlage — hier 1024 × 1024 —
    /// als Wunschmaß, und ein `UIViewRepresentable` setzt sich damit über den
    /// Rahmen von SwiftUI hinweg. Ohne diese Hülle wächst die Animation über
    /// den ganzen Bildschirm hinaus.
    final class Huelle: UIView {
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
    }

    /// Sorgt dafür, dass `fertig` genau einmal gerufen wird — vom Abschluss
    /// der Animation oder von der Frist, je nachdem was zuerst kommt.
    final class Einmal {
        private var schonGerufen = false
        func ruf(_ tun: () -> Void) {
            guard !schonGerufen else { return }
            schonGerufen = true
            tun()
        }
    }

    func makeCoordinator() -> Einmal { Einmal() }

    func makeUIView(context: Context) -> Huelle {
        let huelle = Huelle()
        huelle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        huelle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        huelle.setContentHuggingPriority(.defaultLow, for: .vertical)
        huelle.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let ansicht = LottieAnimationView(name: "startanimation")
        ansicht.contentMode = .scaleAspectFit
        ansicht.loopMode = .playOnce
        // Weiterlaufen lassen, wenn der Bildschirm nicht in Bewegung ist —
        // sonst bleibt die Animation stehen, während im Hintergrund geladen
        // wird.
        ansicht.backgroundBehavior = .pauseAndRestore
        ansicht.translatesAutoresizingMaskIntoConstraints = false
        huelle.addSubview(ansicht)
        NSLayoutConstraint.activate([
            ansicht.topAnchor.constraint(equalTo: huelle.topAnchor),
            ansicht.bottomAnchor.constraint(equalTo: huelle.bottomAnchor),
            ansicht.leadingAnchor.constraint(equalTo: huelle.leadingAnchor),
            ansicht.trailingAnchor.constraint(equalTo: huelle.trailingAnchor),
        ])
        let einmal = context.coordinator
        let weiter = { DispatchQueue.main.asyncAfter(deadline: .now() + nachlauf) {
            einmal.ruf(fertig)
        } }

        // Ohne Vorlage gar nicht erst spielen.
        //
        // `LottieAnimationView(name:)` gibt auch dann eine Ansicht zurück, wenn
        // die Datei fehlt oder nicht gelesen werden kann — nur bleibt
        // `animation` dann nil, und `play(completion:)` ruft seinen Abschluss
        // **nie**. Der Vorhang läge für immer über der App.
        guard ansicht.animation != nil else {
            einmal.ruf(fertig)
            return huelle
        }

        ansicht.play { _ in
            // Das Standbild am Ende einen Moment stehen lassen, bevor die App
            // aufblendet — sonst wirkt die Marke nur durchgereicht.
            weiter()
        }

        // Zweiter Weg zum selben Ziel. Lottie ruft seinen Abschluss auch dann
        // nicht, wenn die Ansicht im Hintergrund pausiert wird und nicht mehr
        // anläuft. Eine Frist daneben kostet nichts und kann die App nicht
        // hängen lassen.
        DispatchQueue.main.asyncAfter(deadline: .now() + spaetestens) {
            einmal.ruf(fertig)
        }
        return huelle
    }

    func updateUIView(_ ansicht: Huelle, context: Context) {}
}

#else

/// Die AppKit-Fassung. Gleicher Ablauf, gleiche Fristen, gleiche Vorsicht:
/// ohne Vorlage gar nicht erst spielen, und eine Frist daneben, damit der
/// Vorhang nie liegenbleibt.
struct Startanimation: NSViewRepresentable {
    var nachlauf: TimeInterval = 0.5
    var spaetestens: TimeInterval = 3.5
    let fertig: () -> Void

    /// Wie auf iOS: ohne eigene Hülle setzt `LottieAnimationView` ihr
    /// Wunschmaß von 1024 × 1024 gegen den Rahmen von SwiftUI durch.
    final class Huelle: NSView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    final class Einmal {
        private var schonGerufen = false
        func ruf(_ tun: () -> Void) {
            guard !schonGerufen else { return }
            schonGerufen = true
            tun()
        }
    }

    func makeCoordinator() -> Einmal { Einmal() }

    func makeNSView(context: Context) -> Huelle {
        let huelle = Huelle()
        let ansicht = LottieAnimationView(name: "startanimation")
        ansicht.contentMode = .scaleAspectFit
        ansicht.loopMode = .playOnce
        ansicht.backgroundBehavior = .pauseAndRestore
        ansicht.translatesAutoresizingMaskIntoConstraints = false
        huelle.addSubview(ansicht)
        NSLayoutConstraint.activate([
            ansicht.topAnchor.constraint(equalTo: huelle.topAnchor),
            ansicht.bottomAnchor.constraint(equalTo: huelle.bottomAnchor),
            ansicht.leadingAnchor.constraint(equalTo: huelle.leadingAnchor),
            ansicht.trailingAnchor.constraint(equalTo: huelle.trailingAnchor),
        ])

        let einmal = context.coordinator
        let weiter = { DispatchQueue.main.asyncAfter(deadline: .now() + nachlauf) {
            einmal.ruf(fertig)
        } }

        guard ansicht.animation != nil else {
            einmal.ruf(fertig)
            return huelle
        }
        ansicht.play { _ in weiter() }
        DispatchQueue.main.asyncAfter(deadline: .now() + spaetestens) {
            einmal.ruf(fertig)
        }
        return huelle
    }

    func updateNSView(_ ansicht: Huelle, context: Context) {}
}
#endif

/// Der Vorhang beim Start: fester Grundton, darauf die Animation. Ist sie
/// durch, blendet die App darunter auf.
struct Startvorhang: View {
    let fertig: () -> Void

    private var kante: CGFloat {
        #if os(tvOS)
        900
        #elseif os(macOS)
        // Das Fenster ist kleiner als ein Fernseher und größer als ein
        // Telefon; 520 sitzt zwischen beiden.
        520
        #else
        440
        #endif
    }

    var body: some View {
        // Der Stapel selbst muss den sicheren Bereich ignorieren, nicht nur
        // die Farbe darin: sonst liegt seine Mitte 12 Punkt zu tief, weil oben
        // 59 Punkt freigehalten werden und unten nur 34.
        ZStack {
            Stil.grund
            Startanimation(fertig: fertig)
                // Die Vorlage ist quadratisch, die Wortmarke steht darin
                // mittig und füllt nur den mittleren Streifen — das Quadrat
                // muss also deutlich größer sein als die Marke wirken soll.
                //
                // Auf dem Fernseher entsprechend mehr: 440 Punkt sind auf
                // 1920 × 1080 eine Briefmarke.
                .frame(width: kante, height: kante)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}
