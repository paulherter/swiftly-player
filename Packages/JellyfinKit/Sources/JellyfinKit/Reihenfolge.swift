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
    public static func nachladenAb(_ items: [Item], spalten: Int) -> String? {
        guard !items.isEmpty else { return nil }
        return items[max(0, items.count - 3 * spalten)].id
    }
}
