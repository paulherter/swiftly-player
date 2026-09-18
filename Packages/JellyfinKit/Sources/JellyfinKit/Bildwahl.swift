import Foundation

/// **Welches Bild eine Kachel zeigt — die Regel, einmal.**
///
/// Sie stand in `AppModel` und war damit für Linux unerreichbar: `AppModel`
/// ist SwiftUI. Hier liegt sie ohne Oberfläche und ohne Übersetzung, also
/// überall gleich und mit Tests belegbar — genau der Fall, für den in
/// `CLAUDE.md` steht, dass Logik ins Paket gehört.
///
/// Zwei Regeln, und beide haben eine Vorgeschichte.
public enum Bildwahl {

    /// Das quer liegende Bild einer „Weiterschauen"-Kachel.
    ///
    /// **Warum eine Kette und nicht eine Zeile.** Vorher stand hier der
    /// Hintergrund der Serie über den Index, ohne Marke. Hat die Serie
    /// keinen, antwortet Jellyfin mit 404 — und die Kachel blieb leer.
    ///
    /// Am Server nachgemessen: eine **Folge hat nie einen eigenen
    /// Hintergrund**, `BackdropImageTags` ist bei ihr immer leer. Der
    /// Hintergrund hängt an der Serie und kommt als
    /// `ParentBackdropImageTags` mit — ein Feld, das lange niemand gelesen hat.
    ///
    /// Jede Stufe wird nur genommen, wenn ihre **Marke** dasteht. Eine Marke
    /// ist Jellyfins Beweis, dass das Bild existiert; ohne sie raten wir und
    /// handeln uns 404 ein, die wie ein leeres Bild aussehen.
    ///
    /// Gibt neben der Adresse zurück, welche Stufe gegriffen hat — das steht
    /// im Protokoll, wenn eine Kachel doch einmal leer bleibt.
    public static func quer(_ item: Item, adressen: Bildadresse,
                            breite: Int = 600) -> (url: URL, quelle: String)? {
        let mass = Bildmass.hoechstensBreit(breite)

        func versuch(_ quelle: String, _ id: String?, _ art: Bildart,
                     _ marke: String?) -> (URL, String)? {
            guard let id, let marke,
                  let url = adressen.bauen(itemID: id, art: art, marke: marke, mass: mass)
            else { return nil }
            return (url, quelle)
        }

        let kette: [(URL, String)?] = [
            // 1 · Der Hintergrund der Serie — Pauls Wunsch, „eine Art Cover".
            versuch("Serienhintergrund",
                    item.parentBackdropItemId ?? item.seriesId,
                    .hintergrund, item.parentBackdropImageTags?.first),
            // 2 · Eigener Hintergrund. Bei Filmen der Normalfall.
            versuch("eigener Hintergrund", item.id, .hintergrund,
                    item.backdropImageTags?.first),
            // 3 · Das quer liegende Vorschaubild der Serie.
            versuch("Serienvorschau", item.parentThumbItemId ?? item.seriesId,
                    .vorschau, item.parentThumbImageTag),
            // 4 · Das eigene Vorschaubild.
            versuch("eigene Vorschau", item.id, .vorschau,
                    item.imageTags?["Thumb"]),
            // 5 · Das Standbild der Folge. Als Cover schwächer — deshalb
            //     zuletzt und nicht zuerst —, aber immer noch ein Bild.
            item.seriesId != nil
                ? versuch("Folgenstandbild", item.id, .poster,
                          item.imageTags?["Primary"])
                : nil,
        ]

        return kette.compactMap { $0 }.first.map { (url: $0.0, quelle: $0.1) }
    }

    /// Das hochkante Plakat einer 2 : 3-Kachel.
    ///
    /// **Bei einer Folge das Plakat der Serie.** Das eigene Bild einer Folge
    /// ist ein 16 : 9-Standbild und würde in einer 2 : 3-Kachel bis zur
    /// Unkenntlichkeit beschnitten.
    public static func hochkant(_ item: Item, adressen: Bildadresse,
                                maxHoehe: Int = 480) -> URL? {
        let quelle: (id: String, marke: String)?
        if let serie = item.seriesId, let marke = item.seriesPrimaryImageTag {
            quelle = (serie, marke)
        } else if let marke = item.imageTags?["Primary"] {
            quelle = (item.id, marke)
        } else {
            quelle = nil
        }
        guard let quelle else { return nil }
        return adressen.bauen(itemID: quelle.id, marke: quelle.marke,
                              mass: .hoechstensHoch(maxHoehe))
    }
}
