import Foundation

// MARK: - Was die Plattform anhängt

/// **Was der Player für „Gemeinsam schauen" hergibt.**
///
/// Jede Plattform hängt ihren Abspieler hier an — VLCKit auf Apple, libVLC
/// auf Linux und Windows, und auf Android der Kern, der die Schritte an
/// Kotlin weiterreicht. Die Sitzung liest **immer den jetzigen Stand**
/// (`titel`, `bereit`, `stelle`), statt ihn sich einmal geben zu lassen: ein
/// Abschluss, der eine SwiftUI-Ansicht fängt, liest ihren Stand von damals.
public protocol SyncPlaySpieler: AnyObject, Sendable {
    /// Welcher Titel gerade läuft (Jellyfin-ID).
    func titel() async -> String
    /// Steht das Bild, und wird gerade kein Titel gewechselt?
    func bereit() async -> Bool
    func stelle() async -> Double
    func weiter() async
    func anhalten() async
    /// Springt und zieht Zeitleiste und Knopf gleich nach.
    func springen(_ ziel: Double) async
}

/// Ein kurzer Hinweis oben im Player: wer kam, wer ging, warum der Film
/// steht. Der Text kommt aus dem Paket, das Zeichen wählt die Plattform.
public struct SyncPlayEreignis: Sendable, Equatable, Identifiable {
    public enum Art: Sendable, Equatable {
        case dabei(String)
        case gegangen(String)
        case wartetAufAlle
        case angehalten
        case gehtWeiter
        case gesprungen
        case keinZugriff
        case nichtAbspielbar
    }

    public let id: UUID
    public let art: Art

    public init(_ art: Art) {
        self.id = UUID()
        self.art = art
    }

    public var text: String {
        switch art {
        case let .dabei(name): return uebersetzt("\(name) ist dabei")
        case let .gegangen(name): return uebersetzt("\(name) ist gegangen")
        case .wartetAufAlle: return uebersetzt("Wartet auf alle")
        case .angehalten: return uebersetzt("Angehalten")
        case .gehtWeiter: return uebersetzt("Geht weiter")
        case .gesprungen: return uebersetzt("Gesprungen")
        case .keinZugriff: return uebersetzt("Einem in der Gruppe fehlt dieser Titel.")
        case .nichtAbspielbar: return uebersetzt("Der Titel der Gruppe lässt sich hier nicht abspielen.")
        }
    }
}

/// Was schiefging — als Meldung für die Ansicht.
public enum SyncPlayFehler: Error, Sendable {
    /// 403: der Betreiber hat es für dieses Konto nicht freigegeben.
    case nichtFreigegeben
    /// Aufgerufen, aber über den Steuerkanal kam nichts zurück.
    case keineAntwort
    case gibtEsNicht
    /// Die Leitung riss ab und der Wiedereintritt gelang nicht.
    case leitungVerloren
    case anderer(any Error & Sendable)

    public var text: String {
        switch self {
        case .nichtFreigegeben:
            return uebersetzt("Gemeinsam schauen ist für dein Konto auf dem Server nicht freigegeben.")
        case .keineAntwort:
            return uebersetzt("Die Gruppe kam nicht zustande: vom Server kam keine Antwort über die Verbindung. Versuch es gleich noch einmal.")
        case .gibtEsNicht:
            return uebersetzt("Diese Gruppe gibt es nicht mehr.")
        case .leitungVerloren:
            return uebersetzt("Die Verbindung zur Gruppe ist abgerissen und ließ sich nicht wiederherstellen. Tritt der Gruppe bitte erneut bei.")
        case let .anderer(fehler):
            return lesbarerFehler(fehler)
        }
    }

    static func aus(_ fehler: any Error) -> SyncPlayFehler {
        if case let JellyfinError.http(status, _) = fehler, status == 403 { return .nichtFreigegeben }
        return .anderer(fehler as? JellyfinError ?? JellyfinError.transport(String(describing: fehler)))
    }
}

/// **Alles, was die Oberfläche von der Gruppe zeigt** — auf jeder Plattform
/// dasselbe. Nach jeder Änderung kommt eine neue über ``SyncPlaySitzung/mitteilungen``.
public struct SyncPlayLage: Sendable, Equatable {
    /// `nil`, solange der Server nichts gesagt hat — dann entscheidet er
    /// beim Aufruf selbst.
    public var recht: SyncPlayRecht?
    /// Gruppen auf dem Server, in denen man nicht selbst ist.
    public var angebote: [SyncPlayGruppe] = []
    /// Die Gruppe, in der man ist.
    public var gruppe: SyncPlayGruppe?
    public var zustand: SyncPlayGruppe.Zustand?
    /// Drei Sekunden lang, dann wieder `nil`.
    public var ereignis: SyncPlayEreignis?
    /// Für den Streifen „… verlassen · Wieder beitreten", acht Sekunden lang.
    public var zuletztVerlassen: SyncPlayGruppe?
    /// Anlegen oder Beitreten läuft.
    public var arbeitet = false
    /// Was die Gruppe gerade schaut (Jellyfin-ID).
    public var schlangeTitel: String?

    public init() {}

    public var darfAnlegen: Bool { recht?.darfAnlegen ?? true }
    public var darfBeitreten: Bool { recht?.darfBeitreten ?? true }

    /// Gehört dieser Titel zu dem, was die Gruppe schaut?
    public func gehoertZurGruppe(_ titel: String) -> Bool {
        gruppe != nil && schlangeTitel == titel
    }
}

public enum SyncPlayMitteilung: Sendable {
    case lage(SyncPlayLage)
    case fehler(SyncPlayFehler)
}

// MARK: - Die Sitzung

/// **Gemeinsam schauen, auf jeder Plattform dieselbe Logik.**
///
/// Die Rechnung steht daneben (``SyncPlayAusfuehrung``, ``Zeitabgleich``,
/// ``Pufferwaechter``). Hier liegt der Ablauf: Gruppe anlegen, beitreten,
/// verlassen, die Uhr messen, die Warteschlange annehmen, Befehle zum
/// Zeitpunkt an den Player geben, Puffern und Bereitschaft melden.
///
/// Bis 25.09.2026 stand das im iOS-Ziel (`Gemeinsammodell`). Für Mac,
/// Fernseher, Android, Linux und Windows hätte jede Plattform es sonst
/// nachgebaut — und die Schleife vom 24.09. (Sprung zum Nachführen →
/// Puffern → alle halten an) hätte jede einzeln wiederentdeckt.
///
/// **Was die Plattform tut:** die Nachrichten des Steuerkanals hereinreichen
/// (``annehmen(_:)``), den Player anhängen (``anschliessen(_:)``), ihm den
/// Takt geben (``spielertakt()``), Bitten weiterreichen, und einen Titel
/// laden, wenn die Gruppe einen setzt (`titelLaden`: im offenen Player
/// wechseln, sonst den Player öffnen; `false`, wenn er sich hier nicht
/// abspielen lässt). Was sie zeigt, kommt als ``SyncPlayLage``.
public actor SyncPlaySitzung {

    public typealias Clientquelle = @Sendable () async -> JellyfinClient?
    public typealias Namensquelle = @Sendable () async -> String?
    public typealias Titellader = @Sendable (_ titel: String, _ ab: Double) async -> Bool

    public nonisolated let mitteilungen: AsyncStream<SyncPlayMitteilung>
    private let ausgang: AsyncStream<SyncPlayMitteilung>.Continuation

    private let clientQuelle: Clientquelle
    private let ichQuelle: Namensquelle
    private let titelLaden: Titellader

    public private(set) var lage = SyncPlayLage() {
        didSet { if lage != oldValue { ausgang.yield(.lage(lage)) } }
    }

    private var uhr: Task<Void, Never>?
    private var geplant: Task<Void, Never>?
    private var laden: Task<Void, Never>?
    private var ereignisUhr: Task<Void, Never>?
    private var verlassenUhr: Task<Void, Never>?

    public private(set) var abgleich = Zeitabgleich()
    private var schlange: SyncPlayWarteschlange?
    private var letzterBefehl: SyncPlayBefehl?
    private var puffer = Pufferwaechter()
    /// Hat der Player für den laufenden Eintrag „bereit" gemeldet? Vorher
    /// werden Befehle nur gemerkt.
    private var geladenFuer: String?
    private var geladenSeit = Date.distantPast
    private var letztesSprungziel: Double?
    /// Wann man selbst zuletzt um etwas gebeten hat — dann braucht es keinen
    /// Streifen, man weiß ja, warum der Film steht.
    private var zuletztGebeten = Date.distantPast

    private var spieler: (any SyncPlaySpieler)?
    private var befehlNummer = 0
    /// Die Gruppe, aus der die Leitung uns geworfen hat — bis der
    /// Wiedereintritt geklappt hat oder endgültig gescheitert ist.
    private var verlorenAus: SyncPlayGruppe?
    private var wiedereintritt: Task<Void, Never>?
    private var leitungsfrist: Task<Void, Never>?
    /// Wie lange nach einem Abriss auf die Neuverbindung gewartet wird, wie
    /// oft und wie lange auf den Beitritt. Für Tests kürzer.
    var geduld = (leitung: 60.0, versuche: 3, antwort: 5.0, pause: 2.0)
    func geduldSetzen(leitung: Double, versuche: Int, antwort: Double, pause: Double) {
        geduld = (leitung, versuche, antwort, pause)
    }
    private let eingang: AsyncStream<SyncPlayNachricht>.Continuation

    public init(client: @escaping Clientquelle, ich: @escaping Namensquelle,
                titelLaden: @escaping Titellader) {
        clientQuelle = client
        ichQuelle = ich
        self.titelLaden = titelLaden
        (mitteilungen, ausgang) = AsyncStream.makeStream(of: SyncPlayMitteilung.self)
        let (nachrichten, eingang) = AsyncStream.makeStream(of: SyncPlayNachricht.self)
        self.eingang = eingang
        // **Eine Schlange, eine Reihenfolge.** Der Steuerkanal ruft von
        // seinem eigenen Faden; ein `Task` je Nachricht käme in beliebiger
        // Reihenfolge an — und „beigetreten" nach der Warteschlange hieße,
        // dass der Titel nie lädt.
        Task { [weak self] in
            for await n in nachrichten { await self?.verarbeiten(n) }
        }
    }

    deinit {
        eingang.finish()
        ausgang.finish()
    }

    /// Läuft der Player gerade in der Gruppe?
    public var imPlayer: Bool { lage.gruppe != nil && spieler != nil }

    private func sag(_ text: String) { Spur.sag("[Gemeinsam] " + text) }

    private func fehler(_ f: SyncPlayFehler) {
        sag("Fehler: \(f)")
        ausgang.yield(.fehler(f))
    }

    // MARK: Anfang und Ende

    /// Das Recht des Kontos, einmal nach dem Anmelden.
    public func rechtHolen() async {
        guard let client = await clientQuelle() else { return }
        lage.recht = await client.syncPlayRecht()
    }

    /// Einmal nach Gruppen fragen. Im Takt der Plattform, und nicht, solange
    /// der Player läuft.
    public func angeboteFragen() async {
        guard lage.darfBeitreten, let client = await clientQuelle() else { return }
        do {
            let alle = try await client.syncPlayGruppen()
            lage.angebote = alle.filter { $0.id != lage.gruppe?.id }
        } catch {
            // Still nach außen, wie bei der Übernahme: gefragt wird im Takt.
            if !lage.angebote.isEmpty { sag("Abfrage fehlgeschlagen: \(error)") }
            lage.angebote = []
        }
    }

    /// Beim Abmelden und Kontowechsel: raus aus der Gruppe, alles vergessen.
    ///
    /// `alterClient` ist der Client des Kontos, von dem man weggeht. **Mit
    /// ihm wird verlassen**, nicht mit dem, den `client` inzwischen liefert —
    /// sonst ginge das `Leave` im Namen des neuen Kontos hinaus, und das alte
    /// stünde weiter in der Gruppe.
    public func beenden(alterClient: JellyfinClient? = nil) {
        if lage.gruppe != nil { verlassen(merken: false, mit: alterClient) }
        // **Auch die Uhren.** `verlassen` hält nur die Gruppe an; die
        // Streifen-Uhr und die Ereignis-Uhr liefen weiter, und das neue
        // Konto sah bis zu acht Sekunden „Wieder beitreten" zur Gruppe des
        // alten.
        uhr?.cancel(); uhr = nil
        verlassenUhr?.cancel(); verlassenUhr = nil
        ereignisUhr?.cancel(); ereignisUhr = nil
        lage.zuletztVerlassen = nil
        lage.ereignis = nil
        lage.angebote = []
        lage.recht = nil
    }

    // MARK: Anlegen, beitreten, verlassen

    /// Gruppe öffnen und gleich den Titel setzen. Alle, auch man selbst,
    /// bekommen daraufhin die Warteschlange und öffnen den Player angehalten.
    /// Ein leerer Name wird „Filmabend". `angenommen` kommt, sobald der
    /// Server ja gesagt hat — dann kann das Blatt zu, während noch auf den
    /// Steuerkanal gewartet wird.
    @discardableResult
    public func anlegen(name: String, titel: String,
                        angenommen: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard let client = await clientQuelle(), !lage.arbeitet else { return false }
        lage.arbeitet = true
        defer { lage.arbeitet = false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.syncPlayAnlegen(name: name.isEmpty ? uebersetzt("Filmabend") : name)
            try await client.syncPlayWarteschlange([titel], ab: 0)
            await angenommen?()
            sag("Gruppe angelegt fuer \(titel)")
            await kanalPruefen()
            return true
        } catch {
            fehler(.aus(error))
            return false
        }
    }

    @discardableResult
    public func beitreten(_ ziel: SyncPlayGruppe,
                          angenommen: (@Sendable () async -> Void)? = nil) async -> Bool {
        guard let client = await clientQuelle(), !lage.arbeitet else { return false }
        lage.arbeitet = true
        defer { lage.arbeitet = false }
        do {
            try await client.syncPlayBeitreten(ziel.id)
            await angenommen?()
            lage.zuletztVerlassen = nil
            lage.angebote.removeAll { $0.id == ziel.id }
            sag("beigetreten: \(ziel.id)")
            await kanalPruefen()
            return true
        } catch {
            fehler(.aus(error))
            return false
        }
    }

    /// **Kommt über den Kanal etwas an?** Alles Weitere — der Beitritt, die
    /// Warteschlange, jeder Befehl — läuft über den Steuerkanal. Steht der
    /// nicht, wäre man auf dem Server in einer Gruppe, und hier geschähe
    /// nichts. Dann lieber gleich wieder raus und es sagen.
    private func kanalPruefen() async {
        for _ in 0..<25 {
            if lage.gruppe != nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        sag("kein GroupJoined binnen 5 s — Kanal stumm?")
        try? await clientQuelle()?.syncPlayVerlassen()
        fehler(.keineAntwort)
    }

    /// Player schließen heißt: die Gruppe verlassen. Ohne Nachfrage — über
    /// den Streifen und das Abzeichen kommt man jederzeit wieder rein.
    public func verlassen(merken: Bool = true, mit client: JellyfinClient? = nil) {
        guard let alt = lage.gruppe else { return }
        let quelle: Clientquelle = if let client { { @Sendable in client } } else { clientQuelle }
        allesZuruecksetzen()
        if merken {
            lage.zuletztVerlassen = alt
            verlassenUhr?.cancel()
            verlassenUhr = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await self?.verlassenVergessen()
            }
        }
        Task {
            do { try await quelle()?.syncPlayVerlassen() }
            catch { Spur.sag("[Gemeinsam] Verlassen fehlgeschlagen: \(error)") }
        }
    }

    private func verlassenVergessen() { lage.zuletztVerlassen = nil }

    public func wiederBeitreten() async {
        guard let alt = lage.zuletztVerlassen else { return }
        lage.zuletztVerlassen = nil
        await beitreten(alt)
    }

    private func allesZuruecksetzen() {
        verlorenAus = nil
        wiedereintritt?.cancel(); wiedereintritt = nil
        leitungsfrist?.cancel(); leitungsfrist = nil
        lage.gruppe = nil
        lage.zustand = nil
        lage.schlangeTitel = nil
        schlange = nil
        letzterBefehl = nil
        geladenFuer = nil
        geplant?.cancel(); geplant = nil
        laden?.cancel(); laden = nil
        uhr?.cancel(); uhr = nil
        abgleich = Zeitabgleich()
        puffer.zuruecksetzen()
    }

    // MARK: Was vom Server kommt

    /// Jede SyncPlay-Nachricht des Steuerkanals. Von jedem Faden aus; sie
    /// werden in der Reihenfolge verarbeitet, in der sie hier ankommen.
    public nonisolated func annehmen(_ nachricht: SyncPlayNachricht) {
        eingang.yield(nachricht)
    }

    private func verarbeiten(_ nachricht: SyncPlayNachricht) async {
        switch nachricht {
        case let .beigetreten(g):
            let neu = lage.gruppe?.id != g.id
            lage.gruppe = g
            lage.zustand = g.zustand
            lage.angebote.removeAll { $0.id == g.id }
            if neu { uhrStarten() }
            if verlorenAus?.id == g.id { verlorenAus = nil }
        case .verlassen, .nichtInGruppe:
            if lage.gruppe != nil { allesZuruecksetzen() }
        case .gibtEsNicht:
            allesZuruecksetzen()
            fehler(.gibtEsNicht)
        case .keinZugriff:
            melden(.keinZugriff)
        case let .jemandKam(name):
            guard let g = lage.gruppe else { return }
            lage.gruppe = SyncPlayGruppe(id: g.id, name: g.name, zustand: lage.zustand,
                                         teilnehmer: g.teilnehmer + [name], stand: g.stand)
            if name != (await ichQuelle()) { melden(.dabei(name)) }
        case let .jemandGing(name):
            guard let g = lage.gruppe else { return }
            var liste = g.teilnehmer
            if let i = liste.firstIndex(of: name) { liste.remove(at: i) }
            lage.gruppe = SyncPlayGruppe(id: g.id, name: g.name, zustand: lage.zustand,
                                         teilnehmer: liste, stand: g.stand)
            if name != (await ichQuelle()) { melden(.gegangen(name)) }
        case .leitungVerloren:
            guard let g = lage.gruppe, verlorenAus == nil else { return }
            sag("Leitung verloren — merke Gruppe \(g.id)")
            verlorenAus = g
            // Kommt die Leitung nicht zurueck, nicht ewig still bleiben.
            let frist = geduld.leitung
            leitungsfrist?.cancel()
            leitungsfrist = Task { [weak self] in
                try? await Task.sleep(for: .seconds(frist))
                guard !Task.isCancelled else { return }
                await self?.wiedereintrittGescheitert("Leitung kam nicht zurück")
            }
        case .leitungWieder:
            guard let ziel = verlorenAus else { return }
            leitungsfrist?.cancel(); leitungsfrist = nil
            wiedereintritt?.cancel()
            wiedereintritt = Task { [weak self] in
                await self?.wiederEintreten(ziel)
            }
        case let .zustand(neu, grund):
            let vorher = lage.zustand
            lage.zustand = neu
            if neu == .wartet, vorher == .laeuft, grund == "Buffer" { melden(.wartetAufAlle) }
        case let .warteschlange(w):
            schlangeAnnehmen(w)
        case let .befehl(b):
            befehlAnnehmen(b)
        }
    }

    /// Nach der Neuverbindung zurueck in die Gruppe: `Join`, auf `GroupJoined`
    /// warten, dann Stand melden. Die Warteschlange, die der Server beim
    /// Beitritt schickt, gleicht Titel und Stelle ab (siehe
    /// ``schlangeAnnehmen(_:)``).
    private func wiederEintreten(_ ziel: SyncPlayGruppe) async {
        for versuch in 1...max(1, geduld.versuche) {
            guard !Task.isCancelled, verlorenAus != nil else { return }
            guard let client = await clientQuelle() else { break }
            do {
                try await client.syncPlayBeitreten(ziel.id)
            } catch {
                sag("Wiedereintritt \(versuch) fehlgeschlagen: \(error)")
                try? await Task.sleep(for: .seconds(geduld.pause))
                continue
            }
            let ende = Date().addingTimeInterval(geduld.antwort)
            while Date() < ende, verlorenAus != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if Task.isCancelled { return }
            if verlorenAus == nil {
                sag("wieder in der Gruppe \(ziel.id)")
                if spieler != nil, geladenFuer != nil {
                    await standMelden(bereit: true, laeuft: lage.zustand == .laeuft)
                }
                return
            }
        }
        if !Task.isCancelled { wiedereintrittGescheitert("kein Wiedereintritt") }
    }

    private func wiedereintrittGescheitert(_ grund: String) {
        guard verlorenAus != nil else { return }
        sag("Gruppe endgültig verloren: \(grund)")
        allesZuruecksetzen()
        fehler(.leitungVerloren)
    }

    private func melden(_ art: SyncPlayEreignis.Art) {
        lage.ereignis = SyncPlayEreignis(art)
        ereignisUhr?.cancel()
        ereignisUhr = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.ereignisVergessen()
        }
    }

    private func ereignisVergessen() { lage.ereignis = nil }

    private func schlangeAnnehmen(_ w: SyncPlayWarteschlange) {
        if let alt = schlange?.stand, let neu = w.stand, neu < alt { return }
        let vorher = schlange?.aktuell
        schlange = w
        lage.schlangeTitel = w.aktuell?.titel
        guard w.wechseltTitel, let aktuell = w.aktuell else { return }
        // Derselbe Eintrag, schon geladen: nichts zu tun.
        if aktuell == vorher, geladenFuer == aktuell.eintrag { return }
        geladenFuer = nil
        puffer.zuruecksetzen()

        // Wo die Gruppe jetzt steht — lieber nach dem letzten Befehl, der
        // kommt öfter als eine neue Warteschlange (wie jellyfin-web).
        var ab = w.startstelle
        if let b = letzterBefehl, let stelle = b.stelle, b.eintrag == aktuell.eintrag,
           (b.ausgesandt ?? b.wann) >= (w.stand ?? .distantPast) {
            ab = b.art == .weiter
                ? SyncPlayAusfuehrung.geschaetzteStelle(stelle: stelle, gueltigAb: b.wann,
                                                       jetzt: Date(), abgleich: abgleich)
                : stelle
        } else if w.laeuft, let stand = w.stand {
            ab = SyncPlayAusfuehrung.geschaetzteStelle(stelle: w.startstelle, gueltigAb: stand,
                                                       jetzt: Date(), abgleich: abgleich)
        }

        laden?.cancel()
        let lader = titelLaden
        laden = Task { [weak self] in
            guard let self else { return }
            await self.titelOeffnen(aktuell, ab: ab, grund: w.grund, lader: lader)
        }
    }

    private func titelOeffnen(_ aktuell: SyncPlayWarteschlange.Eintrag, ab: Double, grund: String,
                              lader: Titellader) async {
        sag("Warteschlange \(grund): \(aktuell.titel) ab \(Int(ab)) s")
        if let spieler, await spieler.titel() == aktuell.titel {
            await spieler.springen(ab)
        } else {
            // Im offenen Player wechseln oder ihn öffnen — das weiß die
            // Plattform. Bis der Player im nächsten Takt nachträgt, gilt der
            // alte Titel als nicht bereit; dafür sorgt sie selbst.
            guard await lader(aktuell.titel, ab) else {
                melden(.nichtAbspielbar)
                return
            }
        }
        guard !Task.isCancelled else { return }
        await aufLadenWarten(eintrag: aktuell.eintrag)
    }

    /// Bis der Player das Bild hat, dann anhalten und „bereit" melden. Der
    /// Server gibt das Weiter frei, sobald alle so weit sind.
    private func aufLadenWarten(eintrag: String) async {
        for _ in 0..<600 {   // höchstens zwei Minuten
            if Task.isCancelled { return }
            if let spieler, await spieler.bereit() {
                await spieler.anhalten()
                geladenFuer = eintrag
                geladenSeit = Date()
                await standMelden(bereit: true, laeuft: false)
                // Ein Befehl, der schon kam, als noch geladen wurde.
                if let b = letzterBefehl, b.eintrag == eintrag { befehlStarten(b) }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func befehlAnnehmen(_ b: SyncPlayBefehl) {
        guard lage.gruppe != nil else { return }
        letzterBefehl = b
        guard spieler != nil, geladenFuer != nil,
              b.eintrag == nil || b.eintrag == geladenFuer || b.art == .stopp else { return }
        befehlStarten(b)
    }

    /// **Ein Befehl löst den vorigen ab**, auch wenn der noch auf seinen
    /// Zeitpunkt wartet. Die Nummer fängt den Fall, dass der nächste kommt,
    /// während dieser noch die Stelle im Player erfragt.
    private func befehlStarten(_ b: SyncPlayBefehl) {
        befehlNummer += 1
        let nummer = befehlNummer
        geplant?.cancel()
        geplant = Task { [weak self] in await self?.ausfuehren(b, nummer: nummer) }
    }

    private func ausfuehren(_ b: SyncPlayBefehl, nummer: Int) async {
        guard let spieler else { return }
        let lokal = await spieler.stelle()
        guard nummer == befehlNummer, !Task.isCancelled else { return }
        let x = SyncPlayAusfuehrung.fuer(b, jetzt: Date(), abgleich: abgleich, lokaleStelle: lokal)
        sag("\(b.art.rawValue) bei \(Int(b.stelle ?? -1)) s · "
            + "in \(Int(x.warten * 1000)) ms · springen \(x.stelle.map { String(Int($0)) } ?? "—")")
        if Date().timeIntervalSince(zuletztGebeten) > 3, Date().timeIntervalSince(geladenSeit) > 3 {
            switch b.art {
            case .pause: melden(.angehalten)
            case .weiter: melden(.gehtWeiter)
            case .springen: melden(.gesprungen)
            case .stopp: break
            }
        }
        // Der Zeitpunkt steht fest, bevor gesprungen wird — der Sprung
        // kostet selbst Zeit.
        let bis = Date().addingTimeInterval(x.warten)
        if x.schritt == .weiter, x.warten > 0, let s = x.stelle { await spieler.springen(s) }
        let rest = bis.timeIntervalSinceNow
        if x.warten > 0, rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
        guard !Task.isCancelled else { return }
        await schrittTun(x, spieler: spieler)
    }

    private func schrittTun(_ x: SyncPlayAusfuehrung, spieler: any SyncPlaySpieler) async {
        let warPuffernd = puffer.puffert
        puffer.zuruecksetzen()
        switch x.schritt {
        case .weiter:
            if x.warten == 0, let s = x.stelle { await spieler.springen(s) }
            await spieler.weiter()
        case .pause:
            await spieler.anhalten()
            if let s = x.stelle { await spieler.springen(s) }
            // **Hatten wir „puffert" gemeldet, muss auch „bereit" kommen.**
            // Der Server hält die Gruppe an, bis es da ist — gemessen
            // wurde es aber nur an einer Stelle, die läuft. Angehalten
            // läuft keine, und die Gruppe wartete für immer.
            if warPuffernd {
                try? await Task.sleep(for: .milliseconds(500))
                await standMelden(bereit: true, laeuft: false)
            }
        case .springen:
            // **Wie jellyfin-web: springen, anspielen, bis das Bild
            // wirklich läuft, dann anhalten und erst jetzt „bereit".**
            //
            // Vorher: angehalten springen und nach höchstens fünf
            // Sekunden „bereit" mit VLCs Zeit. Im Stehen zieht VLC die
            // Zeit nach einem Sprung nicht verlässlich nach — die Meldung
            // trug oft noch die alte Stelle. Der Server prüft sie auf eine
            // halbe Sekunde genau (`WaitingGroupState`, „got lost in
            // time"), schickte uns den Sprung erneut, und die Gruppe blieb
            // in „Warten" hängen: hier stand der Film auf Pause, drüben
            // hielt er immer wieder an.
            if let s = x.stelle {
                await spieler.springen(s)
                await spieler.weiter()
                await bisEsLaeuft(bei: s, spieler: spieler)
                await spieler.anhalten()
                // Kommt derselbe Sprung ein zweites Mal, hat der Server
                // die gemessene Stelle schon einmal abgelehnt — dann das
                // Ziel, sonst drehte sich das im Kreis.
                let wiederholt = letztesSprungziel.map { abs($0 - s) < 0.01 } ?? false
                letztesSprungziel = s
                let meldung = wiederholt ? s
                    : SyncPlayAusfuehrung.bereitStelle(ziel: s, ist: await spieler.stelle())
                await standMelden(bereit: true, laeuft: false, stelle: meldung)
            } else {
                await spieler.anhalten()
                await standMelden(bereit: true, laeuft: false)
            }
        case .stopp:
            await spieler.anhalten()
        }
        // **Eine Zeile je ausgeführtem Schritt, mit der Uhrzeit auf die
        // Millisekunde.** Zwei Geräte derselben Gruppe lassen sich damit
        // nebeneinanderlegen: dieselbe Zeit, dieselbe Stelle — oder eben nicht.
        let hier = await spieler.stelle()
        let t = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        sag("ausgefuehrt \(x.schritt) bei \(String(format: "%.2f", hier)) s, t=\(t)")
    }

    // MARK: Aus dem Player

    /// Der Player ist offen und gehört zur Gruppe.
    public func anschliessen(_ s: any SyncPlaySpieler) {
        spieler = s
    }

    /// Der Player geht zu. **Das ist das Verlassen** (Entwurf A).
    public func abtrennen() {
        spieler = nil
        verlassen()
    }

    /// Anhalten und Weiter gehen als Bitte an den Server. Der Knopf springt
    /// erst um, wenn der Befehl zurückkommt — dann bei allen gleichzeitig.
    public func bitteUmschalten(laeuftGerade: Bool) async {
        guard let client = await clientQuelle() else { return }
        zuletztGebeten = Date()
        do {
            if laeuftGerade { try await client.syncPlayBittePause() }
            else { try await client.syncPlayBitteWeiter() }
        } catch { fehler(.aus(error)) }
    }

    public func bitteSpringen(auf sekunden: Double) async {
        guard let client = await clientQuelle() else { return }
        zuletztGebeten = Date()
        do { try await client.syncPlayBitteSpringen(auf: sekunden) }
        catch { fehler(.aus(error)) }
    }

    /// **Eine andere Folge, für alle.** In der Gruppe wechselt niemand
    /// allein — die Folgenwahl im Player setzt die Warteschlange neu, und
    /// jeder lädt sie, wie beim Anlegen.
    public func bitteTitel(_ titel: String, ab sekunden: Double = 0) async {
        guard let client = await clientQuelle() else { return }
        zuletztGebeten = Date()
        do { try await client.syncPlayWarteschlange([titel], ab: sekunden) }
        catch { fehler(.aus(error)) }
    }

    /// Einmal je Takt des Players: Puffern melden.
    public func spielertakt() async {
        guard let spieler, geladenFuer != nil, lage.gruppe != nil else { return }
        let stelle = await spieler.stelle()
        let jetzt = Date()
        let soll = letzterBefehl.map { $0.art == .weiter && abgleich.lokal($0.wann) <= jetzt } ?? false
        if let meldung = puffer.takt(stelle: stelle, sollLaufen: soll, jetzt: jetzt) {
            sag("\(meldung == .puffert ? "puffert" : "wieder bereit") bei \(Int(stelle)) s")
            await standMelden(bereit: meldung == .bereit, laeuft: true)
        }
        // **Kein Nachführen im Lauf** — wie jellyfin-web, das es von Haus
        // aus abgeschaltet hat (`enableSyncCorrection`). Es stand hier mit
        // einer Sekunde Grenze und war die zweite Hälfte der Schleife vom
        // 24.09.: der Sprung zum Nachführen ließ VLC puffern, das ging als
        // `Buffering` hinaus, der Server hielt alle an und gab sie wieder
        // frei, und die neue Schätzung lag wieder daneben. Abgeglichen wird
        // bei jedem Anhalten, Weiter und Sprung ohnehin.
    }

    /// Bis VLC an der Stelle wirklich spielt — die Zeit bewegt sich, nahe am
    /// Ziel. Höchstens zehn Sekunden.
    private func bisEsLaeuft(bei ziel: Double, spieler: any SyncPlaySpieler) async {
        var vorher = await spieler.stelle()
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            let jetzt = await spieler.stelle()
            if jetzt > vorher + 0.02, abs(jetzt - ziel) < 3 { return }
            vorher = jetzt
        }
        sag("nach dem Sprung auf \(Int(ziel)) s lief nach 10 s noch nichts")
    }

    private func standMelden(bereit: Bool, laeuft: Bool, stelle: Double? = nil) async {
        guard let client = await clientQuelle(), let spieler,
              let eintrag = geladenFuer ?? schlange?.aktuell?.eintrag else { return }
        let hier: Double
        if let stelle { hier = stelle } else { hier = await spieler.stelle() }
        do {
            try await client.syncPlayStand(bereit: bereit, wann: abgleich.server(Date()),
                                           stelle: hier, laeuft: laeuft, eintrag: eintrag)
        } catch {
            sag("\(bereit ? "Ready" : "Buffering") fehlgeschlagen: \(error)")
        }
    }

    // MARK: Uhr

    /// Dreimal im Sekundenabstand messen, danach jede Minute, und jedes Mal
    /// die Laufzeit an den Server — er braucht sie, um den Zeitpunkt für
    /// „Weiter" so zu legen, dass alle ihn erreichen.
    private func uhrStarten() {
        uhr?.cancel()
        uhr = Task { [weak self] in
            var anzahl = 0
            while !Task.isCancelled {
                guard let self else { return }
                anzahl = await self.einmalMessen(anzahl)
                try? await Task.sleep(for: .seconds(Zeitabgleich.pause(nachMessungen: anzahl)))
            }
        }
    }

    private func einmalMessen(_ anzahl: Int) async -> Int {
        guard let client = await clientQuelle() else { return anzahl }
        do {
            let m = try await client.serverzeitMessen()
            guard !Task.isCancelled else { return anzahl }
            abgleich.aufnehmen(m)
            let neu = anzahl + 1
            if neu == 1 || neu % 10 == 0 {
                sag("Uhr: Versatz \(Int(abgleich.versatz * 1000)) ms, Ping \(abgleich.pingMillisekunden) ms")
            }
            try? await client.syncPlayPing(millisekunden: abgleich.pingMillisekunden)
            return neu
        } catch {
            sag("Uhr nicht messbar: \(error)")
            return anzahl
        }
    }
}
