import Foundation

// **Was hier liegt und was nicht.**
//
// Hier stehen die Entscheidungen, die man ohne Simulator nachrechnen kann:
// wer als Nächstes lädt, ob der Platz reicht, was entbehrlich ist, wie eine
// Liste gruppiert wird. Der eigentliche Ladevorgang — `URLSession` im
// Hintergrund, Wiederaufnahme, Ablage auf der Platte — steht in
// `Sources/Shared/Downloadverwaltung.swift`, weil er ein Dateisystem und
// einen laufenden Prozess braucht.
//
// Die Trennung ist nicht Geschmack. `Zeitannahme`, `Folgenende` und
// `Anzeigeregeln` liegen aus demselben Grund im Paket: es sind Regeln, die
// zwischen den Plattformen auseinanderlaufen, sobald sie niemand nachmisst.

/// Was ein Download gerade tut.
///
/// **Der Fortschritt steht bewusst nicht hier drin.** Ein `laedt(0.37)`
/// waere bequem, aber der Stand wird auf die Platte geschrieben, und der
/// Fortschritt aendert sich mehrmals je Sekunde — jede Aenderung waere ein
/// Schreibvorgang. Wie weit es ist, sagt `Downloadposten.geladen` gegen
/// `.bytes`; das steht daneben und wird nur beim Anhalten festgehalten.
public enum Downloadstand: String, Codable, Sendable, Equatable, CaseIterable {
    /// In der Schlange. H4: es laedt immer nur einer.
    case wartet
    /// Dieser hier ist dran.
    case laedt
    /// Von Hand angehalten, oder vom fehlenden WLAN angehalten.
    case angehalten
    case fertig
    case fehler
}

/// Ein Titel auf dem Geraet — geladen, ladend oder wartend.
///
/// **`konto` ist kein Beiwerk.** H11: die Ablage haengt an der `userID`, nicht
/// an der Artikelkennung allein. Zwei Konten auf einem Server tragen dieselben
/// Kennungen, und mit ihnen kaeme der Fortschritt des einen an den Titel des
/// anderen — genau der Schaden, den der `Serienspeicher` einmal hatte, und
/// dort steckte er nicht in den Titeln, sondern in `userData`.
public struct Downloadposten: Codable, Sendable, Equatable, Identifiable {

    public enum Art: String, Codable, Sendable, Equatable {
        case film, folge
    }

    /// Die Artikelkennung des Servers.
    public let id: String
    /// Die `userID`, der dieser Download gehoert. H11.
    public let konto: String
    public let art: Art
    public let titel: String
    /// Bei einer Folge der Name der Serie, sonst `nil`.
    public let serie: String?
    public let serienId: String?
    public let staffel: Int?
    public let folge: Int?
    public let laufzeitTicks: Int64?
    public let container: String?
    /// `mediaSourceId` — dieselbe Quelle, die der Player genommen haette.
    public let quelle: String?
    /// Was der Server als Groesse nennt. 0, wenn er keine nennt.
    public let bytes: Int64

    /// Wie viel davon schon auf der Platte liegt.
    public var geladen: Int64
    public var stand: Downloadstand
    /// Nur gesetzt, wenn `stand == .fehler`.
    public var grund: String?
    /// Fuer H6: nur Gesehenes gilt als entbehrlich.
    public var gesehen: Bool
    public var angelegt: Date
    /// H9. Faellt auf `false`, wenn der Server den Titel nicht mehr kennt —
    /// die Datei bleibt, spielbar, mit einem leisen Hinweis daneben.
    public var nochAufDemServer: Bool

    public init(id: String, konto: String, art: Art, titel: String,
                serie: String? = nil, serienId: String? = nil,
                staffel: Int? = nil, folge: Int? = nil,
                laufzeitTicks: Int64? = nil, container: String? = nil,
                quelle: String? = nil, bytes: Int64,
                geladen: Int64 = 0, stand: Downloadstand = .wartet,
                grund: String? = nil, gesehen: Bool = false,
                angelegt: Date = Date(), nochAufDemServer: Bool = true) {
        self.id = id; self.konto = konto; self.art = art; self.titel = titel
        self.serie = serie; self.serienId = serienId
        self.staffel = staffel; self.folge = folge
        self.laufzeitTicks = laufzeitTicks; self.container = container
        self.quelle = quelle; self.bytes = bytes
        self.geladen = geladen; self.stand = stand; self.grund = grund
        self.gesehen = gesehen; self.angelegt = angelegt
        self.nochAufDemServer = nochAufDemServer
    }

    /// Zwischen 0 und 1. `nil`, wenn der Server keine Groesse genannt hat —
    /// dann gibt es keinen Balken, und der Ring zeigt nur, dass es laeuft.
    public var anteil: Double? {
        guard bytes > 0 else { return nil }
        return min(1, max(0, Double(geladen) / Double(bytes)))
    }

    /// Der Dateiname auf der Platte. Konto und Kennung, damit zwei Konten
    /// sich nicht ins Gehege kommen (H11), und die Endung des Containers,
    /// damit VLC den Demuxer erraet — bei Matroska haengt daran
    /// `:demux=mkv_trusted`, siehe `VLCPlayer.play`.
    public var dateiname: String {
        let endung = (container?.lowercased()).map { "." + $0 } ?? ""
        return "\(konto)-\(id)\(endung)"
    }
}

/// Eine Zeile in der Downloadliste. H12: eine Serie ist **eine** Zeile.
public enum Downloadgruppe: Sendable, Equatable, Identifiable {
    case einzeln(Downloadposten)
    case serie(id: String, titel: String, folgen: [Downloadposten])

    public var id: String {
        switch self {
        case let .einzeln(p): p.id
        case let .serie(id, _, _): "serie-" + id
        }
    }

    public var titel: String {
        switch self {
        case let .einzeln(p): p.titel
        case let .serie(_, titel, _): titel
        }
    }

    public var bytes: Int64 {
        switch self {
        case let .einzeln(p): p.bytes
        case let .serie(_, _, f): f.reduce(0) { $0 + $1.bytes }
        }
    }

    /// Der jüngste Zugang der Gruppe — danach wird sortiert.
    public var angelegt: Date {
        switch self {
        case let .einzeln(p): p.angelegt
        case let .serie(_, _, f): f.map(\.angelegt).max() ?? .distantPast
        }
    }
}

/// Die Entscheidungen rund um Downloads, alle nachrechenbar.
public enum Downloadregeln {

    /// Wie viel Platz auf dem Geraet unangetastet bleibt: **ein Gigabyte.**
    ///
    /// Eine volle Platte ist kein Schoenheitsfehler — iOS kann dann keine
    /// Aktualisierung mehr auspacken, und die Kamera nimmt nichts mehr auf.
    /// Wer 40 GB laedt, soll nicht das Telefon damit anhalten.
    public static let luft: Int64 = 1_073_741_824

    // MARK: H4 — eins nach dem anderen

    /// Welcher Posten als Naechstes laufen soll — oder `nil`.
    ///
    /// `nil` heisst eines von dreien: es laeuft schon einer, es wartet
    /// keiner, oder es fehlt das WLAN und `nurUeberWLAN` gilt. Die drei
    /// werden absichtlich nicht unterschieden: der Aufrufer tut in allen
    /// dreien dasselbe, naemlich nichts.
    public static func naechster(aus posten: [Downloadposten],
                                 imWLAN: Bool, nurUeberWLAN: Bool) -> Downloadposten? {
        guard !posten.contains(where: { $0.stand == .laedt }) else { return nil }
        guard darfLaden(imWLAN: imWLAN, nurUeberWLAN: nurUeberWLAN) else { return nil }
        // Aelteste zuerst: wer den Download zuerst angestossen hat, bekommt
        // ihn zuerst. Bei gleichem Zeitpunkt entscheidet die Kennung, damit
        // die Reihenfolge nicht von der Sortierung des Aufrufers abhaengt.
        return posten
            .filter { $0.stand == .wartet }
            .min { ($0.angelegt, $0.id) < ($1.angelegt, $1.id) }
    }

    // MARK: H5 — Mobilfunk

    /// Darf ueberhaupt geladen werden?
    ///
    /// Ausdruecklich eine eigene Funktion und kein `&&` an der Aufrufstelle:
    /// die Frage wird an drei Stellen gestellt — beim Anstossen, beim
    /// Netzwechsel und beim Start der App —, und sie soll dreimal dieselbe
    /// Antwort geben.
    public static func darfLaden(imWLAN: Bool, nurUeberWLAN: Bool) -> Bool {
        imWLAN || !nurUeberWLAN
    }

    // MARK: H3 und H6 — Platz

    /// Was ein Download kosten wuerde und was es an Auswegen gibt.
    public struct Platzauskunft: Sendable, Equatable {
        /// Passt es ohne Aufraeumen — mit ``luft`` als Reserve?
        public let reicht: Bool
        /// Was nach dem Download frei waere. Kann negativ sein.
        public let freiDanach: Int64
        /// Gesehene Downloads, groesste zuerst. Leer, wenn es keine gibt.
        public let entbehrlich: [Downloadposten]
        /// Wie viel die zusammen belegen.
        public let entbehrlichBytes: Int64

        /// Reicht es, wenn alles Entbehrliche weg ist?
        public var reichtNachAufraeumen: Bool {
            reicht || freiDanach + entbehrlichBytes >= 0
        }
    }

    public static func platz(fuer bytes: Int64, frei: Int64,
                             vorhanden: [Downloadposten]) -> Platzauskunft {
        let uebrig = frei - bytes - luft
        let weg = entbehrlich(aus: vorhanden)
        return Platzauskunft(reicht: uebrig >= 0,
                             freiDanach: uebrig,
                             entbehrlich: weg,
                             entbehrlichBytes: weg.reduce(0) { $0 + $1.bytes })
    }

    /// Was die App zum Entfernen vorschlagen darf: **fertig geladen und
    /// gesehen**, groesste zuerst.
    ///
    /// Angefangene Downloads stehen ausdruecklich nicht dabei, auch wenn sie
    /// Platz belegen: sie wegzuraeumen, um Platz fuer einen anderen zu
    /// schaffen, waere ein Tausch, den niemand verlangt hat.
    public static func entbehrlich(aus posten: [Downloadposten]) -> [Downloadposten] {
        posten
            .filter { $0.stand == .fertig && $0.gesehen }
            .sorted { ($0.bytes, $0.id) > ($1.bytes, $1.id) }
    }

    // MARK: H12 — eine Serie ist eine Zeile

    /// Filme bleiben einzeln, Folgen derselben Serie werden zu einer Gruppe.
    /// Neueste zuerst; innerhalb einer Serie nach Staffel und Folge.
    public static func gruppiert(_ posten: [Downloadposten]) -> [Downloadgruppe] {
        var gruppen: [Downloadgruppe] = []
        var serien: [String: [Downloadposten]] = [:]
        var reihenfolge: [String] = []

        for p in posten {
            // Eine Folge ohne `serienId` kann nicht gruppiert werden und
            // steht deshalb einzeln — besser eine Zeile zu viel als eine
            // Gruppe unter dem Namen `nil`.
            guard p.art == .folge, let sid = p.serienId else {
                gruppen.append(.einzeln(p))
                continue
            }
            if serien[sid] == nil { reihenfolge.append(sid) }
            serien[sid, default: []].append(p)
        }

        for sid in reihenfolge {
            let folgen = (serien[sid] ?? []).sorted {
                ($0.staffel ?? 0, $0.folge ?? 0, $0.id) < ($1.staffel ?? 0, $1.folge ?? 0, $1.id)
            }
            let titel = folgen.first?.serie ?? folgen.first?.titel ?? ""
            gruppen.append(.serie(id: sid, titel: titel, folgen: folgen))
        }

        return gruppen.sorted { ($0.angelegt, $0.id) > ($1.angelegt, $1.id) }
    }

    // MARK: Zahlen in Worte

    /// „18,6 GB" auf Deutsch, „18.6 GB" auf Englisch.
    ///
    /// **Tausenderstufen, nicht Zweierpotenzen** (`.file`): so rechnet der
    /// Finder, so rechnen die iOS-Einstellungen, und daneben steht unsere
    /// Zahl. Eine App, die 17,3 GiB sagt, wo die Einstellungen 18,6 GB
    /// zeigen, sieht falsch aus, auch wenn sie recht hat.
    ///
    /// Nicht `Dateiangaben.groesse` benutzen: die ersetzt den Punkt fest
    /// durch ein Komma und ist damit auf Englisch falsch.
    public static func groesse(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// „3 von 12 Titeln" braucht niemand — aber „12 Titel · 42,8 GB" schon.
    public static func belegung(_ posten: [Downloadposten]) -> (anzahl: Int, bytes: Int64) {
        let fertig = posten.filter { $0.stand == .fertig }
        return (fertig.count, fertig.reduce(0) { $0 + $1.bytes })
    }
}
