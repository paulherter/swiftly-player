import Foundation

/// Wo man in einer Serie steht, und welche Staffel daraus folgt.
///
/// **Warum im Paket.** Beides stand in `AppModel` und erreichte Linux und
/// Windows damit nicht. Die Staffelwahl ist dabei keine Anzeigefrage, sondern
/// die Regel A10: welche Staffel dasteht, entscheidet der Weg auf die Seite.
/// Sie hat auf jeder Plattform dieselbe Antwort zu geben.
public extension JellyfinClient {

    /// Die Folge, bei der man in dieser Serie steht.
    ///
    /// Ist die Serie durch oder hat der Server nichts Offenes, gilt die erste
    /// Folge — sonst hätte die Seite keinen Anhaltspunkt.
    func standInSerie(_ seriesID: String) async -> Item? {
        // `try?` einer optionalen Rückgabe flacht Swift zu **einer** Ebene ab
        // — `offen` ist hier also schon ein `Item`, und ein zusätzliches
        // `offen != nil` wäre immer wahr.
        if let offen = try? await naechsteFolgeDerSerie(seriesID: seriesID) {
            return offen
        }
        return (try? await folgen(seriesID: seriesID))?.first
    }
}

/// **Welche Staffel beim Öffnen dasteht (A10).**
///
/// Kommt ein Hinweis mit — Kennung oder Nummer der Staffel, wie bei jedem Weg
/// von einer Folge aus —, gilt der. Kommt keiner, etwa aus der Bibliothek oder
/// aus der Suche, steht die **laufende** Staffel da, nicht Staffel 1: der
/// Hauptknopf sagt daneben „Weiterschauen S3E4", und eine Folgenliste, die
/// dazu Staffel 1 zeigt, widerspricht ihm auf demselben Schirm. Genau diese
/// Form hatte der Fehler schon einmal — oben „Abspielen S6E1", unten Staffel 5.
///
/// **Kennung *und* Nummer werden verglichen.** Am Gerät gemessen liefert der
/// Server an einer Folge nicht immer eine `SeasonId`; dann greift der
/// Kennungsvergleich ins Leere und nur die Nummer trägt noch.
public enum Staffelwahlregel {

    /// Reine Rechnung, ohne Abruf — damit der Aufrufer entscheidet, wann er
    /// den Stand holt, und ihn nebenher holen kann.
    ///
    /// - Parameters:
    ///   - liste: die Staffeln der Serie, in Serverreihenfolge.
    ///   - hinweisID: die Staffelkennung, über die man kam. `nil` ohne Hinweis.
    ///   - hinweisNummer: die Staffelnummer, über die man kam.
    ///   - stand: wo man in der Serie steht — nur nötig, wenn kein Hinweis kam.
    public static func waehle(aus liste: [Item],
                              hinweisID: String? = nil,
                              hinweisNummer: Int? = nil,
                              stand: Item? = nil) -> Item? {
        liste.first { $0.id == hinweisID }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == hinweisNummer }
            ?? liste.first { $0.id == stand?.seasonId }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == stand?.parentIndexNumber }
            ?? liste.first
    }

    /// Ob der Stand überhaupt geholt werden muss. Ohne Hinweis ja, sonst nein.
    public static func brauchtStand(hinweisID: String?, hinweisNummer: Int?) -> Bool {
        hinweisID == nil && hinweisNummer == nil
    }
}

public extension JellyfinClient {

    /// **Was der Kopf einer Seite zeigt, wenn es keinen Hintergrund gibt.**
    ///
    /// Bei einer Serie tritt das Standbild der nächsten Folge ein — das ist
    /// ein echtes Querbild und passt in die Kopfzone. Erst wenn auch das
    /// fehlt, kommt das Plakat quer beschnitten.
    ///
    /// **Warum nicht einfach das Plakat.** Ein hochkantes Plakat in eine
    /// 380 Punkt hohe Kopfzone geschnitten zeigt einen Ausschnitt aus der
    /// Bildmitte, auf dem meist nichts zu erkennen ist. Das Standbild einer
    /// Folge ist dafür gemacht.
    func kopfbildErsatz(fuer item: Item, adressen: Bildadresse,
                        breite: Int = 1200) async -> URL? {
        if item.type == "Series" {
            // Nicht mit `??` in einer Zeile: dessen rechte Seite ist eine
            // Autoclosure und darf nicht `await` enthalten.
            var folge = try? await naechsteFolgeDerSerie(seriesID: item.id)
            if folge == nil { folge = (try? await folgen(seriesID: item.id))?.first }
            if let folge, let url = Bildwahl.quer(folge, adressen: adressen,
                                                  breite: breite)?.url {
                return url
            }
        }
        return Bildwahl.hochkant(item, adressen: adressen, maxHoehe: breite)
    }
}

public extension JellyfinClient {

    /// **Das Kopfbild in zwei Größen — groß für die Kulisse, winzig für den
    /// Ton.**
    ///
    /// Beide müssen dasselbe Bild zeigen: der Ton wird aus dem winzigen
    /// Abbild gerechnet und färbt die Fläche, auf der das große liegt.
    ///
    /// **Warum es das gibt.** Linux holte das große über ``kopfbildErsatz``
    /// und das winzige daneben über `Bildwahl.quer` — bei einer Serie ohne
    /// Hintergrund gab das erste das Standbild der nächsten Folge und das
    /// zweite gar nichts. Ergebnis: Bild da, Ton nicht, und unter der Kulisse
    /// stand eine harte Kante gegen den blanken Grund. Genau die, die am
    /// 13.09.2026 gemeldet wurde — auf Serienseiten, während Filmseiten
    /// stimmten. Der Mac hat den Fall nicht, weil dort **eine** Adresse
    /// (`kopfbildURL`) beides bedient.
    ///
    /// Der zweite Grund für ein Paar statt zweier Aufrufe: die Suche nach dem
    /// Ersatz kostet einen Abruf. Zweimal gerufen, zweimal bezahlt.
    func kopfbildPaar(fuer item: Item, adressen: Bildadresse,
                      gross: Int = 1600,
                      klein: Int = 16) async -> (gross: URL, klein: URL)? {
        if let g = Bildwahl.quer(item, adressen: adressen, breite: gross)?.url,
           let k = Bildwahl.quer(item, adressen: adressen, breite: klein)?.url {
            return (g, k)
        }
        // Nicht mit `??` in einer Zeile: dessen rechte Seite ist eine
        // Autoclosure und darf kein `await` enthalten.
        if item.type == "Series" {
            var folge = try? await naechsteFolgeDerSerie(seriesID: item.id)
            if folge == nil { folge = (try? await folgen(seriesID: item.id))?.first }
            if let folge,
               let g = Bildwahl.quer(folge, adressen: adressen, breite: gross)?.url,
               let k = Bildwahl.quer(folge, adressen: adressen, breite: klein)?.url {
                return (g, k)
            }
        }
        // **Das Plakat der Sache selbst, nicht das der Folge.** Eine Folge
        // trägt als Plakat das der Serie — dasselbe Bild, ein Umweg mehr.
        guard let g = Bildwahl.hochkant(item, adressen: adressen, maxHoehe: gross),
              let k = Bildwahl.hochkant(item, adressen: adressen, maxHoehe: klein)
        else { return nil }
        return (g, k)
    }
}
