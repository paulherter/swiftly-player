import Foundation
import JellyfinKit
import Network
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
    /// Die aktuelle Generation je Titel — siehe `Downloadaufgabe`.
    @ObservationIgnored private var generation: [String: Int] = [:]
    /// Weitergezählt, nie zurück. Beginnt bei der Uhrzeit, damit eine Zahl
    /// aus einem früheren Programmlauf nicht zufällig wieder gilt.
    @ObservationIgnored private var generationszaehler = Int(Date().timeIntervalSince1970 * 1000)
    /// **Der laufende Stand je Titel, einzeln beobachtbar** — siehe
    /// `Downloadfortschritt`.
    @ObservationIgnored private var live: [String: Downloadfortschritt] = [:]
    /// Solange die Aufgaben eines früheren Laufs gesucht werden, startet
    /// `takt` nichts — sonst liefe derselbe Titel zweimal.
    @ObservationIgnored private var suchtAufgaben = false

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
        fortschritt: { [weak self] t, geladen, gesamt in
            Task { @MainActor in self?.fortschritt(t, geladen: geladen, gesamt: gesamt) }
        },
        fertig: { [weak self] t, datei in
            // **Die Datei muss hier verschoben werden, nicht später.** iOS
            // löscht sie, sobald der Rückruf zurückkehrt — ein `Task`, der
            // sie erst auf dem Hauptfaden abholt, findet nichts mehr vor.
            let ziel = Downloadverwaltung.ordner().appendingPathComponent(datei.name)
            try? FileManager.default.removeItem(at: ziel)
            let gelungen = (try? FileManager.default.moveItem(at: datei.temp, to: ziel)) != nil
            Task { @MainActor in self?.abgeschlossen(t, gelungen: gelungen) }
        },
        gescheitert: { [weak self] t, grund, fortsetzen in
            Task { @MainActor in self?.gescheitert(t, grund: grund, fortsetzen: fortsetzen) }
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

    nonisolated private static var verzeichnisdatei: URL {
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

    /// Mit dem laufenden Stand — wer hier fragt, sieht den Fortschritt und
    /// zeichnet bei jeder Meldung **nur sich** neu.
    func posten(fuer id: String) -> Downloadposten? {
        posten.first { $0.id == id }.map(aktuell)
    }

    /// Ein Posten mit dem, was gerade geladen ist.
    ///
    /// **Der Fortschritt steht nicht in `posten`.** Er stand dort, und weil
    /// `@Observable` die ganze Liste als eine Eigenschaft fuehrt, zeichnete
    /// jede Meldung jede Ansicht neu, die irgendetwas aus der Liste las — die
    /// Downloadseite mit allen Zeilen, jede Folgenliste, die Leiste. Jetzt
    /// liest ihn nur, wer diese Funktion ruft, und nur fuer seinen Titel.
    func aktuell(_ p: Downloadposten) -> Downloadposten {
        guard let f = live[p.id] else { return p }
        var q = p
        q.geladen = f.geladen
        if q.bytes == 0 { q.bytes = f.gesamt }
        return q
    }

    // MARK: Untertitel für offline

    /// Wo die externen Untertitel zu einer geladenen Datei liegen.
    ///
    /// **Ein eigener Ordner, nicht daneben.** VLC lädt Untertitel, deren
    /// Name mit dem der Datei beginnt, von selbst mit — dann stünde dieselbe
    /// Spur doppelt in der Liste, einmal von VLC und einmal von uns.
    nonisolated static func untertitelordner(zur datei: URL) -> URL {
        datei.deletingLastPathComponent()
            .appendingPathComponent(datei.lastPathComponent + ".untertitel", isDirectory: true)
    }

    /// Die geladenen Untertitel einer Datei von der Platte, zum Anhängen.
    /// Dateiname ist `<Jellyfin-Index>.<Endung>`.
    nonisolated static func untertitel(zur datei: URL, merkmal: (URL) -> String?) -> [Untertiteldatei] {
        let ordner = untertitelordner(zur: datei)
        let namen = (try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []
        return namen.sorted().compactMap { name in
            guard let index = Int(name.split(separator: ".").first ?? "") else { return nil }
            let weg = ordner.appendingPathComponent(name)
            return Untertiteldatei(index: index, adresse: weg, merkmal: merkmal(weg))
        }
    }

    /// **Externe Untertitel mitnehmen**, sobald der Film selbst da ist.
    ///
    /// Eingebettete Untertitel stecken in der Datei und reisen ohnehin mit;
    /// externe (.srt, .ass neben dem Film auf dem Server) holte der Player
    /// bisher nur über das Netz — offline standen sie nicht zur Wahl
    /// (Wunsch aus dem Discord, „Add more subtitle options").
    private func untertitelHolen(_ p: Downloadposten) {
        guard let client else { return }
        let datei = Self.ordner().appendingPathComponent(p.dateiname)
        Task {
            guard let plan = try? await client.playbackPlan(for: p.id),
                  let sitzung = await client.currentSession() else { return }
            // Bei einer umgewandelten Datei auch die eingebetteten
            // Textuntertitel — in ihr stecken nur noch Bild und Ton.
            let dateien = Untertiteldatei.mitladen(stroeme: plan.quelle?.mediaStreams ?? [],
                                                   itemID: p.id, quelle: p.quelle ?? plan.quelle?.id,
                                                   server: sitzung.serverURL,
                                                   schluessel: sitzung.accessToken,
                                                   umgewandelt: p.umgewandelt)
            guard !dateien.isEmpty else { return }
            let ziel = Self.untertitelordner(zur: datei)
            try? FileManager.default.createDirectory(at: ziel, withIntermediateDirectories: true)
            var geladen = 0
            for d in dateien {
                guard let (daten, antwort) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(d.adresse)),
                      (antwort as? HTTPURLResponse)?.statusCode == 200, !daten.isEmpty else { continue }
                let endung = d.adresse.pathExtension.isEmpty ? "srt" : d.adresse.pathExtension
                if (try? daten.write(to: ziel.appendingPathComponent("\(d.index).\(endung)"))) != nil {
                    geladen += 1
                }
            }
            Protokoll.schreib("[Download] Untertitel für \(p.id): \(geladen) von \(dateien.count)")
        }
    }

    // MARK: Abschnitte für offline

    /// **Vorspann und Abspann mitnehmen**, sobald die Datei da ist — sonst
    /// gibt es ohne Server weder „Intro überspringen" noch die Karte
    /// „Nächste Folge". Keine Antwort (`nil`) lässt das Feld leer, und
    /// ``abschnitteNachholen()`` fragt beim nächsten Kontakt noch einmal.
    private func abschnitteHolen(_ id: String) {
        guard let client else { return }
        Task {
            guard let teile = await client.abschnitteZumAblegen(fuer: id),
                  let i = posten.firstIndex(where: { $0.id == id }) else { return }
            posten[i].abschnitte = teile
            sichern()
            Protokoll.schreib("[Download] Abschnitte für \(id): \(teile.count)")
        }
    }

    /// Für alles, was vor 1.0.5 geladen wurde oder beim Laden keine Antwort
    /// bekam. Läuft nur mit Server (``AppModel/downloadsNachziehen()``).
    func abschnitteNachholen() {
        for p in posten where p.stand == .fertig && p.abschnitte == nil {
            abschnitteHolen(p.id)
        }
    }

    // MARK: Sehstand auf dem Gerät

    /// **Eine Wiedergabe vermerken — auch ohne Netz.** So zeigt die Liste den
    /// Haken, sobald eine Folge im Flugzeug zu Ende lief, der Abspielknopf der
    /// Serie nimmt die nächste, und die Liste fängt an der gemerkten Stelle an.
    /// Die Schwellen sind die des Servers (``Downloadposten/nachWiedergabe(ticks:wann:)``).
    func wiedergabeVermerken(_ id: String, ticks: Int64, wann: Date = Date()) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        posten[i] = posten[i].nachWiedergabe(ticks: ticks, wann: wann)
        sichern()
    }

    // MARK: Konto

    /// **H11.** Nach dem Anmelden gilt, was diesem Konto gehört — und nur das.
    ///
    /// **Beim Wechsel des Kontos hoert das alte auf zu laden.** Vorher lief
    /// seine Aufgabe weiter, und ihre Rueckmeldungen landeten in der Liste
    /// des neuen — bei zwei Nutzern desselben Servers mit denselben
    /// Kennungen sogar am selben Titel. Die Titel des alten Kontos bleiben
    /// auf der Platte und warten, bis es sich wieder anmeldet.
    func anmelden(client: JellyfinClient?, konto: String?) {
        self.client = client
        // Was vorgemerkt ist, geht **jetzt** und noch unter dem alten Konto
        // hinaus — gleich darauf liest `laden` die Liste neu, und danach
        // gehoerten Posten und Konto nicht mehr zusammen.
        if self.konto != nil, sichernVorgemerkt || konto != self.konto { sofortSichern() }
        if konto != self.konto { loslassen() }
        self.konto = konto
        laden()
        platzMessen()
        // Vor dem `Task` gesetzt, nicht darin: dazwischen darf kein anderer
        // `takt` einen Titel starten, dessen Aufgabe gleich wiedergefunden wird.
        suchtAufgaben = true
        Task {
            await aufgabenWiederfinden()
            suchtAufgaben = false
            takt()
        }
    }

    /// Alles, was zum bisherigen Konto lief, anhalten und vergessen.
    private func loslassen() {
        for (id, aufgabe) in aufgaben {
            neueGeneration(id)
            aufgabe.cancel()
        }
        aufgaben = [:]
        fortsetzdaten = [:]
        gemeldet = [:]
        gemeldetUm = [:]
        live = [:]
    }

    @discardableResult
    private func neueGeneration(_ id: String) -> Int {
        generationszaehler += 1
        generation[id] = generationszaehler
        return generationszaehler
    }

    /// **Was im System weiterlief, gehoert wieder dazu.**
    ///
    /// Die Hintergrundsitzung laedt weiter, wenn die App beendet ist. Beim
    /// naechsten Start stand der Titel trotzdem auf „wartet", und `takt`
    /// startete ihn ein zweites Mal daneben. Jetzt werden die laufenden
    /// Aufgaben erst gesucht und uebernommen.
    private func aufgabenWiederfinden() async {
        guard konto != nil else { return }
        let alle = await sitzung.allTasks
        for aufgabe in alle {
            guard let d = aufgabe as? URLSessionDownloadTask,
                  d.state == .running || d.state == .suspended,
                  let t = Downloadaufgabe.zerlegen(d.taskDescription) else { continue }
            guard aufgaben[t.id] == nil else { continue }
            guard let i = posten.firstIndex(where: { $0.id == t.id }),
                  posten[i].stand == .wartet || posten[i].stand == .laedt else {
                // Gehoert zu keinem wartenden Titel dieses Kontos: angehalten,
                // entfernt, oder ein anderes Konto — dann laeuft sie nicht weiter.
                d.cancel()
                continue
            }
            generation[t.id] = t.generation
            aufgaben[t.id] = d
            posten[i].stand = .laedt
            live[t.id] = Downloadfortschritt(geladen: max(posten[i].geladen, d.countOfBytesReceived),
                                             gesamt: posten[i].bytes)
            if d.state == .suspended { d.resume() }
            Protokoll.schreib("[Download] laufende Aufgabe übernommen: \(t.id)")
        }
    }

    private func laden() {
        // **Hinter dem letzten Schreiben gelesen.** Gesichert wird abseits;
        // ohne das Warten laese dieses Laden womoeglich einen Stand von vor
        // der letzten Aenderung — ein eben angestossener Titel waere weg.
        guard let konto, let alle = Self.schreibschlange.sync(execute: { Self.alleLesen() })
        else { posten = []; return }
        // Die Liste auf der Platte trägt die Titel **aller** Konten; gezeigt
        // wird nur das eigene. Gelöscht wird hier nichts — das andere Konto
        // findet seine Titel wieder, wenn es sich anmeldet.
        posten = alle.filter { $0.konto == konto }
        // Was beim letzten Mal mitten im Laden war, wartet jetzt wieder —
        // es sei denn, seine Aufgabe laeuft in diesem Programmlauf noch
        // (dasselbe Konto meldet sich neu an). Sonst startete `takt` ihn
        // ein zweites Mal daneben. Was im System weiterlief, findet
        // `aufgabenWiederfinden`.
        for i in posten.indices where posten[i].stand == .laedt && aufgaben[posten[i].id] == nil {
            posten[i].stand = .wartet
        }
    }

    /// **Gesichert wird einmal je Durchgang, und nicht auf dem Hauptlauf.**
    ///
    /// Jede Aenderung schrieb die ganze Liste sofort und synchron: lesen,
    /// entschluesseln, verschluesseln, schreiben. `nachziehen` rief das je
    /// Titel zweimal, `allesAnhalten` einmal je Titel — bei vierzig Folgen
    /// achtzig Mal hintereinander auf dem Hauptlauf. Jetzt merkt sich jede
    /// Aenderung nur vor; am Ende des Durchgangs geht **ein** Stand an eine
    /// eigene Schlange, die der Reihe nach schreibt.
    @ObservationIgnored private var sichernVorgemerkt = false

    private func sichern() {
        guard konto != nil, !sichernVorgemerkt else { return }
        sichernVorgemerkt = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sichernVorgemerkt = false
            self.sofortSichern()
        }
    }

    private func sofortSichern() {
        guard let konto else { return }
        let stand = posten.map(aktuell)
        Self.schreibschlange.async { Self.alleSchreiben(stand, konto: konto) }
    }

    /// Seriell: zwei Staende duerfen sich beim Schreiben nicht ueberholen.
    private static let schreibschlange = DispatchQueue(label: "de.paulherter.swiftly.downloadliste",
                                                       qos: .utility)

    /// Die ganze Liste aller Konten — `nil`, wenn es keine gibt oder sie
    /// sich nicht lesen laesst.
    ///
    /// **Eine kaputte Liste wird nicht still ueberschrieben.** Vorher galt
    /// sie als leer: die Seite zeigte nichts, und das naechste Sichern
    /// schrieb nur das eigene Konto zurueck — die Titel aller anderen waren
    /// weg, die Dateien lagen verwaist daneben. Jetzt steht es im Protokoll,
    /// und die Datei wird vorher beiseitegelegt.
    nonisolated private static func alleLesen() -> [Downloadposten]? {
        let weg = verzeichnisdatei
        guard let roh = try? Data(contentsOf: weg) else { return nil }
        do {
            return try JSONDecoder().decode([Downloadposten].self, from: roh)
        } catch {
            let sicherung = weg.deletingPathExtension().appendingPathExtension("defekt.json")
            try? FileManager.default.removeItem(at: sicherung)
            try? FileManager.default.copyItem(at: weg, to: sicherung)
            Protokoll.schreib("[Download] Liste nicht lesbar (\(roh.count) Byte), beiseitegelegt: \(error)")
            return nil
        }
    }

    nonisolated private static func alleSchreiben(_ eigene: [Downloadposten], konto: String) {
        var alle = alleLesen() ?? []
        alle.removeAll { $0.konto == konto }
        alle.append(contentsOf: eigene)
        guard let roh = try? JSONEncoder().encode(alle) else { return }
        try? roh.write(to: verzeichnisdatei, options: .atomic)
    }

    /// Frisch messen, wenn eine Auswahl aufgeht: seit dem Anmelden kann das
    /// Geraet voller geworden sein, und der Fuss rechnet mit dieser Zahl.
    func platzAuffrischen() { platzMessen() }

    private func platzMessen() {
        // **`…ForImportantUsage` gibt es auf tvOS nicht**, und das ist keine
        // Willkuer: ein Apple TV hat keinen Nutzerspeicher, ueber den man
        // Auskunft geben koennte — es raeumt selbst weg. Genau deshalb steht
        // in VERHALTEN F, dass es dort keine Downloads gibt; die Klasse ruht
        // hier nur mit, weil `AppModel` allen gehoert.
        //
        // Die Zahl ist ausserdem eine andere als die schlichte freie
        // Kapazitaet: sie zaehlt mit, was iOS fuer eine wichtige Anforderung
        // freiraeumen wuerde — also das, was ein Download tatsaechlich
        // bekommt.
        #if os(tvOS)
        frei = 0
        #else
        let werte = try? Self.ordner().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        frei = Int64(werte?.volumeAvailableCapacityForImportantUsage ?? 0)
        #endif
    }

    // MARK: Anstossen

    /// Was ein Download kosten würde — für das Blatt vor dem Start (H3).
    func auskunft(fuer bytes: Int64) -> Downloadregeln.Platzauskunft {
        platzMessen()
        return Downloadregeln.platz(fuer: bytes, frei: frei, vorhanden: posten)
    }

    /// Einen Titel in die Schlange stellen. Startet ihn, wenn er dran ist.
    ///
    /// `plakat` ist die Adresse des Titelbilds und wird **mitgeladen**. Ohne
    /// das stünde die Downloadseite im Flugzeug ohne Bilder da: der
    /// Bildspeicher der App hält nur im Arbeitsspeicher, und die Adressen
    /// zeigen auf den Server, den es dann nicht gibt. Ein Plakat ist ein paar
    /// Dutzend Kilobyte neben achtzehn Gigabyte — die einzige Stelle, an der
    /// sich zusätzliches Laden nicht lohnt zu diskutieren.
    /// Einen Titel in die Schlange stellen.
    ///
    /// `bilder` bildet Kennungen auf Bildadressen ab: die des Titels selbst,
    /// und bei einer Folge zusätzlich die der Serie. **Beide werden
    /// gebraucht** — die Liste zeigt für eine Serie das Plakat, die
    /// Folgenliste darunter das Querbild jeder Folge, so wie überall sonst
    /// in der App. Nur das Serienplakat zu sichern hiesse, dass in der
    /// Folgenliste dreimal dasselbe Bild steht.
    func anstossen(_ neu: Downloadposten, bilder: [String: URL] = [:]) {
        anstossen([neu], bilder: bilder)
    }

    /// Eine ganze Staffel. Der Reihe nach, nicht gleichzeitig — H4 sorgt
    /// dafür von selbst, weil immer nur einer läuft.
    func anstossen(_ viele: [Downloadposten], bilder: [String: URL] = [:]) {
        for p in viele where !posten.contains(where: { $0.id == p.id }) {
            posten.append(p)
            if let eigen = bilder[p.id] { bildSichern(p.konto, p.id, von: eigen) }
            if let sid = p.serienId, let serie = bilder[sid] {
                bildSichern(p.konto, sid, von: serie)
            }
            // Das grosse Kopfbild der Serie, einmal je Serie — `bildSichern`
            // laedt nicht, was schon liegt.
            if let sid = p.serienId, let kopf = bilder[Self.kopfschluessel(sid)] {
                bildSichern(p.konto, sid + "-kopf", von: kopf)
            }
        }
        sichern()
        takt()
    }

    /// **Sofort gescheitert?** Das Ladeblatt schliesst beim Druck, und ein
    /// Download, der gleich wieder abbricht — keine Adresse vom Server, kein
    /// Netz —, stand dann nur rot in den Downloads, wo gerade niemand
    /// hinsieht. Wartet kurz und gibt den Grund des ersten gescheiterten
    /// der genannten Titel zurück, sonst `nil`.
    func sofortGescheitert(_ ids: [String], frist: Duration = .seconds(4)) async -> String? {
        guard !ids.isEmpty else { return nil }
        let ende = ContinuousClock.now + frist
        while ContinuousClock.now < ende {
            if let p = posten.first(where: { ids.contains($0.id) && $0.stand == .fehler }) {
                return p.grund.map { String(localized: "Der Download ist gescheitert. \($0)") }
                    ?? String(localized: "Der Download ist gescheitert.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    // MARK: Die Bilder

    private static func bildweg(_ konto: String, _ kennung: String) -> URL {
        ordner().appendingPathComponent(Downloadposten.bildname(konto: konto, kennung: kennung))
    }

    /// Das Bild auf dem Gerät — oder `nil`, dann nimmt die Zeile die Adresse
    /// vom Server. **Ohne Netz gibt es nur die Platte**, und genau dann wird
    /// diese Seite gebraucht.
    ///
    /// `alsGruppe` fragt nach dem Plakat der Serie statt nach dem Bild der
    /// einzelnen Folge.
    func bild(fuer p: Downloadposten, alsGruppe: Bool = false) -> URL? {
        let kennung = alsGruppe ? (p.serienId ?? p.id) : p.id
        let weg = Self.bildweg(p.konto, kennung)
        return FileManager.default.fileExists(atPath: weg.path) ? weg : nil
    }

    /// Unter diesem Schluessel reicht die Serienseite das grosse Kopfbild
    /// in `anstossen(_:bilder:)` herein.
    static func kopfschluessel(_ serienId: String) -> String { "kopf:" + serienId }

    /// **Das Kopfbild der Serie in Bildschirmaufloesung**, fuer die
    /// Serienseite in den Downloads. Das Plakat und die Querbilder sind fuer
    /// Zeilen gemessen (300 und 220 hoch) und standen dort gestreckt und
    /// weich da.
    func kopfbild(serie serienId: String, konto: String) -> URL? {
        let weg = Self.bildweg(konto, serienId + "-kopf")
        return FileManager.default.fileExists(atPath: weg.path) ? weg : nil
    }

    /// Fuer Downloads von vorher, die es noch nicht haben: beim naechsten
    /// Oeffnen mit Netz nachholen. Gibt den Weg zurueck, sobald es liegt.
    func kopfbildNachholen(serie serienId: String, konto: String, von adresse: URL) async -> URL? {
        let ziel = Self.bildweg(konto, serienId + "-kopf")
        guard !FileManager.default.fileExists(atPath: ziel.path) else { return ziel }
        guard let (daten, _) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(adresse)),
              daten.count > 0, (try? daten.write(to: ziel, options: .atomic)) != nil
        else { return nil }
        return ziel
    }

    private func bildSichern(_ konto: String, _ kennung: String, von adresse: URL) {
        let ziel = Self.bildweg(konto, kennung)
        guard !FileManager.default.fileExists(atPath: ziel.path) else { return }
        Task {
            guard let (daten, _) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(adresse)),
                  daten.count > 0 else { return }
            try? daten.write(to: ziel, options: .atomic)
        }
    }

    /// **Anhalten ist kein Fehler.**
    ///
    /// `URLSession` meldet einen Abbruch als Fehler — dieselbe Rueckmeldung,
    /// die auch der Netzwechsel und der abgestuerzte Server ausloesen. Ohne
    /// Unterscheidung kann `gescheitert` die drei nicht unterscheiden und
    /// setzt auf `.fehler`, sobald der Server keine Fortsetzdaten mitgibt.
    /// Der Ring zeigte dann Rot statt Pause, und ein zweiter Tipp darauf
    /// heisst „nochmal versuchen": das Laden ging weiter. Genau so gemeldet —
    /// „wenn ich auf Pause gehe, laedt der weiter runter".
    ///
    /// **Seit 1.0.5 ueber die Generation.** Das Anhalten zaehlt sie weiter;
    /// der Abbruch, den die Sitzung danach meldet, traegt die alte und wird
    /// uebergangen. Vorher stand hier eine Liste der absichtlich Angehaltenen
    /// — die half nicht, wenn zwischen Anhalten und Meldung schon wieder
    /// fortgesetzt war: dann traf der alte Abbruch die neue Aufgabe.
    func anhalten(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        let jetzt = neueGeneration(id)
        if let aufgabe = aufgaben[id] {
            aufgabe.cancel { [weak self] daten in
                Task { @MainActor in
                    // Nur, solange niemand danach neu gestartet hat.
                    if let daten, self?.generation[id] == jetzt { self?.fortsetzdaten[id] = daten }
                }
            }
            aufgaben[id] = nil
        }
        stehenLassen(i)
        posten[i].stand = .angehalten
        sichern()
        takt()
    }

    /// Wie ``anhalten``, nur dass der Titel danach wartet: der Netzwechsel
    /// hat ihn gestoppt, nicht die Pausetaste. Die Fortsetzdaten bleiben.
    private func zurueckstellen(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        let jetzt = neueGeneration(id)
        if let aufgabe = aufgaben[id] {
            aufgabe.cancel { [weak self] daten in
                Task { @MainActor in
                    if let daten, self?.generation[id] == jetzt { self?.fortsetzdaten[id] = daten }
                }
            }
            aufgaben[id] = nil
        }
        stehenLassen(i)
        posten[i].stand = .wartet
        sichern()
    }

    /// Den laufenden Stand in den Posten uebernehmen und nicht mehr einzeln
    /// fuehren — der Titel laedt nicht mehr.
    private func stehenLassen(_ i: Int) {
        let id = posten[i].id
        posten[i] = aktuell(posten[i])
        live[id] = nil
        gemeldet[id] = nil
        gemeldetUm[id] = nil
    }

    func fortsetzen(_ id: String) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        posten[i].stand = .wartet
        posten[i].grund = nil
        sichern()
        takt()
    }

    func entfernen(_ id: String) {
        entfernenOhneSichern(id)
        sichern()
        platzMessen()
        takt()
    }

    private func entfernenOhneSichern(_ id: String) {
        neueGeneration(id)
        if let aufgabe = aufgaben[id] { aufgabe.cancel(); aufgaben[id] = nil }
        fortsetzdaten[id] = nil
        live[id] = nil
        gemeldet[id] = nil
        gemeldetUm[id] = nil
        if let p = posten.first(where: { $0.id == id }) {
            let datei = Self.ordner().appendingPathComponent(p.dateiname)
            try? FileManager.default.removeItem(at: datei)
            try? FileManager.default.removeItem(at: Self.untertitelordner(zur: datei))
            // Das eigene Bild geht immer mit.
            try? FileManager.default.removeItem(at: Self.bildweg(p.konto, p.id))
            // Das Serienplakat teilen sich alle Folgen — es geht erst mit der
            // letzten. Sonst stuende die vorletzte Folge ohne Bild da.
            if let sid = p.serienId,
               !posten.contains(where: { $0.id != id && $0.serienId == sid }) {
                try? FileManager.default.removeItem(at: Self.bildweg(p.konto, sid))
                try? FileManager.default.removeItem(at: Self.bildweg(p.konto, sid + "-kopf"))
            }
        }
        posten.removeAll { $0.id == id }
    }

    /// Mehrere auf einmal: einmal messen, einmal den Takt — nicht je Titel.
    func entfernen(_ ids: [String]) {
        for id in ids { entfernenOhneSichern(id) }
        sichern()
        platzMessen()
        takt()
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
        guard !suchtAufgaben else { return }
        switch Downloadregeln.netzentscheid(imWLAN: netzGelesen ? imWLAN : nil,
                                            nurUeberWLAN: nurUeberWLAN) {
        case .laden:
            break
        case .abwarten:
            // Die erste Meldung des Pfadbeobachters steht noch aus. Nichts
            // anfangen und nichts stoppen — sie kommt in Millisekunden.
            return
        case .zurueckstellen:
            // Kein WLAN und nur-über-WLAN: was läuft, geht zurück in die
            // Reihe. Sonst liefe der Download über Mobilfunk weiter, obwohl
            // es ausgeschaltet ist. **Zurück auf „wartet", nicht angehalten:**
            // angehalten nahm ihn im WLAN niemand mehr auf.
            for p in posten where p.stand == .laedt { zurueckstellen(p.id) }
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
        let jetzt = neueGeneration(p.id)

        let fortsetzen = fortsetzdaten[p.id]
        fortsetzdaten[p.id] = nil
        // **Eine umgewandelte Datei faengt von vorn an.** Der Server nimmt
        // bei ihr keine Bereichsabrufe an (`Accept-Ranges: none`), also gibt
        // es keine Fortsetzdaten; was vorher geladen war, gilt nicht mehr.
        if fortsetzen == nil, posten[i].umgewandelt { posten[i].geladen = 0 }
        live[p.id] = Downloadfortschritt(geladen: posten[i].geladen, gesamt: posten[i].bytes)

        Task { [weak self] in
            guard let adresse = try? await client.downloadURL(itemID: p.id,
                                                              mediaSourceID: p.quelle,
                                                              qualitaet: p.guete) else {
                self?.gescheitert(.init(id: p.id, generation: jetzt, datei: p.dateiname),
                                        grund: String(localized: "Keine Adresse vom Server."),
                                        fortsetzen: nil)
                return
            }
            self?.aufgabeStarten(p, generation: jetzt, adresse: adresse, fortsetzen: fortsetzen)
        }
    }

    private func aufgabeStarten(_ p: Downloadposten, generation jetzt: Int,
                                adresse: URL, fortsetzen: Data?) {
        // In der Zwischenzeit kann der Posten entfernt oder angehalten
        // worden sein — dann faengt hier nichts mehr an. **Und nicht
        // zweimal:** wer waehrend des Wartens anhielt und fortsetzte, hat
        // eine neuere Generation, deren eigener Start gleich hier ankommt.
        guard generation[p.id] == jetzt,
              posten.first(where: { $0.id == p.id })?.stand == .laedt else { return }
        let aufgabe = fortsetzen.map { sitzung.downloadTask(withResumeData: $0) }
            // Mit den eigenen Headern des Servers (Issue #4); ohne Eintrag
            // dieselbe Anfrage wie vorher. Die Fortsetzdaten tragen sie mit.
            ?? sitzung.downloadTask(with: .mitEigenenKoepfen(adresse))
        // Der Dateiname reist mit der Aufgabe, weil der Rückruf aus dem
        // System kommt und unsere Liste dort nicht erreichbar ist.
        aufgabe.taskDescription = Downloadaufgabe.beschreibung(id: p.id, generation: jetzt,
                                                               datei: p.dateiname)
        aufgaben[p.id] = aufgabe
        aufgabe.resume()
    }

    // MARK: Rückmeldungen aus der Sitzung

    /// Zuletzt veroeffentlichter Stand je Download — siehe `fortschritt`.
    @ObservationIgnored private var gemeldet: [String: Int64] = [:]
    /// Wann zuletzt veroeffentlicht wurde — die Zahl soll zaehlen, nicht zittern.
    @ObservationIgnored private var gemeldetUm: [String: Date] = [:]

    /// Ob eine Rueckmeldung zur laufenden Aufgabe des Titels gehoert.
    private func gilt(_ t: Downloadaufgabe.Teile) -> Bool {
        Downloadaufgabe.gilt(gemeldet: t.generation, aktuell: generation[t.id])
    }

    private func fortschritt(_ t: Downloadaufgabe.Teile, geladen: Int64, gesamt: Int64) {
        guard gilt(t) else { return }
        let id = t.id
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }

        // **Nicht jede Rueckmeldung ist eine Aenderung, die man sieht.**
        //
        // `URLSession` meldet den Fortschritt im Takt der ankommenden Pakete
        // — bei einer schnellen Leitung viele Male je Bild. Jede Meldung
        // schreibt in `posten`, und weil `@Observable` die **ganze** Liste
        // als eine Eigenschaft fuehrt, zeichnet danach jede Ansicht neu, die
        // irgendetwas daraus liest: in einer Folgenliste also jede Zeile
        // samt Ring. Das ist das Flackern.
        //
        // **Seit 1.0.5 schreibt sie nicht mehr in `posten`**, sondern in den
        // eigenen `Downloadfortschritt` des Titels — siehe `aktuell`.
        //
        // Ein halbes Prozent ist bei einem 28-Punkt-Ring rund ein halbes
        // Pixel Bogen — darunter gibt es nichts zu sehen, und der letzte
        // Schritt auf voll kommt ohnehin ueber `abgeschlossen`.
        //
        // **Und hoechstens einmal je Sekunde.** Das halbe Prozent allein
        // liess bei schneller Leitung fuenf und mehr Zahlen je Sekunde durch;
        // die Unterzeile las sich wie ein Zittern. Die Regel steht im Paket.
        let jetzt = Date()
        guard Downloadregeln.fortschrittZeigen(
            geladen: geladen, gesamt: gesamt > 0 ? gesamt : posten[i].bytes,
            vorher: gemeldet[id],
            vergangen: gemeldetUm[id].map { jetzt.timeIntervalSince($0) })
        else { return }
        gemeldet[id] = geladen
        gemeldetUm[id] = jetzt

        // Sagt der Server im Katalog keine Grösse, nimmt der Balken die aus
        // der Antwort. **Nicht gesichert** — das wäre ein Schreibvorgang je
        // Fortschrittsmeldung, siehe `Downloadstand`.
        let neuGesamt = posten[i].bytes == 0 && gesamt > 0 ? gesamt : posten[i].bytes
        if let f = live[id] {
            f.geladen = geladen
            if f.gesamt != neuGesamt { f.gesamt = neuGesamt }
        } else {
            live[id] = Downloadfortschritt(geladen: geladen, gesamt: neuGesamt)
        }
    }

    private func abgeschlossen(_ t: Downloadaufgabe.Teile, gelungen: Bool) {
        guard gilt(t) else { return }
        let id = t.id
        aufgaben[id] = nil
        guard let i = posten.firstIndex(where: { $0.id == id }) else {
            live[id] = nil; gemeldet[id] = nil; gemeldetUm[id] = nil
            return
        }
        stehenLassen(i)
        if gelungen {
            posten[i].stand = .fertig
            // **Die Schaetzung weicht der echten Groesse**, sobald die
            // umgewandelte Datei liegt — sonst zaehlte die Belegung weiter
            // mit einer gerechneten Zahl.
            if posten[i].umgewandelt,
               let echt = try? Self.ordner().appendingPathComponent(posten[i].dateiname)
                   .resourceValues(forKeys: [.fileSizeKey]).fileSize, echt > 0 {
                posten[i].bytes = Int64(echt)
            }
            posten[i].geladen = posten[i].bytes
            untertitelHolen(posten[i])
            abschnitteHolen(posten[i].id)
        } else {
            posten[i].stand = .fehler
            posten[i].grund = String(localized: "Die Datei liess sich nicht ablegen.")
        }
        sichern()
        platzMessen()
        takt()
    }

    private func gescheitert(_ t: Downloadaufgabe.Teile, grund: String, fortsetzen: Data?) {
        // **Wer selbst angehalten hat, bekommt keinen Fehler zu sehen.**
        //
        // Der Abbruch kommt hier als Fehler an, weil `URLSession` ihn so
        // meldet. Ob er von der Pausetaste kam oder vom weggebrochenen Netz,
        // steht in der Meldung nicht — die Generation schon: das Anhalten hat
        // sie weitergezaehlt, und die Meldung traegt die alte. Ohne das blieb
        // ein Halt ohne Fortsetzdaten als `.fehler` stehen, der Ring wurde
        // rot, und der naechste Tipp hiess „nochmal versuchen" statt „weiter".
        guard gilt(t) else { return }
        let id = t.id
        aufgaben[id] = nil
        if let fortsetzen { fortsetzdaten[id] = fortsetzen }
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        stehenLassen(i)

        // Ein abgebrochener Download mit Fortsetzdaten ist kein Fehler,
        // sondern eine Pause — meist der Netzwechsel. Als Fehler gezeigt,
        // stünde ein rotes Zeichen da, wo nur die U-Bahn schuld war.
        posten[i].stand = fortsetzen != nil ? .angehalten : .fehler
        posten[i].grund = fortsetzen != nil ? nil : grund
        sichern()
        takt()
    }

    // MARK: Netz

    /// Ob gerade WLAN anliegt. Steuert H5.
    private(set) var imWLAN = true
    /// Gar keine Verbindung. **Der Tag, für den die Funktion gebaut ist** —
    /// die Seite wechselt dann ihre Kopfzeile.
    private(set) var keinNetz = false
    /// Ob der Pfadbeobachter schon einmal gemeldet hat. Vorher ist
    /// ``imWLAN`` nur die Vorgabe, und der Takt wartet ab.
    @ObservationIgnored private var netzGelesen = false

    /// **`NWPathMonitor`, und nicht selbst geraten.**
    ///
    /// Ich hatte hier zuerst gar keine Überwachung stehen, mit dem Hinweis
    /// auf die Dauerlast, die auf Linux einen Kern gefressen hat. Das war
    /// falsch zusammengezogen: dort war es ein offener
    /// `URLSessionWebSocketTask`, nicht ein Pfadbeobachter — nachgemessen,
    /// Zeile 51 der Änderungsliste. Und ohne Beobachter stünde `imWLAN`
    /// dauerhaft auf `true`, womit H5 gar nichts täte: der Schalter „Nur
    /// über WLAN" wäre eine Zeile ohne Wirkung, und das ist schlechter als
    /// keine Zeile.
    ///
    /// Er läuft nur, solange die Funktion eingeschaltet ist.
    @ObservationIgnored private var wache: NWPathMonitor?

    func netzBeobachten() {
        guard wache == nil else { return }
        let w = NWPathMonitor()
        w.pathUpdateHandler = { [weak self] pfad in
            let wlan = pfad.usesInterfaceType(.wifi) || pfad.usesInterfaceType(.wiredEthernet)
            let weg = pfad.status != .satisfied
            Task { @MainActor in self?.netzlage(imWLAN: wlan, keinNetz: weg) }
        }
        w.start(queue: DispatchQueue(label: "de.paulherter.swiftly.netzwache"))
        wache = w
    }

    func netzNichtMehrBeobachten() {
        wache?.cancel()
        wache = nil
        netzGelesen = false
    }

    #if DEBUG
    /// Selbsttest ohne Netz (`Offlinelauf`) — dieselbe Wirkung wie der
    /// Pfadbeobachter, ohne das Netz des Rechners anzufassen.
    func netzSimulieren(weg: Bool) { netzlage(imWLAN: !weg, keinNetz: weg) }
    #endif

    private func netzlage(imWLAN wlan: Bool, keinNetz weg: Bool) {
        let erste = !netzGelesen
        netzGelesen = true
        guard erste || wlan != imWLAN || weg != keinNetz else { return }
        imWLAN = wlan
        keinNetz = weg
        Protokoll.schreib("[Download] Netz: \(weg ? "keins" : wlan ? "WLAN" : "Mobilfunk")")
        // Der Takt hält an oder fährt fort — je nachdem, was jetzt gilt.
        takt()
    }

    // MARK: H9 — der Titel ist vom Server verschwunden

    /// Setzt den Hinweis, ohne die Datei anzufassen.
    ///
    /// **Zweiseitig, seit der Abgleich existiert.** Vorher gab es nur den
    /// Weg nach unten; ein Titel, den ein Servernachlauf wieder eingesammelt
    /// hat, haette den Hinweis fuer immer behalten.
    func aufDemServer(_ id: String, _ an: Bool) {
        guard let i = posten.firstIndex(where: { $0.id == id }),
              posten[i].nochAufDemServer != an else { return }
        posten[i].nochAufDemServer = an
        sichern()
    }

    /// Nachziehen, was der Server über den Sehstand sagt — damit H6 weiss,
    /// was gesehen ist, und die Liste ohne Netz dasselbe zeigt wie mit.
    /// Ein neuerer Stand von hier bleibt (``Downloadregeln/nachziehen(_:sehstand:)``).
    private func sehstand(_ id: String, _ stand: UserItemData?) {
        guard let i = posten.firstIndex(where: { $0.id == id }) else { return }
        let neu = Downloadregeln.nachziehen(posten[i], sehstand: stand)
        guard neu != posten[i] else { return }
        posten[i] = neu
        sichern()
    }

    /// **Was der Server sagt, in einem Zug nachziehen — H6 und H9.**
    ///
    /// Die Setzer darueber standen bis 09.09.2026 da, ohne dass sie
    /// jemand rief. Das war nicht folgenlos, nur unsichtbar:
    /// `Downloadregeln.entbehrlich` filtert auf `gesehen` und gab deshalb
    /// **immer** eine leere Liste zurueck — der Ausweg, den H6 bei
    /// Platzmangel anbietet, erschien nie. Und `nochAufDemServer` blieb
    /// wahr, obwohl beide Downloadseiten den Hinweis dazu schon zeichnen.
    ///
    /// Was hier hereinkommt, ist ausdruecklich **beantwortet**, nicht
    /// abgefragt: wer offline ist, bekommt keine Antwort, und dann waere
    /// „nicht mehr auf dem Server" fuer jeden Titel die falsche Auskunft.
    /// Der Aufrufer haelt das auseinander.
    func nachziehen(vorhanden: Set<String>, sehstand: [String: UserItemData]) {
        for id in posten.map(\.id) {
            if vorhanden.contains(id) { self.sehstand(id, sehstand[id]) }
            aufDemServer(id, vorhanden.contains(id))
        }
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

    typealias Teile = Downloadaufgabe.Teile
    private let aufFortschritt: @Sendable (Teile, Int64, Int64) -> Void
    private let aufFertig: @Sendable (Teile, Fertigmeldung) -> Void
    private let aufFehler: @Sendable (Teile, String, Data?) -> Void

    init(fortschritt: @escaping @Sendable (Teile, Int64, Int64) -> Void,
         fertig: @escaping @Sendable (Teile, Fertigmeldung) -> Void,
         gescheitert: @escaping @Sendable (Teile, String, Data?) -> Void) {
        self.aufFortschritt = fortschritt
        self.aufFertig = fertig
        self.aufFehler = gescheitert
    }

    /// Kennung, Generation und Dateiname — alles hängt an der Aufgabe, weil
    /// der Rückruf unsere Liste nicht erreicht.
    private func teile(_ aufgabe: URLSessionTask) -> Teile? {
        Downloadaufgabe.zerlegen(aufgabe.taskDescription)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = teile(downloadTask) else { return }
        aufFortschritt(t, totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let t = teile(downloadTask) else { return }
        // **Ein Statuscode ist kein Erfolg.** Jellyfin antwortet auf eine
        // abgelaufene Anmeldung mit 401 und einem Rumpf — und der landete
        // hier als „fertige Datei" von 40 Byte.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Der Satz kommt aus `lesbarerFehler`, nicht aus dem Code: sonst stuende
            // hier woertlich „HTTP 401" auf dem Schirm.
            aufFehler(t, lesbarerFehler(JellyfinError.http(status: http.statusCode, body: nil)), nil)
            return
        }
        aufFertig(t, Fertigmeldung(temp: location, name: t.datei))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let fehler = error as NSError?, let t = teile(task) else { return }
        let daten = fehler.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        aufFehler(t, lesbarerFehler(fehler), daten)
    }
}

/// **Der Fortschritt eines Titels, fuer sich beobachtbar.**
///
/// Eine eigene Klasse je Titel, damit eine Meldung nur die Ansichten neu
/// zeichnet, die genau diesen Titel lesen. Solange sie als Zahl in
/// `Downloadverwaltung.posten` stand, war jede Meldung eine Aenderung der
/// ganzen Liste.
@MainActor
@Observable
final class Downloadfortschritt {
    var geladen: Int64
    var gesamt: Int64

    init(geladen: Int64, gesamt: Int64) {
        self.geladen = geladen
        self.gesamt = gesamt
    }
}
