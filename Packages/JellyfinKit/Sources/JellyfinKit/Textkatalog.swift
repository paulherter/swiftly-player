#if !canImport(Darwin)
import Foundation
#if os(Windows)
import WinSDK
#endif

// **Warum es diese Datei gibt: auf Linux übersetzt Foundation nicht.**
//
// Gemessen am 05.09.2026 auf CachyOS gegen die ausgelieferte 1.0.0, gegen die
// installierten Bündel unter `~/.local/share/swiftly-jellyfin/`:
//
// ```
// preferredLanguages            ["en-001"]        — unabhängig von LANG
// SwiftlyLinux  localizations   ["de", "en"]
//               preferred       ["en"]
//               development     "de"
//               NSLocalizedString("Anmelden")   -> "Anmelden"     (deutsch)
// JellyfinKit   localizations   ["de", "en"]
//               preferred       ["de"]
//               development     "en"
//               NSLocalizedString("Zuletzt")    -> "Recent"       (englisch)
// ```
//
// Zwei Dinge stehen damit fest. Erstens hält sich `NSLocalizedString` nicht an
// `preferredLocalizations`, sondern nimmt die **Entwicklungssprache** des
// Bündels — auf Linux gibt es keine Apple-Spracheinstellung, aus der CFBundle
// wählen könnte. Zweitens laufen die beiden Bündel deshalb auseinander: die
// Oberfläche steht immer auf Deutsch (`defaultLocalization: "de"`), die Texte
// des Pakets immer auf Englisch (`defaultLocalization: "en"`). Jeder Nutzer
// bekommt also **beide** Sprachen gleichzeitig, und keiner die seine.
//
// Was nachweislich trägt, ist der Weg über die Datei selbst:
// `url(forResource:withExtension:subdirectory:localization:)` liefert die
// richtige `.lproj`, und `NSDictionary(contentsOf:)` liest sie vollständig.
// Also wird hier nachgeschlagen, statt es Foundation zu überlassen.
//
// **Und noch ein Grund, `NSLocalizedString` zu meiden: es stürzt ab.** Liegt
// neben der `Localizable.strings` eine `Localizable.stringsdict` — im Paket
// tut sie das —, dann segfaultet der Aufruf für jeden Schlüssel, der in der
// stringsdict steht, in `Bundle.localizedString(forKey:value:table:)` beim
// Überbrücken des Mehrzahl-Wörterbuchs. Heute trifft uns das nicht, weil der
// Code diesen Schlüssel gar nicht erst sucht (siehe ``Textschluessel``); nach
// der Reparatur würde es das. Der eigene Weg umgeht den Absturz vollständig.

/// Ein Schlüssel für ``Textkatalog`` — der Linux-Ersatz für
/// `String.LocalizationValue`.
///
/// **Das Problem, das er löst.** Auf Apple ist der Parameter von
/// ``uebersetzt(_:)`` eine `String.LocalizationValue`; sie fängt die
/// Interpolation ab und macht aus `uebersetzt("Staffel \(3)")` den Schlüssel
/// `"Staffel %lld"` mit dem Argument `3`. Auf Linux stand dort bisher ein
/// schlichter `String` — die Interpolation lief also sofort, gesucht wurde
/// `"Staffel 3"`, und das steht in keinem Katalog. Gemessen:
///
/// ```
/// gesucht "Staffel 3"              -> "Staffel 3"     (nicht gefunden)
/// Katalogschlüssel "Staffel %lld"  -> "Season %lld"   (da wäre er)
/// ```
///
/// **Damit waren auf Linux alle 21 Stellen mit Interpolation tot** — Laufzeit,
/// Staffelzahl, Restzeit, Knopfbeschriftung, sämtliche Fehlermeldungen —, und
/// zwar unabhängig davon, ob der Nachschlagweg stimmt. Dieser Typ baut
/// denselben Schlüssel wie Apple und hebt die Argumente für die Formatierung
/// auf.
///
/// Die Spezifizierer sind die von `String.LocalizationValue`: `Int` wird zu
/// `%lld`, `String` zu `%@`, `Double` zu `%lf`. Ein Typ, der hier fehlt, ist
/// **Absicht** — dann bricht der Bau, statt still einen Schlüssel zu erzeugen,
/// der von dem auf Apple abweicht.
public struct Textschluessel: ExpressibleByStringInterpolation, Sendable {

    /// Was auf Argumente wartet. Als Aufzählung statt als `[any CVarArg]`,
    /// damit der Typ `Sendable` bleibt und der Katalog global stehen darf.
    enum Argument: Sendable {
        case zahl(Int)
        case text(String)
        case kommazahl(Double)

        var alsFormatargument: any CVarArg {
            switch self {
            case let .zahl(w):      w
            case let .text(w):      w
            case let .kommazahl(w): w
            }
        }
    }

    let format: String
    let argumente: [Argument]

    /// Ein Schlüssel ohne Platzhalter — der Weg für Aufrufer, die schon einen
    /// `String` in der Hand haben (die Oberfläche formatiert selbst).
    public init(_ text: String) {
        format = text
        argumente = []
    }

    public init(stringLiteral wert: String) {
        self.init(wert)
    }

    public init(stringInterpolation: StringInterpolation) {
        format = stringInterpolation.format
        argumente = stringInterpolation.argumente
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var format = ""
        var argumente: [Argument] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        /// **Ein `%` im Literal wird verdoppelt**, genau wie bei Apple: der
        /// Schlüssel läuft am Ende durch `String(format:)`, und dort wäre ein
        /// einzelnes `%` ein Platzhalter. Im Katalog steht dann ebenfalls
        /// `%%` — heute kommt der Fall nirgends vor.
        public mutating func appendLiteral(_ literal: String) {
            format += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation(_ wert: Int) {
            format += "%lld"
            argumente.append(.zahl(wert))
        }

        public mutating func appendInterpolation(_ wert: String) {
            format += "%@"
            argumente.append(.text(wert))
        }

        public mutating func appendInterpolation(_ wert: Double) {
            format += "%lf"
            argumente.append(.kommazahl(wert))
        }
    }
}

/// Der Textkatalog eines Bündels, einmal beim Start gelesen.
///
/// Ein Bündel findet nur, was in ihm liegt — deshalb bekommt jedes Ziel seinen
/// eigenen: das Paket den seinen, die Oberfläche den ihren. Geteilt ist das
/// **Verfahren**, nicht der Inhalt; eine zweite Kopie dieser Mechanik wäre der
/// sichere Weg, dass die beiden auseinanderlaufen.
public struct Textkatalog: Sendable {

    /// Eine Mehrzahlangabe aus der `Localizable.stringsdict`, in Swift-Typen
    /// übersetzt — `NSDictionary` ist nicht `Sendable`.
    struct Mehrzahlregel: Sendable {
        /// Der Rahmen, etwa `%#@n@`.
        let format: String
        /// Variablenname → Kategorie (`one`, `other`, …) → Wortlaut.
        let variablen: [String: [String: String]]
    }

    /// Die Sprache, die es geworden ist. Für die Fehlersuche und die Probe.
    public let sprache: String
    private let eintraege: [String: String]
    private let mehrzahl: [String: Mehrzahlregel]

    // MARK: Sprachwahl

    /// Die Sprachwünsche des Nutzers, in absteigender Reihenfolge.
    ///
    /// **Aus der Umgebung, weil es sonst nichts gibt.** Linux hat keine
    /// Apple-Spracheinstellung; was der Nutzer will, steht in `LANGUAGE`,
    /// `LC_ALL`, `LC_MESSAGES` und `LANG` — in dieser Rangfolge, wie es jedes
    /// gettext-Programm auf dem System auch liest. `LANGUAGE` ist eine
    /// Doppelpunktliste („ich kann auch Englisch"), die übrigen tragen einen
    /// Wert.
    ///
    /// Aus `de_DE.UTF-8@euro` wird `de-DE`, dann `de` — beides wird versucht,
    /// damit ein Katalog mit `pt-BR` **und** einer mit `pt` gefunden wird.
    /// `C` und `POSIX` sind keine Sprachen und fallen heraus.
    ///
    /// Am Ende steht immer `en`: wer Französisch fährt, bekommt lieber die
    /// englische Fassung als eine deutsche. Fehlt auch die, bleibt der
    /// Schlüssel stehen — und der ist der deutsche Wortlaut, nie eine
    /// kryptische Kennung.
    /// Die Anzeigesprachen, die das System selbst meldet.
    ///
    /// **Nur auf Windows.** Dort setzt niemand `LANG`; die Sprache steht in
    /// den Systemeinstellungen und ist über `GetUserPreferredUILanguages` zu
    /// haben. Ohne diese Quelle bekäme jeder Windows-Nutzer Englisch — die
    /// Windows-Sitzung hat es in ihrer VM gemessen: leere Umgebung,
    /// `UICulture: en-US`, Katalogwahl `en`, auch auf einem deutschen System.
    ///
    /// **Auf Linux bleibt die Liste absichtlich leer.** Foundation meldet dort
    /// `Locale.preferredLanguages == ["en-001"]`, unabhängig von allem — genau
    /// die Falschauskunft, wegen der diese Datei überhaupt existiert. Sie hier
    /// einzuspeisen hiesse, den Fehler durch die Hintertür zurückzuholen.
    static func systemsprachen() -> [String] {
        #if os(Windows)
        var anzahl: ULONG = 0
        var zeichen: ULONG = 0
        // Erst fragen, wie gross der Puffer sein muss.
        // **Kein `.boolValue`.** Swifts WinSDK-Auflage bildet `BOOL` hier
        // bereits auf `Bool` ab; `WindowsBool` gaebe es nur bei einer
        // Rueckgabe, die der Ueberzug nicht kennt. Gemessen beim ersten
        // Uebersetzen unter Windows — sonst „value of type 'Bool' has no
        // member 'boolValue'".
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &anzahl, nil, &zeichen),
              zeichen > 0 else { return [] }
        var puffer = [WCHAR](repeating: 0, count: Int(zeichen))
        guard GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &anzahl,
                                          &puffer, &zeichen) else { return [] }
        // Doppelt nullterminierte Liste: „de-DE\0en-US\0\0".
        var namen: [String] = []
        var anfang = 0
        for (i, zeichenwert) in puffer.enumerated() where zeichenwert == 0 {
            if i > anfang {
                namen.append(String(decoding: puffer[anfang..<i], as: UTF16.self))
            }
            anfang = i + 1
        }
        return namen
        #else
        return []
        #endif
    }

    static func sprachwuensche(aus umgebung: [String: String],
                               system: [String] = []) -> [String] {
        var roh: [String] = []
        if let liste = umgebung["LANGUAGE"] {
            roh += liste.split(separator: ":").map(String.init)
        }
        for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let wert = umgebung[name] { roh.append(wert) }
        }
        // **Die Umgebung schlägt das System.** Wer `LANG` setzt, meint es —
        // das ist ein Eingriff von Hand, und der soll gewinnen. Auf Windows
        // ist die Liste normalerweise leer, dort entscheidet das System.
        roh += system

        var wuensche: [String] = []
        for eintrag in roh {
            // Codierung und Modifikator weg: `de_DE.UTF-8@euro` -> `de_DE`.
            let ohneBeiwerk = eintrag.split(separator: ".")[0].split(separator: "@")[0]
            let teile = ohneBeiwerk.split(separator: "_")
            guard let sprache = teile.first.map(String.init),
                  !sprache.isEmpty, sprache != "C", sprache != "POSIX"
            else { continue }
            if teile.count > 1 { wuensche.append("\(sprache)-\(teile[1])") }
            wuensche.append(sprache)
        }
        wuensche.append("en")

        // Reihenfolge behalten, Wiederholungen raus.
        var gesehen = Set<String>()
        return wuensche.filter { gesehen.insert($0).inserted }
    }

    // MARK: Lesen

    public init(bundle: Bundle) {
        let vorhanden = Set(bundle.localizations)
        // **Eine lokale Konstante, kein `self.sprache`.** Die Hilfsfunktion
        // unten liest sie; griffe sie über `self` darauf zu, verlangte der
        // Compiler die vollständige Initialisierung, bevor das erste Feld
        // steht.
        let gewaehlt = Self.sprachwuensche(aus: ProcessInfo.processInfo.environment,
                                           system: Self.systemsprachen())
            .first { vorhanden.contains($0) } ?? bundle.developmentLocalization ?? "de"
        sprache = gewaehlt

        func datei(_ endung: String) -> NSDictionary? {
            guard let url = bundle.url(forResource: "Localizable", withExtension: endung,
                                       subdirectory: nil, localization: gewaehlt)
            else { return nil }
            return NSDictionary(contentsOf: url)
        }

        eintraege = (datei("strings") as? [String: String]) ?? [:]

        var regeln: [String: Mehrzahlregel] = [:]
        if let roh = datei("stringsdict") {
            for schluessel in roh.allKeys.compactMap({ $0 as? String }) {
                guard let angabe = roh[schluessel] as? NSDictionary,
                      let format = angabe["NSStringLocalizedFormatKey"] as? String
                else { continue }
                var variablen: [String: [String: String]] = [:]
                for name in angabe.allKeys.compactMap({ $0 as? String })
                where name != "NSStringLocalizedFormatKey" {
                    guard let inner = angabe[name] as? NSDictionary else { continue }
                    var kategorien: [String: String] = [:]
                    for k in inner.allKeys.compactMap({ $0 as? String })
                    where !k.hasPrefix("NSStringFormat") {
                        if let wortlaut = inner[k] as? String { kategorien[k] = wortlaut }
                    }
                    variablen[name] = kategorien
                }
                regeln[schluessel] = Mehrzahlregel(format: format, variablen: variablen)
            }
        }
        mehrzahl = regeln
    }

    // MARK: Nachschlagen

    /// Der übersetzte Text — oder der Schlüssel, wenn nichts dasteht.
    public func text(_ schluessel: Textschluessel) -> String {
        let vorlage = mehrzahlvorlage(schluessel)
            ?? eintraege[schluessel.format]
            ?? schluessel.format
        guard !schluessel.argumente.isEmpty else { return vorlage }
        return String(format: vorlage, arguments: schluessel.argumente.map(\.alsFormatargument))
    }

    /// Die Mehrzahlform, falls der Schlüssel in der `stringsdict` steht.
    ///
    /// **Nur der Fall, den wir haben: eine Variable, eine Zahl.** Der Katalog
    /// führt genau einen solchen Eintrag (`%lld neue Folgen`). Mehrere
    /// Variablen in einem Satz kämen ohne die vollen CLDR-Regeln ohnehin nicht
    /// richtig heraus; sie fallen deshalb auf die einfache Übersetzung zurück,
    /// statt geraten zu werden.
    ///
    /// **Die Regel `n == 1` ist für Deutsch und Englisch die richtige** — und
    /// das sind die beiden Sprachen im Katalog. Kommt eine dritte dazu, deren
    /// Mehrzahl anders zählt (Französisch zählt die 0 zur Einzahl, Polnisch
    /// hat vier Formen), muss hier eine echte Kategorienwahl stehen. Bis
    /// dahin wäre sie erfundener Code für einen Fall, den es nicht gibt.
    private func mehrzahlvorlage(_ schluessel: Textschluessel) -> String? {
        guard let regel = mehrzahl[schluessel.format],
              regel.variablen.count == 1,
              let (name, kategorien) = regel.variablen.first,
              case let zahlen = schluessel.argumente.compactMap({
                  if case let .zahl(w) = $0 { w } else { nil }
              }),
              zahlen.count == 1, let zahl = zahlen.first
        else { return nil }

        guard let wortlaut = (zahl == 1 ? kategorien["one"] : nil) ?? kategorien["other"]
        else { return nil }
        return regel.format.replacingOccurrences(of: "%#@\(name)@", with: wortlaut)
    }
}
#endif
