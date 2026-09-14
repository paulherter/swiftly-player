import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **Die Fassade, die Android sieht.**
///
/// Haelt, was auf Apple `AppModel` haelt: den Client und die Sitzung. Kotlin
/// haelt nur Oberflaechenzustand. Antworten gehen als JSON ueber die Bruecke —
/// fertig zusammengesetzt, damit keine Regel in Kotlin ein zweites Mal entsteht
/// (Notizen/Android/PLAN.md, „Regeln fuer die Fassade").
///
/// **Eine Klasse mit Sperre, kein Actor:** jextract wickelt Klassen, und die
/// Aufrufe kommen aus Coroutinen auf beliebigen Faeden.
public final class Kern: @unchecked Sendable {
    private let geraeteID: String
    private let geraeteName: String
    private let fassung: String
    private let sperre = NSLock()
    private var _client: JellyfinClient?
    private var _adressen: Bildadresse?
    private var _sitzung: Session?

    public init(geraeteID: String, geraeteName: String, fassung: String) {
        self.geraeteID = geraeteID
        self.geraeteName = geraeteName
        self.fassung = fassung
    }

    private var client: JellyfinClient? {
        get { sperre.lock(); defer { sperre.unlock() }; return _client }
    }
    private var adressen: Bildadresse? {
        get { sperre.lock(); defer { sperre.unlock() }; return _adressen }
    }
    private func setzen(_ c: JellyfinClient?, _ a: Bildadresse?, _ s: Session? = nil) {
        sperre.lock(); _client = c; _adressen = a; _sitzung = s; sperre.unlock()
    }

    /// Das Profilbild des angemeldeten Kontos — dieselbe Adresse wie
    /// `AppModel.benutzerbildURL()` auf Apple. `nil` ohne Sitzung.
    public func benutzerbild(kante: Int) -> String? {
        sperre.lock(); defer { sperre.unlock() }
        guard let s = _sitzung, let a = _adressen else { return nil }
        return a.benutzer(s.userID, kante: kante)?.absoluteString
    }

    private func neuerClient(_ url: URL, _ sitzung: Session? = nil) -> JellyfinClient {
        JellyfinClient(baseURL: url, deviceID: geraeteID, deviceName: geraeteName,
                       clientVersion: fassung, session: sitzung)
    }

    // MARK: Sprache

    /// **Vor dem ersten Text aufrufen** — beim Start der App. `ordner` enthaelt
    /// die `.lproj`-Ordner des Pakets (aus den Assets entpackt), `sprache` ist
    /// die Geraetesprache. Siehe `Paketsprache` im Paket.
    public static func paketspracheSetzen(ordner: String, sprache: String) {
        #if os(Android)
        Paketsprache.ordner = ordner
        Paketsprache.sprache = sprache
        #endif
    }

    // MARK: Verbinden und Anmelden

    /// Wie `AppModel.connect(to:)`: Adresse normalisieren, bei `https` ohne
    /// Antwort einmal `http` versuchen. Antwort: `{"name","version","adresse"}`.
    public func verbinden(adresse: String) async throws -> String {
        guard let url = AppModelURLNormalizer.normalize(adresse) else { throw Kernfehler.adresse(adresse) }
        var kandidaten = [url]
        if let anders = AppModelURLNormalizer.andersHerum(url) { kandidaten.append(anders) }
        var letzter: Error = Kernfehler.adresse(adresse)
        for kandidat in kandidaten {
            let c = neuerClient(kandidat)
            do {
                let info = try await c.publicSystemInfo()
                setzen(c, Bildadresse(basis: kandidat, token: nil))
                return try json(Serverantwort(name: info.serverName ?? kandidat.host() ?? "",
                                              version: info.version ?? "",
                                              adresse: kandidat.absoluteString))
            } catch { letzter = error }
        }
        throw letzter
    }

    /// Antwort: die Sitzung als JSON — Kotlin legt sie verschluesselt ab und gibt
    /// sie beim naechsten Start an ``sitzungSetzen(json:)`` zurueck.
    public func anmelden(benutzer: String, passwort: String) async throws -> String {
        guard let c = client else { throw Kernfehler.nichtVerbunden }
        let s = try await c.authenticate(username: benutzer, password: passwort)
        let neu = neuerClient(s.serverURL, s)
        setzen(neu, Bildadresse(basis: s.serverURL, token: s.accessToken), s)
        return try json(s)
    }

    public func sitzungSetzen(json text: String) throws {
        let s = try JSONDecoder().decode(Session.self, from: Data(text.utf8))
        setzen(neuerClient(s.serverURL, s), Bildadresse(basis: s.serverURL, token: s.accessToken), s)
    }

    // MARK: Startseite

    /// Fertige Reihen in der eingestellten Folge. `abgelegt`/`aus` sind die
    /// Namen aus den Einstellungen (wie `startReihen`/`startAus` auf Apple).
    public func startseite(getrennt: Bool, abgelegt: [String], aus: [String],
                           filmBibliothek: String, serienBibliothek: String,
                           gattungen: [String], alsChips: Bool) async throws -> String {
        guard let c = client, let a = adressen else { throw Kernfehler.nichtVerbunden }
        // Ohne gemerkte Wahl die erste Sammlung ihrer Art — wie
        // `AppModel.gewaehlteBibliothek(art:)` auf Apple.
        var filme = filmBibliothek.isEmpty ? nil : filmBibliothek
        var serien = serienBibliothek.isEmpty ? nil : serienBibliothek
        if getrennt, filme == nil || serien == nil, let sammlungen = try? await c.userViews() {
            filme = filme ?? sammlungen.first { $0.collectionType == "movies" }?.id
            serien = serien ?? sammlungen.first { $0.collectionType == "tvshows" }?.id
        }
        let stand = await Startseitenlader.laden(von: c, .init(
            getrennt: getrennt, filmBibliothek: filme, serienBibliothek: serien,
            gattungen: alsChips ? nil : gattungen))
        let inhalt: [Startreihe: (quer: Bool, neu: Bool, items: [Item])] = [
            .weiterschauen: (true, false, stand.weiterschauen ?? []),
            .naechsteFolge: (false, false, stand.naechsteFolge ?? []),
            .neuzugaenge: (false, true, stand.zuletzt ?? []),
            .neueFilme: (false, true, stand.neueFilme ?? []),
            .neueSerien: (false, true, stand.neueSerien ?? []),
        ]
        var reihen: [Reihenantwort] = Startreihenfolge
            .sichtbar(abgelegt: abgelegt, aus: Set(aus), getrennt: getrennt)
            .compactMap { r in
                guard let (quer, neu, items) = inhalt[r], !items.isEmpty else { return nil }
                return Reihenantwort(titelSchluessel: r.reihentitel, name: nil, quer: quer,
                                     kacheln: items.map { kachel($0, neuzugang: neu, a) })
            }
        reihen += stand.gattungsreihen.map {
            Reihenantwort(titelSchluessel: nil, name: $0.name, quer: false,
                          kacheln: $0.items.map { kachel($0, neuzugang: false, a) })
        }
        return try json(Startseitenantwort(reihen: reihen, gestoert: stand.gestoert))
    }

    /// Dieselben Zeilen wie `HomeView.Kachel` auf dem iPhone: `neuzugangszeile`
    /// in den Neuzugangsreihen, sonst `folgenkuerzel` — beide aus dem Paket.
    private func kachel(_ i: Item, neuzugang: Bool, _ a: Bildadresse) -> Kachelantwort {
        Kachelantwort(
            id: i.id, name: i.seriesName ?? i.name, typ: i.type ?? "",
            unterzeile: neuzugang ? i.neuzugangszeile : i.folgenkuerzel,
            plakat: Bildwahl.hochkant(i, adressen: a)?.absoluteString,
            quer: Bildwahl.quer(i, adressen: a)?.url.absoluteString,
            fortschritt: i.gesehenerAnteil)
    }

    private func json<T: Encodable>(_ wert: T) throws -> String {
        String(decoding: try JSONEncoder().encode(wert), as: UTF8.self)
    }
}

// MARK: Antworten — was Kotlin liest

struct Serverantwort: Encodable { let name, version, adresse: String }
struct Startseitenantwort: Encodable { let reihen: [Reihenantwort]; let gestoert: Bool }
struct Reihenantwort: Encodable {
    /// Deutscher Wortlaut als Schluessel — Kotlin uebersetzt mit `uebersetzt(...)`.
    let titelSchluessel: String?
    /// Name einer Genre-Reihe, wird nicht uebersetzt.
    let name: String?
    let quer: Bool
    let kacheln: [Kachelantwort]
}
struct Kachelantwort: Encodable {
    let id, name, typ: String
    let unterzeile: String?
    let plakat: String?
    let quer: String?
    let fortschritt: Double?
}
