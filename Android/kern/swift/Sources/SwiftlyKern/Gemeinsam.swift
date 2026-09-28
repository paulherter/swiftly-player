import Foundation
import JellyfinKit

// MARK: - Gemeinsam schauen: was der Kern fuer Kotlin bereithaelt
//
// Die Logik steht im Paket (`SyncPlaySitzung`). Hier liegt nur die Bruecke:
// der Player als `SyncPlaySpieler`, der seinen Stand aus dem Kotlin-Takt
// bekommt und seine Schritte in ein Fach legt, auf das Kotlin wartet; und die
// Lage als JSON. Die oeffentlichen Aufrufe stehen in `Kern.swift`
// („Gemeinsam schauen").

/// **Ein Fach, auf das genau ein Kotlin-Aufruf wartet.** Liegt etwas darin,
/// kommt der Aufruf sofort zurueck; sonst wartet er, bis etwas hineingelegt
/// wird — ohne Takt dazwischen. Die Schritte der Gruppe muessen zum Zeitpunkt
/// ausgefuehrt werden, den die Sitzung ausgerechnet hat, nicht beim naechsten
/// Takt.
///
/// Ein zweiter Wartender loest den ersten mit `""` ab: der erste gehoerte zu
/// einem Player, der schon zu ist.
final class Wartefach: @unchecked Sendable {
    private let sperre = NSLock()
    private var liegt: [String] = []
    private var wartet: CheckedContinuation<String, Never>?

    func legen(_ eintrag: String) {
        sperre.lock()
        if let w = wartet {
            wartet = nil
            sperre.unlock()
            w.resume(returning: eintrag)
            return
        }
        liegt.append(eintrag)
        if liegt.count > 50 { liegt.removeFirst() }
        sperre.unlock()
    }

    func holen() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            sperre.lock()
            if !liegt.isEmpty {
                let eintrag = liegt.removeFirst()
                sperre.unlock()
                c.resume(returning: eintrag)
                return
            }
            let alt = wartet
            wartet = c
            sperre.unlock()
            alt?.resume(returning: "")
        }
    }

    /// Alles verwerfen; wer wartet, bekommt `""` und hoert auf.
    func leeren() {
        sperre.lock()
        let w = wartet
        wartet = nil
        liegt = []
        sperre.unlock()
        w?.resume(returning: "")
    }
}

/// **Die Lage fuer Kotlin, mit Stand.** Jede Aenderung zaehlt den Stand hoch;
/// wer mit einem aelteren Stand fragt, bekommt sofort die jetzige Lage, sonst
/// wartet er auf die naechste. Mehrere duerfen warten (Telefon und Player).
final class Lagetafel: @unchecked Sendable {
    private let sperre = NSLock()
    private var stand = 0
    private var text = "{}"
    private var wartende: [CheckedContinuation<String, Never>] = []

    func setzen(_ neu: String) {
        sperre.lock()
        stand += 1
        text = neu
        let alle = wartende
        wartende = []
        let antwort = Self.antwort(stand, neu)
        sperre.unlock()
        for w in alle { w.resume(returning: antwort) }
    }

    func holen(nach: Int) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            sperre.lock()
            if stand > nach {
                let antwort = Self.antwort(stand, text)
                sperre.unlock()
                c.resume(returning: antwort)
                return
            }
            wartende.append(c)
            sperre.unlock()
        }
    }

    private static func antwort(_ stand: Int, _ lage: String) -> String {
        "{\"stand\":\(stand),\"lage\":\(lage)}"
    }
}

/// **Der Player, wie die Sitzung ihn sieht** — Gegenstueck zu
/// `Gemeinsamspieler` auf Apple.
///
/// Kotlin traegt im Anzeigetakt (250 ms) Titel, „bereit", Stelle und
/// Laufzustand ein. Dazwischen wird die Stelle mit der Uhr fortgeschrieben,
/// aber nur, solange sie sich zwischen zwei Takten wirklich bewegt hat —
/// puffert VLC, steht sie. Die Schritte (weiter, anhalten, springen, laden)
/// gehen in ein ``Wartefach``, das Kotlin sofort abarbeitet.
final class Kernspieler: SyncPlaySpieler, @unchecked Sendable {
    let marke: Int
    let schritte = Wartefach()
    private let sperre = NSLock()
    private var _titel: String
    private var _bereit = false
    private var _stelle = 0.0
    private var _bewegt = false
    private var _um = Date()
    /// Der Titel, auf den gerade gewechselt wird. Bis Kotlin ihn meldet, ist
    /// der Player nicht bereit — sonst ginge „bereit" fuer den alten hinaus.
    private var _erwartet: String?

    init(titel: String, marke: Int) {
        _titel = titel
        self.marke = marke
    }

    func takt(titel: String, bereit: Bool, stelle: Double, laeuft: Bool) {
        sperre.lock(); defer { sperre.unlock() }
        _bewegt = laeuft && abs(stelle - _stelle) > 0.01 && abs(stelle - _stelle) < 3
        _titel = titel
        _bereit = bereit
        _stelle = stelle
        _um = Date()
        if _erwartet == titel { _erwartet = nil }
    }

    /// Die Gruppe schaut etwas anderes — Kotlin wechselt im offenen Player.
    func laden(_ titel: String, ab: Double) {
        sperre.lock(); _erwartet = titel; _bereit = false; sperre.unlock()
        schritte.legen(Self.schritt(Schritt(art: "laden", wert: ab, titel: titel)))
    }

    func titel() async -> String {
        sperre.lock(); defer { sperre.unlock() }
        return _titel
    }

    func bereit() async -> Bool {
        sperre.lock(); defer { sperre.unlock() }
        return _bereit && _erwartet == nil
    }

    func stelle() async -> Double {
        sperre.lock(); defer { sperre.unlock() }
        guard _bewegt else { return _stelle }
        return _stelle + min(max(Date().timeIntervalSince(_um), 0), 0.5)
    }

    func weiter() async { schritte.legen(Self.schritt(Schritt(art: "weiter"))) }
    func anhalten() async { schritte.legen(Self.schritt(Schritt(art: "anhalten"))) }

    func springen(_ ziel: Double) async {
        // Die Stelle gleich nachziehen: die Sitzung misst ab hier, ob es laeuft.
        sperre.lock(); _stelle = ziel; _bewegt = false; _um = Date(); sperre.unlock()
        schritte.legen(Self.schritt(Schritt(art: "springen", wert: ziel)))
    }

    struct Schritt: Encodable {
        let art: String
        var wert: Double? = nil
        var titel: String? = nil
    }

    static func schritt(_ s: Schritt) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - Was Kotlin liest

struct Gruppenantwort: Encodable {
    let id, name: String
    /// Alle, wie der Server sie nennt — fuer die Spalte im Player.
    let teilnehmer: [String]
    /// Jeder Name einmal — fuer „Paul und Tom schauen gerade".
    let namen: [String]
    let zustand: String?

    init(_ g: SyncPlayGruppe, zustand: SyncPlayGruppe.Zustand? = nil) {
        id = g.id
        name = g.name
        teilnehmer = g.teilnehmer
        var gesehen = Set<String>()
        namen = g.teilnehmer.filter { gesehen.insert($0).inserted }
        self.zustand = Self.text(zustand ?? g.zustand)
    }

    static func text(_ z: SyncPlayGruppe.Zustand?) -> String? {
        switch z {
        case .laeuft: return "laeuft"
        case .angehalten: return "angehalten"
        case .wartet: return "wartet"
        case .leer, nil: return nil
        }
    }
}

struct Ereignisantwort: Encodable {
    let id: String
    /// Fuer das Zeichen — die Wahl liegt bei der Plattform.
    let art: String
    /// Fertig uebersetzt aus dem Paket.
    let text: String

    init(_ e: SyncPlayEreignis) {
        id = e.id.uuidString
        text = e.text
        switch e.art {
        case .dabei: art = "dabei"
        case .gegangen: art = "gegangen"
        case .wartetAufAlle: art = "wartet"
        case .angehalten: art = "angehalten"
        case .gehtWeiter: art = "weiter"
        case .gesprungen: art = "gesprungen"
        case .keinZugriff, .nichtAbspielbar: art = "warnung"
        }
    }
}

/// **Alles, was die Oberflaeche von der Gruppe zeigt** — ``SyncPlayLage`` als JSON,
/// dazu, wer ausser einem selbst dabei ist, und die letzte Fehlermeldung.
struct Gemeinsamantwort: Encodable {
    let darfAnlegen, darfBeitreten: Bool
    let angebote: [Gruppenantwort]
    let gruppe: Gruppenantwort?
    /// Ohne einen selbst, jeder Name einmal — fuer „mit Paul und Tom".
    let andere: [String]
    let ereignis: Ereignisantwort?
    let zuletztVerlassen: String?
    let arbeitet: Bool
    let schlangeTitel: String?
    let fehler: String?
    let fehlerNummer: Int
    /// Zaehlt hoch, sobald der Server ein Anlegen oder Beitreten angenommen hat — dann darf das Blatt zu.
    let angenommen: Int

    init(_ l: SyncPlayLage, ich: String?, fehler: String?, fehlerNummer: Int, angenommen: Int) {
        darfAnlegen = l.darfAnlegen
        darfBeitreten = l.darfBeitreten
        angebote = l.angebote.map { Gruppenantwort($0) }
        gruppe = l.gruppe.map { Gruppenantwort($0, zustand: l.zustand) }
        andere = l.gruppe?.andere(als: ich) ?? []
        ereignis = l.ereignis.map(Ereignisantwort.init)
        zuletztVerlassen = l.zuletztVerlassen?.name
        arbeitet = l.arbeitet
        schlangeTitel = l.schlangeTitel
        self.fehler = fehler
        self.fehlerNummer = fehlerNummer
        self.angenommen = angenommen
    }
}
