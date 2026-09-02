import AVFoundation
import AVKit
import OSLog
import JellyfinKit
import Network
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import VLCKit

/// Schreibt Meldungen zusaetzlich in eine Datei im App-Container.
///
/// Beim Test mit ausgeschaltetem WLAN reisst die Protokollverbindung zum Mac
/// mit ab — ohne Datei bleibt ausgerechnet der interessante Teil unsichtbar.
/// Abholen mit Werkzeuge/protokoll-holen.sh
enum Protokoll {
    nonisolated(unsafe) private static var griff: FileHandle?
    private static let sperre = NSLock()

    /// **Auf dem Fernseher nicht `Documents`.**
    ///
    /// tvOS gibt Apps kein beschreibbares Dokumentenverzeichnis — `createFile`
    /// schlaegt dort fehl, und zwar lautlos, weil der Rueckgabewert niemanden
    /// interessiert. Das Protokoll hat auf tvOS also **nie** geschrieben, und
    /// niemandem ist es aufgefallen: ein Werkzeug, das stumm nichts tut, sieht
    /// aus wie ein Werkzeug, an dem es nichts zu sehen gibt. Gemerkt haben wir
    /// es erst, als der Ordner beim Abholen leer war.
    ///
    /// `Caches` ist dort das, was geht. Fuer eine Datei, die ohnehin bei
    /// 256 KB gekappt wird und nur der Fehlersuche dient, ist das richtig —
    /// sie soll gar nicht ueberdauern.
    static let pfad: URL = {
        #if os(tvOS)
        let ordner: FileManager.SearchPathDirectory = .cachesDirectory
        #else
        let ordner: FileManager.SearchPathDirectory = .documentDirectory
        #endif
        return FileManager.default
            .urls(for: ordner, in: .userDomainMask)[0]
            .appendingPathComponent("swiftly.log")
    }()

    static func schreib(_ text: String) {
        // Ein Fehlersuch-Werkzeug gehört nicht in die ausgelieferte Fassung:
        // die Datei liegt in `Documents`, wird in iCloud gesichert und wächst
        // im Betrieb bis 256 KB. `Logger` bleibt, der ist dafür gemacht.
        #if !DEBUG
        return
        #else
        print(text)
        let stempel = String(format: "%.3f", Date().timeIntervalSince1970)
        let zeile = "\(stempel) \(text)\n"
        sperre.lock(); defer { sperre.unlock() }
        if griff == nil {
            let fm = FileManager.default
            if !fm.fileExists(atPath: pfad.path) {
                fm.createFile(atPath: pfad.path, contents: nil)
            }
            // Beim Start kappen, wenn sie gross geworden ist. Sie dient der
            // Fehlersuche, nicht der Archivierung.
            if let groesse = try? fm.attributesOfItem(atPath: pfad.path)[.size] as? Int,
               groesse > 256 * 1024 {
                try? Data().write(to: pfad)
            }
            griff = try? FileHandle(forWritingTo: pfad)
            // `_ =`, weil `seekToEnd()` den neuen Versatz zurueckgibt und
            // `try?` daraus ein `UInt64?` macht, das niemand liest.
            _ = try? griff?.seekToEnd()
        }
        try? griff?.write(contentsOf: Data(zeile.utf8))
        #endif
    }
}

#if os(iOS)
/// Was VLC über die Wiedergabe wissen muss. Alle Zeiten in Millisekunden.
///
/// Diese Methoden ruft VLC aus seinem eigenen Thread — deshalb keine
/// Main-Actor-Isolation und kein Zugriff auf die Oberfläche.
final class MediaController: NSObject, VLCPictureInPictureMediaControlling {
    private let player: VLCMediaPlayer
    init(player: VLCMediaPlayer) { self.player = player }

    func play()  { player.play() }
    func pause() { player.pause() }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        player.jump(withOffset: Int32(clamping: offset), completion: completion)
    }

    func mediaLength() -> Int64    { Int64(player.media?.length.intValue ?? 0) }
    func mediaTime() -> Int64      { Int64(player.time.intValue) }
    func isMediaSeekable() -> Bool { player.isSeekable }
    func isMediaPlaying() -> Bool  { player.isPlaying }
}
#endif

/// Die View, in der das Bild landet — und zugleich VLCs Zeichenfläche.
///
/// `drawable` nimmt laut Header eine UIView direkt an. Genau das wird hier
/// genutzt, statt ein eigenes Objekt dazwischenzuschalten: VLC hängt seine
/// Bildfläche ein und erwartet, dass sie **sofort** hängt. Ein Umweg über
/// `Task { @MainActor in … }` kommt zu spät — bei jedem Sprung baut VLC den
/// Videoausgang neu auf, und die Fläche wurde nie angehängt. Genau daran lag
/// das Standbild nach dem Spulen, samt festgefahrenem Player.
///
/// Für Bild-im-Bild genügt `VLCPictureInPictureDrawable`; dessen beide
/// Rückgaben kollidieren nicht mit UIView. Die Konformität steht weiter
/// unten in einer eigenen Erweiterung — auf tvOS gibt es kein Bild-im-Bild,
/// und eine bedingte Vererbungsliste ginge nur mit unbalanciertem Rumpf.
///
/// **Diese Datei liegt bewusst in `Shared`.** Alles hier — der
/// `mkv_trusted`-Kniff, die Startposition als Medienoption, die
/// Stillstandserkennung, das Neuverbinden nach Netzwechsel — gilt auf beiden
/// Plattformen wörtlich gleich. Zweimal gepflegt liefe es auseinander, und
/// ausgerechnet der Sprungfehler käme auf einer Seite zurück.
@MainActor
final class VLCPlayerView: Basisansicht {

    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "player")

    /// Nur für die Fehlersuche: legt Bild-im-Bild vollständig still, damit
    /// sich messen lässt, ob VLCs Videoausgang dadurch anders aufgebaut wird.
    /// Swiftfin hat kein PiP — und Swiftfin springt schnell.
    static var pipAbgeschaltet = false

    let player = VLCMediaPlayer()

    #if os(iOS)
    fileprivate lazy var controller = MediaController(player: player)
    fileprivate var pipWindow: VLCPictureInPictureWindowControlling?

    var onPiPAvailable: ((Bool) -> Void)?
    var onPiPStateChanged: ((Bool) -> Void)?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        backgroundColor = .black
        #else
        // AppKit kennt keine Hintergrundfarbe auf der Ansicht; sie sitzt auf
        // der Ebene, und die muss dafuer erst angefordert werden.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        #endif

        // **VLCs eigenes Protokoll — und zwar dorthin, wo es lesbar ist.**
        //
        // Es lief auf `VLCConsoleLogger`, also auf die Systemkonsole. Am
        // Fernseher kommt da niemand heran; die Zeilen, die sagen, woran der
        // Demuxer haengt, waren geschrieben und trotzdem unerreichbar.
        // Derselbe Fehler wie beim eigenen Protokoll, das in `Documents`
        // schrieb, wo tvOS nichts schreiben laesst: ein Werkzeug, das lautlos
        // ins Leere laeuft, sieht aus wie eines, das nichts zu melden hat.
        #if DEBUG
        VLCLibrary.shared().loggers = [Dateiprotokoll()]
        #endif

        // Muss die View selbst sein: VLC prüft die Zeichenfläche auf
        // VLCPictureInPictureDrawable, und die Schnittstelle sitzt hier.
        // Auf die Innenansicht gelegt, wird PiP nie bereit — und gebracht
        // hat die Innenansicht ohnehin nichts.
        player.drawable = self
        player.delegate = melder
        melder.beginntZuSpielen = { [weak self] in
            Task { @MainActor in self?.startpositionSetzen() }
        }

        // VLC 4 verbindet eine abgerissene HTTP-Verbindung nicht neu. In
        // modules/access/http/resource.c gibt es zwar ein 'retry:', das gilt
        // aber nur fuer Anmeldung und Weiterleitung, nicht fuer einen Abriss
        // mitten im Strom. Der prefetch-Puffer (16 MiB, gut zehn Sekunden)
        // laeuft dann leer und danach steht das Bild. Genau deshalb haengen
        // sich Plex und Streamyfin an derselben Stelle auf.
        netzwache.pathUpdateHandler = { [weak self] pfad in
            let strecke = pfad.availableInterfaces.map(\.name).joined(separator: ",")
            let erreichbar = pfad.status == .satisfied
            Task { @MainActor in self?.streckeGewechselt(strecke, erreichbar: erreichbar) }
        }
        melder.zustandWechsel = { [weak self] zustand in
            Task { @MainActor in self?.zustandGewechselt(zustand) }
        }
        netzwache.start(queue: DispatchQueue(label: "de.paulherter.swiftly.netz"))
    }

    // MARK: - Netzwechsel und Haenger

    private let netzwache = NWPathMonitor()
    private var letzteStrecke: String?
    private var letzteAdresse: URL?
    private var letzterContainer: String?
    private var letzterNeuaufbau = Date.distantPast
    private var wachhund: Timer?
    private var letzteBekannteZeit: Int32 = -1
    private var stehtSeit: Date?
    private var netzErreichbar = true
    private var wartetAufNetz = false
    private var netzwechselSeit: Date?
    private var einsteuernSeit: Date?
    /// Vom Benutzer beendet. Ohne das wuerde das Schliessen des Players
    /// selbst als Abriss gelten und den Strom wieder aufmachen.
    private var absichtlichBeendet = false
    /// Solange gesetzt, hat der frisch aufgebaute Strom seine Stelle noch
    /// nicht erreicht. Bis dahin darf seine Zeit die gute Stelle nicht
    /// ueberschreiben — sonst merkt sich der Wachhund die Sekunden, die der
    /// neue Strom von vorn abspielt, und die Rettung landet beim naechsten
    /// Mal am Filmanfang.
    private var erstStelle: Double?

    /// Der Strom wird gerade neu aufgebaut.
    ///
    /// Die Oberflaeche braucht das: beim Abriss liest VLC ein Dateiende,
    /// setzt die Zeit auf die Laenge und wirft das Bild weg. Ohne dieses
    /// Wissen zeigt der Schieber das Filmende und der Schirm bleibt schwarz —
    /// als waere der Film zu Ende, statt dass nur die Leitung fehlt.
    private(set) var stelltWiederHer = false {
        didSet {
            guard oldValue != stelltWiederHer else { return }
            onWiederherstellung?(stelltWiederHer)
        }
    }
    var onWiederherstellung: ((Bool) -> Void)?

    /// Die Stelle, die der Oberflaeche waehrend des Wiederaufbaus angezeigt
    /// werden soll — statt des Filmendes, auf das VLC gesprungen ist.
    var guteStelle: Double { letzteGutePosition }

    /// Der Strom steuert seine Startstelle noch an.
    ///
    /// Solange das laeuft, meldet VLC die Zeit des noch nicht gesprungenen
    /// Stroms — also fast null. Wer die anzeigt, laesst den Schieber erst auf
    /// Anfang stehen und dann sichtbar nach vorn springen.
    var stelltEin: Bool { startposition != nil || erstStelle != nil }

    /// Ob fuer diesen Strom `mkv_trusted` gesetzt wurde — siehe `oeffnen`.
    private(set) var matroskaVertraut = false

    // MARK: Sprung ueber die Byte-Stelle

    /// **Ob Spruenge ueber die Zeit bei dieser Datei etwas taugen.**
    ///
    /// Gemessen, nicht angenommen. Bei einer Folge las VLC den Index der Datei
    /// und brach beim Auswerten ab — „MKV/Ebml Parser: m_el[mi_level] == NULL",
    /// danach „loading cues done" mit null Eintraegen. Fuer den naechsten
    /// Sprung waehlte es dann `fpos 3154, pts 0`, also den Dateianfang, und
    /// las sich 125 MB vorwaerts. Bei 11 Mbit/s ist das anderthalb Minuten
    /// fuer einen Sprung, und beim naechsten faengt es von vorn an.
    ///
    /// Beide VLCKit-Fassungen im Haus verhalten sich gleich; dieselbe Datei
    /// laeuft in Swiftfin auf VLCKit 3 sofort. Es ist also kein Fehler der
    /// Alpha, sondern eine Datei, deren Index VLC 4 nicht lesen kann.
    /// **Nur zur Messung, nicht als Weiche.**
    ///
    /// Erster Anlauf sprang bei unbrauchbarem Index ueber den Byte-Anteil
    /// statt ueber die Zeit. Gemessen: das landet **genauso** am Dateianfang.
    /// VLC 4 schickt beide durch denselben Sucher, und der hat ohne
    /// Sprungpunkte nur die schon gelesenen Cluster. Der Rueckfall war also
    /// derselbe Weg unter anderem Namen — und weil er zusaetzliche Spruenge
    /// ausloest, von denen jeder neu vorwaerts liest, machte er es schlimmer.
    ///
    /// Was bleibt, ist die Frage: kam der Sprung an? Sie steht im Protokoll
    /// und haelt die Notbremse zurueck, solange noch einer unterwegs ist.
    private var offenesZiel: Double?
    private var offenSeit: Date?
    /// Wie oft fuer dieses Ziel schon ein anderer Weg probiert wurde.
    private var sprungStufe = 0
    /// Wann zuletzt ein Sprung angestossen wurde — egal ob er ankam.
    private var letzterSprungbefehl = Date.distantPast
    /// Ob fuer diese Datei der zweite Weg der bessere ist — einmal gemessen,
    /// dann fuer alle weiteren Spruenge gemerkt.
    private var zeitsetzenBesser = false



    /// Ob VLC schon ein Bild ausgibt. Davor ist die Flaeche schwarz.
    var zeigtBild: Bool { player.hasVideoOut }

    /// Die letzte Stelle, an der die Wiedergabe nachweislich lief.
    ///
    /// Der Wert ist der Kern der Rettung. Beim Abriss liest VLC ein
    /// Dateiende, setzt die Zeit auf die Laenge des Films und geht auf
    /// Stopped — wer die Position erst dann abfragt, bekommt das Filmende
    /// zurueck und baut dort wieder auf. Genau das ist passiert: schwarzes
    /// Bild in der letzten Sekunde. Deshalb wird die Stelle laufend
    /// mitgeschrieben, solange das Bild wirklich vorwaerts geht.
    private var letzteGutePosition: Double = 0

    private var laengeSekunden: Double {
        guard let ms = player.media?.length.intValue, ms > 0 else { return 0 }
        return Double(ms) / 1000
    }

    /// Beim Wechsel WLAN <-> Mobilfunk bekommt das Geraet eine andere
    /// Quelladresse — die bestehende TCP-Verbindung ist damit tot, ohne dass
    /// jemand sie schliesst.
    ///
    /// Ohne Netz hat ein Aufbau keinen Zweck; der Versuch wuerde nur die
    /// Sperrfrist verbrauchen und den echten Versuch beim Wiederkommen
    /// blockieren. Stattdessen wird vorgemerkt, dass noch etwas offen ist.
    private func streckeGewechselt(_ strecke: String, erreichbar: Bool) {
        let vorher = letzteStrecke
        letzteStrecke = strecke
        netzErreichbar = erreichbar

        guard erreichbar else {
            if letzteGutePosition > 1 { wartetAufNetz = true }
            Protokoll.schreib("[Netz] kein Weg mehr — vorgemerkt bei \(Int(letzteGutePosition)) s")
            return
        }
        // Lief die Wiedergabe schon nicht mehr, sofort ran.
        if wartetAufNetz {
            Protokoll.schreib("[Netz] wieder da (\(strecke)) → nachholen")
            wartetAufNetz = false
            neuVerbinden(grund: "Netz zurueck")
            return
        }
        guard let vorher, vorher != strecke else { return }

        // Hier wurde frueher sofort neu aufgebaut — und damit ein voller
        // Puffer weggeworfen, aus dem VLC noch minutenlang haette spielen
        // koennen. Der Wechsel wird nur vermerkt; eingegriffen wird erst,
        // wenn das Bild wirklich steht. Ist die Unterbrechung kuerzer als der
        // Vorlauf, merkt niemand etwas.
        netzwechselSeit = Date()
        Protokoll.schreib("[Netz] Wechsel: \(vorher) → \(strecke) — Puffer laeuft weiter")
    }

    /// Ein Abriss sieht aus wie ein Filmende. Unterschieden wird an der
    /// letzten guten Stelle: liegt die deutlich vor dem Schluss, war es kein
    /// Ende, sondern ein toter Strom.
    private func zustandGewechselt(_ zustand: VLCMediaPlayerState) {
        // Bei jedem Wechsel nachziehen: sonst zeigt der Knopf im
        // Bild-im-Bild-Fenster weiter Wiedergabe, obwohl pausiert ist.
        refreshPiPState()
        guard !absichtlichBeendet else { return }
        guard zustand == .stopped || zustand == .stopping || zustand == .error else { return }
        let laenge = laengeSekunden
        guard letzteGutePosition > 1 else { return }
        // Kennt VLC die Laenge nicht, laesst sich Abriss und gewolltes Ende
        // nicht unterscheiden. Dann nur eingreifen, wenn kurz zuvor die
        // Strecke gewechselt hat — sonst baut jeder Stopp den Strom in
        // Schleife wieder auf.
        let frisch = netzwechselSeit.map { Date().timeIntervalSince($0) < 90 } ?? false
        guard laenge > 0 ? letzteGutePosition < laenge - 10 : frisch else { return }
        Protokoll.schreib("[Netz] Zustand \(zustand.rawValue): Strom tot bei \(Int(letzteGutePosition)) s von \(Int(laenge)) s")
        neuVerbinden(grund: "Strom abgerissen")
    }

    /// **Ist der Sprung angekommen, wo er hinsollte?**
    ///
    /// Ohne diese Frage bleibt „gesprungen" eine Absicht. Kommt VLC nicht an,
    /// wird der andere der beiden Sprungwege versucht — welcher taugt, haengt
    /// an der Datei, siehe `seek(toSeconds:)`.
    ///
    /// Zweieinhalb Sekunden Frist: ein Sprung ueber einen brauchbaren Index
    /// sitzt in unter einer Sekunde — eine Bereichsanfrage, ein Cluster,
    /// fertig. Laenger zu warten verzoegert nur den Weg, der ankommt.
    private func sprungNachmessen() {
        guard let ziel = offenesZiel, let seit = offenSeit else { return }
        guard Date().timeIntervalSince(seit) > 2.5 else { return }

        let ist = positionSeconds
        let daneben = abs(ist - ziel)
        if daneben <= 5 {
            offenesZiel = nil
            offenSeit = nil
            return
        }

        // **Erst den anderen Weg, dann erst den Server.**
        //
        // Der zweite Versuch kostet nichts als einen weiteren Sprungbefehl —
        // und wenn er ankommt, bleibt die Datei bei Direct Play, ohne dass
        // der Server etwas tun muss. Erst wenn auch er nicht ankommt, ist es
        // wirklich die Datei und nicht der Weg.
        if sprungStufe == 0 {
            sprungStufe = 1
            zeitsetzenBesser.toggle()
            Protokoll.schreib("[VLC] Sprung auf \(Int(ziel)) s kam nicht an (steht bei \(Int(ist)) s) → anderer Weg")
            sprungAusloesen(auf: ziel, ueberZeit: zeitsetzenBesser)
            offenSeit = Date()
            return
        }

        // **Hier endet es.** Frueher bat an dieser Stelle der Server, ab der
        // Zielstelle zu liefern — er packte den Strom dafuer um. Das war der
        // Notausgang, solange VLC 4 in manchen Matroska-Dateien nicht springen
        // konnte. Seit dem Patch am mkv-Sucher springt der Abspieler selbst;
        // kommt ein Sprung trotzdem auf beiden Wegen nicht an, ist das ein
        // Befund und keine Gelegenheit, die Grundregel der App zu brechen.
        zeitsetzenBesser.toggle()
        Protokoll.schreib("[VLC] Sprung auf \(Int(ziel)) s kam auf beiden Wegen nicht an")
        offenesZiel = nil
        offenSeit = nil
    }

    /// Zweite Absicherung fuer Abrisse, bei denen VLC im Zustand Playing
    /// bleibt und nur die Zeit stehen bleibt — Funkloch, Serveraussetzer.
    private func stillstandPruefen() {
        // Zweiter Weg fuer den Startsprung, falls kein Zustandswechsel kommt.
        if startposition != nil { startpositionSetzen() }

        guard !absichtlichBeendet, player.media != nil, player.isPlaying else { return }

        sprungNachmessen()

        let jetzt = player.time.intValue
        let stelle = Double(jetzt) / 1000

        // Steuert der Strom noch seine Startstelle an? Dann steht die Zeit
        // naturgemaess — das ist kein Haenger, und gemerkt wird auch nichts.
        //
        // Diese Pruefung muss *hier* stehen und nicht als Riegel davor: sie
        // ist zugleich die einzige Stelle, die erstStelle wieder loescht. Als
        // vorgezogener guard hat sie sich selbst blockiert, der Ladeschirm
        // blieb ewig stehen und nur der Ton lief.
        if let ziel = erstStelle {
            stehtSeit = nil
            letzteBekannteZeit = jetzt
            if stelle >= ziel - 10 {
                erstStelle = nil
            } else {
                einsteuernSeit = einsteuernSeit ?? Date()
                // Notbremse: kommt der Sprung nie an, darf die Oberflaeche
                // trotzdem nicht fuer immer im Ladeschirm haengen.
                if Date().timeIntervalSince(einsteuernSeit!) > 20 {
                    Protokoll.schreib("[VLC] Einsteuern auf \(Int(ziel)) s aufgegeben, weiter bei \(Int(stelle)) s")
                    erstStelle = nil
                    einsteuernSeit = nil
                }
            }
            return
        }
        einsteuernSeit = nil
        guard startposition == nil else { stehtSeit = nil; return }

        if stelltWiederHer, jetzt > 0 {
            stelltWiederHer = false
            Protokoll.schreib("[Netz] wiederhergestellt bei \(Int(stelle)) s")
        }

        if jetzt != letzteBekannteZeit {
            letzteBekannteZeit = jetzt
            stehtSeit = nil
            let laenge = laengeSekunden
            // Nur mitschreiben, was plausibel ist: nach einem Abriss stuende
            // hier sonst das Filmende drin.
            if stelle > 0, laenge <= 0 || stelle < laenge - 1 {
                letzteGutePosition = stelle
            }
            return
        }

        let seit = stehtSeit ?? Date()
        stehtSeit = seit
        // Nach einem Streckenwechsel ist ein Stillstand erklaert — dann muss
        // nicht lange gewartet werden. Sonst koennte es auch ein zaeher
        // Server sein, da ist Geduld besser als ein Abriss.
        let frisch = netzwechselSeit.map { Date().timeIntervalSince($0) < 90 } ?? false
        let dauer = Date().timeIntervalSince(seit)
        guard dauer >= (frisch ? 2 : 6) else { return }

        // **Wer puffert, lebt — und dem reisst man nichts ab.**
        //
        // Gemessen an einer HEVC-Folge, die minutenlang „lud": der Puffer
        // stieg auf 52 %, sechs Sekunden spaeter riss die Notbremse den Strom
        // ab, der Wiederaufbau kostete zehn Sekunden samt neuem Sprung, und
        // danach fing dasselbe von vorn an. Die Bremse hat den Haenger nicht
        // behoben, sie hat ihn erzeugt.
        //
        // Die Bremse ist fuer Abrisse da — Funkloch, Serveraussetzer. Dort
        // waechst nichts mehr. Waechst der Puffer noch, ist der Strom zaeh,
        // und Geduld ist die richtige Antwort. Erst wenn auch er stillsteht,
        // ist es ein Abriss.
        // **Ein laufender Sprung ist kein Abriss.**
        //
        // Bei einer Datei mit unlesbarem Index liest VLC sich nach jedem
        // Sprung vom Dateianfang vorwaerts. Das dauert, und die Bremse hat
        // genau dort zugeschlagen: abreissen, zehn Sekunden neu aufbauen,
        // neu springen — und dasselbe von vorn. Sie hat den Haenger nicht
        // behoben, sondern verewigt.
        //
        // Der Puffermelder allein reicht als Schutz nicht: waehrend dieser
        // Phase liefert VLCKit gar keine Puffer-Rueckrufe, obwohl VLC intern
        // von 0 auf 99 Prozent zaehlt. Gemessen im Geraeteprotokoll.
        // **Auch nach einem gescheiterten Sprung nicht abreissen.**
        //
        // Gemessen: bei einer Datei mit unlesbarem Index kam der Sprung auf
        // keinem der beiden Wege an; danach stand `offenesZiel` wieder auf
        // nichts, die Bremse griff — und riss den Strom ab, waehrend VLC sich
        // gerade vorwaerts las. Der Wiederaufbau kostete zehn Sekunden und
        // begann von vorn. Sie hat den Haenger nicht behoben, sondern
        // verewigt, und zwar so lange, bis jemand den Player verlaesst.
        //
        // Zwanzig Sekunden Ruhe nach jedem Sprungbefehl. Das war eine
        // Minute, solange ein Sprung in einer Datei mit kaputtem Index
        // beliebig lange dauern konnte; seit dem VLC-Patch sitzt er in
        // Millisekunden. Kuerzer ist besser: solange die Frist laeuft, ist
        // die Absicherung gegen echte Abrisse ausgesetzt.
        if offenesZiel != nil || Date().timeIntervalSince(letzterSprungbefehl) < 20 {
            Protokoll.schreib("[Netz] Bild steht seit \(Int(dauer)) s, Sprung noch unterwegs → abwarten")
            return
        }

        if melder.pufferWuchsVor < 4 {
            Protokoll.schreib("[Netz] Bild steht seit \(Int(dauer)) s, Puffer waechst noch → abwarten")
            return
        }

        neuVerbinden(grund: "Bild steht seit \(Int(dauer)) s")
    }

    /// Strom neu aufmachen und an die letzte gute Stelle springen.
    ///
    /// Das ist erst seit 'mkv_trusted' eine gute Idee: vorher hat der Sprung
    /// zurueck zwanzig Sekunden gekostet und die Rettung waere schlimmer
    /// gewesen als der Schaden. Jetzt sind es rund fuenfzig Millisekunden.
    private func neuVerbinden(grund: String) {
        guard let adresse = letzteAdresse, letzteGutePosition > 1 else { return }

        guard netzErreichbar else {
            wartetAufNetz = true
            Protokoll.schreib("[Netz] \(grund), aber kein Netz — vorgemerkt bei \(Int(letzteGutePosition)) s")
            return
        }
        // Nach einem Wechsel meldet der Monitor mehrfach. Ohne Sperrfrist
        // wuerde der Strom in Schleife neu aufgebaut und nie fertig.
        guard Date().timeIntervalSince(letzterNeuaufbau) > 5 else { return }
        letzterNeuaufbau = Date()
        stehtSeit = nil
        letzteBekannteZeit = -1
        stelltWiederHer = true
        Protokoll.schreib("[Netz] \(grund) → Strom neu aufbauen bei \(Int(letzteGutePosition)) s")
        // Der Versatz bleibt: dieselbe Adresse liefert wieder ab derselben
        // Stelle, gesprungen wird nur der Rest.
        oeffnen(url: adresse, abSekunden: max(letzteGutePosition, 0),
                container: letzterContainer)
    }


    /// Startposition setzen, sobald VLC springen kann.
    ///
    /// Nicht als ':start-time'-Option: die zwingt VLC, schon beim Oeffnen zu
    /// springen, und das kostet ein Vielfaches.
    ///
    /// Haengt bewusst **nicht** allein am Zustandswechsel nach Playing. Baut
    /// man den Strom neu auf, waehrend VLC schon spielt, bleibt es intern bei
    /// Playing — es kommt kein Uebergang, der Rueckruf feuert nie und der
    /// neue Strom laeuft ab Sekunde 0. Genau daran ist die Rettung nach dem
    /// Netzwechsel gescheitert. Der Wachhund ruft deshalb ebenfalls hier an.
    private func startpositionSetzen() {
        guard let ziel = startposition else { return }
        guard ziel > 1 else {
            startposition = nil
            erstStelle = nil
            return
        }
        // Vor dem ersten Bild verpufft ein Sprung wirkungslos.
        guard player.isSeekable, player.time.intValue > 0 else { return }
        startposition = nil
        Protokoll.schreib("[VLC] Startposition gesetzt: \(Int(ziel)) s (von \(Int(positionSeconds)) s)")
        // Ueber denselben Weg wie jeder andere Sprung — samt Nachmessung.
        // Die Startstelle ist der Sprung, der am meisten weh tut, wenn der
        // Index nichts hergibt: er kommt vor dem ersten Bild.
        seek(toSeconds: ziel)
    }

    private var startposition: Double?

    /// Meldet VLCs Zustand. Eigenes Objekt, weil VLCKit aus seinem eigenen
    /// Thread meldet — eine Main-Actor-isolierte View dort aufzurufen ist
    /// unter Swift 6 ein sofortiger Absturz.
    private lazy var melder = Zustandsmelder(player: player)

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("nicht aus Storyboards") }

    /// VLC hängt seine Renderfläche ohne Rahmen ein und baut sie nach einem
    /// Sprung neu auf. Ohne das hier bleibt sie 0 × 0 oder klebt in der Ecke.
    override func didAddSubview(_ subview: Basisansicht) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = Basisansicht.mitwachsend
    }

    /// Sonst zieht die Fläche nach Bild-im-Bild die Größe des kleinen
    /// Fensters als Wunschmaß hinter sich her.
    override var intrinsicContentSize: CGSize {
        CGSize(width: Basisansicht.ohneWunschmass, height: Basisansicht.ohneWunschmass)
    }

    /// Der Layout-Haken heisst in beiden Bausaetzen anders. Der Rumpf ist
    /// derselbe und steht deshalb nur einmal da.
    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        flaechenNachziehen()
    }
    #else
    override func layout() {
        super.layout()
        flaechenNachziehen()
    }
    #endif

    private func flaechenNachziehen() {
        for sub in subviews { sub.frame = bounds }
    }

    #if os(iOS)
    var isPiPPossible: Bool { pipWindow != nil }

    /// Warum PiP gerade nicht geht — für die Oberfläche.
    var pipUnavailableReason: String? {
        if !AVPictureInPictureController.isPictureInPictureSupported() {
            // Trifft im Simulator immer zu: AVKit meldet dort
            // isPictureInPictureSupported = NO. Nur echte Geräte können PiP.
            return String(localized: "Dieses Gerät unterstützt kein Bild-im-Bild. Der Simulator kann es grundsätzlich nicht — auf dem iPhone geht es.")
        }
        if pipWindow == nil { return String(localized: "Bild-im-Bild wird vorbereitet…") }
        return nil
    }
    func startPiP() { pipWindow?.startPictureInPicture() }
    func stopPiP()  { pipWindow?.stopPictureInPicture() }
    #endif

    /// Nach jeder Zustandsänderung nötig, sonst laufen PiP-Fenster und
    /// Player auseinander.
    ///
    /// Auf tvOS ein Nichtstuer — bewusst nicht wegoperiert, damit die
    /// Aufrufstellen in `pause`, `resume` und `stop` auf beiden Plattformen
    /// dieselben bleiben.
    func refreshPiPState() {
        #if os(iOS)
        guard !Self.pipAbgeschaltet else { return }
        pipWindow?.invalidatePlaybackState()
        #endif
    }

    /// Öffnet die Datei und beginnt bei `abSekunden`.
    ///
    /// Die Startposition geht als Medienoption mit, statt nach dem Öffnen
    /// gesprungen zu werden. Das Springen war die Ursache dafür, dass
    /// fortgesetzte Titel nur ein Standbild zeigten: bei großen Dateien über
    /// HTTPS dauert ein Sprung länger als die Wartezeit, die Position las sich
    /// noch als alt, es wurde erneut gesprungen — und der Demuxer kam nie zur
    /// Ruhe. Von vorn gestartete Titel liefen deshalb, fortgesetzte nicht.
    func play(url: URL, abSekunden: Double = 0, container: String? = nil) {
        // Die Sitzung wird beim App-Start eingerichtet. Hier nur prüfen und
        // notfalls nachziehen — mit sichtbarem Fehler statt stillem try?.
        //
        // Den ganzen Abschnitt gibt es auf dem Mac nicht: `AVAudioSession`
        // ist dort nicht verfügbar. macOS mischt und leitet den Ton selbst,
        // eine Sitzung muss keine App anmelden. Das ist kein fehlendes
        // Stück, sondern eine Aufgabe, die dort entfällt.
        #if !os(macOS)
        let sitzung = AVAudioSession.sharedInstance()
        if sitzung.sampleRate < 1 {
            do {
                try sitzung.setCategory(.playback, mode: .moviePlayback)
                try sitzung.setActive(true)
                Protokoll.schreib("[Audio] nachgezogen · \(Int(sitzung.sampleRate)) Hz")
            } catch {
                Protokoll.schreib("[Audio] FEHLER: \(error.localizedDescription)")
            }
        }
        Protokoll.schreib("[Audio] beim Öffnen: \(Int(sitzung.sampleRate)) Hz · aktiv seit Start")
        #endif

        letzteAdresse = url
        letzterContainer = container
        letzteGutePosition = abSekunden
        absichtlichBeendet = false
        offenesZiel = nil
        offenSeit = nil
        sprungStufe = 0
        zeitsetzenBesser = false

        wachhund?.invalidate()
        wachhund = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stillstandPruefen() }
        }

        oeffnen(url: url, abSekunden: abSekunden, container: container)
    }

    /// Der eigentliche Aufbau — auch der Weg zurueck nach einem Netzwechsel.
    private func oeffnen(url: URL, abSekunden: Double, container: String?) {
        guard let medium = VLCMedia(url: url) else {
            Self.log.error("Medium ließ sich nicht öffnen: \(url.ohneGeheimnis, privacy: .public)")
            return
        }

        // Diese eine Option steht hier nach dem Lesen von VLCs MKV-Demuxer,
        // nicht auf Verdacht. Sie ist der Grund, warum Sprünge jetzt sitzen.
        //
        // VLC 4 registriert den Matroska-Demuxer zweimal (mkv.cpp:85–93):
        //
        //     Open        → OpenInternal(…, trust_cues: false)   Rang 50
        //     OpenTrusted → OpenInternal(…, trust_cues: true )   Rang  0
        //
        // Der reguläre Weg misstraut also dem Index der Datei. Jeder Cue-Punkt
        // wird nur als QUESTIONABLE eingetragen (matroska_segment.cpp:213),
        // und beim Sprung siebt find_greatest_seekpoints_in_range über
        // get_first_seekpoint_around(…, TrustLevel = TRUSTED) genau die wieder
        // aus. Übrig bleiben die Cluster, die ohnehin schon gelesen wurden —
        // also der Dateianfang.
        //
        // Zum Gegenprüfen scannt VLC den Bereich mit index_range(). Das aber
        // hängt an b_fastseekable (matroska_segment_seeker.cpp:321), und das
        // ist über HTTP immer false: der prefetch-Filter meldet
        // STREAM_CAN_FASTSEEK grundsätzlich nicht (prefetch.c:355), also setzt
        // mkv.cpp:130 das Flag auf false. Der Index ist damit gelesen,
        // vorhanden — und wird verworfen.
        //
        // Gemessen: Sprung auf 1546 s in einer 10,3-GB-Datei ging auf Byte
        // 16 601 095, das sind rund 12 Sekunden Film. Von dort spulte VLC
        // still vor, daher die 20+ Sekunden.
        //
        // VLC 3 kennt keine Vertrauensstufen und nimmt die Cues immer. Genau
        // deshalb springt Swiftfin, das auf MobileVLCKit (Fassung 3) sitzt, in
        // einer halben Sekunde. Das Untermodul 'mkv_trusted' stellt dieses
        // Verhalten in Fassung 4 wieder her — es hat Rang 0 und wird nie von
        // allein gewählt, nur über seinen Namen.
        //
        // Nur für Matroska setzen: die Option erzwingt den Demuxer, und für
        // MP4 oder TS wäre sie schlicht falsch.
        // Vorlauf vergroessern: 'prefetch-buffer-size' zaehlt in KiB, die
        // Vorgabe von 1<<14 sind 16 MiB — bei rund 11 Mbit/s knapp elf
        // Sekunden. 64 MiB geben etwa dreiviertel Minute.
        //
        // Der Puffer traegt ueber einen Netzwechsel, weil prefetch.c in Read()
        // den Fehler erst prueft, wenn nichts mehr drin ist:
        //
        //     while ((copy = BufferLevel(stream, &eof)) == 0 && !eof)
        //         if (sys->error) { … return 0; }
        //
        // Erst ist der Puffer leer, dann faellt der Strom auf. Genau deshalb
        // wird beim Streckenwechsel nichts abgerissen, sondern abgewartet.
        //
        // **Und genau das kostete beim Springen.**
        //
        // 65536 KiB waren 64 MiB, das Vierfache der Vorgabe. Ein Vorlauf
        // traegt aber nur, solange er steht — bei jedem Sprung wirft VLC ihn
        // weg und fuellt neu, und bis dahin bewegt sich kein Bild. Gemessen an
        // einer Folge, bei der Springen dreissig bis fuenfzig Sekunden
        // brauchte: der Puffer stieg in vier Sekunden auf 96 %, die Leitung
        // war also nie das Problem — er war nur zu gross, um schnell wieder
        // voll zu sein. Dieselbe Datei laeuft in Swiftfin sofort, und
        // Swiftfin setzt diese Option nicht.
        //
        // 16384 KiB sind VLCs Vorgabe, rund elf Sekunden bei 11 Mbit/s. Der
        // Netzwechsel bleibt damit ueberbrueckt, nur nicht mehr eine
        // dreiviertel Minute lang — und das ist der bessere Tausch: ein
        // Wechsel kommt selten, ein Sprung bei jeder Folge.
        // **Gemessen: der Filter laesst sich so nicht abwaehlen.** Mit
        // Groesse null laedt er trotzdem, nur eben ohne Puffer — schlechter
        // als vorher. `STREAM_CAN_FASTSEEK` bleibt aus, und damit bleibt der
        // Bereichs-Scan der Matroska unerreichbar. Zurueck auf 16 MiB.
        medium.addOption(":prefetch-buffer-size=16384")


        // **Die Entscheidung muss ablesbar sein.**
        //
        // Sie ist der Unterschied zwischen „Sprung sitzt" und „Sprung landet
        // am Dateianfang und braucht zwanzig Sekunden". Fällt sie falsch,
        // sieht man ihr das nicht an — man sieht nur einen Player, der beim
        // Spulen an den Anfang springt, und sucht überall sonst.
        matroskaVertraut = istMatroska(container: container, url: url)
        if matroskaVertraut {
            medium.addOption(":demux=mkv_trusted")
            Protokoll.schreib("[VLC] Matroska erkannt → Demuxer mkv_trusted (Cues gelten)")
        }

        startposition = abSekunden
        erstStelle = abSekunden > 1 ? abSekunden : nil
        melder.neuBeginnen()
        Protokoll.schreib("[VLC] Öffne \(url.lastPathComponent), Startposition \(Int(abSekunden)) s")
        player.media = medium
        player.play()
        refreshPiPState()
    }

    /// Entscheidend ist der *ausgelieferte* Container, nicht der der Datei:
    /// bei Direct Stream packt der Server um. Jellyfins Adresse trägt ihn als
    /// Endung („…/stream.mkv"), deshalb hat die Vorrang. Der gemeldete
    /// Container ist nur der Rückfall, wenn keine Endung dasteht.
    private func istMatroska(container: String?, url: URL) -> Bool {
        let namen: Set<String> = ["mkv", "matroska", "webm", "mka", "mks"]
        let endung = url.pathExtension.lowercased()
        if !endung.isEmpty { return namen.contains(endung) }
        guard let container else { return false }
        return container.lowercased().split(separator: ",").contains {
            namen.contains($0.trimmingCharacters(in: .whitespaces))
        }
    }

    func pause()  { player.pause(); refreshPiPState() }
    func resume() { player.play();  refreshPiPState() }
    func stop() {
        absichtlichBeendet = true
        wachhund?.invalidate()
        wachhund = nil
        // netzwache bleibt: cancel() ist endgueltig, und dieselbe View spielt
        // beim Folgenwechsel weiter. Sie kostet im Leerlauf nichts.
        player.stop()
    }

    // MARK: - Spuren und Geschwindigkeit

    /// Verfuegbare Tonspuren. Bei Direct Play sind das die echten Spuren der
    /// Datei — inklusive DTS und TrueHD, die ein AVPlayer nie zu sehen bekaeme.
    var tonspuren: [VLCMediaPlayer.Track] { player.audioTracks }
    var untertitelspuren: [VLCMediaPlayer.Track] { player.textTracks }

    var gewaehlteTonspur: VLCMediaPlayer.Track? { player.audioTracks.first(where: \.isSelected) }
    var gewaehlterUntertitel: VLCMediaPlayer.Track? { player.textTracks.first(where: \.isSelected) }

    /// VLCs Zaehlwerk: verworfene Bilder, Bitraten, Dekoderbloecke.
    ///
    /// **Nur lesend, greift in nichts ein.** Sie beantwortet die eine Frage,
    /// die man einer flatternden Wiedergabe sonst nicht ansieht: laeuft die
    /// Datei wirklich glatt, oder sieht sie nur glatt aus, weil VLC still
    /// Bilder wegwirft? `lostPictures` steigt dann, `displayedPictures`
    /// bleibt zurueck — und genau das ist bei einer App, die niemals
    /// transkodieren will, der Unterschied zwischen „geht" und „geht
    /// gerade noch".
    ///
    /// `nil`, solange kein Medium geladen ist.
    var statistik: VLCMedia.Stats? { player.media?.statistics }

    /// Wählt Ton- und Untertitelspur nach den Voreinstellungen.
    ///
    /// Verglichen wird über den Spurnamen, weil VLC keine Sprachkennung
    /// herausgibt — je nach Datei steht dort „German", „Deutsch" oder „ger".
    /// Findet sich nichts, bleibt es bei dem, was die Datei vorgibt: eine
    /// falsche Spur wäre schlimmer als keine Wahl.
    func wendeSprachenAn(ton: String, untertitel: String, automatisch: Bool) {
        var tonPasst = false
        if !ton.isEmpty,
           let treffer = player.audioTracks.first(where: {
               Sprache.passt($0.trackName, zu: ton)
           }) {
            treffer.isSelectedExclusively = true
            tonPasst = true
        } else if !ton.isEmpty {
            // Kein Treffer heißt: der Ton läuft nicht in der Wunschsprache.
            tonPasst = false
        } else {
            tonPasst = true   // keine Vorgabe, also nichts einzuwenden
        }

        // „Automatisch" heißt: nur einschalten, wenn der Ton nicht passt.
        if automatisch, tonPasst {
            deselectAllTextTracks()
            return
        }
        guard !untertitel.isEmpty else {
            if !automatisch { return }   // ohne Wunschsprache nichts erzwingen
            deselectAllTextTracks()
            return
        }
        if let treffer = player.textTracks.first(where: {
            Sprache.passt($0.trackName, zu: untertitel)
        }) {
            treffer.isSelectedExclusively = true
        }
    }

    private func deselectAllTextTracks() {
        player.textTracks.forEach { $0.isSelected = false }
    }

    func waehleTonspur(_ spur: VLCMediaPlayer.Track) {
        spur.isSelectedExclusively = true
    }

    /// `nil` schaltet Untertitel ab.
    func waehleUntertitel(_ spur: VLCMediaPlayer.Track?) {
        if let spur { spur.isSelectedExclusively = true }
        else { player.deselectAllTextTracks() }
    }

    /// 1.0 ist normal. VLC nimmt Werte zwischen 0,25 und 4.
    var tempo: Float {
        get { player.rate }
        set { player.rate = newValue; refreshPiPState() }
    }

    // MARK: - Position

    /// Aktuelle Position in Sekunden.
    var positionSeconds: Double { Double(player.time.intValue) / 1000 }

    /// Gesamtlaenge in Sekunden. 0, solange VLC die Datei noch liest.
    var durationSeconds: Double {
        guard let ms = player.media?.length.intValue, ms > 0 else { return 0 }
        // Der Server liefert die Restlaenge; die Oberflaeche braucht die
        // ganze. Bei Versatz null ist beides dasselbe.
        return Double(ms) / 1000
    }

    var isPlaying: Bool { player.isPlaying }

    /// Springt an eine absolute Stelle.
    ///
    /// Bewusst über `jump(withOffset:)` statt `player.time = …`. Aus dem
    /// Geräteprotokoll: bei `time =` forderte VLC für Sekunde 1222 das Byte
    /// 21,7 MB an — also Sekunde 30 — und las sich von dort 2,3 GB weit
    /// sequenziell vor. Das dauerte 28 Sekunden. Derselbe Sprung über
    /// `jump(withOffset:)` fordert sofort das richtige Byte an (22,5 % der
    /// Datei) und ist nach sechs Sekunden da.
    /// **Zwei Wege, und welcher taugt, entscheidet die Datei.**
    ///
    /// `jump(withOffset:)` und `player.time = …` landen in VLC 4 in
    /// verschiedenen Suchern. Fuer eine Datei war `jump` der schnelle und
    /// `time` brauchte 28 Sekunden — das steht seit damals in
    /// `Erfahrungen.md`. Fuer eine andere ist es genau umgekehrt: dort sind
    /// die Sprungpunkte unlesbar, `jump` liest ab Dateianfang vorwaerts, und
    /// `time` sitzt sofort. Swiftfin nimmt immer `time` und springt in dieser
    /// Datei ohne Verzoegerung — bei Direct Play, also derselben Rohdatei.
    ///
    /// Es gibt also keinen Weg, der immer richtig ist. Statt einen zu waehlen
    /// und zu hoffen, wird der erste versucht und **nachgemessen**; kommt er
    /// nicht an, nimmt der naechste den anderen. Das kostet einmal je Datei
    /// ein paar Sekunden und danach nie wieder.
    func seek(toSeconds seconds: Double) {
        melder.sprungJetzt()
        sprungAusloesen(auf: seconds, ueberZeit: zeitsetzenBesser)
        sprungBeobachten(ziel: seconds)
        refreshPiPState()
    }

    private func sprungAusloesen(auf sekunden: Double, ueberZeit: Bool) {
        if ueberZeit {
            Protokoll.schreib("[VLC] Sprung auf \(Int(sekunden)) s ueber die Zeit (von \(Int(positionSeconds)) s)")
            player.time = VLCTime(int: Int32(clamping: Int(sekunden * 1000)))
        } else {
            let abstand = sekunden - positionSeconds
            Protokoll.schreib("[VLC] Sprung auf \(Int(sekunden)) s ueber den Abstand \(Int(abstand)) s")
            player.jump(withOffset: Int32(clamping: Int(abstand * 1000)), completion: {})
        }
    }

    /// Merkt sich, wohin gesprungen werden sollte — `sprungNachmessen` sieht
    /// eine Sekunde spaeter nach, ob es geklappt hat.
    private func sprungBeobachten(ziel: Double) {
        offenesZiel = ziel
        offenSeit = Date()
        sprungStufe = 0
        letzterSprungbefehl = Date()
    }


    func jump(seconds: Int32) {
        melder.sprungJetzt()
        let zeile = "[VLC] Sprung um \(seconds) s von \(Int(positionSeconds)) s"
        Self.log.info("\(zeile, privacy: .public)")
        player.jump(withOffset: seconds * 1000, completion: {})
        refreshPiPState()
    }
}


/// Nimmt VLCs Bildfläche auf und hält sie auf voller Größe.
///
/// VLC hängt seine Fläche als Unteransicht ein, ohne ihr einen Rahmen zu
/// geben — sie blieb dadurch in der Ecke hängen.
final class Zeichenflaeche: Basisansicht {
    override func didAddSubview(_ subview: Basisansicht) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = Basisansicht.mitwachsend
    }

    /// Sonst zieht die Fläche nach Bild-im-Bild die Größe des kleinen
    /// Fensters als Wunschmaß hinter sich her.
    override var intrinsicContentSize: CGSize {
        CGSize(width: Basisansicht.ohneWunschmass, height: Basisansicht.ohneWunschmass)
    }

    /// Der Layout-Haken heisst in beiden Bausaetzen anders. Der Rumpf ist
    /// derselbe und steht deshalb nur einmal da.
    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        flaechenNachziehen()
    }
    #else
    override func layout() {
        super.layout()
        flaechenNachziehen()
    }
    #endif

    private func flaechenNachziehen() {
        for sub in subviews { sub.frame = bounds }
    }
}

/// Beobachtet VLCs Zustand — bewusst ohne Actor-Isolation, weil VLCKit aus
/// einem eigenen Thread meldet.
#if DEBUG
/// Leitet VLCs eigene Meldungen in dieselbe Datei wie unsere.
///
/// **Gefiltert, nicht vollstaendig.** Auf `debug` schreibt VLC hunderte Zeilen
/// je Sekunde; ungefiltert waere die Datei nach Sekunden an ihrer Grenze und
/// das Protokollieren selbst der Engpass. Durchgelassen wird, was die Frage
/// beantwortet, wo die Wartezeit herkommt: Zugriffsschicht, Demuxer, Puffer,
/// Decoder — dazu alles, was VLC selbst als Fehler oder Warnung einstuft.
final class Dateiprotokoll: NSObject, VLCLogging, @unchecked Sendable {
    var level: VLCLogLevel = .debug

    /// **Nach Inhalt sieben, nicht nach Modul.**
    ///
    /// Erster Anlauf liess nur Meldungen bestimmter Module durch — mkv,
    /// avcodec, videotoolbox. Im Protokoll standen daraufhin ausschliesslich
    /// `http` und `libvlc`: VLCKit reicht den Modulnamen fuer die meisten
    /// Meldungen gar nicht durch. Der Filter hat also genau das
    /// weggeworfen, wonach gesucht wurde, und das Ergebnis sah aus wie
    /// Funkstille. Geblieben ist nur das, was VLC selbst als Fehler
    /// einstufte.
    ///
    /// Jetzt andersherum: alles behalten, ausser dem HTTP-Rahmenverkehr. Der
    /// ist die eigentliche Flut — tausend Zeilen in dreissig Sekunden —, und
    /// er sagt nichts, was die Bereichsanfragen nicht schon sagen.
    private static let flut = ["frame of", "window update", "setting:", "headers:"]

    func handleMessage(_ nachricht: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let text = nachricht.lowercased()
        guard !Self.flut.contains(where: { text.contains($0) }) else { return }
        let modul = context?.module ?? "?"
        Protokoll.schreib("[vlc/\(modul)] \(nachricht)")
    }
}
#endif

final class Zustandsmelder: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    private weak var player: VLCMediaPlayer?
    private let lock = NSLock()
    private var letzterSprung: Date?

    init(player: VLCMediaPlayer) {
        self.player = player
        super.init()
    }

    func sprungJetzt() {
        lock.lock(); letzterSprung = Date(); lock.unlock()
    }

    private var pufferstand: Float = 0
    private var pufferWuchsZuletzt = Date.distantPast

    /// **Wann der Puffer zuletzt gewachsen ist.**
    ///
    /// Das ist der Unterschied zwischen „langsam" und „tot". Ein abgerissener
    /// Strom fuellt nichts mehr; ein zaeher fuellt weiter, nur nicht schnell
    /// genug. Wer beides gleich behandelt, reisst genau dem den Boden weg,
    /// der gerade dabei ist, sich zu fangen.
    var pufferWuchsVor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(pufferWuchsZuletzt)
    }

    private var seitSprung: String {
        lock.lock(); defer { lock.unlock() }
        guard let letzterSprung else { return "—" }
        return String(format: "%.1f", Date().timeIntervalSince(letzterSprung))
    }

    /// Wird beim ersten Übergang nach Playing gerufen.
    var beginntZuSpielen: (() -> Void)?
    var zustandWechsel: ((VLCMediaPlayerState) -> Void)?
    private var hatGespielt = false

    /// Vor einem neuen Aufbau: sonst bliebe die Startposition ungesetzt, weil
    /// der Uebergang nach Playing nur beim ersten Mal gemeldet wird.
    func neuBeginnen() {
        lock.lock(); defer { lock.unlock() }
        hatGespielt = false
    }

    func mediaPlayerStateChanged(_ neu: VLCMediaPlayerState) {
        let name = VLCMediaPlayerStateToString(neu)
        let position = Int((player?.time.intValue ?? 0) / 1000)
        Protokoll.schreib("[VLC] Zustand: \(name) · Position \(position) s · \(seitSprung) s nach Sprung")

        // Unter derselben Sperre wie neuBeginnen(): der Zustand kommt aus
        // VLCs Thread, das Zuruecksetzen vom Hauptthread.
        lock.lock()
        let erstmals = (neu == .playing && !hatGespielt)
        if erstmals { hatGespielt = true }
        lock.unlock()

        if erstmals { beginntZuSpielen?() }
        zustandWechsel?(neu)
    }

    private var letzteMeldung = Date.distantPast

    func mediaPlayerBufferingChanged(_ fortschritt: Float) {
        // Der Wert kommt als 0,0–1,0. Und die Meldung feuert dutzendfach je
        // Sekunde — ungedrosselt bremst allein das Protokollieren die App.
        guard fortschritt < 1 else { return }
        lock.lock()
        // Ein Ruecksetzer auf null ist der Beginn eines neuen Fuellens, kein
        // Rueckschritt — sonst gaelte der Neuanlauf als Stillstand.
        //
        // **Nur der Sprung auf null, nicht das Verharren dort.** Vorher stand
        // hier `fortschritt == 0`, und das trifft auch einen Puffer, der
        // dauerhaft bei null steht: jeder Rueckruf frischte den Zeitstempel
        // auf, `pufferWuchsVor` blieb bei null, und die Notbremse haette in
        // genau der Lage, fuer die es sie gibt, nie ausgeloest. Gefunden von
        // der iOS-Sitzung beim Gegenlesen; in unserer Messung kamen in dieser
        // Lage gar keine Rueckrufe, der Fehler war also nie zu sehen — eine
        // Luecke in der Logik, kein beobachteter Ausfall.
        if fortschritt > pufferstand || (fortschritt == 0 && pufferstand > 0) {
            pufferWuchsZuletzt = Date()
        }
        pufferstand = fortschritt
        let faellig = Date().timeIntervalSince(letzteMeldung) > 1
        if faellig { letzteMeldung = Date() }
        lock.unlock()
        guard faellig else { return }
        Protokoll.schreib("[VLC] puffert: \(Int(fortschritt * 100)) %")
    }
}

#if os(iOS)
// MARK: - Bild-im-Bild

/// Der Grund für diese App — und der Grund, warum sie VLCKit 4 statt 3
/// einbindet. Auf tvOS gibt es das nicht: dort ist der Fernseher schon das
/// große Bild, und ein kleines daneben hat kein Zuhause.
extension VLCPlayerView: @preconcurrency VLCPictureInPictureDrawable {

    func mediaController() -> VLCPictureInPictureMediaControlling { controller }

    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)? {
        if Self.pipAbgeschaltet {
            Protokoll.schreib("[VLC] Bild-im-Bild für diesen Lauf abgeschaltet")
            return nil
        }
        return { [weak self] window in
            Task { @MainActor in
                guard let self else { return }
                self.pipWindow = window
                window?.stateChangeEventHandler = { [weak self] started in
                    Task { @MainActor in self?.onPiPStateChanged?(started) }
                }
                self.onPiPAvailable?(window != nil)
            }
        }
    }
}
#endif
