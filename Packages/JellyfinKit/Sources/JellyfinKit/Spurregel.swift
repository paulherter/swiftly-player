import Foundation

/// Welche Ton- und Untertitelspur beim Start einer Wiedergabe an ist.
///
/// Entschieden wird über Jellyfins `MediaStream`s, nicht über die Namen im
/// Abspieler; wo die Spur im Abspieler liegt, sagt ``Spurzuordnung``.
///
/// **Ton, von oben nach unten:**
/// 1. Von Hand gewählt, für diese Serie oder diesen Film (T1-M1).
/// 2. Die Tonsprache aus den Einstellungen der App, wenn eine gesetzt ist.
/// 3. Die Vorgabe des Servers (`DefaultAudioStreamIndex`) — dort steht, was
///    im Jellyfin-Profil als Tonsprache eingestellt ist (T3 #7).
/// 4. Sonst entscheidet die Datei.
///
/// **Untertitel, von oben nach unten:**
/// 1. Von Hand gewählt, für diese Serie oder diesen Film — auch „aus". Wer in
///    einer Folge umschaltet, meint die ganze Serie.
/// 2. „Untertitel automatisch" an, und der Ton läuft nicht in der
///    Wunschsprache: die volle Spur in der Untertitelsprache.
/// 3. Die Vorgabe des Servers (`DefaultSubtitleStreamIndex`) — mit
///    „Untertitel automatisch" jede, ohne nur eine erzwungene. Ohne
///    Handwahl sind Untertitel sonst aus, und das bleibt so.
/// 4. Erzwungene Untertitel (`IsForced`), zuerst die in der Tonsprache. Die
///    sind ohne jede Einstellung an: ohne sie versteht man die Szene nicht.
/// 5. Sonst aus. **Nicht** die erste Spur, und nicht, was die Datei als
///    Vorgabe markiert: das hat VLC vorher still übernommen.
///
/// Externe Untertiteldateien zählen überall mit (T1-H4).
public enum Spurregel {

    public enum Untertitel: Equatable, Sendable {
        case aus
        /// Jellyfins `Index`.
        case strom(Int)
    }

    public static func ton(stroeme: [MediaStream], gemerkt: Spurabdruck?,
                           wunschsprache: String, serverVorgabe: Int?) -> Int? {
        let spuren = stroeme.filter { $0.type == "Audio" }
        if let gemerkt, let treffer = gemerkt.bester(unter: stroeme, art: "Audio") {
            return treffer.index
        }
        if !wunschsprache.isEmpty,
           let treffer = spuren.first(where: { Spurabdruck.sprachschluessel($0.language) == wunschsprache }) {
            return treffer.index
        }
        if let serverVorgabe, spuren.contains(where: { $0.index == serverVorgabe }) {
            return serverVorgabe
        }
        return nil
    }

    /// - Parameters:
    ///   - tonindex: die Tonspur, die läuft — ihre Sprache entscheidet, ob
    ///     automatische Untertitel nötig sind und welche erzwungenen passen.
    ///   - tonwunsch: Tonsprache aus den Einstellungen, leer heißt keine.
    ///   - wunschsprache: Untertitelsprache aus den Einstellungen.
    public static func untertitel(stroeme: [MediaStream], gemerkt: Spurgedaechtnis.Wahl?,
                                  serverVorgabe: Int?, automatisch: Bool,
                                  tonindex: Int?, tonwunsch: String,
                                  wunschsprache: String) -> Untertitel {
        let spuren = stroeme.filter { $0.type == "Subtitle" }
        let erzwungen = spuren.filter { $0.isForced == true }

        switch gemerkt {
        case .aus?:
            return .aus
        case .spur(let abdruck)?:
            if let treffer = abdruck.bester(unter: stroeme, art: "Subtitle"), let index = treffer.index {
                return .strom(index)
            }
            // Gibt es sie nicht, gilt der Normalfall statt „aus": die Wahl
            // hieß „diese Sprache", nicht „keine".
        case .name(let alt)?:
            // Vor dem 17.09.2026 gemerkt: nur der Spurname aus VLC.
            if let sprache = Sprache.erkannt(in: alt) {
                let passend = spuren.filter { Spurabdruck.sprachschluessel($0.language) == sprache }
                let willErzwungen = Sprache.klingtErzwungen(alt)
                if let treffer = passend.first(where: { ($0.isForced == true) == willErzwungen }) ?? passend.first,
                   let index = treffer.index {
                    return .strom(index)
                }
            }
        case nil:
            break
        }

        let tonsprache = stroeme.first { $0.type == "Audio" && $0.index == tonindex }
            .flatMap { Spurabdruck.sprachschluessel($0.language) }

        if automatisch, !wunschsprache.isEmpty {
            // Ohne Tonwunsch zählt die Untertitelsprache: wer Deutsch als
            // Untertitel will, braucht sie bei englischem Ton. Ist die
            // Tonsprache unbekannt, wird nichts geraten.
            let soll = tonwunsch.isEmpty ? wunschsprache : tonwunsch
            if let tonsprache, tonsprache != soll {
                let passend = spuren.filter { Spurabdruck.sprachschluessel($0.language) == wunschsprache }
                // Die volle vor der erzwungenen derselben Sprache — wer
                // Untertitel will, weil er den Ton nicht versteht, braucht alles.
                if let voll = passend.first(where: { $0.isForced != true }) ?? passend.first,
                   let index = voll.index {
                    return .strom(index)
                }
            }
        }

        if let serverVorgabe, serverVorgabe >= 0,
           let vorgabe = spuren.first(where: { $0.index == serverVorgabe }),
           automatisch || vorgabe.isForced == true {
            return .strom(serverVorgabe)
        }

        if let tonsprache,
           let passend = erzwungen.first(where: { Spurabdruck.sprachschluessel($0.language) == tonsprache }),
           let index = passend.index {
            return .strom(index)
        }
        if let index = erzwungen.first?.index { return .strom(index) }
        return .aus
    }
}

/// Die von Hand getroffene Spurwahl, je Serie oder Film, dauerhaft.
///
/// Schlüssel ist die Serie, nicht die Folge: abgeschaltet in Folge 3 heißt
/// abgeschaltet in Folge 4. Jellyfin selbst merkt sich die Wahl nur je Folge.
public struct Spurgedaechtnis {
    public enum Wahl: Equatable, Sendable {
        case aus
        case spur(Spurabdruck)
        /// Alter Eintrag: nur der Spurname.
        case name(String)
    }

    /// Derselbe Schlüssel wie bis zum 17.09.2026: dort standen Spurnamen,
    /// leer hieß „aus". Die bleiben lesbar.
    static let untertitelSchluessel = "utJeTitel"
    static let tonSchluessel = "tonJeTitel"
    private let ablage: UserDefaults

    public init(ablage: UserDefaults = .standard) { self.ablage = ablage }

    public static func titel(fuer item: Item) -> String { item.seriesId ?? item.id }

    public func untertitel(fuer titel: String) -> Wahl? { lesen(Self.untertitelSchluessel, titel) }

    public func ton(fuer titel: String) -> Spurabdruck? {
        if case .spur(let abdruck)? = lesen(Self.tonSchluessel, titel) { return abdruck }
        return nil
    }

    public func merkeUntertitel(_ wahl: Wahl, fuer titel: String) {
        schreiben(Self.untertitelSchluessel, titel, wahl)
    }

    public func merkeTon(_ abdruck: Spurabdruck, fuer titel: String) {
        schreiben(Self.tonSchluessel, titel, .spur(abdruck))
    }

    private func lesen(_ schluessel: String, _ titel: String) -> Wahl? {
        guard let roh = (ablage.dictionary(forKey: schluessel) as? [String: String])?[titel] else { return nil }
        if roh.isEmpty { return .aus }
        if roh.hasPrefix("{"),
           let abdruck = try? JSONDecoder().decode(Spurabdruck.self, from: Data(roh.utf8)) {
            return .spur(abdruck)
        }
        return .name(roh)
    }

    private func schreiben(_ schluessel: String, _ titel: String, _ wahl: Wahl) {
        var alle = (ablage.dictionary(forKey: schluessel) as? [String: String]) ?? [:]
        switch wahl {
        case .aus: alle[titel] = ""
        case .name(let name): alle[titel] = name
        case .spur(let abdruck):
            let daten = (try? JSONEncoder().encode(abdruck)) ?? Data()
            alle[titel] = String(decoding: daten, as: UTF8.self)
        }
        ablage.set(alle, forKey: schluessel)
    }
}

/// Die laufenden Spuren als Jellyfin-Index, für Start- und
/// Fortschrittsmeldung (T3 #8). Untertitel `-1` heißt „aus".
public struct Spurindizes: Sendable, Equatable {
    public var ton: Int?
    public var untertitel: Int?

    public init(ton: Int? = nil, untertitel: Int? = nil) {
        self.ton = ton; self.untertitel = untertitel
    }
}
