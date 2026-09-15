import Foundation

/// Regeln fuer Listen, die in eine Ansicht gehen.
///
/// **Warum das im Paket steht und nicht in der Ansicht.** Eine Liste mit
/// doppelter Kennung ist kein Schoenheitsfehler: `ForEach` ordnet seine
/// Zeilen ueber die Kennung zu, und bei zwei gleichen greift ein Tipp
/// daneben. Am 07.09.2026 gemeldet — auf „Zuletzt hinzugefuegt" oeffnete ein
/// Druck auf eine Serie die uebernaechste.
///
/// Die Bibliothek und die Merkliste haben die Regel je fuer sich gebaut, weil
/// der Server zwischen zwei Seiten etwas hinzufuegen kann. Die Startseite
/// hatte sie nicht — dort kommt jede Reihe aus einem einzigen Abruf, und die
/// Annahme war, ein Abruf liefere nichts doppelt. Ein Server mit
/// durcheinandergeratener Bibliothek tut genau das.
public enum Listenregeln {

    /// Jede Kennung genau einmal, in der Reihenfolge des ersten Auftretens.
    ///
    /// Die Reihenfolge ist der Punkt: der Server hat sie sortiert
    /// zurueckgegeben, und die spaetere Kopie ist der Nachzuegler, nicht das
    /// Original.
    public static func ohneDoppelte(_ items: [Item]) -> [Item] {
        var gesehen = Set<String>()
        return items.filter { gesehen.insert($0.id).inserted }
    }

    /// Dieselbe Regel fuer ein Anhaengen: was schon dasteht, kommt nicht noch
    /// einmal dazu.
    public static func anhaengen(_ neue: [Item], an bestehende: [Item]) -> [Item] {
        var gesehen = Set(bestehende.map(\.id))
        return bestehende + neue.filter { gesehen.insert($0.id).inserted }
    }

    // MARK: Nachladen

    /// Ob es hinter dem, was schon dasteht, noch etwas gibt.
    public static func nochMehrDa(geladen: Int, gesamt: Int) -> Bool {
        geladen < gesamt
    }

    /// **Ab welchem Eintrag nachgeladen wird: der drittletzten Reihe.**
    ///
    /// Der Nachschub soll stehen, bevor jemand unten ankommt. Zwei Reihen
    /// waeren beim schnellen Ziehen zu spaet, vier laedt zu frueh und holt
    /// Seiten, die niemand ansieht.
    ///
    /// `nil` heisst: es gibt nichts, woran der Ausloeser haengen koennte.
    ///
    /// **Warum das hier steht und nicht in der Ansicht.** Die Regel stand
    /// wortgleich in `Bibliotheksmodell` und in `Merklistenmodell` — von
    /// `doppelte-finden.sh` mit 100 Prozent gemeldet. Zwei Fassungen
    /// derselben Zahl laufen auseinander, sobald jemand eine davon anfasst,
    /// und der Unterschied waere nur einem aufgefallen, der beide Listen
    /// nebeneinander benutzt.
    ///
    /// **Jede Kachel der letzten drei Reihen löst aus, nicht genau eine.**
    /// Vorher hing das Nachladen am `onAppear` einer einzigen Kachel. Kam
    /// deren Auslöser ins Leere — die Liste war beim Zurückkommen von einer
    /// Detailseite gerade auf die erste Seite gekürzt worden, oder das
    /// Nachladen scheiterte —, erschien sie im `LazyVGrid` nicht noch einmal,
    /// solange sie im Bild blieb. Auf dem Apple TV blieb eine große Bibliothek
    /// damit nach etwa fünfzig Titeln stehen, bis man weit genug hoch- und
    /// wieder runtergescrollt hatte. Mehrfache Auslöser fängt `laedtNach` ab.
    public static func imNachladebereich(_ id: String, in items: [Item], spalten: Int) -> Bool {
        items.suffix(max(1, 3 * spalten)).contains { $0.id == id }
    }

    /// **Neu geladen wird die erste Seite — die weiteren bleiben stehen.**
    ///
    /// Eine Ansicht lädt bei jedem Erscheinen neu, also auch beim Zurückkommen
    /// von einer Detailseite. Ersetzte die erste Seite alles, standen danach
    /// wieder sechzig Titel da: wer beim hundertsten war, fand seinen Titel
    /// nicht mehr, der Fokus fiel woanders hin, und der Auslöser fürs
    /// Nachladen stand schon im Bild.
    ///
    /// Hat sich die Gesamtzahl geändert, ist etwas dazugekommen oder
    /// weggefallen, und hinten verschöbe sich alles — dann doch ersetzen.
    public static func auffrischen(_ erste: [Item], in bestehende: [Item],
                                   gesamtVorher: Int, gesamtJetzt: Int) -> [Item] {
        guard gesamtVorher == gesamtJetzt, bestehende.count > erste.count
        else { return ohneDoppelte(erste) }
        return anhaengen(Array(bestehende.dropFirst(erste.count)), an: ohneDoppelte(erste))
    }
}

public extension JellyfinClient {

    /// **Was zuletzt dazugekommen ist — eine Zeile je Serie.**
    ///
    /// **Nicht Jellyfins eigene Gruppierung.** `GroupItems=true` fasst zwar
    /// zusammen, liefert dabei aber so wenige Einträge, dass die Reihe fast
    /// leer aussieht: bei zwanzig angefragten Titeln blieben vier übrig. Also
    /// **ungruppiert und großzügig holen**, dann selbst zusammenfassen —
    /// eine Serie steht einmal da, mit ihrer neuesten Folge, ein Film für sich.
    ///
    /// Sechzig geholt, vierundzwanzig gezeigt: der Überhang deckt den Fall,
    /// dass eine einzelne Serie die halbe Antwort füllt.
    func zuletztHinzugefuegt(in bibliothek: String? = nil,
                             holen: Int = 60, zeigen: Int = 24) async -> [Item]? {
        guard let roh = try? await latest(parentID: bibliothek, limit: holen,
                                          gruppieren: false)
        else { return nil }
        var gesehen = Set<String>()
        var ergebnis: [Item] = []
        for eintrag in roh {
            // Filme haben keine Serie und stehen für sich.
            let schluessel = eintrag.seriesId ?? eintrag.id
            guard gesehen.insert(schluessel).inserted else { continue }
            ergebnis.append(eintrag)
            if ergebnis.count >= zeigen { break }
        }
        return ergebnis
    }
}
