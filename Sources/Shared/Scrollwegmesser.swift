import JellyfinKit
import SwiftUI

extension View {
    /// **Der Scrollweg unter einem zuklappenden Kopf**, fuer Bibliothek,
    /// Merkliste und Sammlungen. Die Rechnung und warum sie so ist, steht in
    /// `Kopfscrollweg` im Paket.
    ///
    /// `aktiv` haelt die Messung an, solange ein Bereichswechsel die Flaeche
    /// neu rechnet — dann ist sie nichts wert.
    func scrollweg(aktiv: Bool = true, _ setzen: @escaping (CGFloat) -> Void) -> some View {
        onScrollGeometryChange(for: CGPoint.self) {
            CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y)
        } action: { _, neu in
            guard aktiv, let weg = Kopfscrollweg.weg(rand: neu.x, versatz: neu.y) else { return }
            setzen(weg)
        }
    }
}
