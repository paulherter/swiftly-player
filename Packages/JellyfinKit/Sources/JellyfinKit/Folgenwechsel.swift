import Foundation

/// Der Wechsel zur nächsten Folge im laufenden Player — **ein** Ablauf für
/// alle Plattformen.
///
/// Er stand dreimal von Hand in den Apple-Playern (iOS, tvOS, macOS) und lief
/// dort auseinander (Audit 16.09.2026, Teil 1 H1, H3, M2, M4, M6): auf dem
/// Fernseher ohne Riegel, sodass ein zweiter Druck einen zweiten Wechsel
/// startete und am Server zwei Sitzungen offen blieben; überall ohne Abbruch,
/// sodass nach dem Schließen die nächste Folge unsichtbar mit Ton anlief.
///
/// **Was hier steht, ist die Reihenfolge, nicht die Darstellung.**
///
/// 1. Riegel: ein Wechsel zur Zeit. Ein zweiter Auslöser kommt mit
///    `.gesperrt` zurück und tut nichts.
/// 2. Alte Sitzung stoppen und neuen Plan holen — **nebeneinander**; bei
///    totem Netz ist das die längere der beiden Fristen, nicht ihre Summe.
///    Ab hier gilt `meldungenErlaubt == false`: die Taktschleife schweigt,
///    sonst ginge nach dem Stopp noch Fortschritt für die alte Folge hinaus.
/// 3. Kein Plan: `gescheitert` — die Plattform zeigt einen Hinweis, die alte
///    Folge läuft weiter und wird neu als gestartet gemeldet.
/// 4. Geschlossen, während 2 lief: `.abgebrochen`, und **nichts** wird
///    angewandt. Die Fläche ist dann schon abgeräumt; ein `play` darauf war
///    der Ton ohne Bild.
/// 5. `anwenden` setzt alle Folgen-Zustände der Plattform zurück und startet
///    den Strom, dann wird der Start gemeldet.
/// 6. Geschlossen, während der Start unterwegs war: der Stopp der neuen Folge
///    wird **nach** dem Start geschickt, nicht davor — sonst eröffnete der
///    späte Start die Sitzung neu, und sie bliebe offen.
///
/// Danach fällt der Riegel. Nächste Folge und Abschnitte kommen über
/// `nachschlagen` — ohne Riegel, damit keine Taste auf sie wartet.
///
/// **Isolation vom Aufrufer.** `ausfuehren` läuft auf dem Akteur, von dem es
/// gerufen wird (`#isolation`): auf Apple der Hauptakteur, sodass `anwenden`
/// und `schliessen` nie ineinander greifen. Android ruft über JNI ohne
/// Hauptwarteschlange; deshalb ist der Typ **nicht** an `@MainActor`
/// gebunden, und der Zustand liegt hinter einem Schloss.
public final class Folgenwechsel: @unchecked Sendable {

    public enum Phase: Equatable, Sendable {
        case ruht
        /// Alte Sitzung wird gestoppt, der neue Plan geholt.
        case stopptUndPlant
        /// Die neue Folge ist angewandt, ihr Start unterwegs.
        case startet
        /// Der Player ist zu. Endgültig.
        case geschlossen
    }

    public enum Ergebnis: Equatable, Sendable {
        case gewechselt
        /// Es lief schon ein Wechsel.
        case gesperrt
        /// Der Player wurde geschlossen.
        case abgebrochen
        /// Kein Plan für die neue Folge.
        case gescheitert
    }

    /// Was die Plattform beisteuert.
    ///
    /// Die Abrufe sind `@Sendable`: sie laufen nebeneinander. `anwenden` und
    /// `gescheitert` laufen auf dem Akteur des Aufrufers und dürfen dessen
    /// Zustand anfassen.
    public struct Schritte<Plan: Sendable> {
        /// Die alte Sitzung beenden. Die Stopp-Sperre sitzt dahinter
        /// (`Stoppsperre`), ein zweiter Stopp derselben Sitzung fällt dort weg.
        public var stoppen: @Sendable () async -> Void
        public var planen: @Sendable () async -> Plan?
        /// Titel und Plan setzen, Folgen-Zustände zurücksetzen, abspielen.
        public var anwenden: (Plan) -> Void
        public var starten: @Sendable (Plan) async -> Void
        public var gescheitert: () -> Void

        public init(stoppen: @escaping @Sendable () async -> Void,
                    planen: @escaping @Sendable () async -> Plan?,
                    anwenden: @escaping (Plan) -> Void,
                    starten: @escaping @Sendable (Plan) async -> Void,
                    gescheitert: @escaping () -> Void) {
            self.stoppen = stoppen
            self.planen = planen
            self.anwenden = anwenden
            self.starten = starten
            self.gescheitert = gescheitert
        }
    }

    private let schloss = NSLock()
    private var _phase: Phase = .ruht
    /// Zählt jeden begonnenen Wechsel — ein Nachschlag gilt nur für den
    /// Wechsel, nach dem er geholt wurde.
    private var _zaehler = 0
    private var aufgeschobenerStopp: (@Sendable () async -> Void)?

    public init() {}

    private func mitSchloss<T>(_ tun: () -> T) -> T {
        schloss.lock(); defer { schloss.unlock() }
        return tun()
    }

    public var phase: Phase { mitSchloss { _phase } }

    /// Der Riegel liegt.
    public var laeuft: Bool {
        mitSchloss { _phase == .stopptUndPlant || _phase == .startet }
    }

    /// Darf die Taktschleife Start und Fortschritt melden? Nur in Ruhe.
    public var meldungenErlaubt: Bool { mitSchloss { _phase == .ruht } }

    /// Der Wechsel.
    public func ausfuehren<Plan: Sendable>(
        _ schritte: Schritte<Plan>,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Ergebnis {
        let begonnen = mitSchloss { () -> Bool in
            guard _phase == .ruht else { return false }
            _phase = .stopptUndPlant
            _zaehler += 1
            return true
        }
        guard begonnen else { return .gesperrt }

        let stoppen = schritte.stoppen
        let planen = schritte.planen
        async let gestoppt: Void = stoppen()
        async let geplant = planen()
        // Stopp vor Start bleibt gewahrt: gestartet wird erst unten.
        await gestoppt
        let plan = await geplant

        let weiter = mitSchloss { () -> Bool? in
            guard _phase == .stopptUndPlant else { return nil }
            _phase = plan == nil ? .ruht : .startet
            return plan != nil
        }
        guard let weiter else { return .abgebrochen }
        guard weiter, let plan else {
            schritte.gescheitert()
            return .gescheitert
        }

        schritte.anwenden(plan)
        await schritte.starten(plan)

        let nachgeholt = mitSchloss { () -> (@Sendable () async -> Void)? in
            if _phase == .startet { _phase = .ruht }
            defer { aufgeschobenerStopp = nil }
            return aufgeschobenerStopp
        }
        if let nachgeholt {
            await nachgeholt()
            return .abgebrochen
        }
        return .gewechselt
    }

    /// Der Player geht zu. `stoppen` meldet das Ende dessen, was **jetzt**
    /// läuft — ist dessen Start noch unterwegs, erst danach.
    ///
    /// Nur der erste Aufruf zählt; ein zweiter (etwa aus `onDisappear` nach
    /// einem eigenen Schließen-Knopf) tut nichts.
    public func schliessen(stoppen: @escaping @Sendable () async -> Void) {
        let sofort = mitSchloss { () -> Bool? in
            let vorher = _phase
            guard vorher != .geschlossen else { return nil }
            _phase = .geschlossen
            if vorher == .startet {
                aufgeschobenerStopp = stoppen
                return false
            }
            return true
        }
        if sofort == true { Task { await stoppen() } }
    }

    /// Holt etwas zur laufenden Folge nach — nächste Folge, Abschnitte — und
    /// übernimmt es nur, wenn seither kein Wechsel begonnen hat und der Player
    /// offen ist. Sonst zeigte „Nächste Folge" kurz auf die Folge, die gerade
    /// läuft (Teil 1 M4).
    public func nachschlagen<Wert: Sendable>(
        holen: @Sendable () async -> Wert,
        uebernehmen: (Wert) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        let marke = mitSchloss { _zaehler }
        let wert = await holen()
        let gilt = mitSchloss { _zaehler == marke && _phase != .geschlossen }
        guard gilt else { return }
        uebernehmen(wert)
    }
}

/// Stopp-Sperre je PlaySession: `Sessions/Playing/Stopped` genau einmal.
///
/// Vorbild Streamyfin (Audit Teil 3, #13). Beim Folgenwechsel und beim
/// Schließen melden zwei Stellen dasselbe Ende; ohne Sperre kam es doppelt,
/// und ein Fortschritt danach eröffnete die Sitzung am Server neu.
///
/// - Ein Start gibt die Sitzung wieder frei.
/// - Ein gescheiterter Stopp gibt sie frei, damit ein späterer es noch
///   einmal versuchen kann.
/// - Nach dem Stopp wird Fortschritt verworfen.
public final class Stoppsperre: @unchecked Sendable {
    private let schloss = NSLock()
    private var gestoppt: Set<String> = []

    public init() {}

    /// Ohne PlaySession (von der Platte) steht der Titel für die Sitzung.
    public static func schluessel(itemID: String, playSessionID: String?) -> String {
        if let playSessionID { return "sitzung:" + playSessionID }
        return "titel:" + itemID
    }

    public func gestartet(_ schluessel: String) {
        schloss.lock(); defer { schloss.unlock() }
        gestoppt.remove(schluessel)
    }

    /// `true`: dieser Aufruf meldet den Stopp. `false`: schon gemeldet oder
    /// unterwegs — nichts schicken.
    public func stoppAnnehmen(_ schluessel: String) -> Bool {
        schloss.lock(); defer { schloss.unlock() }
        return gestoppt.insert(schluessel).inserted
    }

    public func stoppGescheitert(_ schluessel: String) {
        schloss.lock(); defer { schloss.unlock() }
        gestoppt.remove(schluessel)
    }

    public func fortschrittErlaubt(_ schluessel: String) -> Bool {
        schloss.lock(); defer { schloss.unlock() }
        return !gestoppt.contains(schluessel)
    }
}
