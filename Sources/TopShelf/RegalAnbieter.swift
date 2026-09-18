import TVServices

/// Füllt den Top Shelf auf dem Startbildschirm des Apple TV.
///
/// Bewusst ohne eigene Serveranfrage: die Erweiterung wird jedes Mal
/// aufgerufen, wenn der Fokus auf dem App-Zeichen landet, und hat dann
/// Sekundenbruchteile. Eine Anfrage über HTTPS wäre in dieser Zeit nicht
/// durch, und das Regal bliebe leer. Sie liest deshalb nur, was die App beim
/// letzten Öffnen der Startseite hinterlegt hat — siehe `Regalvorschau`.
final class RegalAnbieter: TVTopShelfContentProvider {

    /// Bewusst die Fassung mit Abschlussblock, nicht die mit `async`.
    ///
    /// `TVTopShelfContent` ist nicht `Sendable`, und unter Swift 6 darf ein
    /// solcher Wert nicht aus einer `async`-Überschreibung über die
    /// Aktorgrenze zurückgegeben werden. Der Abschlussblock kennt diese
    /// Grenze nicht — und gebraucht wird sie hier auch nicht: gelesen wird
    /// eine kleine Datei, das dauert nichts.
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let vorschau = Regal.lesen(), !vorschau.rubriken.isEmpty else {
            completionHandler(nil)
            return
        }

        let sammlungen = vorschau.rubriken.map { rubrik in
            let eintraege = rubrik.eintraege.map { eintrag -> TVTopShelfSectionedItem in
                let stueck = TVTopShelfSectionedItem(identifier: eintrag.id)
                stueck.title = eintrag.titel
                stueck.imageShape = rubrik.quer ? .hdtv : .poster
                if let bild = eintrag.bild {
                    stueck.setImageURL(bild, for: .screenScale1x)
                    stueck.setImageURL(bild, for: .screenScale2x)
                }
                if let anteil = eintrag.fortschritt {
                    stueck.playbackProgress = anteil
                }
                // Beide Wege führen in die App an dieselbe Stelle: der eine
                // beim Auswählen, der andere beim Drücken der Abspieltaste.
                let ziel = URL(string: "swiftly://titel/\(eintrag.id)")
                stueck.displayAction = ziel.map(TVTopShelfAction.init(url:))
                stueck.playAction = ziel.map(TVTopShelfAction.init(url:))
                return stueck
            }
            let sammlung = TVTopShelfItemCollection(items: eintraege)
            sammlung.title = rubrik.titel
            return sammlung
        }

        completionHandler(TVTopShelfSectionedContent(sections: sammlungen))
    }
}
