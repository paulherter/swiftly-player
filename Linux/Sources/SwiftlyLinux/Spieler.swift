import CGtk
import Foundation
import JellyfinKit

/// Der Player. Noch nicht gebaut — hier steht vorerst nur der Weg hinein,
/// damit die Detailseiten schon die richtigen Wege nehmen (A1, A4, A5).
extension App {
    func spielerOeffnen(_ item: Item, ab: Double) {
        FileHandle.standardError.write(
            Data("[Spieler] \(item.name) ab \(Int(ab)) s — noch nicht gebaut\n".utf8))
    }
}
