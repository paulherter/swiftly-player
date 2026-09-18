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

        /// Ob man diesen Abschnitt grundsätzlich überspringen will.
        ///
        /// „Unbekannt" nicht, weil niemand weiß, was dort übersprungen würde.
        /// Der Abspann steht hier mit drin, gilt aber nur, wenn danach noch
        /// etwas kommt. Das entscheidet ``Abschnittslogik``, weil es die
        /// Dateilänge braucht.
        var ueberspringbar: Bool {
            switch self {
            case .vorspann, .rueckblick, .vorschau, .werbung, .abspann: true
            case .unbekannt: false
            }
        }

        public var beschriftung: String {
            switch self {
            case .vorspann:   uebersetzt("Intro überspringen")
            case .rueckblick: uebersetzt("Rückblick überspringen")
            case .vorschau:   uebersetzt("Vorschau überspringen")
            case .werbung:    uebersetzt("Werbung überspringen")
            case .abspann:    uebersetzt("Abspann überspringen")
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
/// „Nächste Folge"; nur Beschriftung und Zeitpunkt wechseln. Die
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

    /// Kürzere Abschnitte bekommen keinen Knopf (Audit Teil 3, #14).
    ///
    /// Wie bei Jellyfin Android TV: ein Knopf, der nach zwei Sekunden schon
    /// wieder weg ist, ist kein Angebot, sondern ein Blitz im Bild.
    public static let mindestlaenge: Double = 3

    /// Wie nah ein Abspann ans Dateiende reichen muss, um als „bis zum Schluss"
    /// zu gelten (T3 #2). Die Analyse endet selten auf dem letzten Bild.
    public static let abspannToleranz: Double = 2

    /// Abschnitte, die für einen Knopf taugen.
    static func gueltig(_ abschnitte: [Abschnitt]) -> [Abschnitt] {
        abschnitte.filter { $0.bis - $0.von >= mindestlaenge }
    }

    /// Reicht der Abspann bis ans Dateiende? Dann ist „Nächste Folge" das
    /// Angebot. Sonst kommt danach noch eine Szene, und er wird übersprungen.
    static func reichtAnsEnde(_ abspann: Abschnitt, dauer: Double) -> Bool {
        // Ohne Dauer lässt sich nichts sagen. Dann lieber wie bisher.
        guard dauer > 0 else { return true }
        return abspann.bis >= dauer - abspannToleranz
    }

    public static func angebot(position: Double, dauer: Double,
                               abschnitte: [Abschnitt],
                               hatNaechsteFolge: Bool) -> Knopfangebot {
        let abschnitte = gueltig(abschnitte)

        // 1. Steht die Stelle in einem überspringbaren Abschnitt, gilt der.
        //    Ein Abspann nur, wenn danach noch etwas kommt: sonst spränge der
        //    Knopf ans Dateiende, und das ist kein Überspringen.
        if let hier = abschnitte.first(where: {
            $0.art.ueberspringbar && $0.enthaelt(position) && ($0.bis - position) > mindestrest
                && !($0.art == .abspann && reichtAnsEnde($0, dauer: dauer))
        }) {
            return .ueberspringen(nach: hier.bis, art: hier.art)
        }

        guard hatNaechsteFolge else { return .keiner }

        // 2. Gibt es eine Abspannangabe, gilt sie — und zwar allein.
        //    Nicht zusätzlich die Restzeitregel: zwei Zeitpunkte für einen
        //    Knopf hieße, dass er zweimal erscheint. Reicht der Abspann nicht
        //    bis ans Ende, kommt „Nächste Folge" nach ihm, also nach der Szene
        //    hinter dem Abspann.
        if let abspann = abschnitte.first(where: { $0.art == .abspann }) {
            let ab = reichtAnsEnde(abspann, dauer: dauer) ? abspann.von : abspann.bis
            return position >= ab ? .naechsteFolge : .keiner
        }

        // 3. Sonst wie bisher.
        return Folgenende.knopfZeigen(position: position, dauer: dauer)
            ? .naechsteFolge : .keiner
    }

    /// Ob die Karte „Nächste Folge" von selbst aufgeht (T3 #3).
    ///
    /// **Nur mit Abspann-Abschnitt vom Server, der bis ans Ende reicht**
    /// (Paul, 17.09.2026): dann ab Beginn des Abspanns. Ohne Abspann gibt es
    /// keine Karte und kein automatisches Weiter — nur den Knopf in der
    /// Steuerung. Früher ging sie dann in den letzten zehn Sekunden auf; ohne
    /// Analyse weiß aber niemand, ob dort noch Handlung ist.
    ///
    /// Kommt nach dem Abspann noch eine Szene, wird der Abspann übersprungen,
    /// und die Szene danach bekommt keine Karte: ein Countdown mitten in ihr
    /// würde sie abschneiden.
    public static func karteFaellig(position: Double, dauer: Double,
                                    abschnitte: [Abschnitt],
                                    hatNaechsteFolge: Bool) -> Bool {
        // Ohne Dauer ist nichts „am Ende" — vor dem ersten Bild steht sie auf 0.
        guard dauer > 0,
              let abspann = gueltig(abschnitte).first(where: { $0.art == .abspann }),
              reichtAnsEnde(abspann, dauer: dauer), position >= abspann.von
        else { return false }
        return angebot(position: position, dauer: dauer, abschnitte: abschnitte,
                       hatNaechsteFolge: hatNaechsteFolge) == .naechsteFolge
    }

    /// Wie lange die Füllung der Karte läuft, wenn sie an dieser Stelle aufgeht:
    /// ``Angebotsebene/countdown``, aber nie über das Dateiende hinaus.
    public static func countdown(position: Double, dauer: Double) -> Double {
        guard dauer > 0 else { return Angebotsebene.countdown }
        return min(Angebotsebene.countdown, max(dauer - position, 1))
    }
}
