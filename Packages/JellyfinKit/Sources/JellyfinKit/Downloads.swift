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
    ///
    /// **Bei einer umgewandelten Datei eine Schaetzung** — bis sie fertig
    /// ist; dann steht hier, was auf der Platte liegt. Deshalb `var`.
    public var bytes: Int64
    /// In welcher Qualitaet geladen wird. `nil` heisst Original — so steht
    /// es in jeder Liste von vor 1.0.5, und so bleibt es lesbar.
    public let qualitaet: Downloadqualitaet?

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

    // MARK: Offline (1.0.5)
    //
    // Alle drei optional und am Ende: eine Liste von vor 1.0.5 liest sich
    // weiter, und was fehlt, holt ``Downloadregeln`` beim naechsten Kontakt
    // mit dem Server nach.

    /// Vorspann, Rueckblick, Abspann — beim Laden mitgenommen, damit
    /// „Intro ueberspringen" und die Karte „Naechste Folge" auch ohne Server
    /// kommen. `nil`: nie gefragt; leer: der Server kennt keine.
    public var abschnitte: [Abschnitt]?
    /// Wo zuletzt aufgehoert wurde, in Ticks. `nil` heisst von vorn.
    public var stelleTicks: Int64?
    /// Wann zuletzt gespielt — hier auf dem Geraet oder laut Server.
    public var zuletzt: Date?
    /// Codec der Bildspur der geladenen Datei (``MediaSource/bildcodec``).
    /// Offline gibt es keine Quelle, an der der Player XviD erkennt
    /// (``Erstbild/softwareVonAnfang(bildcodec:methode:)``). `nil`: vor
    /// dieser Angabe geladen oder umgewandelt — dann gilt die freie Wahl.
    public var bildcodec: String?

    public init(id: String, konto: String, art: Art, titel: String,
                serie: String? = nil, serienId: String? = nil,
                staffel: Int? = nil, folge: Int? = nil,
                laufzeitTicks: Int64? = nil, container: String? = nil,
                quelle: String? = nil, bytes: Int64,
                qualitaet: Downloadqualitaet? = nil,
                geladen: Int64 = 0, stand: Downloadstand = .wartet,
                grund: String? = nil, gesehen: Bool = false,
                angelegt: Date = Date(), nochAufDemServer: Bool = true,
                abschnitte: [Abschnitt]? = nil, stelleTicks: Int64? = nil,
                zuletzt: Date? = nil, bildcodec: String? = nil) {
        self.id = id; self.konto = konto; self.art = art; self.titel = titel
        self.serie = serie; self.serienId = serienId
        self.staffel = staffel; self.folge = folge
        self.laufzeitTicks = laufzeitTicks; self.container = container
        self.quelle = quelle; self.bytes = bytes
        self.qualitaet = qualitaet == .original ? nil : qualitaet
        self.geladen = geladen; self.stand = stand; self.grund = grund
        self.gesehen = gesehen; self.angelegt = angelegt
        self.nochAufDemServer = nochAufDemServer
        self.abschnitte = abschnitte; self.stelleTicks = stelleTicks
        self.zuletzt = zuletzt
        // Eine umgewandelte Datei hat den Bildcodec des Servers, nicht den des Originals.
        self.bildcodec = self.qualitaet == nil ? bildcodec : nil
    }

    /// **Der Sehstand eines Titels, wie der Server ihn kennt** — beim Anlegen
    /// eines Downloads mitgeben, damit die Liste ihn ohne Netz zeigt.
    public init(id: String, konto: String, art: Art, titel: String,
                serie: String? = nil, serienId: String? = nil,
                staffel: Int? = nil, folge: Int? = nil,
                laufzeitTicks: Int64? = nil, container: String? = nil,
                quelle: String? = nil, bytes: Int64,
                sehstand: UserItemData?, bildcodec: String? = nil) {
        self.init(id: id, konto: konto, art: art, titel: titel, serie: serie,
                  serienId: serienId, staffel: staffel, folge: folge,
                  laufzeitTicks: laufzeitTicks, container: container, quelle: quelle,
                  bytes: bytes, gesehen: sehstand?.played ?? false,
                  stelleTicks: sehstand?.playbackPositionTicks.flatMap { $0 > 0 ? $0 : nil },
                  zuletzt: sehstand?.zuletztGespielt, bildcodec: bildcodec)
    }

    /// Zwischen 0 und 1. `nil`, wenn der Server keine Groesse genannt hat —
    /// dann gibt es keinen Balken, und der Ring zeigt nur, dass es laeuft.
    public var anteil: Double? {
        guard bytes > 0 else { return nil }
        let wert = min(1, max(0, Double(geladen) / Double(bytes)))
        // **Eine Schaetzung erreicht nie ganz das Ende.** Laeuft die
        // umgewandelte Datei groesser aus als gerechnet, stuende der Ring
        // sonst lange voll da, obwohl noch geladen wird.
        return umgewandelt && stand != .fertig ? min(wert, 0.99) : wert
    }

    /// Wird die Datei vom Server umgewandelt? Dann ist ``bytes`` bis zum
    /// Ende geschaetzt.
    public var umgewandelt: Bool { qualitaet.map { !$0.istOriginal } ?? false }

    /// Die gewaehlte Qualitaet, `nil` gilt als Original.
    public var guete: Downloadqualitaet { qualitaet ?? .original }

    /// **Derselbe Posten in einer anderen Qualitaet.** Container und Groesse
    /// aendern sich mit: eine umgewandelte Datei ist Matroska, und ihre
    /// Groesse ist geschaetzt (``Downloadqualitaet/geschaetzteBytes(original:laufzeitTicks:)``).
    /// Beim Original bleibt alles, wie es der Server nennt.
    ///
    /// Gerufen wird es auf dem Posten, wie ihn der Katalog beschreibt — also
    /// mit Originalgroesse und -container; die Schaetzung rechnet von dort.
    public func inQualitaet(_ q: Downloadqualitaet) -> Downloadposten {
        Downloadposten(
            id: id, konto: konto, art: art, titel: titel, serie: serie, serienId: serienId,
            staffel: staffel, folge: folge, laufzeitTicks: laufzeitTicks,
            container: q.istOriginal ? container : Downloadqualitaet.container,
            quelle: quelle,
            bytes: q.geschaetzteBytes(original: bytes, laufzeitTicks: laufzeitTicks),
            qualitaet: q, geladen: geladen, stand: stand, grund: grund, gesehen: gesehen,
            angelegt: angelegt, nochAufDemServer: nochAufDemServer,
            abschnitte: abschnitte, stelleTicks: stelleTicks, zuletzt: zuletzt,
            bildcodec: bildcodec)
    }

    /// Ein `Item` aus dem, was hier steht — **fuer die Wiedergabe ohne Netz.**
    ///
    /// Der Player braucht ein `Item`, und offline gibt es keinen Server, der
    /// eines liefert. Alles Noetige steht ohnehin im Posten: Kennung, Titel,
    /// Laufzeit, und bei einer Folge Serie, Staffel und Nummer.
    ///
    /// **Ausdruecklich kein Ersatz fuer den Server**, sobald einer da ist:
    /// Handlung, Besetzung und Fortschritt fehlen. Fuer das Abspielen aus der
    /// Downloadliste heraus braucht es sie nicht.
    public var alsItem: Item {
        Item(id: id, name: titel,
             type: art == .folge ? "Episode" : "Movie",
             runTimeTicks: laufzeitTicks,
             seriesName: serie, indexNumber: folge,
             parentIndexNumber: staffel, seriesId: serienId)
    }

    /// Ab wo die Downloadliste abspielt: die gemerkte Stelle, sonst von vorn.
    /// Gesehenes faengt von vorn an — wie „Nochmal ansehen" online.
    public var fortsetzenAb: Double {
        guard !gesehen, let t = stelleTicks, t > 0 else { return 0 }
        return Double(t) / 10_000_000
    }

    /// **Eine Wiedergabe auf diesem Geraet vermerken** — mit oder ohne Netz.
    ///
    /// Dieselben Schwellen wie der Server (`MinResumePct` 5, `MaxResumePct`
    /// 90, Jellyfins Vorgaben): unter 5 % zaehlt nichts als Stelle, ueber 90 %
    /// gilt der Titel als gesehen und die Stelle faellt weg. Dazwischen bleibt
    /// „gesehen", wie es war — auch das haelt der Server so. So zeigt die
    /// Liste offline, was sie nach dem Wiederverbinden vom Server hoeren wird.
    public func nachWiedergabe(ticks: Int64, wann: Date) -> Downloadposten {
        var p = self
        p.zuletzt = wann
        guard let laufzeit = laufzeitTicks, laufzeit > 0 else {
            p.stelleTicks = ticks > 0 ? ticks : nil
            return p
        }
        let anteil = Double(ticks) / Double(laufzeit)
        if anteil >= Downloadregeln.gesehenAb {
            p.gesehen = true
            p.stelleTicks = nil
        } else if anteil < Downloadregeln.stelleAb {
            p.stelleTicks = nil
        } else {
            p.stelleTicks = ticks
        }
        return p
    }

    /// Der Dateiname auf der Platte. Konto und Kennung, damit zwei Konten
    /// sich nicht ins Gehege kommen (H11), und die Endung des Containers,
    /// damit VLC den Demuxer erraet — bei Matroska haengt daran
    /// `:demux=mkv_trusted`, siehe `VLCPlayer.play`.
    ///
    /// Alle drei Teile kommen vom Server und gehen durch ``Pfadteil`` —
    /// ein boeswilliger Server bekommt so keinen Pfad aus dem Ordner heraus.
    public var dateiname: String {
        let endung = Pfadteil.endung(container).map { "." + $0 } ?? ""
        return "\(Pfadteil.sicher(konto))-\(Pfadteil.sicher(id))\(endung)"
    }

    /// Der Name des Bildes auf der Platte, neben der Datei.
    public static func bildname(konto: String, kennung: String) -> String {
        "\(Pfadteil.sicher(konto))-\(Pfadteil.sicher(kennung)).jpg"
    }
}

/// **Ein Stueck Dateiname aus Serverdaten** — nie ein Weg aus dem Ordner.
///
/// Kennungen (Jellyfin-GUIDs) und Endungen bleiben, wie sie sind; alles
/// andere wird so entschaerft, dass kein `/`, `\`, `..` oder
/// Steuerzeichen im Dateinamen landet. Echte Werte aendern sich dadurch
/// nicht — bestehende Downloads werden weiter gefunden.
public enum Pfadteil {
    /// Buchstaben, Ziffern, `-` und `_` bleiben; jedes andere Zeichen wird
    /// `_`. Leer wird `_`.
    public static func sicher(_ teil: String) -> String {
        let erlaubt = teil.unicodeScalars.map { z -> Character in
            switch z {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": Character(z)
            default: "_"
            }
        }
        return erlaubt.isEmpty ? "_" : String(erlaubt)
    }

    /// Sieht das aus wie eine Jellyfin-Kennung (GUID, mit oder ohne
    /// Bindestriche)? Fuer Kennungen, die von aussen kommen — ein
    /// `swiftly://titel/<id>`-Link —, bevor sie in eine Serveradresse gehen:
    /// ein `..%2F..` darin wuerde sonst einen anderen Endpunkt treffen.
    public static func istKennung(_ text: String) -> Bool {
        (1...64).contains(text.count)
            && text.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || ("0"..."9").contains($0) || $0 == "-"
            }
    }

    /// Die Endung aus dem Container des Servers: `[a-z0-9]{1,8}`, sonst
    /// `nil` (dann ohne Endung, wie bei fehlendem Container). Eine Liste wie
    /// `mov,mp4,m4a` bleibt erlaubt, solange jedes Glied passt — so heissen
    /// schon geladene Dateien, und ein Komma fuehrt nirgendwohin.
    public static func endung(_ container: String?) -> String? {
        guard let c = container?.lowercased(), !c.isEmpty else { return nil }
        let glieder = c.split(separator: ",", omittingEmptySubsequences: false)
        let passt = glieder.allSatisfy { g in
            (1...8).contains(g.count)
                && g.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
        return passt ? c : nil
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

    /// Was der Takt mit dem Netz anfaengt.
    public enum Netzentscheid: Sendable, Equatable {
        /// Laden darf beginnen oder weiterlaufen.
        case laden
        /// Was laeuft, geht zurueck in die Reihe — es wartet auf WLAN.
        case zurueckstellen
        /// Noch nichts tun: das Netz ist nicht bekannt.
        case abwarten
    }

    /// **Solange das Netz unbekannt ist, faengt nichts an.**
    ///
    /// Die erste Meldung des Pfadbeobachters kommt erst nach dem ersten
    /// Takt. Bis dahin WLAN anzunehmen hiess: beim Start im Mobilnetz lief
    /// ein wartender Download los und wurde Millisekunden spaeter wieder
    /// gestoppt — auf Android brach das die App ab (Issue #3). Ohne
    /// „Nur ueber WLAN" spielt das Netz keine Rolle, dann gilt `laden`.
    ///
    /// `zurueckstellen` ist kein Anhalten: der Titel wartet danach, damit
    /// ihn der naechste Takt im WLAN von selbst wieder aufnimmt.
    public static func netzentscheid(imWLAN: Bool?, nurUeberWLAN: Bool) -> Netzentscheid {
        guard nurUeberWLAN else { return .laden }
        guard let imWLAN else { return .abwarten }
        return imWLAN ? .laden : .zurueckstellen
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

    /// Was der Fuss einer Ladeauswahl rechts sagt — **bevor** man drueckt.
    public enum Fussplatz: Sendable, Equatable {
        /// So viel bleibt nach dem Laden frei.
        case frei(Int64)
        /// So viel fehlt, damit es reicht — die Reserve eingerechnet.
        case zuWenig(Int64)
    }

    /// **Der Fuss sagt dasselbe wie das Blatt danach.**
    ///
    /// Ob es reicht, entscheidet ``platz(fuer:frei:vorhanden:)`` mit ``luft``
    /// als Reserve. Rechnete der Fuss ohne sie, stuende dort „Danach 0,4 GB
    /// frei", und der Knopf fuehrte trotzdem ins Blatt „Nicht genug Platz".
    /// Also zaehlt die Reserve beim Fehlbetrag mit; reicht es, steht die
    /// schlichte Differenz da, denn das ist, was das Geraet danach zeigt.
    ///
    /// Ohne Auswahl fehlt nichts: dann steht da, was jetzt frei ist — auch
    /// wenn das weniger als die Reserve ist.
    public static func fussplatz(fuer bytes: Int64, frei: Int64) -> Fussplatz {
        guard bytes > 0 else { return .frei(max(frei, 0)) }
        let uebrig = frei - bytes - luft
        return uebrig >= 0 ? .frei(frei - bytes) : .zuWenig(-uebrig)
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
    /// ``Dateiangaben/groesse(_:)`` im Dateiauszug rechnet hierüber — eine
    /// Datei darf in der Downloadliste nicht anders gemessen sein als auf
    /// der Detailseite.
    public static func groesse(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// **Wann ein Fortschritt gezeigt wird: hoechstens einmal je Sekunde.**
    ///
    /// `URLSession` meldet im Takt der Pakete. Die Grenze von einem halben
    /// Prozent allein liess bei einer schnellen Leitung fuenf und mehr neue
    /// Zahlen je Sekunde durch — die Unterzeile zitterte, statt zu zaehlen.
    /// Durch kommen immer: die erste Meldung, ein Neuanfang (weniger als
    /// vorher) und das Ende.
    public static func fortschrittZeigen(geladen: Int64, gesamt: Int64,
                                         vorher: Int64?, vergangen: TimeInterval?) -> Bool {
        guard let vorher, let vergangen else { return true }
        if geladen < vorher { return true }
        if gesamt > 0, geladen >= gesamt { return geladen != vorher }
        let schritt = max(Int64(1), gesamt / 200)
        return geladen - vorher >= schritt && vergangen >= 1
    }

    /// „0,84 von 2,31 GB" — **beide Zahlen in derselben Einheit, mit fester
    /// Stellenzahl.**
    ///
    /// ``groesse(_:)`` passt Einheit und Nachkommastellen dem Wert an: aus
    /// „845 MB" wird „1 GB", dann „1,01 GB", dann „1,1 GB". Fuer eine
    /// Angabe, die stillsteht, ist das richtig; fuer eine, die zaehlt, heisst
    /// es, dass Komma und Breite staendig wechseln. Hier gibt die Gesamtgroesse
    /// die Einheit vor, und die Stellenzahl bleibt: GB mit zwei, MB ohne.
    public static func fortschritt(geladen: Int64, von gesamt: Int64,
                                   locale: Locale = .current) -> (geladen: String, gesamt: String) {
        let (teiler, einheit, stellen): (Double, String, Int) =
            gesamt >= 1_000_000_000 ? (1e9, "GB", 2)
            : gesamt >= 1_000_000 ? (1e6, "MB", 0) : (1e3, "KB", 0)
        func zahl(_ b: Int64) -> String {
            (Double(max(b, 0)) / teiler).formatted(
                .number.precision(.fractionLength(stellen)).locale(locale))
        }
        return (zahl(min(geladen, max(gesamt, geladen))), zahl(gesamt) + " " + einheit)
    }

    /// **Welche geladene Folge der Abspielknopf nimmt.** Die erste
    /// fertige, die noch nicht gesehen ist, nach Staffel und Folge; ist
    /// alles gesehen, die erste — wie „von vorn". Laufende und wartende
    /// zaehlen nicht: sie lassen sich noch nicht abspielen.
    public static func naechsteFolge(aus posten: [Downloadposten]) -> Downloadposten? {
        let fertig = posten.filter { $0.stand == .fertig }.sorted {
            ($0.staffel ?? 0, $0.folge ?? 0, $0.id) < ($1.staffel ?? 0, $1.folge ?? 0, $1.id)
        }
        return fertig.first { !$0.gesehen } ?? fertig.first
    }

    // MARK: Offline (1.0.5)

    /// Ab diesem Anteil gilt ein Titel als gesehen — Jellyfins `MaxResumePct`.
    public static let gesehenAb = 0.9
    /// Darunter wird keine Stelle gemerkt — Jellyfins `MinResumePct`.
    public static let stelleAb = 0.05

    /// **Die naechste geladene Folge nach dieser** — fuer „Naechste Folge",
    /// wenn kein Server antwortet.
    ///
    /// Nach Staffel und Folge, nur fertige Downloads desselben Kontos und
    /// derselben Serie. Specials (Staffel 0) liegen vorn und kommen damit
    /// nach einer regulaeren Folge nie dran. **Eine Luecke wird
    /// uebersprungen**: fehlt Folge 4, ist 5 die naechste geladene — offline
    /// gibt es keine andere, und „keine" hiesse, dass der Abend endet.
    /// Ohne Folgennummer laesst sich nichts ordnen; dann gibt es keine.
    public static func folgeNach(_ id: String, aus posten: [Downloadposten]) -> Downloadposten? {
        guard let jetzt = posten.first(where: { $0.id == id }), jetzt.art == .folge,
              let serie = jetzt.serienId, let nummer = jetzt.folge else { return nil }
        let hier = (jetzt.staffel ?? 0, nummer)
        return posten
            .filter {
                $0.stand == .fertig && $0.konto == jetzt.konto && $0.serienId == serie
                    && $0.id != id && $0.folge != nil
                    && ($0.staffel ?? 0, $0.folge ?? 0) > hier
            }
            .min { ($0.staffel ?? 0, $0.folge ?? 0, $0.id) < ($1.staffel ?? 0, $1.folge ?? 0, $1.id) }
    }

    /// **Die Abschnitte eines Titels — die abgelegten zuerst.**
    ///
    /// Liegen beim Download welche ab, gelten sie sofort, ohne Anfrage: sie
    /// kamen vom selben Server, und ohne Netz — oder unterwegs, wo der Server
    /// daheim nicht antwortet — waere eine Anfrage erst nach ihrer Frist
    /// beantwortet, und der Knopf „Intro ueberspringen" kaeme zu spaet.
    /// Sonst fragt ``server``; leer heisst dort „keine" oder „nicht
    /// erreichbar", und beides heisst: kein Knopf.
    public static func abschnitte(abgelegt: [Abschnitt]?,
                                  server: @Sendable () async -> [Abschnitt]) async -> [Abschnitt] {
        if let abgelegt, !abgelegt.isEmpty { return abgelegt }
        return await server()
    }

    /// **„Naechste Folge" — online wie bisher, ohne Server die naechste
    /// geladene** (``folgeNach(_:aus:)``).
    ///
    /// Ohne Netz wird gar nicht erst gefragt. Mit Netz fragt ``server``;
    /// scheitert die Anfrage (Server daheim nicht erreichbar), gilt die
    /// geladene. Antwortet der Server „keine", bleibt es dabei — er weiss es
    /// besser als die Liste auf dem Geraet.
    public static func folgeNach(_ item: Item, aus posten: [Downloadposten], ohneNetz: Bool,
                                 server: @Sendable () async throws -> Item?) async -> Item? {
        let geladen = folgeNach(item.id, aus: posten)?.alsItem
        if ohneNetz { return geladen }
        do { return try await server() } catch { return geladen }
    }

    /// **Was der Server ueber einen geladenen Titel sagt, in den Posten.**
    ///
    /// Gesehen, Stelle und Zeitpunkt kommen vom Server — **ausser** der
    /// Posten traegt einen neueren Stand von hier, der noch nicht gemeldet
    /// ist (`zuletzt` juenger als die Angabe des Servers). Dann bleibt er;
    /// die Nachmeldung bringt ihn hin, und die naechste Abfrage bestaetigt ihn.
    public static func nachziehen(_ p: Downloadposten, sehstand: UserItemData?) -> Downloadposten {
        guard let sehstand else { return p }
        // Eine Sekunde Spiel: die Nachmeldung schreibt genau diesen Zeitpunkt
        // an den Server, und was zurueckkommt, darf gerundet sein.
        if let hier = p.zuletzt,
           hier.timeIntervalSince(sehstand.zuletztGespielt ?? .distantPast) > 1 { return p }
        var q = p
        q.gesehen = sehstand.played ?? false
        q.stelleTicks = sehstand.playbackPositionTicks.flatMap { $0 > 0 ? $0 : nil }
        q.zuletzt = sehstand.zuletztGespielt ?? p.zuletzt
        return q
    }

    /// „3 von 12 Titeln" braucht niemand — aber „12 Titel · 42,8 GB" schon.
    public static func belegung(_ posten: [Downloadposten]) -> (anzahl: Int, bytes: Int64) {
        let fertig = posten.filter { $0.stand == .fertig }
        return (fertig.count, fertig.reduce(0) { $0 + $1.bytes })
    }
}

/// **Zwischen zwei Meldungen weiterzaehlen — nie rueckwaerts.**
///
/// Gemeldet wird hoechstens einmal je Sekunde (``Downloadregeln/fortschrittZeigen(geladen:gesamt:vorher:vergangen:)``).
/// Zeigt man nur die Meldungen, springt die Zahl stueckweise; so machen es
/// die Laeden nicht: App Store und Musik zaehlen dazwischen im Tempo der
/// letzten Sekunden weiter. Genau das rechnet dieser Schaetzer — und Balken,
/// Ring und Zahl lesen alle denselben Wert, damit keiner dem anderen
/// vorauslaeuft.
///
/// Vier Regeln: (1) das Tempo ist geglaettet, ein einzelnes schnelles Paket
/// reisst es nicht hoch; (2) hoechstens anderthalb Sekunden ueber die letzte
/// Meldung hinaus, dann steht die Zahl, bis wieder etwas kommt; (3) nie
/// weniger als zuletzt gezeigt — nur ein Neuanfang (weniger als die vorige
/// Meldung) setzt zurueck; (4) **angehalten heisst stehen.** Pause, Warten,
/// Fehler, kein Netz: ``anhalten()`` friert die Zahl ein, und beim
/// Fortsetzen misst er das Tempo neu, statt ueber die Pause zu rechnen —
/// die Zahl steht, bis die echte sie einholt, und springt nicht.
public struct Fortschrittsschaetzer: Sendable {
    private var gemeldet: Int64?
    private var meldeZeit: Date?
    private var gesamt: Int64 = 0
    private var laeuft = false
    /// Byte je Sekunde, geglaettet.
    public private(set) var tempo: Double = 0
    private var gezeigt: Int64 = 0

    public init() {}

    public mutating func melden(_ geladen: Int64, gesamt: Int64, um zeit: Date) {
        self.gesamt = gesamt
        if let g = gemeldet, geladen < g {
            // Neuanfang: was vorher stand, gilt nicht mehr.
            tempo = 0
            gezeigt = geladen
        } else if laeuft, let g = gemeldet, let mz = meldeZeit {
            let dt = zeit.timeIntervalSince(mz)
            if dt > 0.05 {
                let neu = Double(geladen - g) / dt
                tempo = tempo == 0 ? neu : tempo * 0.7 + neu * 0.3
            }
        }
        gemeldet = geladen
        meldeZeit = zeit
        laeuft = true
    }

    /// Es kommen keine Byte mehr — die Zahl bleibt, wo sie steht.
    public mutating func anhalten() {
        laeuft = false
        tempo = 0
    }

    public mutating func wert(um zeit: Date) -> Int64 {
        guard let g = gemeldet, let mz = meldeZeit else { return gezeigt }
        var schaetzung = g
        if laeuft {
            let dt = min(max(zeit.timeIntervalSince(mz), 0), 1.5)
            schaetzung += Int64(tempo * dt)
        }
        if gesamt > 0 { schaetzung = min(schaetzung, gesamt) }
        gezeigt = max(gezeigt, schaetzung)
        return gezeigt
    }
}
