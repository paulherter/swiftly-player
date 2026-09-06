import Foundation
import JellyfinKit
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Was tatsächlich lädt und wo es liegt.
///
/// **Die Regeln stehen nicht hier.** Wer als Nächstes dran ist, ob der Platz
/// reicht, was entbehrlich ist — das steht als `Downloadregeln` im Paket und
/// ist dort ohne Simulator nachgerechnet. Hier steht nur, was ein
/// Dateisystem und einen laufenden Prozess braucht.
///
/// **Warum eine Hintergrundsitzung und nicht `URLSession.shared`.** Eine
/// 18-GB-Datei lädt nicht in den dreissig Sekunden, die iOS einer App im
/// Hintergrund lässt. `URLSessionConfiguration.background` gibt den Vorgang
/// an einen Systemdienst ab, der weiterläuft, wenn die App längst beendet
/// ist — und die App beim Fertigwerden wieder startet. Das ist der einzige
/// Weg, der bei diesen Größen trägt.
///
/// **Und die Dateien sind von der Sicherung ausgenommen.** Vierzig Gigabyte
/// Video in ein iCloud-Backup zu schreiben wäre schon für sich verkehrt; für
/// Apple ist es ausserdem ein Ablehnungsgrund (Data Storage Guidelines):
/// wiederbeschaffbare Inhalte gehören nicht in die Sicherung. Das Merkmal
/// sitzt auf dem Ordner, nicht auf jeder Datei — sonst vergisst es die
/// nächste Ablagestelle.
@MainActor
@Observable
final class Downloadverwaltung {

    /// Die Kennung der Hintergrundsitzung. **Fest und einmalig:** iOS ordnet
    /// laufende Vorgänge daran zu, und eine neue Kennung hiesse, dass ein
    /// Neustart der App die laufenden Downloads nicht mehr wiederfindet.
    static let sitzungskennung = "de.paulherter.swiftly.downloads"

    private(set) var posten: [Downloadposten] = []
    /// Zuletzt gemessener freier Platz. Wird beim Öffnen der Seite und nach
    /// jedem fertigen Download neu geholt.
    private(set) var frei: Int64 = 0
    /// Die letzte Meldung, die eine Ansicht zeigen soll.
    var meldung: String?

    /// Ob überhaupt geladen werden darf — kommt aus den Einstellungen.
    var nurUeberWLAN = true { didSet { takt() } }

    // **`@ObservationIgnored` ist hier Pflicht, nicht Feinschliff.**
    // `@Observable` legt fuer jede gespeicherte Eigenschaft einen
    // `init`-Zugriff an, und der kommt an eine `lazy` nicht heran — der Bau
    // bricht mit „init accessors can refer only to stored properties" ab.
    // Beobachtet werden muss davon ohnehin nichts: keine Ansicht liest die
    // Sitzung, den Boten oder die laufenden Aufgaben.
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var konto: String?
    /// Von der Artikelkennung auf die laufende Aufgabe.
    @ObservationIgnored private var aufgaben: [String: URLSessionDownloadTask] = [:]
    /// Was beim Anhalten zurückkam, für die Wiederaufnahme.
    @ObservationIgnored private var fortsetzdaten: [String: Data] = [:]

    @ObservationIgnored private lazy var sitzung: URLSession = {
        let k = URLSessionConfiguration.background(withIdentifier: Self.sitzungskennung)
        // **Beides absichtlich.** `isDiscretionary` würde iOS erlauben, den
        // Download auf „gute Gelegenheit" zu verschieben — nachts, am Strom;
        // wer auf Abfahrt drückt, will jetzt laden. Und `waitsFor…` sorgt
        // dafür, dass ein Download im Funkloch wartet statt zu scheitern.
        k.isDiscretionary = false
        k.waitsForConnectivity = true
        // Wir entscheiden über Mobilfunk selbst (H5), also lässt die Sitzung
        // beides zu und wird von `darfLaden` gesteuert.
        k.allowsCellularAccess = true
        k.sessionSendsLaunchEvents = true
        return URLSession(configuration: k, delegate: melder, delegateQueue: nil)
    }()

    @ObservationIgnored private lazy var melder = Downloadmelder(
        fortschritt: { [weak self] id, geladen, gesamt in
            Task { @MainActor in self?.fortschritt(id, geladen: geladen, gesamt: gesamt) }
        },
        fertig: { [weak self] id, datei in
            // **Die Datei muss hier verschoben werden, nicht später.** iOS
            // löscht sie, sobald der Rückruf zurückkehrt — ein `Task`, der
            // sie erst auf dem Hauptfaden abholt, findet nichts mehr vor.
            let ziel = Downloadverwaltung.ordner().appendingPathComponent(datei.name)
            try? FileManager.default.removeItem(at: ziel)
            let gelungen = (try? FileManager.default.moveItem(at: datei.temp, to: ziel)) != nil
            Task { @MainActor in self?.abgeschlossen(id, gelungen: gelungen) }
        },
        gescheitert: { [weak self] id, grund, fortsetzen in
            Task { @MainActor in self?.gescheitert(id, grund: grund, fortsetzen: fortsetzen) }
        })

    // MARK: Ablage

    /// **`nonisolated`, weil der Bote sie braucht.** Er laeuft auf der
    /// Warteschlange der Sitzung, also auf einem fremden Faden, und muss die
    /// fertige Datei dort verschieben, wo iOS sie ihm hinlegt — vor dem
    /// Ruecksprung, sonst ist sie weg. Die Funktion fasst keinen Zustand an,
    /// also kostet das nichts.
    nonisolated static func ordner() -> URL {
        let f = FileManager.default
        let basis = (try? f.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        var ordner = basis.appendingPathComponent("Downloads", isDirectory: true)
        if !f.fileExists(atPath: ordner.path) {
            try? f.createDirectory(at: ordner, withIntermediateDirectories: true)
        }
        // Auf dem Ordner, nicht auf den Dateien — siehe oben.
        var werte = URLResourceValues()
        werte.isExcludedFromBackup = true
        try? ordner.setResourceValues(werte)
        return ordner
    }

    private static var verzeichnisdatei: URL {
        ordner().appendingPathComponent("liste.json")
    }

    /// Wo die Datei zu einem Titel liegt — oder `nil`, wenn sie nicht da ist.
    ///
    /// **H8.** Der Player fragt hier zuerst und merkt sonst nichts von der
    /// ganzen Sache.
    func datei(fuer id: String) -> URL? {
        guard let p = posten.first(where: { $0.id == id && $0.stand == .fertig }) else { return nil }
        let weg = Self.ordner().appendingPathComponent(p.dateiname)
        return FileManager.default.fileExists(atPath: weg.path) ? weg : nil
    }

    func posten(fuer id: String) -> Downloadposten? {
        posten.first { $0.id == id }
    }

    // MARK: Konto

    /// **H11.** Nach dem Anmelden gilt, was diesem Konto gehört — und nur das.
    func anmelden(client: JellyfinClient?, konto: String?) {
        self.client = client
        self.konto = konto
        laden()
        platzMessen()
        takt()
    }

    private func laden() {
        guard let konto,
              let roh = try? Data(contentsOf: Self.verzeichnisdatei),
              let alle = try? JSONDecoder().decode([Downloadposten].self, from: roh)
        else { posten = []; return }
        // Die Liste auf der Platte trägt die Titel **aller** Konten; gezeigt
        // wird nur das eigene. Gelöscht wird hier nichts — das andere Konto
        // findet seine Titel wieder, wenn es sich anmeldet.
        posten = alle.filter { $0.konto == konto }
        // Was beim letzten Mal mitten im Laden war, wartet jetzt wieder:
        // die Aufgabe ist mit dem Prozess gegangen.
        for i in posten.indices where posten[i].stand == .laedt {
            posten[i].stand = .wartet
        }
    }

    private func sichern() {
        guard let konto else { return }
        var alle = (try? Data(contentsOf: Self.verzeichnisdatei))
            .flatMap { try? JSONDecoder().decode([Downloadposten].self, from: $0) } ?? []
        alle.removeAll { $0.konto == konto }
        alle.append(contentsOf: posten)
        guard let roh = try? JSONEncoder().encode(alle) else { return }
        try? roh.write(to: Self.verzeichnisdatei, options: .atomic)
    }

    private func platzMessen() {
        let werte = try? Self.ordner().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        frei = Int64(werte?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Anstossen

    /// Was ein Download kosten würde — für das Blatt vor dem Start (H3).
    func auskunft(fuer bytes: Int64) -> Downloadregeln.Platzauskunft {
        platzMessen()
        return Downloadregeln.platz(fuer: bytes, frei: frei, vorhanden: posten)
    }

    /// Einen Titel in die Schlange stellen. Startet ihn, wenn er dran ist.
    func anstossen(_ neu: Downloadposten) {
        guard !posten.contains(where: { $0.id == neu.id }) else { return }
        posten.append(neu)
        sichern()
        takt()
    }

    /// Eine ganze Staffel. Der Reihe nach, nicht gleichzeitig — H4 sorgt
    /// dafür von selbst, weil immer nur einer läuft.
    func anstossen(_ viele: [Downloadposten]) {
        for p in viele where !posten.contains(where: { $0.id == p.id }) {
            posten.append(p)
        }
        sichern()
        takt()
    }

    func anhalten(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        if let aufgabe = aufgaben[id] {
            aufgabe.cancel { [weak self] daten in
                Task { @MainActor in
                    if let daten { self?.fortsetzdaten[id] = daten }
                }
            }
            aufgaben[id] = nil
        }
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
        if let aufgabe = aufgaben[id] { aufgabe.cancel(); aufgaben[id] = nil }
        fortsetzdaten[id] = nil
        if let p = posten.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(
                at: Self.ordner().appendingPathComponent(p.dateiname))
        }
        posten.removeAll { $0.id == id }
        sichern()
        platzMessen()
        takt()
    }

    func entfernen(_ ids: [String]) {
        for id in ids { entfernen(id) }
    }

    /// Alles anhalten, ohne etwas zu loeschen — H10.
    ///
    /// Das ist, was das Ausschalten des Schalters tut. Was auf der Platte
    /// liegt, bleibt liegen; was lief, wartet. Legt jemand den Schalter
    /// wieder um, geht es weiter, wo es aufgehoert hat.
    func allesAnhalten() {
        for p in posten where p.stand == .laedt || p.stand == .wartet {
            anhalten(p.id)
        }
    }

    /// H10, die andere Antwort: alles wegraeumen.
    func allesEntfernen() {
        entfernen(posten.map(\.id))
    }

    // MARK: Der Takt

    /// **Die eine Stelle, an der ein Download anfängt.**
    ///
    /// Sie wird nach jeder Änderung gerufen — angestossen, angehalten,
    /// fertig, Netzwechsel, App-Start. Dadurch gibt es keinen zweiten Weg
    /// in einen laufenden Download, und `Downloadregeln.naechster` ist die
    /// einzige Entscheidung darüber, wer dran ist.
    func takt() {
        // Kein WLAN und nur-über-WLAN: was läuft, wird angehalten. Sonst
        // liefe der Download über Mobilfunk weiter, obwohl es ausgeschaltet
        // ist — der Schalter muss auch mitten im Laden greifen.
        if !Downloadregeln.darfLaden(imWLAN: imWLAN, nurUeberWLAN: nurUeberWLAN) {
            for p in posten where p.stand == .laedt { anhalten(p.id) }
            return
        }
        guard let naechster = Downloadregeln.naechster(
            aus: posten, imWLAN: imWLAN, nurUeberWLAN: nurUeberWLAN) else { return }
        starten(naechster)
    }

    private func starten(_ p: Downloadposten) {
        guard let client, let i = posten.firstIndex(where: { $0.id == p.id }) else { return }

        // **Der Zustand wird vor dem Warten gesetzt, nicht danach.**
        // `JellyfinClient` ist ein Actor, die Adresse kommt also erst nach
        // einem `await`. Wuerde `.laedt` erst dahinter gesetzt, saehe ein
        // zweiter `takt()` in der Zwischenzeit keinen laufenden Download —
        // und startete denselben Titel ein zweites Mal. H4 haengt daran.
        posten[i].stand = .laedt
        posten[i].grund = nil
        sichern()

        let fortsetzen = fortsetzdaten[p.id]
        fortsetzdaten[p.id] = nil

        Task { [weak self] in
            guard let adresse = try? await client.downloadURL(itemID: p.id,
                                                              mediaSourceID: p.quelle) else {
                await self?.gescheitert(p.id,
                                        grund: String(localized: "Keine Adresse vom Server."),
                                        fortsetzen: nil)
                return
            }
            await self?.aufgabeStarten(p, adresse: adresse, fortsetzen: fortsetzen)
        }
    }

    private func aufgabeStarten(_ p: Downloadposten, adresse: URL, fortsetzen: Data?) {
        // In der Zwischenzeit kann der Posten entfernt oder angehalten
        // worden sein — dann faengt hier nichts mehr an.
        guard posten.first(where: { $0.id == p.id })?.stand == .laedt else { return }
        let aufgabe = fortsetzen.map { sitzung.downloadTask(withResumeData: $0) }
            ?? sitzung.downloadTask(with: adresse)
        // Der Dateiname reist mit der Aufgabe, weil der Rückruf aus dem
        // System kommt und unsere Liste dort nicht erreichbar ist.
        aufgabe.taskDescription = p.id + "\u{1F}" + p.dateiname
        aufgaben[p.id] = aufgabe
        aufgabe.resume()
    }

    // MARK: Rückmeldungen aus der Sitzung

    private func fortschritt(_ id: String, geladen: Int64, gesamt: Int64) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        posten[i].geladen = geladen
        // Sagt der Server im Katalog keine Grösse, nimmt der Balken die aus
        // der Antwort. **Nicht gesichert** — das wäre ein Schreibvorgang je
        // Fortschrittsmeldung, siehe `Downloadstand`.
        if posten[i].bytes == 0, gesamt > 0 {
            let alt = posten[i]
            posten[i] = Downloadposten(
                id: alt.id, konto: alt.konto, art: alt.art, titel: alt.titel,
                serie: alt.serie, serienId: alt.serienId,
                staffel: alt.staffel, folge: alt.folge,
                laufzeitTicks: alt.laufzeitTicks, container: alt.container,
                quelle: alt.quelle, bytes: gesamt, geladen: geladen,
                stand: alt.stand, grund: alt.grund, gesehen: alt.gesehen,
                angelegt: alt.angelegt, nochAufDemServer: alt.nochAufDemServer)
        }
    }

    private func abgeschlossen(_ id: String, gelungen: Bool) {
        aufgaben[id] = nil
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        if gelungen {
            posten[i].stand = .fertig
            posten[i].geladen = posten[i].bytes
        } else {
            posten[i].stand = .fehler
            posten[i].grund = String(localized: "Die Datei liess sich nicht ablegen.")
        }
        sichern()
        platzMessen()
        takt()
    }

    private func gescheitert(_ id: String, grund: String, fortsetzen: Data?) {
        aufgaben[id] = nil
        if let fortsetzen { fortsetzdaten[id] = fortsetzen }
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        // Ein abgebrochener Download mit Fortsetzdaten ist kein Fehler,
        // sondern eine Pause — meist der Netzwechsel. Als Fehler gezeigt,
        // stünde ein rotes Zeichen da, wo nur die U-Bahn schuld war.
        posten[i].stand = fortsetzen != nil ? .angehalten : .fehler
        posten[i].grund = fortsetzen != nil ? nil : grund
        sichern()
        takt()
    }

    // MARK: Netz

    /// Ob gerade WLAN anliegt.
    ///
    /// **Ausdrücklich keine eigene Netzüberwachung.** `NWPathMonitor` wäre
    /// die saubere Antwort, kostet aber einen dauerhaft laufenden Beobachter
    /// — und genau eine solche Dauerlast hat auf Linux einen ganzen Kern
    /// gefressen (Zeile 51 der Änderungsliste). Hier reicht die Frage im
    /// Takt, und der Takt läuft nur, wenn sich etwas ändert.
    @ObservationIgnored private var imWLANGemerkt = true
    var imWLAN: Bool {
        get { imWLANGemerkt }
        set { let alt = imWLANGemerkt; imWLANGemerkt = newValue; if alt != newValue { takt() } }
    }

    // MARK: H9 — der Titel ist vom Server verschwunden

    /// Setzt den Hinweis, ohne die Datei anzufassen.
    func nichtMehrAufDemServer(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        posten[i].nochAufDemServer = false
        sichern()
    }

    /// Nachziehen, was der Server über den Fortschritt sagt — damit H6
    /// weiss, was gesehen ist.
    func gesehen(_ id: String, _ an: Bool) {
        guard let i = posten.firstIndex(where: { $0.id == id }), posten[i].gesehen != an
        else { return }
        posten[i].gesehen = an
        sichern()
    }
}

/// Der Bote zwischen der Hintergrundsitzung und dem Hauptfaden.
///
/// **Bewusst kein `@MainActor`.** Die Rückrufe kommen aus der Warteschlange
/// der Sitzung, also von einem fremden Faden. Eine `@MainActor`-Klasse, deren
/// Methoden von dort gerufen werden, bricht unter Swift 6 ab — im Protokoll
/// steht dann nur „terminated due to signal 5", und die Ursache steht
/// nirgends. Genau so ist es beim Sperrbildschirm passiert; die Regel steht
/// in `Erfahrungen.md`. Deshalb hebt dieser Bote jeden Rückruf einzeln.
final class Downloadmelder: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    struct Fertigmeldung { let temp: URL; let name: String }

    private let aufFortschritt: @Sendable (String, Int64, Int64) -> Void
    private let aufFertig: @Sendable (String, Fertigmeldung) -> Void
    private let aufFehler: @Sendable (String, String, Data?) -> Void

    init(fortschritt: @escaping @Sendable (String, Int64, Int64) -> Void,
         fertig: @escaping @Sendable (String, Fertigmeldung) -> Void,
         gescheitert: @escaping @Sendable (String, String, Data?) -> Void) {
        self.aufFortschritt = fortschritt
        self.aufFertig = fertig
        self.aufFehler = gescheitert
    }

    /// `id\u{1F}dateiname` — beides hängt an der Aufgabe, weil der Rückruf
    /// unsere Liste nicht erreicht.
    private func teile(_ aufgabe: URLSessionTask) -> (id: String, name: String)? {
        let stuecke = (aufgabe.taskDescription ?? "").split(separator: "\u{1F}", maxSplits: 1)
        guard stuecke.count == 2 else { return nil }
        return (String(stuecke[0]), String(stuecke[1]))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = teile(downloadTask) else { return }
        aufFortschritt(t.id, totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let t = teile(downloadTask) else { return }
        // **Ein Statuscode ist kein Erfolg.** Jellyfin antwortet auf eine
        // abgelaufene Anmeldung mit 401 und einem Rumpf — und der landete
        // hier als „fertige Datei" von 40 Byte.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            aufFehler(t.id, "HTTP \(http.statusCode)", nil)
            return
        }
        aufFertig(t.id, Fertigmeldung(temp: location, name: t.name))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let fehler = error as NSError?, let t = teile(task) else { return }
        let daten = fehler.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        aufFehler(t.id, fehler.localizedDescription, daten)
    }
}
