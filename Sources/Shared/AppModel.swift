import Foundation
import OSLog
import JellyfinKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case disconnected
        case connecting
        case needsLogin(serverName: String, version: String)
        case ready
    }

    var phase: Phase = .disconnected
    var errorMessage: String?
    var views: [Item] = []
    /// Für die Kopfzeile im Profilmenü.
    var serverName: String?

    // MARK: Einstellungen

    /// Nie umwandeln lassen. Der Grund für diese App — deshalb Vorgabe an.
    var immerDirectPlay: Bool { didSet { merken(immerDirectPlay, "immerDirectPlay") } }
    /// Obergrenze in Mbit/s, 0 heißt unbegrenzt. Greift nur, wenn Direct Play
    /// nicht erzwungen wird.
    var bitratenGrenze: Int { didSet { merken(bitratenGrenze, "bitratenGrenze") } }
    var querformatFest: Bool { didSet { merken(querformatFest, "querformatFest") } }
    var fortschrittAufKacheln: Bool { didSet { merken(fortschrittAufKacheln, "fortschritt") } }

    /// Leer heißt: nehmen, was der Server vorgibt.
    var tonSprache: String { didSet { merken(tonSprache, "tonSprache") } }
    var untertitelSprache: String { didSet { merken(untertitelSprache, "utSprache") } }
    /// Untertitel nur einschalten, wenn der Ton nicht in der gewünschten
    /// Sprache läuft.
    var untertitelAutomatisch: Bool { didSet { merken(untertitelAutomatisch, "utAuto") } }
    var naechsteAutomatisch: Bool { didSet { merken(naechsteAutomatisch, "naechsteAuto") } }

    /// „Zuletzt hinzugefügt" getrennt nach Filmen und Serien.
    ///
    /// **Vorgabe aus, damit sich für niemanden etwas ändert.** Eine Reihe mit
    /// allem ist der Stand seit der ersten Fassung; wer sie getrennt will,
    /// schaltet um. Ausdrücklich `false` beim ersten Start — `UserDefaults`
    /// gibt für einen unbekannten Schlüssel ohnehin `false`, aber das hier
    /// steht als Absicht da, nicht als Zufall.
    var neuzugangGetrennt: Bool { didSet { merken(neuzugangGetrennt, "neuGetrennt") } }
    var zurueckSekunden: Int { didSet { merken(zurueckSekunden, "zurueckSek") } }
    var vorSekunden: Int { didSet { merken(vorSekunden, "vorSek") } }


    private func merken(_ wert: Any, _ name: String) {
        UserDefaults.standard.set(wert, forKey: name)
    }

    // MARK: - Mehrere Bibliotheken derselben Gattung

    /// Alle Bibliotheken einer Gattung, in der Reihenfolge des Servers.
    ///
    /// **Ein Server kann mehrere Filmbibliotheken haben** — aus dem
    /// TestFlight: eine auf einer externen Platte, eine lokale. Der Reiter
    /// „Filme" nahm bis dahin `views.first` und zeigte damit nur die erste;
    /// die zweite war in der App nicht erreichbar. Aufgefallen ist es nie,
    /// weil unser Prüfserver genau eine hat.
    ///
    /// Suche, „Weiterschauen" und „Zuletzt hinzugefügt" gehen ohne
    /// `ParentId` an den Server und sahen deshalb immer alles — nur das
    /// Durchblättern war halbiert.
    func bibliotheken(art: String) -> [Item] {
        views.filter { $0.collectionType == art }
    }

    /// Welche Bibliothek zuletzt gewählt war — je Gattung gemerkt.
    ///
    /// Über die Kennung und nicht über den Platz in der Liste: der Server
    /// darf umsortieren, und dann zeigte „Filme" plötzlich die andere
    /// Sammlung. Ist die gemerkte Bibliothek verschwunden, fällt die Wahl
    /// still auf die erste zurück.
    func gewaehlteBibliothek(art: String) -> Item? {
        let vorhanden = bibliotheken(art: art)
        if let kennung = UserDefaults.standard.string(forKey: Self.bibliotheksname(art)),
           let treffer = vorhanden.first(where: { $0.id == kennung }) {
            return treffer
        }
        return vorhanden.first
    }

    func bibliothekWaehlen(_ bibliothek: Item, art: String) {
        merken(bibliothek.id, Self.bibliotheksname(art))
    }

    private static func bibliotheksname(_ art: String) -> String { "bibliothek-\(art)" }

    /// Was dem Server als Grenze gemeldet wird.
    ///
    /// Eine Milliarde heißt praktisch unbegrenzt — ein Limit löst
    /// Transkodierung aus, auch wenn Container und Codec passen.
    private var profilBitrate: Int {
        immerDirectPlay || bitratenGrenze <= 0 ? 1_000_000_000 : bitratenGrenze * 1_000_000
    }
    var serverVersion: String?
    var isWorking = false

    private(set) var client: JellyfinClient?
    private(set) var session: Session?

    /// Alle Konten auf diesem Server, in der Reihenfolge des Streifens über
    /// der Profilseite. Leer, solange niemand angemeldet ist.
    private(set) var konten: [Session] = []

    /// Zählt jeden Kontowechsel. Ansichten hängen sich daran, um neu zu laden.
    ///
    /// **Warum ein Zähler und nicht `phase`.** Beim ersten Anmelden springt
    /// die Phase von `disconnected` auf `ready`, und daran hängt die
    /// Startseite. Beim Wechsel zwischen zwei Konten bleibt sie auf `ready`
    /// stehen — es passiert also nichts, und auf dem Schirm steht weiter das
    /// vorige Konto.
    private(set) var kontowechsel = 0

    /// **Die Quelle der Wahrheit dafür, wer angemeldet ist.**
    ///
    /// `session` bleibt daneben stehen, weil die halbe App sie liest; sie
    /// wird von hier aus nachgezogen und nirgends sonst gesetzt. Zwei
    /// Stellen, die dasselbe behaupten dürfen, laufen sonst auseinander —
    /// bei `trefferauskunft` ist genau das passiert.
    private var bund: Kontenbund? {
        didSet {
            konten = bund?.konten ?? []
            session = bund?.aktives
        }
    }

    private static let sessionKey = "session"
    /// Der Schlüssel für den ganzen Bund. Der alte oben bleibt liegen: wer
    /// noch einmal eine ältere Fassung startet, findet dort seine Sitzung.
    private static let kontenKey = "konten"
    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "start")

    /// Stabile Geräte-ID. Jellyfin listet damit die Sitzung im Dashboard.
    /// **Nicht mehr `private`.** `Uebernahmemodell` muss die eigene Kennung
    /// kennen, sonst zeigt das Gerät sich selbst als „läuft woanders" an —
    /// und das fällt erst auf, wenn nur ein Gerät läuft.
    static var deviceID: String = {
        let key = "de.paulherter.swiftly.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "Mac"
        #endif
    }

    init() {
        let ablage = UserDefaults.standard
        // `object(forKey:)` unterscheidet „nie gesetzt" von „aus" — mit
        // `bool(forKey:)` wäre die Vorgabe immer falsch.
        immerDirectPlay = ablage.object(forKey: "immerDirectPlay") as? Bool ?? true
        bitratenGrenze = ablage.integer(forKey: "bitratenGrenze")
        querformatFest = ablage.object(forKey: "querformatFest") as? Bool ?? true
        fortschrittAufKacheln = ablage.object(forKey: "fortschritt") as? Bool ?? true
        tonSprache = ablage.string(forKey: "tonSprache") ?? ""
        untertitelSprache = ablage.string(forKey: "utSprache") ?? ""
        untertitelAutomatisch = ablage.object(forKey: "utAuto") as? Bool ?? false
        naechsteAutomatisch = ablage.object(forKey: "naechsteAuto") as? Bool ?? true
        neuzugangGetrennt = ablage.object(forKey: "neuGetrennt") as? Bool ?? false
        zurueckSekunden = ablage.object(forKey: "zurueckSek") as? Int ?? 10
        vorSekunden = ablage.object(forKey: "vorSek") as? Int ?? 30

        Self.keychainSelbsttest()
        restoreSession()
    }

    /// Prüft, ob der Server antwortet, und zieht dabei Name und Fassung nach.
    func verbindungPruefen() async -> String {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            let info = try await client.publicSystemInfo()
            serverName = info.serverName ?? serverName
            serverVersion = info.version ?? serverVersion
            return String(localized: "Erreichbar — Jellyfin \(info.version ?? "?")")
        } catch {
            return error.localizedDescription
        }
    }

    /// Schreibt und liest beim Start einen Testwert. Schlägt das fehl, geht
    /// auch die Sitzung verloren — dann steht der Grund im Log statt dass man
    /// sich wundert, warum man sich ständig neu anmelden muss.
    private static func keychainSelbsttest() {
        // Bleibt bewusst liegen: so lässt sich messen, ob Einträge eine
        // Neuinstallation überleben — genau das ist die Frage.
        if let alt = Keychain.load(key: "dauertest"),
           let text = String(data: alt, encoding: .utf8) {
            Self.log.info("Keychain: Eintrag überlebt seit \(text, privacy: .public)")
        } else {
            let stempel = ISO8601DateFormatter().string(from: Date())
            do {
                try Keychain.save(Data(stempel.utf8), key: "dauertest")
                Self.log.info("Keychain: kein alter Eintrag, neu angelegt um \(stempel, privacy: .public)")
            } catch {
                Self.log.error("Keychain: Schreiben fehlgeschlagen — \(String(describing: error), privacy: .public)")
            }
        }
        Self.log.info("Keychain: Sitzung vorhanden = \(Keychain.load(key: sessionKey) != nil, privacy: .public)")
    }

    // MARK: - Verbinden

    func connect(to raw: String) async {
        errorMessage = nil
        phase = .connecting

        guard let url = Self.normalizeServerURL(raw) else {
            errorMessage = String(localized: "Die Adresse konnte nicht gelesen werden.")
            phase = .disconnected
            return
        }

        // Erst wie geraten, dann andersherum.
        //
        // Ohne Schema wird für Adressen außerhalb des Heimnetzes `https`
        // angenommen. Läuft dort ein Server ohne Zertifikat, scheitert der
        // erste Versuch an der Verbindung — nicht an einer Antwort. Genau
        // dann, und nur dann, ist ein zweiter Versuch über `http` sinnvoll.
        // Bei einer Antwort mit Fehlercode wäre er falsch: der Server ist ja
        // da, er sagt nur etwas anderes.
        if await verbindeMit(url) { return }

        // Den Grund des **ersten** Versuchs festhalten.
        //
        // Sonst überschreibt der Ausweichversuch ihn mit seinem eigenen, und
        // der ist fast immer der falsche: scheitert `https` schon an der
        // Namensauflösung, scheitert `http` daran ebenso — es meldet nur
        // vorher, dass iOS unverschlüsselte Verbindungen sperrt. Der Nutzer
        // liest dann „richte https ein", obwohl der Server schlicht nicht zu
        // finden war.
        let echterGrund = errorMessage

        if raw.contains("://") == false,
           let ausweich = AppModelURLNormalizer.andersHerum(url),
           await verbindeMit(ausweich) { return }

        errorMessage = echterGrund
        phase = .disconnected
    }

    /// - Returns: `true`, wenn der Server geantwortet hat.
    private func verbindeMit(_ url: URL) async -> Bool {
        let c = JellyfinClient(baseURL: url, deviceID: Self.deviceID, deviceName: Self.deviceName)
        do {
            let info = try await c.publicSystemInfo()
            client = c
            serverName = info.serverName ?? url.host()
            serverVersion = info.version
            phase = .needsLogin(serverName: info.serverName ?? url.host() ?? "Server",
                                version: info.version ?? "?")
            serverMerken(adresse: url.host() ?? url.absoluteString,
                         name: info.serverName ?? url.host() ?? "Server",
                         version: info.version ?? "?")
            errorMessage = nil
            return true
        } catch {
            errorMessage = anschlussfehler(error, adresse: url)
            return false
        }
    }

    /// Verbindungsfehler so, dass die Ursache daraus hervorgeht.
    ///
    /// Der häufigste Fall bei selbst gehosteten Servern ist eine unver-
    /// schlüsselte Adresse außerhalb des Heimnetzes: die sperrt iOS von sich
    /// aus, und die Fehlermeldung des Systems sagt das nicht.
    /// Den Systemfehler um den Hinweis ergänzen, der ihn deutbar macht.
    ///
    /// **Der Fall, um den es hier geht, ist eine Falschmeldung des Systems.**
    /// Verweigert der Nutzer die Ortsnetz-Erlaubnis, meldet URLSession
    /// „Die Internetverbindung scheint offline zu sein" — obwohl das Netz
    /// einwandfrei läuft und nur diese eine Erlaubnis fehlt. Wer das liest,
    /// prüft sein WLAN und findet nichts. Also sagen wir es.
    ///
    /// Der frühere Hinweis („richte https ein") ist weg: seit
    /// `NSAllowsArbitraryLoads` sperrt iOS http nicht mehr, und ein Rat, der
    /// nicht mehr stimmt, ist schlechter als keiner.
    private func anschlussfehler(_ fehler: any Error, adresse: URL) -> String {
        let text = lesbar(fehler)
        let imHeimnetz = AppModelURLNormalizer.istImHeimnetz(adresse.host() ?? "")
        // Nur bei „offline", und nur im Heimnetz: draußen ist derselbe Fehler
        // schlicht ein fehlendes Netz, und dann wäre der Hinweis irreführend.
        if imHeimnetz, (fehler as? URLError)?.code == .notConnectedToInternet {
            return String(localized: "Der Server war nicht erreichbar. Hat Swiftly die Erlaubnis, Geräte im heimischen Netz zu suchen? Sie steht in den Systemeinstellungen unter „Swiftly · Lokales Netzwerk\".")
        }
        return text
    }

    /// Was nach jeder erfolgreichen Anmeldung gleich abläuft — egal ob über
    /// Passwort oder Quick Connect.
    /// Nimmt eine frische Sitzung an. Gibt zurück, ob es ein **Kontowechsel**
    /// war — dann hat diese Funktion bereits aufgeräumt und neu geladen, und
    /// der Aufrufer soll nicht noch einmal laden.
    @discardableResult
    func sitzungUebernehmen(_ s: Session) -> Bool {
        let warAngemeldet = bund != nil
        // Derselbe Server: das Konto kommt dazu und gilt sofort. Ein anderer
        // Server heißt von vorn — ein Bund gehört zu genau einem Server.
        if var vorhanden = bund, vorhanden.passtZumServer(s) {
            vorhanden.aufnehmen(s)
            bund = vorhanden
        } else {
            bund = Kontenbund(s)
        }
        bundSichern()
        phase = .ready
        // **War die App schon angemeldet, ist das ein Kontowechsel.** Der
        // Client trägt nach dem Anmelden bereits das neue Merkmal; was fehlt,
        // ist alles andere. Ohne das Aufräumen bleiben Bibliotheken und
        // Startseite beim vorigen Konto stehen — und mit dem neuen Merkmal
        // abgefragt gibt der Server sie nicht heraus. Genau so kam
        // „Anmeldung abgelehnt", nachdem ein zweites Konto dazukam.
        if warAngemeldet { nachDemWechsel() }
        // Name und Fassung stehen sonst nur nach einer frischen Verbindung
        // bereit — in den Einstellungen stand danach „Server · ?".
        Task { _ = await verbindungPruefen() }
        return warAngemeldet
    }

    /// Was nach jedem Kontowechsel neu muss — außer dem Client selbst.
    private func nachDemWechsel() {
        views = []
        errorMessage = nil
        kontowechsel += 1
        #if os(tvOS)
        Regal.leeren()
        #endif
        // **Die Fernsteuerung gehört dazu, und das sieht man ihr nicht an.**
        // Sie wird sonst nur beim Erscheinen der Hauptansicht gestartet — die
        // bleibt beim Wechsel aber stehen, und dann meldete sich das Gerät
        // weiter mit dem Merkmal des vorigen Kontos am Server.
        Task {
            await fernsteuerungBeenden()
            await fernsteuerungStarten()
        }
    }

    func login(username: String, password: String) async {
        guard let client else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let s = try await client.authenticate(username: username, password: password)
            sitzungUebernehmen(s)
            await loadViews()
        } catch {
            errorMessage = lesbar(error)
        }
    }

    /// Quick Connect: Code freigeben, der auf einem anderen Gerät steht.
    func quickConnectFreigeben(code: String) async throws {
        guard let client else { throw JellyfinError.notAuthenticated }
        try await client.quickConnectFreigeben(code: code)
    }

    // MARK: Fernsteuerung

    /// Die offene Socket-Verbindung, über die Befehle vom Server kommen.
    @ObservationIgnored private var fern: Fernsteuerung?
    /// Setzt der Player, solange er auf dem Schirm ist.
    @ObservationIgnored var fernbefehl: ((Fernbefehl) -> Void)?

    /// Fähigkeiten melden und zuhören.
    ///
    /// Beides ist nötig, damit das Dashboard die Sitzung bedienen kann: ohne
    /// die Meldung bleiben dort die Knöpfe grau, ohne den Socket kommen die
    /// Befehle nie an.
    func fernsteuerungStarten() async {
        guard let client, fern == nil else { return }
        do {
            try await client.faehigkeitenMelden()
        } catch {
            Self.log.warning("Fähigkeiten nicht gemeldet: \(error.localizedDescription)")
        }
        guard let steuerung = try? await client.fernsteuerung() else { return }
        fern = steuerung
        await steuerung.starten { [weak self] befehl in
            Task { @MainActor in self?.fernbefehl?(befehl) }
        }
    }

    func fernsteuerungBeenden() async {
        await fern?.beenden()
        fern = nil
    }

    func loadViews() async {
        guard let client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            views = try await client.userViews()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Einen Titel frisch holen — vor allem wegen der Wiedergabeposition.
    func item(id: String) async -> Item? {
        guard let client else { return nil }
        return try? await client.item(id: id)
    }

    /// Der erste Trailer, der als Datei auf dem Server liegt.
    func trailer(zu item: Item) async -> Item? {
        guard let client else { return nil }
        return (try? await client.trailer(zu: item.id))?.first
    }

    /// Stösst das Neueinlesen der Metadaten an. Der Server arbeitet danach im
    /// Hintergrund weiter — die Antwort heisst nur „angenommen".
    func metadatenAuffrischen(_ item: Item) async -> String {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do {
            try await client.metadatenAuffrischen(item.id)
            return String(localized: "Der Server liest die Metadaten neu ein.")
        } catch {
            return error.localizedDescription
        }
    }

    func aehnliche(_ item: Item) async -> [Item] {
        guard let client else { return [] }
        return (try? await client.aehnliche(itemID: item.id)) ?? []
    }

    func extras(_ item: Item) async -> [Item] {
        guard let client else { return [] }
        return (try? await client.extras(itemID: item.id)) ?? []
    }

    func suche(_ begriff: String) async -> [Item] {
        guard let client, begriff.count >= 2 else { return [] }
        return (try? await client.suche(begriff)) ?? []
    }

    /// Der eine Ort, an dem Bildadressen entstehen.
    ///
    /// Vorher taten das fünf fast gleiche Blöcke, und zwei davon hängten das
    /// Zugangsmerkmal nicht an — was nur solange gutging, wie der Server
    /// Bilder auch unangemeldet herausgibt.
    private var bilder: Bildadresse? {
        guard let session else { return nil }
        return Bildadresse(basis: session.serverURL, token: session.accessToken)
    }

    /// Porträt eines Mitwirkenden.
    func personBild(_ person: Person, maxHeight: Int = 220) -> URL? {
        bilder?.bauen(itemID: person.id, marke: person.primaryImageTag,
                      mass: .hoechstensHoch(maxHeight))
    }

    func setzeMerkliste(_ item: Item, an: Bool) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do { try await client.setzeMerkliste(itemID: item.id, an: an); return nil }
        catch { return lesbar(error) }
    }

    @discardableResult
    func setzeGesehen(_ item: Item, an: Bool) async -> String? {
        guard let client else { return String(localized: "Nicht angemeldet.") }
        do { try await client.setzeGesehen(itemID: item.id, an: an); return nil }
        catch { return lesbar(error) }
    }

    func staffeln(_ serie: Item) async -> [Item] {
        guard let client else { return [] }
        return (try? await client.staffeln(seriesID: serie.id)) ?? []
    }

    func folgen(serie: String, staffel: String?) async -> [Item] {
        guard let client else { return [] }
        return (try? await client.folgen(seriesID: serie, seasonID: staffel)) ?? []
    }

    /// Wo man in dieser Serie steht — für den großen Knopf.
    func standInSerie(_ serie: Item) async -> Item? {
        guard let client else { return nil }
        // `try?` einer optionalen Rückgabe flacht Swift zu **einer** Ebene ab
        // — `offen` ist hier also schon ein `Item`, und das zusätzliche
        // `offen != nil`, das einmal danebenstand, war immer wahr.
        if let offen = try? await client.naechsteFolgeDerSerie(seriesID: serie.id) {
            return offen
        }
        // Serie ganz gesehen oder NextUp leer: dann die erste Folge.
        return (try? await client.folgen(seriesID: serie.id))?.first
    }

    /// Das Profilbild aus Jellyfin. Fehlt es, antwortet der Server mit 404
    /// und die Ansicht faellt auf den Anfangsbuchstaben zurueck.
    func benutzerbildURL(groesse: Int = 120) -> URL? {
        guard let session else { return nil }
        return bilder?.benutzer(session.userID, kante: groesse * 2)
    }

    /// Dasselbe für ein bestimmtes Konto — für den Streifen, in dem mehrere
    /// nebeneinander stehen und nur eines das aktive ist.
    func benutzerbildURL(fuer konto: Session, groesse: Int = 120) -> URL? {
        bilder?.benutzer(konto.userID, kante: groesse * 2)
    }

    /// Waagerechtes Bild für die Reihe „Weiterschauen".
    ///
    /// Bewusst vom übergeordneten Titel, nicht von der Folge: ein Standbild
    /// aus der Folge sagt wenig und sieht neben den anderen Reihen beliebig
    /// aus. Gefragt war „eine Art Cover".
    func querbildURL(for item: Item, breite: Int = 600) -> URL? {
        querbild(for: item, breite: breite)?.url
    }

    /// Woher das Querbild kam — nur fuer das Protokoll.
    func querbildQuelle(for item: Item) -> String {
        querbild(for: item, breite: 600)?.quelle ?? "nichts"
    }

    /// **Die Kette liegt jetzt im Paket** — `JellyfinKit.Bildwahl.quer`.
    ///
    /// Sie stand hier, war damit aber an SwiftUI gebunden und fuer die
    /// Linux-Fassung unerreichbar. An ihr haengt nichts, was mit Oberflaeche
    /// oder Uebersetzung zu tun haette; die Begruendung zu jeder Stufe steht
    /// dort, samt der Messung, dass eine Folge nie einen eigenen Hintergrund
    /// hat.
    private func querbild(for item: Item, breite: Int) -> (url: URL, quelle: String)? {
        guard let bilder else { return nil }
        return Bildwahl.quer(item, adressen: bilder, breite: breite)
    }

    /// Das Bild fuer den Sperrbildschirm und das Kontrollzentrum.
    ///
    /// **Bei Folgen das Standbild der Folge, nicht das Plakat der Serie.**
    /// Das Plakat sagt nur, welche Serie laeuft — das steht daneben ohnehin
    /// als Text. Das Standbild zeigt, *wo* man ist, und das ist die Auskunft,
    /// die dort etwas traegt.
    ///
    /// Filme behalten ihr Plakat: dort gibt es kein Standbild, und das
    /// Plakat *ist* der Titel.
    func sperrbildURL(for item: Item, hoehe: Int = 600) -> URL? {
        if item.seriesId != nil, let marke = item.imageTags?["Primary"] {
            return bilder?.bauen(itemID: item.id, marke: marke,
                                 mass: .hoechstensHoch(hoehe))
        }
        return imageURL(for: item, maxHeight: hoehe, hochkant: true)
    }

    func backdropURL(for item: Item) -> URL? {
        guard let tag = item.backdropImageTags?.first else { return nil }
        return bilder?.bauen(itemID: item.id, art: .hintergrund, marke: tag,
                             mass: .hoechstensBreit(1200), guete: 85)
    }

    /// Die Folge nach dieser.
    func folgeNach(_ item: Item) async -> Item? {
        guard let client, let serie = item.seriesId else { return nil }
        return try? await client.folgeNach(itemID: item.id, seriesID: serie)
    }

    /// Angefangene Titel.
    /// `nil` heißt: die Anfrage ist fehlgeschlagen. Das ist etwas anderes als
    /// eine leere Liste — mit `try?` sah beides gleich aus, und ein einzelner
    /// Aussetzer hat die Startseite lautlos geleert.
    func weiterschauen() async -> [Item]? {
        guard let client else { return nil }
        return try? await client.resumeItems()
    }

    /// Nächste ungesehene Folgen laufender Serien.
    ///
    /// - Parameter ohne: Titel, die schon unter „Weiterschauen" stehen.
    ///   Jellyfin listet angefangene Folgen in beiden Abfragen; ohne das
    ///   Aussortieren stünde dieselbe Folge zweimal auf der Startseite.
    func naechsteFolge(ohne bereitsGezeigt: [Item] = []) async -> [Item]? {
        guard let client, let alle = try? await client.nextUp() else { return nil }
        let schonDa = Set(bereitsGezeigt.map(\.id))
        return alle.filter { !schonDa.contains($0.id) }
    }

    /// Zuletzt Hinzugefügtes über alle Bibliotheken.
    /// Neu dazugekommen — je Serie ein Eintrag, neueste zuerst.
    ///
    /// Jellyfins eigene Zusammenfassung nennt nur die Serie und die Zahl der
    /// neuen Folgen, nicht die Staffel. Deshalb ungruppiert holen und selbst
    /// zusammenfassen: die erste Folge je Serie ist die neueste, weil der
    /// Server bereits nach Datum sortiert.
    /// - Parameter in: Nur aus dieser Bibliothek. `nil` heißt: aus allen.
    func zuletztHinzugefuegt(in bibliothek: String? = nil) async -> [Item]? {
        guard let client,
              let roh = try? await client.latest(parentID: bibliothek,
                                                 limit: 60, gruppieren: false)
        else { return nil }

        var gesehen = Set<String>()
        var ergebnis: [Item] = []
        for eintrag in roh {
            // Filme haben keine Serie und stehen für sich.
            let schluessel = eintrag.seriesId ?? eintrag.id
            guard gesehen.insert(schluessel).inserted else { continue }
            ergebnis.append(eintrag)
            if ergebnis.count >= 24 { break }
        }
        return ergebnis
    }

    /// Eine Seite aus einer Bibliothek.
    ///
    /// Gibt neben den Titeln zurück, wie viele es insgesamt gibt — sonst weiß
    /// die Ansicht nicht, wann sie aufhören darf nachzuladen. Vorher wurden
    /// stur die ersten zweihundert geholt und der Rest war über die
    /// Oberfläche nicht erreichbar.
    func items(in parentID: String,
               art: String? = nil,
               sortierung: Sortierung = .name,
               filter: Bibliotheksfilter = .alle,
               ab startIndex: Int = 0,
               anzahl: Int = AppModel.seitengroesse) async -> (titel: [Item], gesamt: Int)? {
        guard let client else { return nil }
        let gattungen = Bibliotheksgattung.typen(zu: art)
        do {
            let antwort = try await client.items(parentID: parentID,
                                                 limit: anzahl,
                                                 startIndex: startIndex,
                                                 sortBy: sortierung.feld,
                                                 sortOrder: sortierung.richtung,
                                                 filters: filter.jellyfinFilter,
                                                 istGesehen: filter.istGesehen,
                                                 // Rekursiv, sobald die Gattung
                                                 // feststeht: sonst blieben die
                                                 // Titel unter den virtuellen
                                                 // Ordnern unerreichbar.
                                                 recursive: Bibliotheksgattung.rekursiv(zu: art),
                                                 includeItemTypes: gattungen)
            return (antwort.items, antwort.totalRecordCount)
        } catch {
            errorMessage = lesbar(error)
            return nil
        }
    }

    /// Groß genug, dass man beim ersten Wischen nicht ans Ende kommt, klein
    /// genug, dass die erste Seite schnell steht.
    static let seitengroesse = 60

    // MARK: - Dateien, deren Index nichts taugt





    /// Fragt den Server, wie er diesen Titel ausliefern würde.
    ///
    func plan(for itemID: String) async -> PlaybackPlan? {
        guard let client else { return nil }
        do {
            let plan = try await client.playbackPlan(for: itemID,
                                                       profile: .vlc(maxBitrate: profilBitrate))
            if plan == nil {
                // Tritt bei Serien und Staffeln auf: die haben keine
                // Mediendatei, nur ihre Folgen haben eine.
                Self.log.error("Kein Plan für \(itemID, privacy: .public) — Server nannte keine MediaSource")
            }
            return plan
        } catch {
            Self.log.error("PlaybackInfo fehlgeschlagen für \(itemID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Poster-URL. Wird hier gebaut statt im Client, damit die Ansichten
    /// nicht auf den Actor warten müssen.
    func imageURL(for item: Item, maxHeight: Int = 480, hochkant: Bool = false) -> URL? {
        guard let bilder else { return nil }
        // Hochkant heisst bei einer Folge: das Plakat der Serie. Warum, steht
        // in `Bildwahl.hochkant` — hier stand dieselbe Regel ein zweites Mal.
        if hochkant {
            return Bildwahl.hochkant(item, adressen: bilder, maxHoehe: maxHeight)
        }
        guard let marke = item.imageTags?["Primary"] else { return nil }
        return bilder.bauen(itemID: item.id, marke: marke,
                            mass: .hoechstensHoch(maxHeight))
    }

    /// Vorspann, Rückblick und Abspann einer Folge.
    ///
    /// Leer heißt: der Server weiß nichts davon — kein Plugin, keine Analyse,
    /// oder eine ältere Fassung. Dann bleibt alles wie vorher.
    func abschnitte(fuer itemID: String) async -> [JellyfinKit.Abschnitt] {
        guard let client else { return [] }
        return await client.abschnitte(fuer: itemID)
    }

    // MARK: - Wiedergabe melden
    //
    // Schlägt eine Meldung fehl, ist das kein Grund, die Wiedergabe zu stören —
    // deshalb wird der Fehler hier nur vermerkt, nicht angezeigt.

    func reportStart(item: Item, plan: PlaybackPlan, seconds: Double) async {
        guard let client else { return }
        do {
            try await client.reportStart(itemID: item.id, plan: plan,
                                         ticks: JellyfinClient.ticks(fromSeconds: seconds))
            Self.log.info("Wiedergabe gemeldet: Start bei \(Int(seconds)) s")
        } catch {
            Self.log.error("Start-Meldung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reportProgress(item: Item, plan: PlaybackPlan, seconds: Double, paused: Bool) async {
        guard let client else { return }
        do {
            try await client.reportProgress(itemID: item.id, plan: plan,
                                            positionTicks: JellyfinClient.ticks(fromSeconds: seconds),
                                            paused: paused)
            Self.log.info("Wiedergabe gemeldet: \(Int(seconds)) s")
        } catch {
            Self.log.error("Fortschritt-Meldung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reportStopped(item: Item, plan: PlaybackPlan, seconds: Double) async {
        guard let client else { return }
        do {
            try await client.reportStopped(itemID: item.id, plan: plan,
                                           positionTicks: JellyfinClient.ticks(fromSeconds: seconds))
            Self.log.info("Wiedergabe gemeldet: Ende bei \(Int(seconds)) s")
        } catch {
            Self.log.error("Ende-Meldung fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Auf ein anderes Konto desselben Servers umschalten.
    ///
    /// **Kein neues Passwort.** Beide Merkmale liegen im Schlüsselbund; der
    /// Wechsel tauscht nur, welches gilt. Was danach neu aufgebaut werden
    /// muss, steht in ``neuVerbinden()`` — es ist mehr, als man denkt.
    func kontoWechseln(zu kennung: String) {
        guard var neu = bund, neu.aktiveKennung != kennung,
              neu.konten.contains(where: { $0.userID == kennung }) else { return }
        neu.wechseln(zu: kennung)
        bund = neu
        bundSichern()
        neuVerbinden()
    }

    /// Baut alles neu auf, was am angemeldeten Konto hängt.
    ///
    /// **Die Fernsteuerung gehört dazu, und das sieht man ihr nicht an.**
    /// Sie wird sonst nur beim Erscheinen der Hauptansicht gestartet — die
    /// bleibt beim Kontowechsel aber stehen, und dann meldete sich das Gerät
    /// weiter mit dem Merkmal des vorigen Kontos am Server. Auf dem iPhone
    /// wäre danach die falsche Wiedergabe zum Übernehmen angeboten worden.
    private func neuVerbinden() {
        guard let s = session else { return }
        // **Beim Wechsel wird nicht abgemeldet.** `abmelden()` schickt ein
        // `Sessions/Logout` an den Server und zieht das Merkmal ein — richtig
        // beim Abmelden, verheerend beim Umschalten: das Konto, von dem man
        // weggeht, waere danach unbrauchbar, und der Weg zurueck endet in
        // „Anmeldung abgelehnt". Der alte Client wird einfach fallen
        // gelassen; das Merkmal bleibt gueltig und liegt im Schluesselbund.
        let neuer = JellyfinClient(baseURL: s.serverURL, deviceID: Self.deviceID,
                                   deviceName: Self.deviceName, session: s)
        client = neuer
        phase = .ready
        nachDemWechsel()
        Task { _ = await verbindungPruefen() }
    }

    func signOut() {
        // Der Socket lief vorher weiter — mit einem Zugangsmerkmal, das der
        // Nutzer gerade loswerden wollte. Seit die Fernsteuerung sich nach
        // einem Abriss selbst wieder aufbaut, hätte sie das auch getan.
        let alter = client
        Task {
            await fernsteuerungBeenden()
            await alter?.abmelden()
        }
        // **Abmelden trifft nur das aktive Konto.** Sind noch andere da,
        // schaltet die App auf das nächste um, statt zur Serveranmeldung
        // zurückzufallen — wer den Server ganz verlassen will, meldet jedes
        // Konto einzeln ab. Ein Knopf, eine Bedeutung.
        if let rest = bund?.entfernt(bund?.aktiveKennung ?? "") {
            bund = rest
            bundSichern()
            neuVerbinden()
            return
        }

        Keychain.delete(key: Self.kontenKey)
        Keychain.delete(key: Self.sessionKey)
        // Sonst stehen im Top Shelf weiter die Titel des vorigen Kontos.
        //
        // **Nur auf dem Fernseher, und deshalb eingeklammert.** Ein Top Shelf
        // gibt es sonst nirgends: `Regalvorschau.swift` steht in der
        // tvOS-App und in ihrer Erweiterung, in keinem anderen Ziel. Ohne
        // die Klammer bricht macOS an dieser Zeile ab — dort sind die
        // geteilten Dateien einzeln aufgezaehlt, waehrend iOS `Sources/Shared`
        // als ganzen Ordner nimmt und die Datei versehentlich mitbekommt.
        // Der Bau auf iOS beweist hier also nichts.
        #if os(tvOS)
        Regal.leeren()
        #endif
        bund = nil
        client = nil
        views = []
        errorMessage = nil
        phase = .disconnected
    }

    // MARK: - Sitzung sichern

    func bundSichern() {
        guard let bund else { return }
        do {
            try Keychain.save(JSONEncoder().encode(bund), key: Self.kontenKey)
            // Sofort zurücklesen: ein Schreibfehler, der erst beim nächsten
            // Start auffällt, kostet unnötig eine Anmeldung.
            guard Keychain.load(key: Self.kontenKey) != nil else {
                Self.log.error("Keychain: Sitzung geschrieben, aber nicht lesbar")
                errorMessage = String(localized: "Sitzung ließ sich nicht sichern — du müsstest dich neu anmelden.")
                return
            }
            Self.log.info("Keychain: Sitzung gesichert")
        } catch {
            errorMessage = String(localized: "Sitzung ließ sich nicht sichern.")
        }
    }

    /// Liest den Bund — und nimmt eine einzelne Sitzung aus der Zeit davor an.
    ///
    /// **Die Übernahme steht hier und nicht im Paket**, weil nur der
    /// Zustandshalter weiß, wo etwas liegt. Der alte Eintrag wird nicht
    /// gelöscht: wer noch einmal eine ältere Fassung startet, soll nicht
    /// plötzlich abgemeldet sein.
    private func bundLaden() -> Kontenbund? {
        if let daten = Keychain.load(key: Self.kontenKey),
           let b = try? JSONDecoder().decode(Kontenbund.self, from: daten) {
            return b
        }
        guard let daten = Keychain.load(key: Self.sessionKey),
              let alt = try? JSONDecoder().decode(Session.self, from: daten) else { return nil }
        Self.log.info("Keychain: einzelne Sitzung als Bund übernommen")
        return Kontenbund(alt)
    }

    private func restoreSession() {
        guard let wieder = bundLaden() else { return }
        bund = wieder
        let s = wieder.aktives
        let neuer = JellyfinClient(baseURL: s.serverURL, deviceID: Self.deviceID,
                                   deviceName: Self.deviceName, session: s)
        client = neuer
        phase = .ready
        Task {
            // Name und Fassung stehen sonst nur nach einer frischen Verbindung
            // bereit — in den Einstellungen stand danach „Server · ?".
            _ = await verbindungPruefen()

            // Und prüfen, ob das Merkmal überhaupt noch gilt.
            //
            // Vorher genügte ein Eintrag im Keychain, um `ready` zu setzen.
            // Ein widerrufenes Merkmal führte damit nicht auf den
            // Anmeldebildschirm, sondern in „Kein Kontakt zum Server" — und
            // von dort gibt es keinen Weg zurück außer über das Profilmenü.
            guard await neuer.sitzungGiltNoch() else {
                let name = session?.userName
                signOut()
                // **Nach dem Abmelden kann noch ein Konto da sein.** Seit es
                // mehrere gibt, schaltet `signOut` auf das nächste um statt
                // zur Serveranmeldung zurückzufallen — und dann wäre „bitte
                // neu anmelden" schlicht falsch: der Nutzer ist angemeldet,
                // nur mit einem anderen Konto.
                if let weiter = session?.userName {
                    errorMessage = String(localized: "Die Anmeldung von \(name ?? "?") gilt nicht mehr. Jetzt angemeldet als \(weiter).")
                } else {
                    errorMessage = String(localized: "Die Anmeldung gilt nicht mehr. Bitte neu anmelden.")
                }
                return
            }
        }
    }

    /// Liegt in JellyfinKit, damit sie ohne Simulator testbar ist.
    static func normalizeServerURL(_ raw: String) -> URL? {
        AppModelURLNormalizer.normalize(raw)
    }
}

extension AppModel {
    /// **Der Weg in die Wiedergabe einer Folge, einmal.**
    ///
    /// Stand zeichengleich in `Shared/SeriesView.swift` und
    /// `tvOS/SerienView.swift` — bis auf das Zuweisungsziel. Genau die Sorte,
    /// die auseinanderlaeuft: Es reicht, dass einer die Meldung aendert oder
    /// eine Pruefung ergaenzt, und die Plattformen antworten verschieden.
    ///
    /// Gibt `nil` zurueck, wenn der Server keinen Plan liefert. Die Meldung
    /// dazu steht in `folgeNichtGeladen`, damit sie ebenfalls nur einmal
    /// existiert.
    func folgenwunsch(_ folge: Item, ab: Double) async -> Abspielwunsch? {
        guard let plan = await plan(for: folge.id) else { return nil }
        return Abspielwunsch(item: folge, plan: plan, startAt: ab)
    }

    static var folgeNichtGeladen: String {
        String(localized: "Die Folge konnte nicht geladen werden.")
    }
}
