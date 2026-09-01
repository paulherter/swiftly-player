#if canImport(UIKit)
import UIKit

/// Die Ansichtsklasse der Plattform.
///
/// UIKit gibt es auf iPhone und Fernseher, auf dem Mac nicht. Statt
/// `VLCPlayerView` und `Zeichenflaeche` zweimal zu schreiben — und damit
/// genau die Doppelung anzulegen, gegen die dieses Projekt sonst antritt —,
/// hängen beide an diesem Namen.
///
/// Was sich zwischen den Bausätzen wirklich unterscheidet, ist überschaubar:
/// der Layout-Haken heißt anders, die Hintergrundfarbe sitzt bei AppKit auf
/// der Ebene statt auf der Ansicht, und die Autoresizing-Werte heißen anders.
/// Diese vier Stellen stehen als `#if` im Player, alles andere gilt wörtlich
/// für beide.
typealias Basisansicht = UIView

extension Basisansicht {
    /// „Wachse mit dem Elternteil mit" — heißt in beiden Bausätzen anders.
    static var mitwachsend: AutoresizingMask { [.flexibleWidth, .flexibleHeight] }
    static var ohneWunschmass: CGFloat { UIView.noIntrinsicMetric }
}
#else
import AppKit

/// Siehe die UIKit-Fassung oben — dieselbe Erklärung.
typealias Basisansicht = NSView

extension Basisansicht {
    static var mitwachsend: AutoresizingMask { [.width, .height] }
    static var ohneWunschmass: CGFloat { NSView.noIntrinsicMetric }
}
#endif
