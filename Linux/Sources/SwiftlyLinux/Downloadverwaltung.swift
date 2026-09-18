import Foundation
import JellyfinKit
import CGtk

// Auf Apple liegt `URLSession` in Foundation, hier in FoundationNetworking.
// Derselbe bedingte Import steht im Paket, aus demselben Grund.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Downloads auf Linux und Windows.**
///
/// Die Regeln stehen nicht hier. Wer als Naechstes laedt (H4), ob der Platz
/// reicht (H3), was entbehrlich ist (H6), wie die Liste gruppiert wird (H12)
/// — das alles steht als `Downloadregeln` im Paket und gilt auf allen sechs
/// Plattformen wortgleich. Hier steht nur, wie die Bytes ankommen.
///
/// **Und die kommen anders an als auf Apple.** Dort traegt
/// `URLSessionConfiguration.background` den Vorgang weiter, wenn die App
/// nicht mehr im Vordergrund ist; das System laedt selbst und weckt die App
/// zum Schluss. Unter Linux und Windows gibt es das nicht — es gibt aber auch
/// das Problem nicht, gegen das es hilft: hier beendet niemand die App, weil
/// sie in den Hintergrund geraet. Ein Fenster, das nicht sichtbar ist, laeuft
/// weiter.
///
/// Geladen wird deshalb mit einer gewoehnlichen Sitzung und einem
/// **Datenauftrag**, nicht mit `downloadTask`:
///
/// - `downloadTask` legt die Datei erst am Ende hin. Ein Abbruch bei 90 %
///   waere ein verlorener Vormittag, und die `resumeData`, mit der Apple das
///   loest, kennt swift-corelibs-foundation nicht verlaesslich.
/// - Ein Datenauftrag reicht jedes Stueck sofort durch. Wir haengen es an die
///   Datei an und wissen jederzeit, wie weit wir sind — das steht ohnehin
///   schon in `Downloadposten.geladen`.
/// - Fortgesetzt wird deshalb ueber `Range: bytes=N-`, also ueber HTTP statt
///   ueber einen undurchsichtigen Wiederaufnahmeblock. Jellyfin beantwortet
///   das mit `206`; wer mit `200` antwortet, hat die Bereichsanfrage
///   uebergangen, und dann faengt die Datei von vorn an — auch das faellt
///   hier auf, statt still das Falsche anzuhaengen.
///
/// **Ein Download nach dem anderen**, wie ueberall sonst: `Downloadregeln.
/// naechster` entscheidet, und ``takt()`` ist die einzige Stelle, die etwas
/// startet.
final class Downloadverwaltung: NSObject, @unchecked Sendable {

    /// Wird nach jeder Aenderung auf dem Hauptfaden gerufen. Die Oberflaeche
    /// haengt daran; die Verwaltung kennt kein Widget.
    var beiAenderung: (() -> Void)?

    private(set) var posten: [Downloadposten] = []

    private var client: JellyfinClient?
    private var konto: String?

    private var sitzung: URLSession!
    private var auftrag: URLSessionDataTask?
    /// Die Kennung des Postens, der gerade laeuft. Nicht aus `posten`
    /// abgeleitet: der Rueckruf kommt aus einem fremden Faden und braucht
    /// eine Antwort, die sich nicht nebenbei aendert.
    private var laufend: String?
    private var ziel: FileHandle?
    private var zielpfad: URL?
    /// Wie viel bei diesem Anlauf schon dastand. Der Fortschritt zaehlt
    /// darauf, sonst faengt der Balken beim Fortsetzen wieder bei null an.
    private var vorher: Int64 = 0
    private var zuletztGesichert = Date.distantPast

    /// H5 gilt hier nicht: ein Schreibtischrechner hat kein Mobilfunknetz,
    /// und was ein USB-Modem kostet, weiss die App nicht. Die Regel wird
    /// trotzdem befragt, damit es **eine** Stelle bleibt.
    /// **Doch, es gibt hier etwas zu messen.**
    ///
    /// Hier stand `imWLAN = true` und `nurUeberWLAN = false`, fest, mit der
    /// Begruendung, ein Schreibtischrechner haenge nie am Mobilfunk. Der
    /// Schalter in den Einstellungen wurde also gezeigt, gesichert — und
    /// gelesen hat ihn niemand. Ein Bedienelement, das eine Wirkung
    /// verspricht, die es nicht hat, ist schlechter als keins.
    ///
    /// GLib beantwortet genau diese Frage: `g_network_monitor_get_network_metered`
    /// sagt, ob die Verbindung getaktet ist — bei NetworkManager also
    /// Mobilfunk oder ein als „getaktet" markiertes WLAN.
    ///
    /// **Das ist strenger als der Mac, und der Unterschied ist bekannt.**
    /// Dort steht `pfad.usesInterfaceType(.wifi) || .wiredEthernet`
    /// (`Sources/Shared/Downloadverwaltung.swift:512`) — die Schnittstellenart,
    /// nicht die Taktung. Ein Telefon-Hotspot ist fuer den Mac damit „WLAN"
    /// und laedt trotz eingeschaltetem Schalter; hier wartet er. GLib kennt
    /// die Schnittstellenart gar nicht, und `NWPathMonitor.isExpensive` waere
    /// auf Apple die Entsprechung zu dem, was hier gemessen wird — gerufen
    /// wird es dort nirgends. **Fuer Paul zum Entscheiden:** entweder der Mac
    /// nimmt `isExpensive` dazu, oder diese Zeile wird auf „immer WLAN"
    /// zurueckgedreht. Bis dahin tut Linux, was H5 sagt, und der Mac etwas
    /// Grosszuegigeres.
    /// Nicht privat: die Ladetafel fragt sie, bevor sie den Knopf beschriftet.
    var imWLAN: Bool {
        guard let wacht = g_network_monitor_get_default() else { return true }
        return g_network_monitor_get_network_metered(wacht) == 0
    }
    var nurUeberWLAN: Bool { Wahlen.lesen().nurUeberWLAN }

    override init() {
        super.init()
        let k = URLSessionConfiguration.default
        // Ein Download darf lange dauern; was nicht lange dauern darf, ist
        // ein Server, der gar nichts sagt.
        k.timeoutIntervalForRequest = 60
        k.timeoutIntervalForResource = 60 * 60 * 24
        sitzung = URLSession(configuration: k, delegate: self, delegateQueue: nil)
        // **Hier wird nichts geladen.** Welche Titel gelten, haengt am Konto,
        // und das steht beim Start noch nicht fest — `anmelden(client:konto:)`
        // laedt.
        aufraeumenNachAbsturz()
    }

    // MARK: Konto

    func anmelden(client: JellyfinClient?, konto: String?) {
        self.client = client
        self.konto = konto
        laden()
        takt()
    }

    /// **Ein Download gehoert seinem Konto** (H11).
    ///
    /// Die Liste auf der Platte traegt die Titel **aller** Konten; gezeigt
    /// wird nur das eigene. Hier stand vorher ein ungefiltertes
    /// `Speicher.downloadsLesen()` im `init` — zwei Konten auf demselben
    /// Geraet sahen dieselben Titel und, schlimmer, denselben Fortschritt.
    /// Genau der Schaden, den H11 beschreibt, und dieselbe Lehre wie beim
    /// `Serienspeicher`.
    ///
    /// **Geloescht wird hier nichts.** Das andere Konto findet seine Titel
    /// wieder, wenn es sich anmeldet.
    private func laden() {
        guard let konto else { posten = []; return }
        posten = Speicher.downloadsLesen().filter { $0.konto == konto }
        // Was beim letzten Mal mitten im Laden war, wartet jetzt wieder.
        for i in posten.indices where posten[i].stand == .laedt {
            posten[i].stand = .wartet
        }
    }

    /// **Was beim letzten Mal mitten im Laden stand, wartet wieder.**
    ///
    /// `.laedt` auf der Platte heisst: die App ist gegangen, waehrend etwas
    /// lief. Bliebe der Stand stehen, hielte `Downloadregeln.naechster` ihn
    /// fuer einen laufenden Download und starte nie wieder etwas — H4 wuerde
    /// gegen sich selbst arbeiten.
    private func aufraeumenNachAbsturz() {
        var geaendert = false
        for i in posten.indices where posten[i].stand == .laedt {
            posten[i].stand = .wartet
            geaendert = true
        }
        if geaendert { sichern() }
    }

    // MARK: Ablage

    func datei(fuer id: String) -> URL? {
        guard let p = posten.first(where: { $0.id == id }), p.stand == .fertig else { return nil }
        let pfad = Speicher.downloadordner.appendingPathComponent(p.dateiname)
        return FileManager.default.fileExists(atPath: pfad.path) ? pfad : nil
    }

    func posten(fuer id: String) -> Downloadposten? {
        posten.first { $0.id == id }
    }

    /// **Die fremden Posten bleiben stehen** (H11). Wer nur die eigene Liste
    /// schreibt, loescht die Titel des anderen Kontos von der Platte —
    /// waehrend die Dateien liegenbleiben und niemand mehr weiss, wem sie
    /// gehoeren.
    private func sichern() {
        let meins = konto
        let fremde = Speicher.downloadsLesen().filter { $0.konto != meins }
        Speicher.downloadsSchreiben(fremde + posten)
        melden()
    }

    /// **Der Rueckruf wird auf dem Hauptfaden gelesen, nicht mitgenommen.**
    /// Ihn hier zu fassen und drueben aufzurufen hiesse, eine Funktion ueber
    /// eine Fadengrenze zu reichen, die niemand als sicher erklaert hat —
    /// und der Uebersetzer weist das zu Recht zurueck. Ueber `self` gelesen
    /// gilt, was zum Zeitpunkt des Zeichnens gilt.
    private func melden() {
        aufHauptfaden { [weak self] in self?.beiAenderung?() }
    }

    // MARK: Platz

    /// Was auf der Platte frei ist, in Bytes.
    ///
    /// `FileManager` beantwortet das auf allen drei Systemen gleich —
    /// `volumeAvailableCapacityForImportantUsageKey` gibt es allerdings nur
    /// auf Apple, deshalb der schlichtere Schluessel. Antwortet niemand,
    /// gilt der Platz als unbekannt und nicht als „null": eine Null hier
    /// hiesse, dass gar nichts mehr geladen werden darf.
    var freierPlatz: Int64 {
        let werte = try? Speicher.downloadordner
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let frei = werte?.volumeAvailableCapacity { return Int64(frei) }
        let heim = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(heim?.volumeAvailableCapacity ?? Int.max)
    }

    func auskunft(fuer bytes: Int64) -> Downloadregeln.Platzauskunft {
        Downloadregeln.platz(fuer: bytes, frei: freierPlatz, vorhanden: posten)
    }

    // MARK: Anstossen

    func anstossen(_ neu: Downloadposten, bilder: [String: URL] = [:]) {
        anstossen([neu], bilder: bilder)
    }

    func anstossen(_ viele: [Downloadposten], bilder: [String: URL] = [:]) {
        for n in viele where !posten.contains(where: { $0.id == n.id }) {
            posten.append(n)
            if let adresse = bilder[n.id] { bildSichern(n.konto, n.id, von: adresse) }
            if let sid = n.serienId, let adresse = bilder[sid] {
                bildSichern(n.konto, sid, von: adresse)
            }
        }
        sichern()
        takt()
    }

    // MARK: Die Bilder

    private static func bildweg(_ konto: String, _ kennung: String) -> URL {
        Speicher.downloadordner.appendingPathComponent("\(konto)-\(kennung).jpg")
    }

    /// Das Bild auf der Platte — oder `nil`, dann bleibt das Zeichen stehen.
    ///
    /// **Ohne Netz gibt es nur die Platte**, und genau dann wird diese Seite
    /// gebraucht. Ein Plakat, das erst vom Server geholt wird, waere in dem
    /// einen Fall weg, fuer den es Downloads gibt. Wortgleich die Ueberlegung
    /// von `Downloadverwaltung.bild(fuer:)` auf Apple.
    func bild(fuer p: Downloadposten, alsGruppe: Bool = false) -> URL? {
        let kennung = alsGruppe ? (p.serienId ?? p.id) : p.id
        let weg = Self.bildweg(p.konto, kennung)
        return FileManager.default.fileExists(atPath: weg.path) ? weg : nil
    }

    private func bildSichern(_ konto: String, _ kennung: String, von adresse: URL) {
        let ziel = Self.bildweg(konto, kennung)
        guard !FileManager.default.fileExists(atPath: ziel.path) else { return }
        try? FileManager.default.createDirectory(at: Speicher.downloadordner,
                                                 withIntermediateDirectories: true)
        Task {
            guard let (daten, _) = try? await URLSession.shared.data(from: adresse),
                  !daten.isEmpty else { return }
            try? daten.write(to: ziel, options: .atomic)
            self.melden()
        }
    }

    // MARK: Anhalten, fortsetzen, entfernen

    func anhalten(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        if laufend == id { abbrechen() }
        posten[i].stand = .angehalten
        sichern()
        takt()
    }

    func fortsetzen(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        posten[i].stand = .wartet
        posten[i].grund = nil
        sichern()
        takt()
    }

    func entfernen(_ id: String) {
        entfernen([id])
    }

    func entfernen(_ ids: [String]) {
        let weg = Set(ids)
        if let laufend, weg.contains(laufend) { abbrechen() }
        for p in posten where weg.contains(p.id) {
            try? FileManager.default.removeItem(
                at: Speicher.downloadordner.appendingPathComponent(p.dateiname))
            // Das Bild gehoert zum Posten. Bliebe es liegen, sammelte der
            // Ordner Plakate zu Titeln an, die es hier nicht mehr gibt.
            try? FileManager.default.removeItem(at: Self.bildweg(p.konto, p.id))
            // **Das Serienplakat teilen sich alle Folgen** — es geht erst mit
            // der letzten, sonst stuende die vorletzte ohne Bild da. Hier
            // ging es **nie**: die Datei blieb fuer immer im Ordner liegen,
            // eine je jemals geladener Serie. Der Mac prueft an derselben
            // Stelle (`Sources/Shared/Downloadverwaltung.swift:306-311`).
            if let sid = p.serienId,
               !posten.contains(where: { !weg.contains($0.id) && $0.serienId == sid }) {
                try? FileManager.default.removeItem(at: Self.bildweg(p.konto, sid))
            }
        }
        posten.removeAll { weg.contains($0.id) }
        sichern()
        takt()
    }

    func allesAnhalten() {
        abbrechen()
        for i in posten.indices where posten[i].stand == .laedt || posten[i].stand == .wartet {
            posten[i].stand = .angehalten
        }
        sichern()
    }

    func allesEntfernen() {
        entfernen(posten.map(\.id))
    }

    /// H9: der Server kennt den Titel nicht mehr. Die Datei bleibt.
    func nichtMehrAufDemServer(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }),
              posten[i].nochAufDemServer else { return }
        posten[i].nochAufDemServer = false
        sichern()
    }

    func gesehen(_ id: String, _ an: Bool) {
        guard let i = posten.firstIndex(where: { $0.id == id }), posten[i].gesehen != an
        else { return }
        posten[i].gesehen = an
        sichern()
    }

    /// **Was der Server inzwischen sagt** — H6 und H9.
    ///
    /// `nichtMehrAufDemServer` und `gesehen` gab es hier, aber **niemand rief
    /// sie**: beide Angaben standen fuer immer auf dem Stand des
    /// Downloadzeitpunkts. Damit rechnete H6 („welche Titel sind
    /// entbehrlich") dauerhaft mit alten Daten, und H9s leiser Hinweis
    /// erschien nie. Auf Apple laeuft derselbe Abgleich als
    /// `AppModel.downloadsNachziehen` bei jedem Erscheinen der Hauptansicht.
    ///
    /// **Hundert Kennungen je Anfrage** — dasselbe Mass, mit dem auch die
    /// Bibliotheksseiten blaettern. Bei zehn Downloads ist es eine.
    func nachziehen() {
        guard let client, !posten.isEmpty else { return }
        let ids = posten.map(\.id)
        Task.detached { [self] in
            var vorhanden: Set<String> = []
            var gesehene: Set<String> = []
            for ab in stride(from: 0, to: ids.count, by: 100) {
                let stueck = Array(ids[ab ..< min(ab + 100, ids.count)])
                guard let antwort = try? await client.items(limit: stueck.count, ids: stueck)
                else { return }
                for titel in antwort.items {
                    vorhanden.insert(titel.id)
                    if titel.istGesehen { gesehene.insert(titel.id) }
                }
            }
            let da = vorhanden, gs = gesehene
            aufHauptfaden {
                for id in self.posten.map(\.id) {
                    self.gesehen(id, gs.contains(id))
                    // **Was zurueckkommt, gibt es; was fehlt, nicht mehr.**
                    if !da.contains(id) { self.nichtMehrAufDemServer(id) }
                }
            }
        }
    }

    // MARK: Der Takt

    /// Die **einzige** Stelle, die einen Download startet.
    func takt() {
        guard laufend == nil else { return }
        guard let naechster = Downloadregeln.naechster(aus: posten, imWLAN: imWLAN,
                                                       nurUeberWLAN: nurUeberWLAN)
        else { return }
        starten(naechster)
    }

    private func starten(_ p: Downloadposten) {
        guard let client, let i = posten.firstIndex(where: { $0.id == p.id }) else { return }

        // **Der Zustand wird vor dem Warten gesetzt, nicht danach.** Die
        // Adresse kommt erst nach einem `await`; wuerde `.laedt` erst
        // dahinter gesetzt, saehe ein zweiter `takt()` in der Zwischenzeit
        // keinen laufenden Download und startete denselben Titel noch
        // einmal. H4 haengt daran. Auf Apple steht derselbe Absatz.
        posten[i].stand = .laedt
        posten[i].grund = nil
        laufend = p.id
        sichern()

        Task { [weak self] in
            guard let self else { return }
            guard let adresse = try? await client.downloadURL(itemID: p.id,
                                                              mediaSourceID: p.quelle) else {
                self.gescheitert(p.id, grund: uebersetzt("Keine Adresse vom Server."))
                return
            }
            self.auftragStarten(p, adresse: adresse)
        }
    }

    private func auftragStarten(_ p: Downloadposten, adresse: URL) {
        // In der Zwischenzeit kann der Posten entfernt oder angehalten
        // worden sein — dann faengt hier nichts mehr an.
        guard posten.first(where: { $0.id == p.id })?.stand == .laedt else { return }

        let ordner = Speicher.downloadordner
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let pfad = ordner.appendingPathComponent(p.dateiname)

        // Was schon dasteht, zaehlt — nicht, was in der Liste steht. Die
        // Liste kann aelter sein als die Datei, wenn die App weg war,
        // waehrend geschrieben wurde.
        vorher = (try? FileManager.default.attributesOfItem(atPath: pfad.path)[.size] as? Int64) ?? 0

        var anfrage = URLRequest(url: adresse)
        if vorher > 0 { anfrage.setValue("bytes=\(vorher)-", forHTTPHeaderField: "Range") }

        if !FileManager.default.fileExists(atPath: pfad.path) {
            FileManager.default.createFile(atPath: pfad.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: pfad) else {
            gescheitert(p.id, grund: uebersetzt("Die Datei ließ sich nicht anlegen."))
            return
        }
        try? handle.seekToEnd()
        ziel = handle
        zielpfad = pfad

        let a = sitzung.dataTask(with: anfrage)
        auftrag = a
        a.resume()
    }

    /// Bricht ab, was laeuft — ohne den Stand zu setzen. Wer abbricht, sagt
    /// selbst, was danach gilt.
    private func abbrechen() {
        auftrag?.cancel()
        auftrag = nil
        try? ziel?.close()
        ziel = nil
        zielpfad = nil
        laufend = nil
    }

    // MARK: Rueckmeldungen aus der Sitzung

    /// Zuletzt gemeldeter Stand je Download — siehe ``fortschritt(_:)``.
    private var gemeldet: [String: Int64] = [:]

    private func fortschritt(_ geladen: Int64) {
        guard let id = laufend, let i = posten.firstIndex(where: { $0.id == id }) else { return }

        // **Nicht jede Rueckmeldung ist eine Aenderung, die man sieht.**
        //
        // Sie kommt im Takt der ankommenden Pakete — bei einer schnellen
        // Leitung viele Male je Bild —, und `melden()` zeichnet daran haengende
        // Zeilen samt Ring neu. Das ist das Flackern, das auf Apple schon
        // einmal behoben wurde (`Sources/Shared/Downloadverwaltung.swift:405-423`).
        //
        // Ein halbes Prozent ist bei einem kleinen Ring rund ein halber
        // Bildpunkt Bogen — darunter gibt es nichts zu sehen, und der letzte
        // Schritt auf voll kommt ohnehin ueber den Abschluss.
        let grenze = max(Int64(1), posten[i].bytes / 200)
        let vorher = gemeldet[id] ?? 0
        guard geladen - vorher >= grenze || geladen < vorher else { return }
        gemeldet[id] = geladen

        posten[i].geladen = geladen

        // **Nicht bei jedem Stueck auf die Platte.** Der Fortschritt aendert
        // sich mehrmals je Sekunde; jede Aenderung zu sichern hiesse, die
        // Platte fuer eine Zahl zu beschaeftigen, die ohnehin gleich wieder
        // anders ist. Einmal je Sekunde reicht — und beim Anhalten steht
        // sie sowieso.
        let jetzt = Date()
        if jetzt.timeIntervalSince(zuletztGesichert) > 1 {
            zuletztGesichert = jetzt
            sichern()
        }
        melden()
    }

    private func abgeschlossen(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        posten[i].stand = .fertig
        posten[i].grund = nil
        // Was der Server als Groesse nannte, kann falsch gewesen sein.
        // Massgeblich ist, was dasteht.
        if let pfad = zielpfad,
           let groesse = try? FileManager.default
               .attributesOfItem(atPath: pfad.path)[.size] as? Int64 {
            posten[i].geladen = groesse
        }
        abbrechen()
        sichern()
        takt()
    }

    private func gescheitert(_ id: String, grund: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else {
            abbrechen(); takt(); return
        }
        // **Ein Abbruch ist kein Fehler.** `cancel()` meldet sich als
        // Fehler zurueck — dieselbe Rueckmeldung wie ein abgerissenes Netz.
        // Wer von Hand angehalten hat, soll aber kein rotes Wort sehen.
        if posten[i].stand == .angehalten {
            abbrechen(); takt(); return
        }
        posten[i].stand = .fehler
        posten[i].grund = grund
        abbrechen()
        sichern()
        takt()
    }
}

// MARK: - Der Faden, auf dem die Bytes ankommen

/// **Alles Weitere laeuft auf dem Hauptfaden.**
///
/// Die Rueckrufe kommen aus der Warteschlange der Sitzung. Wuerde von dort
/// aus `posten` angefasst, saehe der Hauptfaden eine Liste, die sich unter
/// ihm aendert — und GTK zeichnet aus einer Liste, die gerade umgebaut wird.
/// Deshalb geht jeder Rueckruf ueber ``aufHauptfaden``; nur das Schreiben in
/// die Datei bleibt hier, weil es niemanden sonst angeht.
extension Downloadverwaltung: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow); return
        }
        // **Eine Bereichsanfrage, die mit 200 beantwortet wird, ist keine.**
        // Der Server schickt dann von vorn. Haengten wir das an, staende ab
        // der Fortsetzstelle derselbe Anfang ein zweites Mal in der Datei —
        // und die waere still unbrauchbar. Also von vorn schreiben.
        if vorher > 0 && http.statusCode == 200 {
            aufHauptfaden { [weak self] in
                guard let self, let pfad = self.zielpfad else { return }
                try? self.ziel?.truncate(atOffset: 0)
                try? self.ziel?.seek(toOffset: 0)
                self.vorher = 0
                _ = pfad
            }
        }
        if http.statusCode >= 400 {
            let code = http.statusCode
            aufHauptfaden { [weak self] in
                guard let self, let id = self.laufend else { return }
                self.gescheitert(id, grund: String(format: uebersetzt("Der Server antwortete mit %d."), code))
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let ziel else { return }
        do {
            try ziel.write(contentsOf: data)
        } catch {
            let text = lesbarerFehler(error)
            aufHauptfaden { [weak self] in
                guard let self, let id = self.laufend else { return }
                self.gescheitert(id, grund: text)
            }
            dataTask.cancel()
            return
        }
        let stand = (try? ziel.offset()).map(Int64.init) ?? 0
        aufHauptfaden { [weak self] in self?.fortschritt(stand) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let text = error.map(lesbarerFehler)
        aufHauptfaden { [weak self] in
            guard let self, let id = self.laufend else { return }
            if let text {
                self.gescheitert(id, grund: text)
            } else {
                self.abgeschlossen(id)
            }
        }
    }
}
