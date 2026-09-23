import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ein eigener HTTP-Kopf, den der Nutzer selbst einträgt.
///
/// **Wofür es das gibt.** Wer Jellyfin oder Seerr hinter Cloudflare Access,
/// Authelia, Authentik oder Pangolin stellt, lässt dort nur durch, wer einen
/// bestimmten Kopf mitbringt — bei Cloudflare etwa `CF-Access-Client-Id` und
/// `CF-Access-Client-Secret`. Ohne ihn antwortet der Vorposten mit seiner
/// eigenen Anmeldeseite, und die App bekommt HTML statt einer Antwort.
///
/// **Der Wert ist ein Geheimnis.** Er wird wie ein Passwort behandelt:
/// verdeckt eingegeben, im Schlüsselbund abgelegt und nie protokolliert —
/// auch nicht in ``Spur``. Wer eine Zeile fürs Protokoll braucht, nimmt
/// ``Eigenkoepfe/namen(_:)``.
public struct Eigenkopf: Codable, Sendable, Hashable {
    public var name: String
    public var wert: String

    public init(name: String, wert: String) {
        self.name = name
        self.wert = wert
    }
}

/// Welche eigenen Köpfe an welchen Server gehen — und welche nie.
///
/// **Eine Tafel nach Adresse, nicht ein Feld am Klienten.** Die Köpfe
/// müssen an *jede* Anfrage an diesen Server: an die Schnittstelle, an jedes
/// Plakat, an das Kachelblatt, an den Download, an den Steuerkanal. Die
/// meisten davon sehen den ``JellyfinClient`` nie, nur eine fertige
/// Adresse. Deshalb fragt jede Stelle hier mit der Adresse nach, und die
/// Antwort hängt allein daran, **wohin** die Anfrage geht.
///
/// **Nur an den eigenen Server.** Ein Plakat von TMDB, ein Untertitel von
/// woanders, ein fremder Stream bekommen nichts — verglichen werden Schema,
/// Rechner, Port und der Pfad der Basisadresse (ein Jellyfin unter
/// `/jellyfin` hinter einem Proxy). Übernommen von Streamyfin, wo genau das
/// die Regel ist: die Zugangsdaten des Vorpostens gehen niemanden sonst an.
///
/// **Leer ist der Normalfall.** Wer nichts einträgt, bei dem ändert sich
/// nichts: ``anwenden(auf:)`` rührt eine Anfrage ohne Treffer nicht an.
public enum Eigenkoepfe {

    // MARK: Was nie hinausgeht

    /// Köpfe, die die App selbst setzt oder die das Netz sich vorbehält.
    ///
    /// **`Authorization` und die `X-Emby-…`-Namen** trügen sonst das
    /// Jellyfin-Merkmal fort — ein eigener Kopf gleichen Namens ersetzte es,
    /// und der Nutzer wäre abgemeldet, ohne zu wissen, warum. Streamyfin
    /// sperrt dieselben drei aus demselben Grund. **`Cookie`** trägt die
    /// Seerr-Sitzung. Der Rest gehört dem Netz: `URLSession` ignoriert oder
    /// überschreibt ihn ohnehin, und ein Eintrag, der stillschweigend nichts
    /// tut, ist schlimmer als einer, der gar nicht erst angenommen wird.
    static let gesperrt: Set<String> = [
        "authorization", "x-emby-authorization", "x-emby-token", "x-mediabrowser-token",
        "cookie", "accept", "content-type", "content-length", "host",
        "connection", "transfer-encoding", "proxy-authorization", "upgrade",
    ]

    /// Darf dieser Name nicht verwendet werden? Für den Hinweis in der
    /// Eingabe — die Prüfung selbst steckt in ``bereinigt(_:)``.
    public static func istGesperrt(_ name: String) -> Bool {
        gesperrt.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Ist das ein zulässiger Kopfname? RFC 9110, „token": Buchstaben,
    /// Ziffern und ``!#$%&'*+-.^_`|~`` — kein Leerzeichen, kein Doppelpunkt.
    public static func nameTaugt(_ name: String) -> Bool {
        let zulaessig = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !name.isEmpty && name.allSatisfy { zulaessig.contains($0) }
    }

    /// Was von einer Eingabe übrig bleibt, bevor sie gespeichert oder
    /// gesendet wird — **die eine Schleuse** für beides.
    ///
    /// Heraus fällt: was keinen Namen oder keinen Wert hat, was einen
    /// unzulässigen Namen trägt, was ``gesperrt`` ist, was ein Steuerzeichen
    /// im Wert hat (ein Zeilenumbruch dort hängte einen weiteren Kopf an),
    /// und jeder zweite Eintrag desselben Namens — Groß- und Kleinschreibung
    /// zählen bei Köpfen nicht, also auch hier nicht. Der erste gewinnt.
    public static func bereinigt(_ koepfe: [Eigenkopf]) -> [Eigenkopf] {
        var gesehen = Set<String>()
        return koepfe.compactMap { k in
            let name = k.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let wert = k.wert.trimmingCharacters(in: .whitespacesAndNewlines)
            guard nameTaugt(name), !wert.isEmpty,
                  !gesperrt.contains(name.lowercased()),
                  !wert.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
                  gesehen.insert(name.lowercased()).inserted
            else { return nil }
            return Eigenkopf(name: name, wert: wert)
        }
    }

    /// Nur die Namen, für ein Protokoll. **Nie die Werte.**
    public static func namen(_ koepfe: [Eigenkopf]) -> String {
        koepfe.isEmpty ? "keine" : koepfe.map(\.name).joined(separator: ", ")
    }

    // MARK: Die Tafel

    /// Hinter einer Sperre, weil Bilder, Downloads und der Player von
    /// überall her fragen — auch von außerhalb jedes Akteurs.
    private final class Tafel: @unchecked Sendable {
        let sperre = NSLock()
        var eintraege: [String: [Eigenkopf]] = [:]
    }
    private static let tafel = Tafel()

    /// Die Köpfe für einen Server setzen. Eine leere Liste nimmt ihn heraus.
    public static func setzen(_ koepfe: [Eigenkopf], fuer basis: URL) {
        guard let schluessel = schluessel(basis) else { return }
        let sauber = bereinigt(koepfe)
        tafel.sperre.lock(); defer { tafel.sperre.unlock() }
        if sauber.isEmpty { tafel.eintraege[schluessel] = nil }
        else { tafel.eintraege[schluessel] = sauber }
    }

    /// Was für genau diese Basisadresse eingetragen ist — für die Eingabe,
    /// die den Stand zeigen soll. Zum Senden ist ``fuer(_:)`` da.
    public static func eingetragen(fuer basis: URL) -> [Eigenkopf] {
        guard let schluessel = schluessel(basis) else { return [] }
        tafel.sperre.lock(); defer { tafel.sperre.unlock() }
        return tafel.eintraege[schluessel] ?? []
    }

    /// Die Köpfe für eine Anfrage an diese Adresse.
    ///
    /// **Die längste passende Basis gewinnt.** Liegen Jellyfin unter
    /// `/jellyfin` und Seerr unter `/seerr` hinter demselben Rechner, hat
    /// jeder seine eigenen.
    public static func fuer(_ url: URL) -> [Eigenkopf] {
        guard let ziel = teile(url) else { return [] }
        tafel.sperre.lock(); defer { tafel.sperre.unlock() }
        guard !tafel.eintraege.isEmpty else { return [] }
        var bester: (laenge: Int, koepfe: [Eigenkopf])?
        for (schluessel, koepfe) in tafel.eintraege {
            guard let basis = URL(string: schluessel).flatMap(teile),
                  basis.ursprung == ziel.ursprung,
                  basis.pfad.isEmpty || ziel.pfad == basis.pfad
                    || ziel.pfad.hasPrefix(basis.pfad + "/")
            else { continue }
            if basis.pfad.count >= (bester?.laenge ?? -1) { bester = (basis.pfad.count, koepfe) }
        }
        return bester?.koepfe ?? []
    }

    /// Dieselben Köpfe als Wörterbuch — für `AVURLAsset` und alles, was
    /// keine `URLRequest` nimmt.
    public static func felder(fuer url: URL) -> [String: String] {
        Dictionary(fuer(url).map { ($0.name, $0.wert) }, uniquingKeysWith: { a, _ in a })
    }

    /// In eine Anfrage schreiben. Ohne Treffer bleibt sie, wie sie war.
    public static func anwenden(auf anfrage: inout URLRequest) {
        guard let url = anfrage.url else { return }
        anwenden(fuer(url), auf: &anfrage)
    }

    /// Eine bekannte Liste in eine Anfrage schreiben — für Seerr, dessen
    /// Köpfe am Zugang hängen und nicht in der Tafel stehen.
    public static func anwenden(_ koepfe: [Eigenkopf], auf anfrage: inout URLRequest) {
        for k in bereinigt(koepfe) { anfrage.setValue(k.wert, forHTTPHeaderField: k.name) }
    }

    // MARK: Ablage

    /// Die ganze Tafel zum Ablegen — **in den Schlüsselbund**, nicht in die
    /// Einstellungen: die Werte sind Zugänge.
    public static func ablage() -> Data {
        tafel.sperre.lock(); defer { tafel.sperre.unlock() }
        return (try? JSONEncoder().encode(tafel.eintraege)) ?? Data("{}".utf8)
    }

    /// Eine abgelegte Tafel zurückholen. Ersetzt, was da war.
    public static func laden(_ daten: Data?) {
        let gelesen = daten.flatMap { try? JSONDecoder().decode([String: [Eigenkopf]].self, from: $0) } ?? [:]
        var sauber: [String: [Eigenkopf]] = [:]
        for (s, k) in gelesen {
            let b = bereinigt(k)
            if !b.isEmpty, let url = URL(string: s), let neu = schluessel(url) { sauber[neu] = b }
        }
        tafel.sperre.lock(); defer { tafel.sperre.unlock() }
        tafel.eintraege = sauber
    }

    // MARK: Adressvergleich

    private struct Teile { let ursprung: String; let pfad: String }

    /// Schema, Rechner, Port und Pfad in vergleichbarer Form.
    ///
    /// **`ws` zählt wie `http`, `wss` wie `https`** — der Steuerkanal ist ein
    /// WebSocket zum selben Server, und der Vorposten davor derselbe.
    /// **Ein `..` im Pfad passt nie**: damit ließe sich aus dem Basispfad
    /// herausklettern.
    private static func teile(_ url: URL) -> Teile? {
        guard let k = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var schema = k.scheme?.lowercased(), let rechner = k.host?.lowercased(),
              !rechner.isEmpty else { return nil }
        if schema == "ws" { schema = "http" }
        if schema == "wss" { schema = "https" }
        guard schema == "http" || schema == "https" else { return nil }
        let port = k.port ?? (schema == "https" ? 443 : 80)
        var pfad = k.percentEncodedPath
        guard !pfad.split(separator: "/").contains("..") else { return nil }
        while pfad.hasSuffix("/") { pfad.removeLast() }
        return Teile(ursprung: "\(schema)://\(rechner):\(port)", pfad: pfad)
    }

    private static func schluessel(_ basis: URL) -> String? {
        teile(basis).map { $0.ursprung + $0.pfad }
    }

    // MARK: Abgefangen

    /// Hat statt des Servers ein Vorposten geantwortet — mit einer
    /// Anmeldeseite?
    ///
    /// **Das ist der Fehler, den dieses ganze Stück behebt**, und ohne die
    /// Frage sah er aus wie etwas anderes: Cloudflare Access leitet auf seine
    /// Anmeldeseite um, `URLSession` folgt, und am Ende steht eine 200 mit
    /// HTML. Die App meldete „unverständliche Antwort" oder „Seerr hat keine
    /// Sitzung mitgegeben" — beides wahr und beides ohne Hinweis darauf, was
    /// zu tun ist. Die Schnittstellen von Jellyfin und Seerr liefern nie HTML.
    public static func anmeldeseite(_ antwort: URLResponse?) -> Bool {
        guard let http = antwort as? HTTPURLResponse,
              let art = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else { return false }
        return art.hasPrefix("text/html")
    }

    /// Der Satz dazu, für den Nutzer.
    public static var anmeldeseiteText: String {
        uebersetzt("Vor dem Server sitzt eine Anmeldeseite, etwa Cloudflare Access oder Authelia. Trag die Header, die sie verlangt, unter „Erweitert“ ein.")
    }
}

public extension URLRequest {
    /// Die eigenen Köpfe des Zielservers eintragen, falls es welche gibt.
    mutating func eigeneKoepfeSetzen() { Eigenkoepfe.anwenden(auf: &self) }

    /// Ein schlichter Abruf von `url`, mit den eigenen Köpfen ihres Servers —
    /// für die Stellen, die bisher `data(from: url)` sagten: Bilder,
    /// Untertitel, Downloads. Ohne Eintrag ist es dieselbe Anfrage wie vorher.
    static func mitEigenenKoepfen(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.eigeneKoepfeSetzen()
        return r
    }
}
