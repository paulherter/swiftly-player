import JellyfinKit
import SwiftUI

/// Eine einzelne Bibliothek als eigene Seite.
///
/// **Fuer die Sammlungen neben Filme und Serien.** Die beiden Bereiche oben in
/// der Leiste zeigen je eine Bibliothek ihrer Gattung; alles Weitere —
/// „Filmabend", „Lieblingsfolgen", was der Server sonst noch fuehrt — steht
/// unter *Bibliotheken* und oeffnet sich hier, mit **seinem eigenen Namen**
/// ueber der Seite.
///
/// Vorher schalteten diese Zeilen den Filme-Bereich um. Das war zweimal
/// falsch: die Ueberschrift sagte danach „Filme", obwohl „Filmabend" gemeint
/// war, und der Bereich stand auf einer Sammlung, die man dort nie gewaehlt
/// hatte.
///
/// **Sie ist eine Wurzel, keine Seite.** Filme und Serien sind Wurzeln, also
/// ist das hier eine: kein Hereinfahren von rechts, kein Zurueckpfeil.
///
/// Das Regal gehoert der Ansicht. Bei den Bereichen liegt es aussen, weil die
/// Wurzel bei jedem Leistenwechsel weggeworfen wird — hier ist genau das
/// gewollt: eine andere Bibliothek ist ein anderes Regal.
struct Bibliotheksseite: View {
    let model: AppModel
    let bibliothek: Item

    @State private var regal = Bibliotheksmodell()
    @State private var gewaehlt: Item?

    var body: some View {
        BibliothekView(model: model,
                       art: bibliothek.collectionType ?? "movies",
                       titel: LocalizedStringKey(bibliothek.name),
                       regal: regal,
                       gewaehlt: $gewaehlt,
                       nurDiese: true)
            .onAppear { if gewaehlt == nil { gewaehlt = bibliothek } }
    }
}
