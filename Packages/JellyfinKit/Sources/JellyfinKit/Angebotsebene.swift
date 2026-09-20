import Foundation

/// Die Ebene über dem Bild, auf der „Intro überspringen" und „Nächste Folge"
/// von selbst erscheinen — ohne dass die Steuerung aufgeht.
///
/// Wunsch von Paul (16.09.2026, LISTE): wie bei Netflix. Vorbilder mit Quellen
/// in `Notizen/Audit/2026-09-16-teil3-vergleich.md`, Abschnitt 1.
///
/// **Neu gefasst nach Pauls Tests am iPhone (17.09.2026):**
///
/// - **Überspringen** (Intro, Rückblick …) steht, solange der Abschnitt
///   läuft — **egal, ob die Steuerung offen oder zu ist**; Öffnen und
///   Schließen lassen ihn stehen. Er geht nur, wenn der Abschnitt endet oder
///   er gedrückt wurde. (Eine Fassung davor schickte ihn nach Auf und Zu der
///   Steuerung weg; das wirkte, als gehe er mal mit der Steuerung und mal
///   nicht.)
/// - **Nächste Folge** als Karte gibt es nur mit Abspann-Abschnitt vom Server
///   (``Abschnittslogik/karteFaellig(position:dauer:abschnitte:hatNaechsteFolge:)``).
///   Sie bleibt stehen, die Füllung läuft ``countdown`` lang, und wenn sie
///   sichtbar voll ist, startet nach ``nachlauf`` die nächste Folge —
///   **immer**, unabhängig von „Nächste Folge automatisch" und von der
///   Kontovorgabe. Wer währenddessen die Steuerung **bewusst** öffnet, sagt
///   sie ab; dann steht nur der normale Knopf in der Steuerung. Ohne
///   Abspann-Abschnitt geht es nie von selbst weiter.
/// - **Zeigerbewegung ist kein Absagen** (Paul, 17.09.2026): Auf dem Mac,
///   unter Linux und Windows holt jede Mausbewegung die Steuerung. Geht sie
///   so auf (``Oeffnung/nebenbei``), bleibt die Karte an ihrer Stelle und
///   zählt weiter. Erst Klick ins Bild, eine Taste oder ein Knopf
///   (``Oeffnung/bewusst``) sagt sie ab.
///
/// *Welches* Angebot gilt, sagt ``Abschnittslogik``; Darstellung und Fokus
/// macht die Plattform. Die Zeit kommt als vergangene Sekunden je Takt
/// herein, nicht als Uhr — so lässt sich jeder Ablauf ohne Warten prüfen, und
/// eine Pause hält die Zeit von selbst an.
///
/// Der Knopf in der Steuerung bleibt davon unberührt: er zeigt weiter
/// ``Abschnittslogik/angebot(position:dauer:abschnitte:hatNaechsteFolge:)``.
public struct Angebotsebene: Sendable, Equatable {

    /// So lange läuft die Füllung der Karte „Nächste Folge" höchstens. Kürzer,
    /// wenn die Datei vorher endet (``Abschnittslogik/countdown(position:dauer:)``).
    /// Zehn Sekunden waren Paul zu lang (17.09.2026).
    public static let countdown: Double = 7

    /// Wie lange nach dem rechnerischen Ende der Füllung gewechselt wird.
    ///
    /// Die Plattformen ziehen die Füllung über einen Takt hinweg nach (eine
    /// halbe Sekunde), sichtbar voll ist sie also erst dann; danach noch
    /// 0,4 s Ruhe. Vorher wechselte die Folge, als der Balken noch nicht voll
    /// aussah.
    public static let nachlauf: Double = 0.5 + 0.4

    public enum Anzeige: Sendable, Equatable {
        case nichts
        case knopf(Knopfangebot)
        /// `anteil` läuft von 0 bis 1 — so weit ist der Countdown.
        case karte(anteil: Double)

        public var sichtbar: Bool { self != .nichts }
    }

    /// Wofür der gemerkte Zustand gilt. Wechselt es, fängt alles neu an.
    private enum Anlass: Sendable, Equatable {
        case keiner
        case ueberspringen(nach: Double)
        case naechsteFolge
    }

    private var anlass: Anlass = .keiner
    private var angebot: Knopfangebot = .keiner
    private var geschlossen = false
    private var gelaufen: Double = 0
    private var laenge: Double = Self.countdown
    private var ausgeloest = false
    private var steuerungOffen = false
    /// Offen, aber nur durch Zeigerbewegung — die Karte läuft dann weiter.
    private var nurNebenbei = false

    /// Wie die Steuerung aufging.
    public enum Oeffnung: Sendable, Equatable {
        /// Tippen, Klick ins Bild, Taste, Fernbedienung: sagt die Karte ab.
        case bewusst
        /// Zeigerbewegung (oder bloßer Abgleich mit dem Stand der Ansicht):
        /// sagt nichts ab und macht eine bewusst geöffnete Steuerung nicht
        /// wieder zu „nebenbei".
        case nebenbei
    }

    /// Die Steuerung verdeckt die Karte: offen, und nicht nur durch den Zeiger.
    private var steuerungDeckt: Bool { steuerungOffen && !nurNebenbei }

    /// Der Countdown wurde abgebrochen. Dann schaltet diese Folge auch am
    /// Dateiende nicht mehr von selbst weiter — wer den Abspann sehen wollte,
    /// soll nicht eine Sekunde vor Schluss doch herausgeworfen werden.
    public private(set) var weiterAbgesagt = false

    public init() {}

    /// Ein Takt. `true` heißt: jetzt zur nächsten Folge wechseln — genau
    /// einmal je Folge.
    ///
    /// **Auch direkt nach einem Sprung rufen, mit `vergangen: 0`.** Dann
    /// erscheint oder verschwindet der Knopf sofort mit der neuen Stelle und
    /// nicht erst im nächsten Takt.
    ///
    /// - Parameters:
    ///   - angebot: was ``Abschnittslogik`` gerade anbietet.
    ///   - karteFaellig: ``Abschnittslogik/karteFaellig(position:dauer:abschnitte:hatNaechsteFolge:)``.
    ///   - laeuft: im Stehen läuft kein Countdown.
    ///   - vergangen: Sekunden seit dem letzten Takt.
    ///   - countdown: wie lang die Füllung dauert, wenn die Karte jetzt
    ///     aufgeht — ``Abschnittslogik/countdown(position:dauer:)``.
    public mutating func takt(angebot neu: Knopfangebot, karteFaellig: Bool,
                              laeuft: Bool, vergangen: Double,
                              countdown: Double = Self.countdown) -> Bool {
        let neuerAnlass: Anlass
        switch neu {
        case let .ueberspringen(nach, _): neuerAnlass = .ueberspringen(nach: nach)
        case .naechsteFolge: neuerAnlass = karteFaellig ? .naechsteFolge : .keiner
        case .keiner: neuerAnlass = .keiner
        }
        if neuerAnlass != anlass {
            anlass = neuerAnlass
            gelaufen = 0
            laenge = max(countdown, 0.5)
            geschlossen = false
        }
        angebot = neu

        guard laeuft, vergangen > 0, anlass == .naechsteFolge, !geschlossen,
              !steuerungDeckt, !ausgeloest else { return false }
        gelaufen += vergangen
        if gelaufen >= laenge + Self.nachlauf {
            ausgeloest = true
            return true
        }
        return false
    }

    /// Die Steuerung geht auf oder zu. Sofort rufen, nicht erst im Takt.
    ///
    /// Bewusstes Auf sagt eine Karte „Nächste Folge" ab — auch, wenn die
    /// Steuerung vorher schon durch den Zeiger offen stand. Auf durch den
    /// Zeiger (`.nebenbei`) lässt sie laufen. Einen Überspringen-Knopf berührt
    /// beides nicht.
    public mutating func steuerung(offen: Bool, durch art: Oeffnung = .bewusst) {
        guard offen else {
            steuerungOffen = false
            nurNebenbei = false
            return
        }
        switch art {
        case .bewusst:
            guard !steuerungDeckt else { return }
            if anlass == .naechsteFolge { schliessen() }
            steuerungOffen = true
            nurNebenbei = false
        case .nebenbei:
            guard !steuerungOffen else { return }
            steuerungOffen = true
            nurNebenbei = true
        }
    }

    /// Was über dem Bild steht. Ein Überspringen-Knopf auch bei offener
    /// Steuerung; die Karte bei geschlossener oder nur durch den Zeiger
    /// geöffneter — bei bewusst offener steht dort der normale Knopf, und den
    /// zeigt die Plattform.
    public var anzeige: Anzeige {
        guard anlass != .keiner, !geschlossen, !ausgeloest else { return .nichts }
        if anlass == .naechsteFolge {
            guard !steuerungDeckt else { return .nichts }
            return .karte(anteil: min(gelaufen / laenge, 1))
        }
        return .knopf(angebot)
    }

    /// Wie lange die Füllung der gerade stehenden Karte läuft.
    public var countdownLaenge: Double { laenge }

    /// Sekunden bis zum Wechsel, für Vorlesen und Beschriftung.
    public var countdownRest: Int {
        Int((laenge - min(gelaufen, laenge)).rounded(.up))
    }

    /// Ob am Dateiende von selbst weitergeschaltet wird: nur mit Karte, und
    /// nur, wenn sie nicht abgesagt ist.
    public var weiterAmEnde: Bool {
        anlass == .naechsteFolge && !weiterAbgesagt
    }

    /// Zurück, oder der Fokus geht woanders hin: die Einblendung ist weg, bis
    /// ein neues Angebot kommt. Ein laufender Countdown ist damit abgesagt.
    ///
    /// - Returns: `true`, wenn etwas zu schließen war — dann hat Zurück hier
    ///   seine Arbeit getan und darf den Player nicht verlassen.
    @discardableResult
    public mutating func schliessen() -> Bool {
        guard anlass != .keiner, !geschlossen, !ausgeloest else { return false }
        if anlass == .naechsteFolge { weiterAbgesagt = true }
        geschlossen = true
        return true
    }

    /// Der Knopf wurde gedrückt. Die Einblendung geht, die Plattform führt aus.
    public mutating func gedrueckt() {
        geschlossen = true
    }

    /// Eine neue Folge läuft: alles vergessen, auch eine Absage. Nur ob die
    /// Steuerung offen ist, bleibt — die Ansicht bleibt ja dieselbe.
    public mutating func neueFolge() {
        let offen = steuerungOffen, nebenbei = nurNebenbei
        self = Angebotsebene()
        steuerungOffen = offen
        nurNebenbei = nebenbei
    }
}

/// **Die Füllung der Karte als durchgehende Bewegung** (Paul, 17.09.2026).
///
/// Die Ebene zählt im Takt; eine Füllung, die jeden Takt auf den neuen Wert
/// nachzieht, ruckelte am iPhone am Anfang und gegen Ende. Diese Uhr rechnet
/// den Anteil aus der Zeit seit dem letzten Start — die Plattform fragt sie
/// bei jedem Bild (`TimelineView`, Animationstakt). Im Stehen hält sie genau
/// dort an, wo sie gerade war, und läuft danach von dort weiter; sie springt
/// dabei nie zurück.
public struct Fuellungsuhr: Sendable, Equatable {
    private var basis: Double = 0
    private var seit: Date?
    private var laenge: Double = Angebotsebene.countdown

    public init() {}

    /// Im Takt und bei jeder Änderung rufen. `anteil` ist der Anteil der
    /// Ebene, `nil` heißt: keine Karte — dann steht die Uhr auf null.
    public mutating func stellen(anteil: Double?, laeuft: Bool, laenge: Double,
                                 jetzt: Date = Date()) {
        guard let anteil else { self = Fuellungsuhr(); return }
        self.laenge = max(laenge, 0.5)
        if laeuft {
            if seit == nil {
                basis = max(basis, anteil)
                seit = jetzt
            }
        } else if seit != nil {
            basis = self.anteil(jetzt: jetzt)
            seit = nil
        }
    }

    /// Der Anteil zu diesem Zeitpunkt, 0 bis 1.
    public func anteil(jetzt: Date = Date()) -> Double {
        let lauf = seit.map { max(jetzt.timeIntervalSince($0), 0) } ?? 0
        return min(basis + lauf / laenge, 1)
    }
}

/// Ob am Ende von selbst zur nächsten Folge gewechselt wird (T3 #15).
///
/// **Wer in Swiftly den Schalter umgelegt hat, behält seine Wahl.** Wer ihn nie
/// angefasst hat, bekommt die Einstellung seines Jellyfin-Kontos
/// (`EnableNextEpisodeAutoPlay`), so gilt sie auf allen Geräten gleich — wie in
/// Swiftfin. Weiß der Server nichts, bleibt es bei „an", der Vorgabe seit der
/// ersten Fassung.
public enum Weiterschalten {
    public static func gilt(eigeneWahl: Bool?, konto: Bool?) -> Bool {
        eigeneWahl ?? konto ?? true
    }
}

/// Was vom Jellyfin-Konto zählt — aus `GET /Users/{id}`, aus den Feldern
/// `Configuration` (was der Nutzer für sich eingestellt hat) und `Policy`
/// (was der Betreiber ihm erlaubt). **Zwei Blöcke, eine Anfrage:** die App
/// holt diese Antwort ohnehin bei jedem Start.
public struct Kontovorgaben: Sendable, Equatable, Decodable {
    public let naechsteFolgeAutomatisch: Bool?
    /// `Policy.EnableContentDownloading`. `nil`, wenn der Server nichts sagt —
    /// dann gilt ``Downloadrecht/unbekannt``, also erlaubt.
    public let downloadsErlaubt: Bool?
    /// `Policy.EnableVideoPlaybackTranscoding` — darf der Server für dieses
    /// Konto Video umwandeln? `nil`, wenn er nichts sagt.
    public let umwandelnErlaubt: Bool?

    public init(naechsteFolgeAutomatisch: Bool?, downloadsErlaubt: Bool? = nil,
                umwandelnErlaubt: Bool? = nil) {
        self.naechsteFolgeAutomatisch = naechsteFolgeAutomatisch
        self.downloadsErlaubt = downloadsErlaubt
        self.umwandelnErlaubt = umwandelnErlaubt
    }

    /// Die Entscheidung liegt im ``Downloadrecht``, nicht in einem `Bool?`,
    /// das jede Plattform anders auslegt.
    public var downloadrecht: Downloadrecht { .vomServer(downloadsErlaubt) }

    enum AussenSchluessel: String, CodingKey {
        case configuration = "Configuration"
        case policy = "Policy"
    }
    enum Schluessel: String, CodingKey { case naechste = "EnableNextEpisodeAutoPlay" }
    enum Rechteschluessel: String, CodingKey {
        case download = "EnableContentDownloading"
        case umwandeln = "EnableVideoPlaybackTranscoding"
    }

    public init(from decoder: any Decoder) throws {
        let aussen = try decoder.container(keyedBy: AussenSchluessel.self)
        // **Jeder Block für sich.** Vorher stieg der Dekodierer bei fehlendem
        // `Configuration` sofort aus; mit zwei Blöcken hätte das den Riegel
        // mitgenommen, obwohl `Policy` daneben stand.
        if aussen.contains(.configuration) {
            let c = try aussen.nestedContainer(keyedBy: Schluessel.self, forKey: .configuration)
            naechsteFolgeAutomatisch = try c.decodeIfPresent(Bool.self, forKey: .naechste)
        } else {
            naechsteFolgeAutomatisch = nil
        }
        if aussen.contains(.policy) {
            let p = try aussen.nestedContainer(keyedBy: Rechteschluessel.self, forKey: .policy)
            downloadsErlaubt = try p.decodeIfPresent(Bool.self, forKey: .download)
            umwandelnErlaubt = try p.decodeIfPresent(Bool.self, forKey: .umwandeln)
        } else {
            downloadsErlaubt = nil
            umwandelnErlaubt = nil
        }
    }
}
