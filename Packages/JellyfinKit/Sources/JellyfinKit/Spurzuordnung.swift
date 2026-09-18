import Foundation

/// Eine Ton- oder Untertitelspur, wie der Abspieler sie aufzählt.
///
/// **Kein VLC-Objekt, nur seine Angaben** — damit die Zuordnung hier im Paket
/// liegt, ohne Abspieler testbar ist und Android, Linux und Windows sie ohne
/// Kopie bekommen. libVLC 4 liefert dieselben Felder überall.
public struct Abspielerspur: Sendable, Equatable {
    /// libVLCs Spurkennung (`trackId`): `audio/1`, `spu/3`, bei einer
    /// nachgeladenen Datei `<md5 der Adresse>/spu/0`.
    public let kennung: String
    public let name: String
    /// Wie libVLC sie meldet — `ger`, `German` oder leer.
    public let sprache: String?
    /// In der Schreibweise von ``Technikangaben/codecname(_:)``, sonst `nil`.
    public let codec: String?
    public let kanaele: Int?

    public init(kennung: String, name: String, sprache: String?, codec: String?, kanaele: Int?) {
        self.kennung = kennung; self.name = name; self.sprache = sprache
        self.codec = codec; self.kanaele = kanaele
    }

    /// Kommt die Spur aus einer nachgeladenen Datei? libVLC setzt dann den
    /// MD5 der Adresse vor die Art (`src/input/es_out.c`, `EsOutCreateStrId`;
    /// `input.c`, `InputSourceNew`). Die Spuren der Datei selbst haben keinen
    /// Vorsatz.
    public var zusatzkennung: String? {
        guard let erstes = kennung.split(separator: "/").first, erstes.count == 32,
              erstes.allSatisfy(\.isHexDigit) else { return nil }
        return String(erstes)
    }

    /// Untertitel, die libVLC aus einer Videospur zieht (`…/cc/…`). Die
    /// kennt der Server nicht.
    var istUntertitelAusBild: Bool { kennung.contains("/cc/") }
}

/// Eine Untertiteldatei neben dem Film, die der Abspieler nachlädt.
public struct Untertiteldatei: Sendable, Equatable {
    /// Jellyfins `Index` des `MediaStream`.
    public let index: Int
    public let adresse: URL
    /// MD5 von `adresse.absoluteString` als Kleinbuchstaben-Hex — so erkennt
    /// man die Spur im Abspieler wieder. `nil`, wenn die Plattform keinen
    /// MD5 bilden kann; dann zählt die Reihenfolge.
    public let merkmal: String?

    public init(index: Int, adresse: URL, merkmal: String?) {
        self.index = index; self.adresse = adresse; self.merkmal = merkmal
    }

    /// Die externen Untertitel einer Quelle mit voller Adresse.
    ///
    /// `DeliveryUrl` kommt serverrelativ und trägt keinen Schlüssel; der
    /// wird angehängt wie bei der Abspieladresse (`ApiKey`).
    public static func aus(stroeme: [MediaStream], server: URL, schluessel: String?,
                           merkmal: (URL) -> String? = { _ in nil }) -> [Untertiteldatei] {
        stroeme.compactMap { strom in
            guard strom.type == "Subtitle", strom.isExternal == true,
                  let index = strom.index, let pfad = strom.deliveryUrl, !pfad.isEmpty,
                  let ganz = URL(string: pfad, relativeTo: server)?.absoluteURL,
                  var teile = URLComponents(url: ganz, resolvingAgainstBaseURL: false)
            else { return nil }
            let vorhanden = teile.queryItems ?? []
            if let schluessel, !vorhanden.contains(where: { ["apikey", "api_key"].contains($0.name.lowercased()) }) {
                teile.queryItems = vorhanden + [URLQueryItem(name: "ApiKey", value: schluessel)]
            }
            guard let adresse = teile.url else { return nil }
            return Untertiteldatei(index: index, adresse: adresse, merkmal: merkmal(adresse))
        }
    }
}

/// Welche Spur im Abspieler welcher `MediaStream` des Servers ist.
///
/// **Über die Reihenfolge je Art, mit Gegenprobe** (Audit 16.09., T3 #6).
/// Server und libVLC zählen die Spuren einer Datei in Dateireihenfolge auf.
/// Stimmen Anzahl, Sprache und Codec paarweise, gilt die Position. Weicht die
/// Anzahl ab — libVLC lässt Spuren weg, die es nicht lesen kann —, wird nur
/// zugeordnet, was sich an Sprache oder Codec belegen lässt; der Rest bleibt
/// `nil`, statt geraten.
///
/// Nachgeladene Untertiteldateien zählen getrennt: sie werden über den MD5
/// ihrer Adresse erkannt (wie Swiftfin), sonst über die Reihenfolge.
///
/// Vorher ging alles über den Spurnamen, und zwei Spuren namens „Deutsch"
/// waren nicht zu unterscheiden (T1-N4).
public struct Spurzuordnung: Sendable, Equatable {
    /// Jellyfin-Index je Position in der Tonspurliste des Abspielers.
    public let ton: [Int?]
    /// Jellyfin-Index je Position in der Untertitelliste des Abspielers.
    public let untertitel: [Int?]

    public init(ton: [Int?] = [], untertitel: [Int?] = []) {
        self.ton = ton; self.untertitel = untertitel
    }

    public static func bilden(ton: [Abspielerspur], untertitel: [Abspielerspur],
                              stroeme: [MediaStream], dateien: [Untertiteldatei]) -> Spurzuordnung {
        let tonstroeme = stroeme.filter { $0.type == "Audio" && $0.isExternal != true }
        let tonIndizes = ordnen(ton, tonstroeme)

        var utIndizes = [Int?](repeating: nil, count: untertitel.count)
        // Nachgeladene zuerst: sie dürfen beim Abzählen der eingebetteten
        // nicht mitzählen.
        var offen = dateien
        var ohneMerkmal: [Int] = []
        for (position, spur) in untertitel.enumerated() {
            guard let zusatz = spur.zusatzkennung else { continue }
            if let treffer = offen.firstIndex(where: { $0.merkmal?.lowercased() == zusatz.lowercased() }) {
                utIndizes[position] = offen.remove(at: treffer).index
            } else {
                ohneMerkmal.append(position)
            }
        }
        // Ohne Merkmal nur, wenn es aufgeht — eine Datei, die nicht geladen
        // wurde, verschöbe sonst alle folgenden.
        if !ohneMerkmal.isEmpty, ohneMerkmal.count == offen.count {
            for (position, datei) in zip(ohneMerkmal, offen) { utIndizes[position] = datei.index }
        }

        let eingebettetePositionen = untertitel.indices.filter {
            untertitel[$0].zusatzkennung == nil && !untertitel[$0].istUntertitelAusBild
        }
        let utStroeme = stroeme.filter { $0.type == "Subtitle" && $0.isExternal != true }
        let eingebettet = ordnen(eingebettetePositionen.map { untertitel[$0] }, utStroeme)
        for (i, position) in eingebettetePositionen.enumerated() { utIndizes[position] = eingebettet[i] }

        return Spurzuordnung(ton: tonIndizes, untertitel: utIndizes)
    }

    public func tonposition(index: Int) -> Int? { ton.firstIndex(of: index) }
    public func untertitelposition(index: Int) -> Int? { untertitel.firstIndex(of: index) }

    /// Eine Liste einer Art: Position, wenn alles zusammenpasst, sonst nur,
    /// was sich belegen lässt.
    static func ordnen(_ spuren: [Abspielerspur], _ stroeme: [MediaStream]) -> [Int?] {
        if spuren.count == stroeme.count,
           zip(spuren, stroeme).allSatisfy({ vertraeglich($0, $1) }) {
            return stroeme.map(\.index)
        }
        var ab = 0
        return spuren.map { spur in
            guard let treffer = stroeme.indices.dropFirst(ab).first(where: {
                vertraeglich(spur, stroeme[$0]) && belegt(spur, stroeme[$0])
            }) else { return nil }
            ab = treffer + 1
            return stroeme[treffer].index
        }
    }

    /// Nichts spricht dagegen: Sprache und Codec widersprechen sich nicht,
    /// wo beide Seiten sie kennen.
    static func vertraeglich(_ spur: Abspielerspur, _ strom: MediaStream) -> Bool {
        if let a = sprache(spur.sprache), let b = sprache(strom.language), a != b { return false }
        if let a = spur.codec, let b = Technikangaben.codecname(strom.codec), a != b { return false }
        return true
    }

    /// Etwas spricht dafür: dieselbe Sprache oder derselbe Codec.
    static func belegt(_ spur: Abspielerspur, _ strom: MediaStream) -> Bool {
        if let a = sprache(spur.sprache), a == sprache(strom.language) { return true }
        if let a = spur.codec, a == Technikangaben.codecname(strom.codec) { return true }
        return false
    }

    /// Nur Sprachen, die sich sicher erkennen lassen, zählen als Widerspruch
    /// — „pol" gegen „Polish" wäre sonst einer.
    static func sprache(_ roh: String?) -> String? {
        guard let roh, !roh.isEmpty else { return nil }
        return Sprache.erkannt(in: roh)
    }
}

/// Was die nächste Folge an einer Spur wiedererkennen soll.
///
/// **Ähnlichkeit statt Name** (Audit 16.09., T3 #6, wie jellyfin-web und
/// Streamyfin): die Sprache muss stimmen, danach entscheiden Titel,
/// erzwungen, Codec, Position und Kanäle. So trifft „Deutsch voll" in der
/// nächsten Folge nicht „Deutsch erzwungen", auch wenn beide gleich heißen.
public struct Spurabdruck: Codable, Sendable, Equatable {
    public var sprache: String?
    public var codec: String?
    public var titel: String?
    public var erzwungen: Bool
    public var kanaele: Int?
    /// Position unter den Spuren derselben Art beim Server.
    public var position: Int?
    public var extern: Bool
    /// Spurname im Abspieler, nur zur Auskunft.
    public var name: String?

    public init(sprache: String?, codec: String?, titel: String?, erzwungen: Bool,
                kanaele: Int?, position: Int?, extern: Bool, name: String?) {
        self.sprache = sprache; self.codec = codec; self.titel = titel
        self.erzwungen = erzwungen; self.kanaele = kanaele; self.position = position
        self.extern = extern; self.name = name
    }

    /// Aus einem Server-Strom.
    public init(strom: MediaStream, in stroeme: [MediaStream], name: String? = nil) {
        let art = stroeme.filter { $0.type == strom.type }
        self.init(sprache: strom.language, codec: strom.codec, titel: strom.title,
                  erzwungen: strom.isForced == true,
                  kanaele: strom.type == "Audio" ? strom.channels : nil,
                  position: art.firstIndex(of: strom), extern: strom.isExternal == true,
                  name: name)
    }

    /// Aus einer Abspielerspur, die sich keinem Strom zuordnen ließ.
    public init(spur: Abspielerspur) {
        self.init(sprache: spur.sprache, codec: nil, titel: nil,
                  erzwungen: Sprache.klingtErzwungen(spur.name),
                  kanaele: spur.kanaele, position: nil, extern: spur.zusatzkennung != nil,
                  name: spur.name)
    }

    /// Der Strom, der dem Abdruck am nächsten kommt — oder `nil`.
    ///
    /// Ist eine Sprache gemerkt, muss sie stimmen: Englisch ist kein Ersatz
    /// für Deutsch, auch wenn Codec und Position passen.
    public func bester(unter stroeme: [MediaStream], art: String) -> MediaStream? {
        let kandidaten = stroeme.filter { $0.type == art }
        let gemerkteSprache = Self.sprachschluessel(sprache)
        var bester: (strom: MediaStream, punkte: Int)?
        for (position, strom) in kandidaten.enumerated() {
            if let gemerkteSprache, Self.sprachschluessel(strom.language) != gemerkteSprache { continue }
            var punkte = gemerkteSprache == nil ? 0 : 3
            if let titel, !titel.isEmpty, titel == strom.title { punkte += 2 }
            if erzwungen == (strom.isForced == true) { punkte += 2 }
            if let codec, Technikangaben.codecname(codec) == Technikangaben.codecname(strom.codec) { punkte += 1 }
            if position == self.position { punkte += 1 }
            if let kanaele, kanaele == strom.channels { punkte += 1 }
            if extern == (strom.isExternal == true) { punkte += 1 }
            if bester == nil || punkte > bester!.punkte { bester = (strom, punkte) }
        }
        // Ohne Sprache reicht ein zufälliges Zusammentreffen nicht.
        guard let bester, bester.punkte >= 3 else { return nil }
        return bester.strom
    }

    /// `ger`, `deu` und „German" sind dieselbe Sprache.
    static func sprachschluessel(_ roh: String?) -> String? {
        guard let roh, !roh.isEmpty, !["und", "unknown", "mis", "zxx"].contains(roh.lowercased())
        else { return nil }
        return Sprache.erkannt(in: roh) ?? roh.lowercased()
    }
}
