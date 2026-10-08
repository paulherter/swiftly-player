import Foundation

/// Ein Kapitel eines Films oder einer Folge — so, wie es in der Datei steht.
///
/// Kommt aus `/Items/{id}` mit `Fields=Chapters`, als `ChapterInfo`: der
/// Anfang in Ticks und ein Name. **Ein Ende gibt es nicht** — ein Kapitel
/// reicht bis zum Anfang des nächsten, das letzte bis zum Dateiende.
///
/// **Nicht zu verwechseln mit ``Abschnitt``.** Abschnitte sagt die Analyse
/// des Servers an (Vorspann, Abspann) und sie haben einen Knopf; Kapitel
/// stehen in der Datei selbst, und sie gliedern die Leiste. Beide können an
/// derselben Stelle liegen, gemeint ist trotzdem etwas anderes.
///
/// Die Feldnamen stammen aus der OpenAPI-Beschreibung (`ChapterInfo`).
public struct Kapitel: Sendable, Equatable, Decodable {
    /// Wie der Server es nennt. Unbenannte und als Zeit benannte Kapitel
    /// („00:05:00.000") heissen dort schon „Kapitel 3" — in der Sprache des
    /// Servers, nicht des Geräts. Leer nur, wenn gar nichts kam.
    public let name: String
    /// Sekunden, nicht Ticks — umgerechnet beim Einlesen.
    public let von: Double

    public init(name: String, von: Double) {
        self.name = name
        self.von = von
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case vonTicks = "StartPositionTicks"
    }

    /// **Ein Kapitel ohne Anfang ist keins.** Fehlt `StartPositionTicks`,
    /// wirft das Einlesen — und ``KapitelAntwort`` lässt genau dieses eine weg, nicht
    /// die ganze Liste. Ein Kapitel, das stillschweigend bei 0 anfinge, läge
    /// sonst über dem ersten.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        von = Double(try c.decode(Int64.self, forKey: .vonTicks)) / 10_000_000
    }
}

/// Der Teil einer Titelantwort, der die Kapitel trägt.
public struct KapitelAntwort: Sendable, Decodable {
    public let kapitel: [Kapitel]

    enum CodingKeys: String, CodingKey { case kapitel = "Chapters" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kapitel = try c.decodeIfPresent(Nachsichtig<Kapitel>.self, forKey: .kapitel)?.werte ?? []
    }
}

// MARK: - Die geteilte Leiste

/// **Die Zeitleiste, an den Kapitelgrenzen geteilt.**
///
/// Eine Leiste in Stücken sagt, bevor man greift, wie der Film gebaut ist —
/// und beim Spulen hebt sich das Stück, in dem der Griff gerade steht. Welche
/// Kapitel dafür taugen und wo die Schnitte liegen, gehört ins Paket: drei
/// Leisten zeichnen dieselben Stücke, und gerade das Weglassen zu enger
/// Schnitte ist die Sorte Regel, die sonst je Plattform anders ausfällt.
///
/// **Ohne Kapitel ist die Leiste ein einziges Stück** — und sieht aus wie
/// vorher.
public enum Kapitelleiste {

    /// Ein Stück der Leiste, als Anteil der Laufzeit (0…1).
    public struct Stueck: Sendable, Equatable {
        public let von: Double
        public let bis: Double

        public init(von: Double, bis: Double) {
            self.von = von
            self.bis = bis
        }

        /// **Wo das Stück auf der Leiste liegt, in Punkt.**
        ///
        /// Die Lücke geht je zur Hälfte von beiden Nachbarn ab, nicht von
        /// einem: so steht die Mitte der Lücke genau auf der Kapitelgrenze,
        /// und die Zeit unter dem Griff stimmt mit dem Bild darüber. An den
        /// beiden Enden der Leiste geht nichts ab.
        public func rahmen(breite: Double, luecke: Double) -> (x: Double, breite: Double) {
            let links = von > 0 ? luecke / 2 : 0
            let rechts = bis < 1 ? luecke / 2 : 0
            let x = von * breite + links
            return (x, max(bis * breite - rechts - x, 0))
        }
    }

    /// **Die Kapitel, die die Leiste gliedern dürfen** — sortiert, ohne
    /// doppelte Anfänge, ohne Unsinn.
    ///
    /// Was nicht im Film liegt (negativ, nicht endlich), fällt vor dem Zählen
    /// weg. Leer heisst danach: keine Gliederung. Das gilt in zwei Fällen:
    ///
    /// - **Weniger als zwei Kapitel.** Ein einziges, das bei 0 anfängt, teilt
    ///   nichts.
    /// - **Ein gleichmäßiges Raster ab 0.** Jellyfin legt für Dateien ohne
    ///   Kapitel auf Wunsch Platzhalter an (`DummyChapterDuration`), alle so
    ///   viele Sekunden eins, und ältere Fassungen taten das von sich aus.
    ///   Ihre Namen helfen nicht beim Erkennen: der Server nennt auch echte,
    ///   unbenannte Kapitel „Kapitel 3". Das Raster verrät sie — von Hand oder
    ///   von einer Scheibe gesetzte Kapitel liegen nie auf die Sekunde gleich
    ///   weit auseinander. Und selbst wenn: ein Lineal sagt nichts über den
    ///   Film.
    public static func brauchbar(_ kapitel: [Kapitel]) -> [Kapitel] {
        var gesehen = Set<Double>()
        let sortiert = kapitel
            .filter { $0.von.isFinite && $0.von >= 0 }
            .sorted { $0.von < $1.von }
            // Zwei Kapitel am selben Anfang: das erste gilt, wie bei
            // Wiedergabeprogrammen, die die Liste der Reihe nach lesen.
            .filter { gesehen.insert($0.von).inserted }
        guard sortiert.count >= 2, !istRaster(sortiert) else { return [] }
        return sortiert
    }

    /// So weit dürfen die Abstände eines Rasters auseinanderliegen. Der
    /// Server legt seine Platzhalter auf die Sekunde genau; Werkzeuge, die
    /// Kapitel „alle fünf Minuten" setzen, rücken sie oft aufs nächste
    /// Schlüsselbild, und auch das bleibt ein Lineal.
    static let rastertoleranz: Double = 0.5

    /// Ab 0, und jeder Abstand gleich dem ersten.
    static func istRaster(_ sortiert: [Kapitel]) -> Bool {
        guard sortiert.count >= 3, let erstes = sortiert.first,
              erstes.von <= rastertoleranz else { return false }
        let schritt = sortiert[1].von - erstes.von
        guard schritt > 0 else { return false }
        return zip(sortiert, sortiert.dropFirst())
            .allSatisfy { abs(($1.von - $0.von) - schritt) <= rastertoleranz }
    }

    /// **Wo geschnitten wird**, in Sekunden: jeder Kapitelanfang im Inneren
    /// der Laufzeit. Der bei 0 fällt weg (dort fängt die Leiste ohnehin an),
    /// ebenso alles ab dem Dateiende — Kapitel einer anderen Fassung, oder
    /// eine Dauer, die VLC noch nicht kennt.
    ///
    /// `kapitel` wie aus ``brauchbar(_:)`` — so liefert sie der Client.
    public static func grenzen(_ kapitel: [Kapitel], dauer: Double) -> [Double] {
        guard dauer > 0 else { return [] }
        return kapitel.map(\.von).filter { $0 > 0 && $0 < dauer }
    }

    /// **Die Stücke der Leiste.**
    ///
    /// Ein Schnitt, der ein Stück schmaler als `mindestbreite` Punkt ließe,
    /// fällt weg — das Stück davor reicht dann bis zum nächsten. Zwanzig
    /// Kapitel auf einem schmalen iPhone wären sonst ein gestrichelter Strich,
    /// auf dem man kein Stück mehr als Stück erkennt, und Stücke dünner als
    /// die Lücke dazwischen verschwinden ganz.
    ///
    /// Das betrifft nur die Zeichnung. Welches Kapitel an einer Stelle gilt,
    /// sagt weiter ``kapitel(bei:in:)``, auch wenn sein Schnitt fehlt.
    ///
    /// - Parameters:
    ///   - grenzen: die Schnitte in Sekunden (``grenzen(_:dauer:)``).
    ///   - dauer: die Laufzeit in Sekunden.
    ///   - breite: die Breite der Leiste in Punkt.
    ///   - mindestbreite: schmaler wird kein Stück, in Punkt.
    public static func stuecke(grenzen: [Double], dauer: Double, breite: Double,
                               mindestbreite: Double) -> [Stueck] {
        let ganz = [Stueck(von: 0, bis: 1)]
        guard dauer > 0, breite > 0 else { return ganz }
        let schnitte = grenzen.map { $0 / dauer }.filter { $0 > 0 && $0 < 1 }.sorted()
        var stuecke: [Stueck] = []
        var anfang = 0.0
        for schnitt in schnitte
        where (schnitt - anfang) * breite >= mindestbreite
            && (1 - schnitt) * breite >= mindestbreite {
            stuecke.append(Stueck(von: anfang, bis: schnitt))
            anfang = schnitt
        }
        stuecke.append(Stueck(von: anfang, bis: 1))
        return stuecke
    }

    /// **Woran der Regler einrastet** — die Schnitte zwischen den Stücken, in
    /// Sekunden, aber nur die mit Platz auf beiden Seiten.
    ///
    /// ``Kerbenfang`` fängt je Schnitt ``Kerbenfang/fangweite`` Punkt nach
    /// links und rechts. Liegen Schnitte enger, als zwei Fangbereiche und
    /// etwas freie Leiste dazwischen brauchen, würde der Regler nur noch von
    /// Kapitel zu Kapitel springen — dreissig Kapitel einer Scheibe auf einem
    /// iPhone im Hochformat, und man träfe keine Stelle mehr dazwischen. Ein
    /// Schnitt fängt deshalb nur, wenn beide Nachbarstücke mindestens
    /// ``fangabstand`` Fangweiten breit sind; gezeichnet wird er trotzdem.
    public static func fangschnitte(_ stuecke: [Stueck], dauer: Double, breite: Double) -> [Double] {
        guard dauer > 0, breite > 0, stuecke.count > 1 else { return [] }
        let noetig = fangabstand * Kerbenfang.fangweite / breite
        return zip(stuecke, stuecke.dropFirst())
            .filter { $0.bis - $0.von >= noetig && $1.bis - $1.von >= noetig }
            .map { $1.von * dauer }
    }

    /// Wie viele Fangweiten ein Stück breit sein muss, damit an seinen Rändern
    /// eingerastet wird: zwei für die Fangbereiche an beiden Enden, zwei für
    /// die freie Mitte.
    static let fangabstand: Double = 4

    /// Das Stück, in dem ein Anteil liegt — eine Grenze gehört zum Stück, das
    /// dort anfängt, wie ein Kapitel zu seinem Anfang.
    public static func stueck(bei anteil: Double, in stuecke: [Stueck]) -> Int? {
        guard !stuecke.isEmpty, anteil.isFinite else { return nil }
        return stuecke.lastIndex { $0.von <= anteil } ?? 0
    }

    /// **Das Kapitel an einer Stelle**, oder `nil` davor — fängt das erste
    /// Kapitel erst nach 0 an, gehört der Anfang zu keinem.
    ///
    /// `kapitel` sortiert, wie aus ``brauchbar(_:)``. Gefragt wird bei jedem
    /// Bild, solange gespult wird — deshalb hier kein zweites Sortieren.
    ///
    /// **Mit einer Millisekunde Spiel.** Rastet der Regler an einem Schnitt
    /// ein, kommt die Stelle über Anteil und Laufzeit zurück und liegt dabei
    /// oft um die letzte Stelle der Gleitkommazahl *vor* dem Kapitelanfang.
    /// Ohne Spiel nannte die Vorschau dann das Kapitel davor, während schon
    /// das richtige Stück gehoben war.
    public static func kapitel(bei stelle: Double, in kapitel: [Kapitel]) -> Kapitel? {
        guard stelle.isFinite else { return nil }
        return kapitel.last { $0.von <= stelle + spiel }
    }

    static let spiel: Double = 0.001
}
