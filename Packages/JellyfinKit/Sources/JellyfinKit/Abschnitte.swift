import Foundation

/// Ein markierter Abschnitt einer Folge — Vorspann, Rückblick, Abspann.
///
/// Kommt aus `/MediaSegments/{itemId}`. **Das ist seit Jellyfin 10.10 eine
/// Kernschnittstelle, kein Plugin-Endpunkt.** Das Intro-Skipper-Plugin
/// *schreibt* dort hinein, gelesen wird über den offiziellen Weg — die alten
/// plugin-eigenen Pfade (`/Episode/{id}/IntroTimestamps/v1`) antworten auf
/// 10.11 mit 404, am Server nachgemessen.
///
/// Deshalb braucht es **keine Plugin-Erkennung**: kommt eine leere Liste,
/// gibt es keine Abschnitte und damit keinen Knopf. Das fällt von selbst
/// heraus, statt über eine Abfrage „läuft das Plugin?".
///
/// Die Feldnamen stammen aus der OpenAPI-Beschreibung des Servers
/// (`MediaSegmentDto`), nicht aus einer gefüllten Antwort — auf dem
/// Prüfserver ist nichts analysiert. Geraten ist daran trotzdem nichts.
public struct Abschnitt: Sendable, Equatable, Decodable {

    public enum Art: String, Sendable, Decodable {
        case unbekannt  = "Unknown"
        case werbung    = "Commercial"
        case vorschau   = "Preview"
        case rueckblick = "Recap"
        case abspann    = "Outro"
        case vorspann   = "Intro"

        /// Ob man diesen Abschnitt überspringen will.
        ///
        /// Der Abspann nicht: dort geht es nicht zurück in die Folge, sondern
        /// weiter zur nächsten. Und „unbekannt" nicht, weil niemand weiß,
        /// was dort übersprungen würde.
        var ueberspringbar: Bool {
            switch self {
            case .vorspann, .rueckblick, .vorschau, .werbung: true
            case .abspann, .unbekannt: false
            }
        }

        public var beschriftung: String {
            switch self {
            case .vorspann:   uebersetzt("Vorspann überspringen")
            case .rueckblick: uebersetzt("Rückblick überspringen")
            case .vorschau:   uebersetzt("Vorschau überspringen")
            case .werbung:    uebersetzt("Werbung überspringen")
            case .abspann:    uebersetzt("Nächste Folge")
            case .unbekannt:  uebersetzt("Überspringen")
            }
        }
    }

    public let art: Art
    /// Sekunden, nicht Ticks — umgerechnet beim Einlesen.
    public let von: Double
    public let bis: Double

    public init(art: Art, von: Double, bis: Double) {
        self.art = art
        self.von = von
        self.bis = bis
    }

    enum CodingKeys: String, CodingKey {
        case art = "Type"
        case vonTicks = "StartTicks"
        case bisTicks = "EndTicks"
    }

    /// **Ticks sind Hundertnanosekunden.** Zehn Millionen auf die Sekunde;
    /// wer sie für Millisekunden nimmt, landet um den Faktor 10.000 daneben.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        art = try c.decodeIfPresent(Art.self, forKey: .art) ?? .unbekannt
        von = Double(try c.decodeIfPresent(Int64.self, forKey: .vonTicks) ?? 0) / 10_000_000
        bis = Double(try c.decodeIfPresent(Int64.self, forKey: .bisTicks) ?? 0) / 10_000_000
    }

    public func enthaelt(_ stelle: Double) -> Bool {
        stelle >= von && stelle < bis
    }
}

/// Die Antwortform von `/MediaSegments/{itemId}`.
public struct AbschnittsAntwort: Sendable, Decodable {
    public let items: [Abschnitt]

    enum CodingKeys: String, CodingKey { case items = "Items" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Abschnitt].self, forKey: .items) ?? []
    }
}

// MARK: - Welcher Knopf gerade gilt

/// Was der Knopf unten rechts im Player anbietet.
///
/// **Es ist derselbe Knopf.** Gestaltung und Platz kommen vom heutigen
/// „Nächste Folge"; nur Beschriftung und Zeitpunkt wechseln. Pauls
/// ausdrücklicher Wunsch, und es spart eine zweite Gestaltung.
public enum Knopfangebot: Sendable, Equatable {
    case keiner
    /// Springen — auf diese Sekunde, mit dieser Beschriftung.
    case ueberspringen(nach: Double, art: Abschnitt.Art)
    case naechsteFolge

    /// Was auf dem Knopf steht.
    public var beschriftung: String {
        switch self {
        case .keiner:                 ""
        case let .ueberspringen(_, art): art.beschriftung
        case .naechsteFolge:          uebersetzt("Nächste Folge")
        }
    }

    /// Welches Zeichen davor steht.
    ///
    /// **Zwei verschiedene, und das ist Absicht.** Überspringen führt *in*
    /// derselben Folge weiter, Weiterschalten *aus* ihr heraus. Dasselbe
    /// Zeichen für beides würde den Unterschied verwischen, und der ist der
    /// einzige, den man vor dem Druck nicht zurücknehmen kann.
    public var zeichen: String {
        switch self {
        case .keiner:          ""
        case .ueberspringen:   "forward.fill"
        case .naechsteFolge:   "forward.end.fill"
        }
    }

    public var sichtbar: Bool { self != .keiner }
}

/// Entscheidet aus Stelle, Dauer und Abschnitten, welcher Knopf gilt.
///
/// **Gehört ins Paket und nicht in die Ansichten.** Vier Plattformen zeigen
/// denselben Knopf, und das ist genau die Sorte Regel, die auseinanderläuft,
/// wenn sie niemand nachmisst — bei `Titelangaben` ist es passiert, bei
/// `Folgenende` beinahe.
///
/// **Ohne Abschnitte ändert sich nichts, auch nicht die Zeitpunkte.** Dann
/// entscheidet allein ``Folgenende/knopfZeigen(position:dauer:)`` wie bisher.
public enum Abschnittslogik {

    /// Kurz vor dem Ende eines Abschnitts wird nicht mehr angeboten.
    ///
    /// Sonst blitzt der Knopf für einen Wimpernschlag auf und ist weg, bevor
    /// der Daumen dort ist — und ein Sprung auf eine Stelle, die ohnehin
    /// gleich erreicht ist, ist keiner.
    public static let mindestrest: Double = 1.5

    public static func angebot(position: Double, dauer: Double,
                               abschnitte: [Abschnitt],
                               hatNaechsteFolge: Bool) -> Knopfangebot {

        // 1. Steht die Stelle in einem überspringbaren Abschnitt, gilt der —
        //    auch wenn daneben ein Abspann angegeben ist.
        if let hier = abschnitte.first(where: {
            $0.art.ueberspringbar && $0.enthaelt(position) && ($0.bis - position) > mindestrest
        }) {
            return .ueberspringen(nach: hier.bis, art: hier.art)
        }

        guard hatNaechsteFolge else { return .keiner }

        // 2. Gibt es eine Abspannangabe, gilt sie — und zwar allein.
        //    Nicht zusätzlich die Restzeitregel: zwei Zeitpunkte für einen
        //    Knopf hieße, dass er zweimal erscheint.
        if let abspann = abschnitte.first(where: { $0.art == .abspann }) {
            return position >= abspann.von ? .naechsteFolge : .keiner
        }

        // 3. Sonst wie bisher.
        return Folgenende.knopfZeigen(position: position, dauer: dauer)
            ? .naechsteFolge : .keiner
    }
}
