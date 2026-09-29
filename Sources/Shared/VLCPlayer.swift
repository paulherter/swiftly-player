import AVFoundation
import AVKit
import CoreText
import CryptoKit
import ImageIO
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

/// **Wie Textuntertitel aussehen** (SRT, WebVTT, ASS ohne eigenen Stil).
///
/// VLCs Vorgabe war Helvetica Neue, 6,25 % der Bildhoehe, dicke schwarze
/// Kontur (4 % der Schrifthoehe) und ein harter halbdunkler Versatz — laut
/// und billig. Vorbild ist Netflix: halbfett, weiss, feine Kontur, leichter
/// Schatten, etwas hoeher ueber dem Rand. Linux, Windows und Android setzen
/// dieselben Werte (`Abspieler.swift`, `PlayerSeite.kt`).
///
/// - **Schrift:** Inter SemiBold liegt der App bei (`Mittel/`, OFL). Die
///   Systemschrift erreicht VLC nicht: `fonts/darwin.c` sucht ueber CoreText
///   nach Familiennamen, SF Pro ist dort unsichtbar. Angemeldet fuer den
///   Prozess findet CoreText Inter und liefert VLC den Dateipfad.
/// - **Groesse:** Faktor auf VLCs Vorgabe (6,25 % der
///   Bildhoehe). Am Fernseher etwas groesser, weil man weiter weg sitzt.
/// - **Kontur/Schatten:** `outline-thickness` ist Prozent der Schrifthoehe;
///   3 statt VLCs 4. VLC kann keinen weichen Schatten, deshalb nur ein
///   kurzer, halbdurchsichtiger Versatz nach unten. Auf hellem Bild gegen
///   2 % Kontur verglichen: die wirkte dort hohl und schlecht lesbar.
/// - **Rand:** `sub-margin` in Bildpunkten des Videos; VLC 4 setzt den Text
///   sonst dichter an die Unterkante als VLC 3.
///
/// ASS mit eigenem Stil zeichnet libass, Bilduntertitel (PGS, VobSub, DVB)
/// sind fertige Bilder — beide bleiben, wie sie sind.
enum Untertitelstil {
    static let schriftname = "Inter18pt-SemiBold"

    static let vlcOptionen = [
        "--freetype-font=\(schriftname)",
        "--freetype-color=16777215",
        "--freetype-outline-thickness=3",
        "--freetype-outline-opacity=230",
        "--freetype-shadow-opacity=120",
        "--freetype-shadow-distance=0.04",
        "--freetype-shadow-angle=-70",
        "--sub-margin=30",
    ]

    /// Faktor auf VLCs Vorgabe (1 = 6,25 % der Bildhoehe).
    @MainActor static var groesse: Float {
        #if os(tvOS)
        0.88
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 0.82 : 0.78
        #else
        0.78
        #endif
    }

    static func schriftAnmelden() {
        guard let adresse = Bundle.main.url(forResource: "Inter-SemiBold", withExtension: "ttf") else {
            Protokoll.schreib("[Untertitel] Inter-SemiBold.ttf fehlt im Paket")
            return
        }
        var fehler: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(adresse as CFURL, .process, &fehler) {
            Protokoll.schreib("[Untertitel] Schrift nicht angemeldet: \(fehler?.takeRetainedValue().localizedDescription ?? "?")")
        }
    }
}

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
        // **Der Speicher gilt in jedem Bau** — daraus teilt der Nutzer sein
        // Protokoll (`Protokollring`, Profil → „Protokoll teilen"). Geschwärzt wird
        // dort beim Eintragen.
        Protokollring.geteilt.anhaengen(text)

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

/// **Die ersten Sekunden nach dem Öffnen, auf die Millisekunde.**
///
/// Gemeldet am 27.09.2026: auf allen Geräten hängt das Bild etwa eine
/// Sekunde nach jedem Start einmal kurz, danach läuft es. Das Technikschild
/// sieht davon nichts — es mittelt über eine Sekunde. Welcher der Kandidaten
/// es ist (Tonausgang und Uhr, Spurwahl, Ladeschirm, erste Meldung an den
/// Server, blockierter Hauptlauf), sagt nur eine Zeitachse. Jede Zeile trägt
/// deshalb `[Start] +ms` ab dem Öffnen und landet im geteilten Protokoll.
///
/// Läuft nur die ersten ``dauer`` Sekunden nach einem Öffnen. Im Debug-Bau
/// an, sonst aus — der 10-ms-Takt soll nicht bei den Testern laufen.
/// Einschalten: Schlüssel `startmessung` auf `true` in den Standardwerten.
/// Gehört wieder entfernt, sobald die Ursache feststeht.
final class Startmessung: @unchecked Sendable {
    static let geteilt = Startmessung()

    /// So lange nach dem Öffnen wird gemessen.
    static let dauer: TimeInterval = 4

    static var an: Bool {
        #if DEBUG
        UserDefaults.standard.object(forKey: "startmessung") as? Bool ?? true
        #else
        UserDefaults.standard.bool(forKey: "startmessung")
        #endif
    }

    private let sperre = NSLock()
    private var beginn: Date?

    /// Neuer Start: die Uhr beginnt bei null.
    func beginnen() {
        guard Self.an else { return }
        sperre.lock(); beginn = Date(); sperre.unlock()
    }

    /// Millisekunden seit dem Öffnen, oder `nil` außerhalb des Fensters.
    var millisekunden: Int? {
        sperre.lock(); defer { sperre.unlock() }
        guard let beginn else { return nil }
        let seit = Date().timeIntervalSince(beginn)
        return seit <= Self.dauer ? Int(seit * 1000) : nil
    }

    /// Eine Zeile mit Zeitstempel — nur im Fenster, aus jedem Thread.
    func marke(_ text: String) {
        guard let ms = millisekunden else { return }
        Protokoll.schreib("[Start] +\(ms) ms \(text)")
    }

    /// VLC-Meldungen, die im Fenster zusätzlich durchgelassen werden: alles,
    /// was von Uhr, Tonausgang und verspäteten Bildern handelt.
    static let vlcStichworte = ["late", "early", "sampl", "discontinu", "flush",
                                "jitter", "drift", "screwed", "clock", "restart",
                                "buffering done", "decoder wait", "first picture",
                                "aout", "vout"]

    /// Von den `debug`-Zeilen nur die, die sagen, wann der Ton wirklich
    /// anläuft und ob die Uhr danach umspringt. Eng gefasst: auf `debug`
    /// meldet VLC hunderte Zeilen je Sekunde, und wer alle schreibt, misst
    /// das Schreiben mit.
    static let vlcDebugStichworte = ["deferring start", "starting late", "outputlatency",
                                     "iobufferduration", "displayed late", "clock context",
                                     "resetting master clock", "discontinuity", "too late",
                                     "audio output", "output on", "underrun",
                                     "timing report", "sample renderer started", "timebase came up"]
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

    /// **Eine eigene Bibliothek, damit VLC keine Bilder vorab wegwirft.**
    ///
    /// DVD-Rips ruckelten auf Apple TV und iPhone, 4K-HEVC nicht; beim
    /// Kollegen alle DVD-Rips, also auch progressive. Rückmeldung am Gerät:
    /// dekodiert Ø 22,6–25,4, gezeigt Ø 22,6–23,7, verworfen bis 298.
    ///
    /// **Der Ausgabeweg, im tvOS-Simulator protokolliert** (dessen VLCKit ist
    /// wie am Geraet mit TARGET_OS_IPHONE gebaut): `samplebufferdisplay`
    /// nimmt nur `CVPX_BGRA` (VLCSampleBufferDisplay.m, CreateCVPXConverter).
    /// Software-Bilder laufen deshalb `I420 -> swscale -> BGRA -> cvpx`, jedes
    /// Bild auf der CPU. HEVC kommt von VideoToolbox schon als CVPixelBuffer.
    /// Der Mac nimmt einen anderen Weg (`vout_macosx`, OpenGL) und zeigt
    /// davon nichts.
    ///
    /// **Verworfen wird vor dem Zeichnen, nach einer Schaetzung.** Der vout
    /// nimmt den *Hoechstwert* von Filter- und Renderdauer
    /// (video_output.c, IsPictureLateToStaticFilter) und wirft ein Bild weg,
    /// wenn es danach zu spaet kaeme. Eine einzige Zeitspitze im Wandler
    /// kostet so ganze Bilder, obwohl die CPU nicht ausgelastet ist.
    ///
    /// Gemessen am 15.09.2026 gegen 33e3c0e, tvOS-Simulator, Prozess auf
    /// Hintergrund gedrosselt, nachgebaute Dateien (MPEG-2 720×576 5 Mbit/s,
    /// AC-3 5.1, VobSub, MKV), je 25 s, Deinterlace `bob`:
    ///
    ///     Einstellung                          gezeigt/s   verloren
    ///     Vorgabe, interlaced (2 Laeufe)       12,4–12,8   311
    ///     Vorgabe, progressiv (2 Laeufe)       14,0–16,4   211–284
    ///     --no-drop-late-frames, interlaced    24,9–25,3   0
    ///     --no-drop-late-frames, progressiv    24,0–24,9   0
    ///     :no-drop-late-frames (Medium)        11,2        344
    ///     --no-skip-frames allein              15,5        230
    ///     --swscale-mode=0                     15,2        246
    ///
    /// Ungedrosselt laeuft alles mit 25/s. **Als Medienoption wirkt es
    /// nicht:** der vout haengt am Player und erbt von der Bibliothek, nicht
    /// vom Eingang. `initWithOptions:` haengt an VLCKits Vorgaben an
    /// (VLCLibrary.m:169), es geht also nichts verloren. Android setzt die
    /// Option in `Spielwerk` seit jeher.
    ///
    /// Was es kostet: ein wirklich zu spaetes Bild wird kurz spaet gezeigt
    /// statt weggelassen. Bei VideoToolbox-Material tritt das kaum ein.
    /// Quellen: code.videolan.org/videolan/vlc/-/merge_requests/3436
    /// (samplebufferdisplay), VLC-Quelltext im Baubaum.
    static let bibliothek: VLCLibrary = {
        Untertitelstil.schriftAnmelden()
        // `--deinterlace-mode=bob` aus demselben Grund hier und nicht am
        // Medium — siehe `oeffnen`, Abschnitt „Entflechten".
        return VLCLibrary(options: ["--no-drop-late-frames", "--deinterlace-mode=bob"]
                          + Untertitelstil.vlcOptionen)
    }()

    let player = VLCMediaPlayer(library: VLCPlayerView.bibliothek)

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
        VLCPlayerView.bibliothek.loggers = [Dateiprotokoll()]
        player.currentSubTitleFontScale = Untertitelstil.groesse

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
        melder.untertitelHinzu = { [weak self] in
            Task { @MainActor in self?.offenenUntertitelSetzen() }
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

    /// Letzter Stand der beiden VLC-Zaehler, fuer ``bildfluss(jetzt:)``.
    /// `nil` heisst: noch kein Vergleichswert, also noch kein Urteil.
    private var letzteBilder: UInt64?
    private var letzteBytes: UInt64?
    private var stehtSeit: Date?
    private var netzErreichbar = true
    private var wartetAufNetz = false
    private var netzwechselSeit: Date?
    private var einsteuernSeit: Date?
    /// Vom Benutzer beendet. Ohne das wuerde das Schliessen des Players
    /// selbst als Abriss gelten und den Strom wieder aufmachen.
    private var absichtlichBeendet = false
    /// `stop()` ist endgueltig: die Flaeche wird danach abgeraeumt. Getrennt
    /// von `absichtlichBeendet`, weil `play` jenes zuruecksetzt. Ein spaeter
    /// Folgenwechsel spielte sonst auf der abgeraeumten Flaeche weiter —
    /// Ton ohne Bild (Audit 16.09.2026, T1-H3).
    private var endgueltigGestoppt = false
    /// Solange gesetzt, hat der frisch aufgebaute Strom seine Stelle noch
    /// nicht erreicht. Bis dahin darf seine Zeit die gute Stelle nicht
    /// ueberschreiben — sonst merkt sich der Wachhund die Sekunden, die der
    /// neue Strom von vorn abspielt, und die Rettung landet beim naechsten
    /// Mal am Filmanfang.
    private var erstStelle: Double?

    /// **Stumm, solange die Startstelle angesteuert wird.**
    ///
    /// Der Sprung auf die gemerkte Stelle geht bewusst *nach* dem Öffnen los
    /// und nicht als `:start-time` — siehe `startpositionSetzen()`. Er braucht
    /// dafür ein laufendes Bild (`player.time > 0`). Das Bild ist in dieser
    /// Zeit ausgeblendet, der **Ton war es nicht**: man hörte rund eine
    /// Sekunde vom Anfang der Folge, dann sprang es an die richtige Stelle.
    ///
    /// Gemeldet auf dem Mac, betrifft aber jede Plattform — es ist derselbe
    /// Weg.
    ///
    /// Geregelt über die Lautstärke, **nicht** über `isMuted`: für
    /// `setMuted:` ist bei VLCKit eine Verklemmung gemeldet (Fehler 111).
    private var lautstaerkeVorher: Int32?

    private func tonZurueckhalten(_ zurueck: Bool) {
        // **Der stille Ausgang.** Gibt es den Tonausgang beim Oeffnen noch
        // nicht, faellt der Rueckhalt hier lautlos aus — und der Zuschauer
        // hoert genau die Sekunde vom Anfang, die er nicht hoeren soll.
        // 09.2026 wieder gemeldet, obwohl der Rueckhalt gebaut ist; ob es
        // dieser Ausgang ist, sagt nur eine Messung.
        guard let ton = player.audio else {
            Protokoll.schreib("[Ton] Rueckhalt(\(zurueck)) ohne Tonausgang — wirkungslos")
            return
        }
        if zurueck {
            guard lautstaerkeVorher == nil else { return }
            // **Was VLC vor dem ersten Ton meldet, ist kein Messwert.**
            //
            // `tonZurueckhalten(true)` laeuft in `oeffnen(…)`, also bevor
            // `player.media` gesetzt ist — der Tonausgang existiert da noch
            // gar nicht und `volume` steht auf 0 oder -1. Gemerkt und spaeter
            // „wiederhergestellt" hiess damit: dauerhaft stumm.
            //
            // Genau das.
            let jetzt = ton.volume
            lautstaerkeVorher = jetzt > 0 ? jetzt : 100
            ton.volume = 0
            Protokoll.schreib("[Ton] stumm ab jetzt (war \(jetzt), gemerkt \(lautstaerkeVorher!))")
        } else if let vorher = lautstaerkeVorher {
            lautstaerkeVorher = nil
            Startmessung.geteilt.marke("Ton freigegeben")
            let ziel = vorher > 0 ? vorher : 100
            if Self.uebergabeAufblenden {
                Self.uebergabeAufblenden = false
                tonAufblenden(ton, auf: ziel)
            } else {
                ton.volume = ziel
                Protokoll.schreib("[Ton] wieder laut (\(vorher))")
            }
            tonstandMelden()
        }
    }

    /// **Wo der Ton nach dem Freigeben steht** — Teil der ``Startmessung``.
    /// Lautstärke und Stummschaltung, wie VLC sie liest, ob Tonpuffer
    /// wirklich gespielt werden, und wie die Tonsitzung dasteht — für den
    /// Fall, dass nach einem Start Bild ohne Ton kommt.
    private func tonstandMelden() {
        guard Startmessung.an else { return }
        for verzoegerung in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + verzoegerung) { [weak self] in
                guard let self, let ton = self.player.audio else { return }
                let stat = self.player.media?.statistics
                var zeile = "Tonstand · Lautstärke \(ton.volume) · stumm \(ton.isMuted)"
                    + " · Ton dekodiert \(stat?.decodedAudio ?? 0), gespielt \(stat?.playedAudioBuffers ?? 0),"
                    + " verloren \(stat?.lostAudioBuffers ?? 0)"
                #if !os(macOS)
                let sitzung = AVAudioSession.sharedInstance()
                let ausgaenge = sitzung.currentRoute.outputs.map { "\($0.portType.rawValue)/\($0.channels?.count ?? 0)" }
                zeile += " · Sitzung \(sitzung.category.rawValue)/\(sitzung.mode.rawValue)"
                    + " Politik \(sitzung.routeSharingPolicy.rawValue) Optionen \(sitzung.categoryOptions.rawValue)"
                    + " · Ausgang \(ausgaenge.joined(separator: ",")) · Systemlautstärke \(sitzung.outputVolume)"
                    + " · andere spielen \(sitzung.isOtherAudioPlaying)"
                #endif
                Startmessung.geteilt.marke(zeile)
            }
        }
    }

    /// **Die nächste Wiedergabe kommt aus einer Übergabe** („Hier
    /// weiterschauen"): sie startet stumm und blendet den Ton auf, sobald
    /// ihr erstes Bild steht — statt mit voller Lautstärke unter der Karte
    /// loszulegen. Gilt für genau einen Start.
    static var uebergabeAufblenden = false

    /// **Das stehende Bild als Bild** — für die Karte des Abgebers, die in
    /// einer eigenen Ebene über allem liegt. VLC schreibt es als PNG; hier
    /// wird bis 0,6 s darauf gewartet. `breite` in Pixeln, Seitenverhältnis
    /// bleibt. `nil`, wenn nichts kam.
    func standbild(breite: Int) async -> CGImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uebergabe-\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: url.path, withWidth: Int32(breite), andHeight: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .milliseconds(15))
            guard let quelle = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(quelle) == .statusComplete,
                  let bild = CGImageSourceCreateImageAtIndex(quelle, 0, nil) else { continue }
            return bild
        }
        return nil
    }

    /// Linear auf `ziel` in 0,6 s, in Schritten von 40 ms — VLC hat keine
    /// eigene Rampe. Über die Lautstärke, nicht `isMuted` (siehe oben).
    private func tonAufblenden(_ ton: VLCAudio, auf ziel: Int32) {
        Protokoll.schreib("[Ton] Übergabe: blendet auf (\(ziel))")
        let schritte = 15
        Task { @MainActor [weak self] in
            for i in 1 ... schritte {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !self.absichtlichBeendet, self.lautstaerkeVorher == nil else { return }
                ton.volume = Int32(Double(ziel) * Double(i) / Double(schritte))
            }
        }
    }


    /// **Sicherheitsnetz gegen dauerhafte Stille.**
    ///
    /// Der Ton wird an genau einer Stelle zurueckgehalten und an vier wieder
    /// freigegeben. Wird eine davon je uebersehen — oder kommt ein Weg dazu,
    /// den heute niemand kennt —, bleibt der Film stumm, und das ist der
    /// schlimmste stille Fehler, den dieser Player haben kann. Deshalb prueft
    /// der Takt es zusaetzlich: wird nicht mehr eingesteuert, darf nichts
    /// mehr zurueckgehalten werden.
    private func tonFreigebenFallsFaellig() {
        guard lautstaerkeVorher != nil, !stelltEin else { return }
        Protokoll.schreib("[Ton] Rueckhalt hing noch — freigegeben")
        tonZurueckhalten(false)
    }

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

    /// **Ist der Start ganz abgeschlossen?** Auch der pausierte Start
    /// (`startsprung`) — der setzt am Ziel von selbst fort. Wer vorher
    /// anhält (gemeinsam schauen: „bereit" melden), dem liefe der Film
    /// sonst unter der Hand wieder los.
    var startFertig: Bool { startsprung == nil && !stelltEin }

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
    ///
    /// Nach einem Folgenwechsel erst, wenn das **neue** Medium ein Bild
    /// gezeigt hat — bis dahin gehoeren Bildausgabe und Uhr noch der alten
    /// Folge (`Zeitannahme.bildGehoertDemMedium`).
    var zeigtBild: Bool {
        let bilder = mediumGewechselt ? (player.media?.statistics.displayedPictures ?? 0) : 0
        let gilt = Zeitannahme.bildGehoertDemMedium(bildausgabe: player.hasVideoOut,
                                                    gezeigteBilder: bilder,
                                                    nachWechsel: mediumGewechselt)
        if gilt, mediumGewechselt { mediumGewechselt = false }
        return gilt
    }
    /// `play` auf eine Flaeche, die schon ein Medium hatte.
    private var mediumGewechselt = false

    /// Die letzte Stelle, an der die Wiedergabe nachweislich lief.
    ///
    /// Der Wert ist der Kern der Rettung. Beim Abriss liest VLC ein
    /// Dateiende, setzt die Zeit auf die Laenge des Films und geht auf
    /// Stopped — wer die Position erst dann abfragt, bekommt das Filmende
    /// zurueck und baut dort wieder auf. Genau das ist passiert: schwarzes
    /// Bild in der letzten Sekunde. Deshalb wird die Stelle laufend
    /// mitgeschrieben, solange das Bild wirklich vorwaerts geht.
    private var letzteGutePosition: Double = 0

    private var laengeSekunden: Double { durationSeconds }

    /// Beim Wechsel WLAN <-> Mobilfunk bekommt das Geraet eine andere
    /// Quelladresse — die bestehende TCP-Verbindung ist damit tot, ohne dass
    /// jemand sie schliesst.
    ///
    /// Ohne Netz hat ein Aufbau keinen Zweck; der Versuch wuerde nur die
    /// Sperrfrist verbrauchen und den echten Versuch beim Wiederkommen
    /// blockieren. Stattdessen wird vorgemerkt, dass noch etwas offen ist.
    private func streckeGewechselt(_ strecke: String, erreichbar: Bool) {
        guard !endgueltigGestoppt else { return }
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
        Startmessung.geteilt.marke("Zustand \(VLCMediaPlayerStateToString(zustand))")
        // Bei jedem Wechsel nachziehen: sonst zeigt der Knopf im
        // Bild-im-Bild-Fenster weiter Wiedergabe, obwohl pausiert ist.
        refreshPiPState()
        anzeigeschlafZulassen()

        // Pausierter Start: jeder Wechsel ist ein Anlass, sofort statt beim
        // naechsten Takt — bei Paused ist das der Moment zum Fortsetzen.
        if startsprung != nil { startsprungPruefen(anlass: VLCMediaPlayerStateToString(zustand)) }

        // **Der Knopf folgt der Maschine, nicht der Uhr.**
        //
        // Der Zustand des Abspielknopfes hing bisher am Takt, und der schlägt
        // alle 500 ms (`Wiedergabetakt.taktlaenge`). Der Knopf sprang also bis
        // zu einer halben Sekunde nach dem Druck um.
        //
        // Setzt man ihn stattdessen sofort im Klick, ist er zu **früh**: das
        // Bild braucht noch seine Zeit. Am Mac gemessen, dreimal:
        //
        // Klick → VLC meldet „angehalten"   17–25 ms Klick → Filmzeit steht
        // wirklich   26–36 ms
        //
        // Alle Geräte hier laufen mit **120 Hz**, ein Bild ist also 8,3 ms —
        // das sind drei bis vier Bilder, nicht ein bis zwei. (Hier stand
        // zuerst die Rechnung für 60 Hz; sie hat den Abstand halbiert und
        // damit kleiner aussehen lassen, als er ist.) Das ist der Abstand, den
        //
        // Also weder das eine noch das andere: der Knopf hängt an genau der
        // Meldung, mit der die Maschine selbst umschaltet. Dann sind Knopf und
        // Bild im selben Moment still, und der Abstand verschwindet — nicht,
        // weil er kleiner wird, sondern weil es keine zwei Zeitpunkte mehr
        // gibt.
        //
        // Warum nicht schneller: Jellyfin Media Player und Jellium haben das
        // Problem nicht, aber beide setzen auf **libmpv**, nicht auf libvlc —
        // andere Ausgabewarteschlange. Das ist kein Kniff zum Übernehmen, das
        // ist ein anderer Motor.
        switch zustand {
        case .playing:  pausiertSeit = nil; laeuftGemeldet?(true); verzoegerungNachziehen()
        case .paused:   if pausiertSeit == nil { pausiertSeit = Date() }; laeuftGemeldet?(false)
        default:        break
        }
        guard !absichtlichBeendet else { return }
        guard zustand == .stopped || zustand == .stopping || zustand == .error else { return }
        // Ein Fehler vor dem ersten Bild: das Protokoll sagt es, den Grund
        // nennen die vlc-Zeilen davor. Die Oberfläche erfährt es auch und
        // zeigt „Das startet nicht" statt endlos Schwarz.
        if zustand == .error, letzteGutePosition <= 1 {
            Protokoll.schreib("[VLC] Fehler vor dem ersten Bild")
            startFehlerGemeldet?("VLC-Fehler vor dem ersten Bild")
        }
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

    /// **Wach halten darf nur VLCs Leerlaufsperre, nicht die Bildebene.**
    ///
    /// Bei angehaltenem Film ging das Apple TV nie in den Bildschirmschoner
    /// und nie in den Ruhezustand (gemeldet 22.09.2026). Die Leerlaufsperre war es
    /// nicht: `isIdleTimerDisabled` steht im Simulator gemessen nur beim
    /// Abspielen auf `true` und wird bei Pause und Schliessen sofort `false`,
    /// auch nach 75 s Pause noch — VLCs `uikit_inhibit` haengt an
    /// `vout_ChangePause` und macht das richtig.
    ///
    /// Wach hielt die `AVSampleBufferDisplayLayer`, in die VLC das Bild legt.
    /// `preventsDisplaySleepDuringVideoPlayback` steht auf iOS und tvOS von
    /// Haus aus auf `true`, und die Ebene hat keine eigene Zeitbasis (Rate
    /// immer 1,0). Fuer sie laeuft also jedes Bild, das ankommt — und VLC
    /// legt auch angehalten weiter Bilder nach: das letzte wird alle 80 ms
    /// neu gezeigt (`VOUT_REDISPLAY_DELAY`), gemessen gut 11 je Sekunde, 330
    /// in 30 s Pause. Auf dem Mac nachgestellt: dieselbe Ebene mit dem
    /// Schalter an haelt `PreventUserIdleDisplaySleep`, solange Bilder kommen,
    /// mit dem Schalter aus nichts.
    ///
    /// VLC baut die Ebene bei jedem neuen Bildausgang neu (Folgenwechsel,
    /// Neuaufbau nach Netzabriss), und sie sitzt eine Ebene tiefer in VLCs
    /// eigener Fensteransicht. Deshalb bei jedem Zustandswechsel und jede
    /// Sekunde nachsehen; der Gang durch eine Handvoll Ebenen kostet nichts.
    /// Auf dem Mac steht der Schalter von Haus aus auf `false`, dort ist das
    /// eine Absicherung.
    private func anzeigeschlafZulassen() {
        func freigeben(_ ebene: CALayer) {
            if let bild = ebene as? AVSampleBufferDisplayLayer, bild.preventsDisplaySleepDuringVideoPlayback {
                bild.preventsDisplaySleepDuringVideoPlayback = false
            }
            ebene.sublayers?.forEach(freigeben)
        }
        let wurzel: CALayer? = layer
        wurzel.map(freigeben)
    }

    /// Zweite Absicherung fuer Abrisse, bei denen VLC im Zustand Playing
    /// bleibt und nur die Zeit stehen bleibt — Funkloch, Serveraussetzer.
    private func stillstandPruefen() {
        // Zweiter Weg fuer den Startsprung, falls kein Zustandswechsel kommt.
        if startposition != nil { startpositionSetzen() }

        guard !absichtlichBeendet, player.media != nil, player.isPlaying else { return }

        sprungNachmessen()
        tonFreigebenFallsFaellig()

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
                tonZurueckhalten(false)
            } else {
                einsteuernSeit = einsteuernSeit ?? Date()
                // Notbremse: kommt der Sprung nie an, darf die Oberflaeche
                // trotzdem nicht fuer immer im Ladeschirm haengen.
                if Date().timeIntervalSince(einsteuernSeit!) > 20 {
                    Protokoll.schreib("[VLC] Einsteuern auf \(Int(ziel)) s aufgegeben, weiter bei \(Int(stelle)) s")
                    erstStelle = nil
                    tonZurueckhalten(false)
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
            spurenWiederSetzen()
        }

        if jetzt != letzteBekannteZeit {
            if erstbildPruefen(jetzt: jetzt) { return }
            bildfluss(jetzt: jetzt)
            letzteBekannteZeit = jetzt
            stehtSeit = nil
            // **Die Uhr laeuft — aber kommt auch ein Bild?** Ohne diese
            // Zeilen endete die Pruefung hier, und ein Strom, dessen Uhr
            // weiterlaeuft, galt fuer immer als gesund. Dieselben Schwellen
            // wie unten: `Stromwacht` haelt sie an einer Stelle, und eine
            // falsche davon kostet den Zuschauer zehn Sekunden Film.
            if let seit = bilderStehenSeit {
                let dauer = Date().timeIntervalSince(seit)
                if case .neuVerbinden = Stromwacht.rat(
                    stillstandSeit: dauer,
                    netzwechselVor: netzwechselSeit.map { Date().timeIntervalSince($0) },
                    sprungOffen: offenesZiel != nil,
                    letzterSprungVor: Date().timeIntervalSince(letzterSprungbefehl),
                    pufferWuchsVor: melder.pufferWuchsVor) {
                    bilderStehenSeit = nil
                    neuVerbinden(grund: "kein neues Bild seit \(Int(dauer)) s, Uhr laeuft weiter")
                    return
                }
            }
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
        let dauer = Date().timeIntervalSince(seit)

        // **Die Entscheidung steht in `Stromwacht`, nicht mehr hier.**
        //
        // Fuenf Schwellen, alle gemessen, und eine falsche davon kostet den
        // Zuschauer zehn Sekunden Film — die Bremse hat einmal genau den
        // Haenger erzeugt, den sie beheben sollte. Im Paket ist sie ohne
        // Abspieler pruefbar; die Begruendungen stehen dort je Konstante.
        switch Stromwacht.rat(
            stillstandSeit: dauer,
            netzwechselVor: netzwechselSeit.map { Date().timeIntervalSince($0) },
            sprungOffen: offenesZiel != nil,
            letzterSprungVor: Date().timeIntervalSince(letzterSprungbefehl),
            pufferWuchsVor: melder.pufferWuchsVor
        ) {
        case .nochNicht:
            return
        case .sprungLaeuft:
            Protokoll.schreib("[Netz] Bild steht seit \(Int(dauer)) s, Sprung noch unterwegs → abwarten")
            return
        case .pufferWaechst:
            Protokoll.schreib("[Netz] Bild steht seit \(Int(dauer)) s, Puffer waechst noch → abwarten")
            return
        case .neuVerbinden:
            break
        }

        neuVerbinden(grund: "Bild steht seit \(Int(dauer)) s")
    }

    /// **Die Uhr laeuft, das Bild steht — davon weiss `stillstandPruefen`
    /// nichts.**
    ///
    /// Die Absicherung darueber schlaegt an, wenn die *Zeit* stehen bleibt.
    /// 09.2026 den umgekehrten Fall gemeldet: App lag lange im Hintergrund,
    /// Player auf Pause; zurueck in der App lief es eine halbe Minute, dann
    /// Standbild — und die Zeit lief weiter. Fuer `Stromwacht` ist das ein
    /// gesunder Strom, denn `jetzt` aendert sich jede Sekunde. Sie ist fuer
    /// genau diesen Fehler blind, und zwar bauartbedingt.
    ///
    /// Deshalb hier die zweite Groesse. VLC fuehrt sie selbst mit:
    /// `displayedPictures` sind die gezeigten Bilder, `demuxReadBytes` das,
    /// was ueberhaupt vom Server ankommt. Die beiden zusammen trennen die zwei
    /// Erklaerungen, die sich sonst nicht unterscheiden lassen:
    ///
    /// - Bytes wachsen, Bilder nicht → die Daten kommen, die Ausgabe ist tot.
    /// - Beide stehen → es kommt nichts mehr, die Verbindung ist weg.
    ///
    /// **Noch wird nur mitgeschrieben, nicht eingegriffen.** Welche der beiden
    /// es ist, weiss niemand, und eine Bremse auf Verdacht hat in dieser Datei
    /// schon einmal den Haenger erzeugt, den sie beheben sollte — siehe
    /// `Stromwacht`. Erst messen. Seit wann kein neues Bild mehr ausgegeben
    /// wurde.
    ///
    /// **Der zweite Fuehler, und der bessere.** Die Wacht darueber vergleicht
    /// `player.time`; laeuft die Uhr, gilt der Strom als lebendig. Am
    /// 05.09.2026 lief sie bei Auf dem Geraet gemessen: `displayedPictures`
    /// **76 Sekunden lang** eingefroren auf 15925, Zuwachs von
    /// `demuxReadBytes` durchgehend 0, die Uhr lief in derselben Zeit von 6388
    /// auf 6464 s im Gleichtakt mit der Wanduhr.
    ///
    /// Der Fuehler war die ganze Zeit da — `bildfluss` hat ihn gelesen und
    /// **nur ins Protokoll geschrieben**. Jetzt wirkt er.
    private var bilderStehenSeit: Date?

    private func bildfluss(jetzt: Int32) {
        guard let stat = player.media?.statistics else { return }
        defer {
            letzteBilder = stat.displayedPictures
            letzteBytes = stat.demuxReadBytes
        }
        guard let vorherBytes = letzteBytes,
              Stromwacht.bilderStehen(vorher: letzteBilder, jetzt: stat.displayedPictures) == true
        else {
            bilderStehenSeit = nil
            return
        }
        bilderStehenSeit = bilderStehenSeit ?? Date()

        // Nur der auffaellige Fall kommt ins Protokoll. Jede Sekunde eine
        // Zeile zu schreiben, macht die Datei unlesbar und verdeckt genau
        // den Moment, um den es geht.

        let bytes = Stromwacht.zuwachs(stat.demuxReadBytes, seit: vorherBytes)
        Protokoll.schreib("[Bild] Uhr bei \(jetzt / 1000) s laeuft, aber kein neues Bild"
            + " (gezeigt \(stat.displayedPictures), verloren \(stat.lostPictures),"
            + " neue Bytes \(bytes)) → \(bytes > 0 ? "Daten kommen an, Ausgabe steht" : "es kommt nichts mehr")")
    }

    // MARK: Erstes Bild

    /// Was fuer diesen Titel schon versucht wurde — siehe ``Erstbild``.
    /// Gilt je Titel (`play`), nicht je Aufbau: sonst finge jeder Neuaufbau
    /// wieder bei der ersten Rettung an, und es gaebe nie Ruhe.
    private var erstbildStufe: Erstbild.Stufe = .keine
    /// Filmzeit seit dem letzten Aufbau, in der die Uhr lief. Je Aufbau.
    private var erstbildLauf: TimeInterval = 0
    private var erstbildVorher: TimeInterval?
    /// Nach der zweiten Rettung, oder von Anfang an bei MPEG-4 Part 2, bleibt
    /// es fuer den Titel beim Software-Dekoder — auch ueber einen spaeteren
    /// Netz-Neuaufbau.
    private var softwareDekoder = false
    private var erstbildGesehen = false
    /// Laeuft Bild-im-Bild? Dort zeichnet das System, nicht diese Regel.
    private var bildImBildLaeuft = false
    #if DEBUG
    /// Nur fuer ``Erstbildlauf``: Bildspur behaupten, ohne Serverquelle.
    var testVideospur = false
    /// Nur fuer ``Erstbildlauf``: diese `codec`-Option erzwingen (kein Bild),
    /// solange kein Software-Dekoder angefordert ist — oder immer.
    static var testZwang: (option: String, auchSoftware: Bool)?
    /// Nur fuer Messlaeufe: weitere Optionen am Medium (`Tempolauf`).
    static var testZusatz: [String] = []
    #endif

    /// Fuer das Technikschild: `nil`, solange nicht eingegriffen wurde.
    var erstbildHinweis: String? { Erstbild.hinweis(erstbildStufe) }

    private var hatVideospur: Bool {
        #if DEBUG
        if testVideospur { return true }
        #endif
        return spurQuelle.flatMap(Dateiangaben.videospur) != nil
    }

    /// **Die Uhr laeuft, der Ton spielt — und es kam nie ein Bild.**
    ///
    /// `bildfluss` schweigt dazu: ``Stromwacht/bilderStehen(vorher:jetzt:)``
    /// gibt bei null gezeigten Bildern `nil` zurueck. Die Entscheidung steht
    /// in ``Erstbild`` im Paket; hier nur die Zaehler und die Ausfuehrung.
    /// Laeuft nur, wenn die Uhr weiterging (`stillstandPruefen`), also nie in
    /// Pause, beim Puffern oder waehrend AirPlay (VLC steht dann).
    ///
    /// - Returns: `true`, wenn neu aufgebaut wurde.
    private func erstbildPruefen(jetzt: Int32) -> Bool {
        let stelle = Double(jetzt) / 1000
        erstbildLauf += Erstbild.zuwachs(vorher: erstbildVorher, jetzt: stelle)
        erstbildVorher = stelle
        guard let stat = player.media?.statistics else { return false }
        if stat.displayedPictures > 0 {
            if !erstbildGesehen, erstbildStufe != .keine {
                Protokoll.schreib("[Bild] erstes Bild nach Rettung (\(erstbildStufe)) bei \(Int(stelle)) s"
                    + " · Dekoder \(softwareDekoder ? "Software" : "frei")")
            }
            erstbildGesehen = true
            return false
        }
        let rat = Erstbild.rat(hatVideospur: hatVideospur, ausgenommen: bildImBildLaeuft,
                               gezeigt: stat.displayedPictures, laufzeit: erstbildLauf,
                               bisher: erstbildStufe)
        switch rat {
        case .nichts, .warten: return false
        case .ausgabeNeu, .softwareDekoder, .aufgeben: break
        }
        let spur = player.videoTracks.first
        let server = spurQuelle.flatMap(Dateiangaben.videospur)?.codec ?? "—"
        Protokoll.schreib("[Bild] kein erstes Bild nach \(Int(erstbildLauf)) s Laufzeit bei \(Int(stelle)) s"
            + " · Server \(server) · VLC-Spur \(spur.map { Technikangaben.codecname(vlcKennung: $0.codec) ?? $0.codecName() } ?? "keine")"
            + " · dekodiert \(stat.decodedVideo), gezeigt \(stat.displayedPictures), verloren \(stat.lostPictures)"
            + " · Ton gespielt \(stat.playedAudioBuffers) · Dekoder \(softwareDekoder ? "Software" : "frei") → \(rat)")
        erstbildStufe = Erstbild.naechste(nach: rat, bisher: erstbildStufe)
        guard !endgueltigGestoppt, let adresse = letzteAdresse else { return false }
        switch rat {
        case .ausgabeNeu:
            aufbauen(grund: "kein erstes Bild", ab: stelle, adresse: adresse)
            return true
        case .softwareDekoder:
            softwareDekoder = true
            aufbauen(grund: "kein erstes Bild, jetzt mit Software-Dekoder", ab: stelle, adresse: adresse)
            return true
        default:
            return false
        }
    }

    /// Strom neu aufmachen und an die letzte gute Stelle springen.
    ///
    /// Das ist erst seit 'mkv_trusted' eine gute Idee: vorher hat der Sprung
    /// zurueck zwanzig Sekunden gekostet und die Rettung waere schlimmer
    /// gewesen als der Schaden. Jetzt sind es rund fuenfzig Millisekunden.
    private func neuVerbinden(grund: String) {
        // Nach `stop()` gibt es nichts mehr aufzubauen — sonst spielt eine
        // abgeraeumte Ansicht wieder los, nur zu hoeren, nicht zu sehen.
        guard !endgueltigGestoppt else { return }
        guard let adresse = letzteAdresse, letzteGutePosition > 1 else { return }

        guard netzErreichbar else {
            wartetAufNetz = true
            Protokoll.schreib("[Netz] \(grund), aber kein Netz — vorgemerkt bei \(Int(letzteGutePosition)) s")
            return
        }
        // Nach einem Wechsel meldet der Monitor mehrfach. Ohne Sperrfrist
        // wuerde der Strom in Schleife neu aufgebaut und nie fertig.
        guard Date().timeIntervalSince(letzterNeuaufbau) > 5 else { return }
        aufbauen(grund: grund, ab: letzteGutePosition, adresse: adresse)
    }

    /// Der gemeinsame Teil von ``neuVerbinden(grund:)`` und der
    /// Erstbild-Rettung: Strom an `ab` neu oeffnen, Spurwahl mitnehmen.
    private func aufbauen(grund: String, ab: Double, adresse: URL) {
        letzterNeuaufbau = Date()
        stehtSeit = nil
        letzteBekannteZeit = -1
        stelltWiederHer = true
        // **Die laufende Spurwahl mitnehmen.** Ein neu geoeffneter Strom
        // bringt VLCs eigene Voreinstellung mit - meist die Untertitelspur mit
        // „Standard"-Markierung aus der MKV. Ohne das gingen abgeschaltete
        // Untertitel nach einem kurzen Abriss von selbst wieder an
        // (18.09.2026: Caddy neu gestartet, Apple TV).
        spurenNachAufbau = gemeldeteSpuren
        Protokoll.schreib("[Netz] \(grund) → Strom neu aufbauen bei \(Int(ab)) s")
        // Der Versatz bleibt: dieselbe Adresse liefert wieder ab derselben
        // Stelle, gesprungen wird nur der Rest.
        oeffnen(url: adresse, abSekunden: max(ab, 0), container: letzterContainer)
    }


    /// Startposition setzen, sobald VLC springen kann.
    ///
    /// **Nicht als ':start-time'-Option — und der urspruengliche Grund dafuer
    /// ist nicht mehr der richtige.**
    ///
    /// Hier stand: die Option zwinge VLC, schon beim Oeffnen zu springen, und
    /// das koste ein Vielfaches. Das galt vor `mkv_trusted`, als ein Sprung
    /// ohne Index zwanzig Sekunden dauerte. Heute sind es Millisekunden, also
    /// habe ich es am 04.09.2026 umgebaut — und binnen Minuten am Geraet
    /// wieder ausgebaut.
    ///
    /// **Der neue Grund ist ein anderer und ein besserer.** Die gemerkte
    /// Stelle kann am Dateiende liegen: eine Folge laeuft durch, die App merkt
    /// sich 3707 s, und beim naechsten Oeffnen steht genau dort die
    /// Startposition. Mit ':start-time' meldet VLC dann sofort `end of stream`
    /// — gemessen, 141 ms nach dem Oeffnen, die Folgenende- Erkennung greift
    /// und die App springt in die naechste Folge.
    ///
    /// Der Weg ueber den nachtraeglichen Sprung hat den Fehler nicht: dort
    /// laeuft der Strom erst an, und ein Sprung ans eigene Ende ist harmlos.
    ///
    /// Wer es erneut versucht, braucht **vorher** die Laufzeit und einen
    /// Abstand zum Ende — und die Laufzeit steht beim Oeffnen noch nicht fest.
    /// Das ist der eigentliche Aufwand, nicht die Option.
    ///
    /// Haengt bewusst **nicht** allein am Zustandswechsel nach Playing. Baut
    /// man den Strom neu auf, waehrend VLC schon spielt, bleibt es intern bei
    /// Playing — es kommt kein Uebergang, der Rueckruf feuert nie und der neue
    /// Strom laeuft ab Sekunde 0. Genau daran ist die Rettung nach dem
    /// Netzwechsel gescheitert. Der Wachhund ruft deshalb ebenfalls hier an.
    private func startpositionSetzen() {
        // Der pausierte Start hat Vorrang; dieser Weg ist nur noch der
        // Rueckfall fuer Startstellen unter einer Sekunde.
        guard startsprung == nil else { return }
        guard let ziel = startposition else { return }
        guard ziel > 1 else {
            startposition = nil
            erstStelle = nil
            tonZurueckhalten(false)
            return
        }
        // Vor dem ersten Bild verpufft ein Sprung wirkungslos.
        guard player.isSeekable, player.time.intValue > 0 else { return }

        // Hat `:start-time` getroffen, waere ein Nachsprung ein Sprung fuer
        // nichts — und der Ladeschirm bliebe dafuer laenger stehen.
        if positionSeconds >= ziel - 10 {
            Protokoll.schreib("[VLC] Strom steht schon bei \(Int(positionSeconds)) s — kein Nachsprung")
            startposition = nil
            erstStelle = nil
            tonZurueckhalten(false)
            return
        }

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
            return String(localized: "Dieses Gerät kann kein Bild-im-Bild. Im Simulator geht es nie, auf dem iPhone schon.")
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
    /// Wieviel Vorrat der naechste Start haelt. Vor `play(url:)` setzen —
    /// die Optionen haengen am Medium, und das entsteht erst dort.
    var puffer: Pufferstufe = .normal

    /// Welche Spuren der nächste Start will — vor `play(url:)` setzen, wie
    /// ``puffer``. Daraus werden `:audio-track`/`:sub-track` am Medium, damit
    /// VLC gleich mit der richtigen Spur anläuft statt nach dem ersten Bild
    /// umzuschalten (siehe ``Spurzuordnung/startpositionen(stroeme:ton:untertitel:)``).
    /// `nil`: VLC wählt selbst, wie vorher.
    var spurwunsch: Spurwunsch?

    /// Die Eingaben von ``wendeSprachenAn(ton:untertitel:automatisch:quelle:titel:)``.
    struct Spurwunsch {
        let ton: String
        let untertitel: String
        let automatisch: Bool
        let quelle: MediaSource?
        let titel: String?
    }

    /// - Parameter softwareDekoder: gleich mit Software-Dekoder öffnen —
    ///   ``PlaybackPlan/softwareDekoder`` (MPEG-4 Part 2).
    func play(url: URL, abSekunden: Double = 0, container: String? = nil,
              untertitel: [Untertiteldatei] = [], softwareDekoder anfangsSoftware: Bool = false) {
        guard !endgueltigGestoppt else {
            Protokoll.schreib("[Player] play nach stop verworfen")
            return
        }
        // Wie beim Sprung: eine Startstelle ohne Zahl beginnt vorn, statt
        // spaeter in `Int(…)` abzustuerzen.
        let abSekunden = Sprungziel.sekunden(abSekunden) ?? 0
        // Ein neuer Titel erbt die Pause des alten nicht.
        pausiertSeit = nil
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
            // **Systemhinweise duerfen den Film nicht anhalten.**
            //
            // Die Mitteilungszentrale herunterzuziehen loeste eine
            // Tonunterbrechung aus, und die hielt die Wiedergabe an --
            // dreimal derselbe Handgriff, dreimal `pausing` von VLC. Anhalten
            // soll aber nur, wer die App wirklich verlaesst: ohne
            // Bild-im-Bild in den Hintergrund, geschlossen, oder Geraet aus.
            //
            // `setPrefersNoInterruptionsFromSystemAlerts` ist genau dafuer
            // da. Apples Dokumentation sagt nicht ausdruecklich, dass die
            // Mitteilungszentrale darunter faellt -- deshalb wird der Grund
            // der Unterbrechung zusaetzlich mitgeschrieben, statt es
            // anzunehmen.
            if #available(iOS 14.5, tvOS 14.5, *) {
                try? sitzung.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
                try sitzung.setActive(true)
                Protokoll.schreib("[Audio] nachgezogen · \(Int(sitzung.sampleRate)) Hz")
            } catch {
                Protokoll.schreib("[Audio] FEHLER: \(error.localizedDescription)")
            }
        }
        // **Wie viele Kanäle nimmt der Ausgang überhaupt an?**
        //
        // Swiftfin meldet, dass sein VLCKit-Player bei 5.1-Dateien nur Stereo
        // ausgibt, während der native Player alle Kanäle liefert
        // (jellyfin/Swiftfin#2199, offen); Streamyfin hatte bei 7.1 gar keinen
        // Ton (#1515). Für eine App, die niemals transkodieren will, wäre ein
        // stiller Downmix im Client der peinlichste Fehler überhaupt: der
        // Server liefert brav Direct Play, und wir werfen die Kanäle weg.
        //
        // Ob das bei uns passiert, sagt kein Quelltext, sondern nur diese
        // Zeile am Gerät. `maximumOutputNumberOfChannels` ist, was die Route
        // könnte; `currentRoute.outputs.channels` ist, was sie gerade führt.
        // Am iPhone-Lautsprecher sind zwei Kanäle richtig — interessant wird
        // es an HDMI, AirPlay und am Apple TV.
        let ausgang = sitzung.currentRoute.outputs.first
        Protokoll.schreib("[Audio] beim Öffnen: \(Int(sitzung.sampleRate)) Hz"
            + " · Ausgang \(ausgang?.portType.rawValue ?? "—")"
            + " führt \(ausgang?.channels?.count ?? 0) Kanäle"
            + ", könnte \(sitzung.maximumOutputNumberOfChannels)")
        #endif

        #if DEBUG
        Self.zuletzt = self
        #endif
        mediumGewechselt = player.media != nil
        letzteAdresse = url
        letzterContainer = container
        untertiteldateien = untertitel
        spurQuelle = nil
        erstbildStufe = .keine
        softwareDekoder = anfangsSoftware
        player.videoAspectRatio = nil
        offenerUntertitel = nil
        spurindizesMelden(Spurindizes())
        letzteGutePosition = abSekunden
        absichtlichBeendet = false
        offenesZiel = nil
        offenSeit = nil
        sprungStufe = 0
        zeitsetzenBesser = false

        wachhund?.invalidate()
        wachhund = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stillstandPruefen()
                self?.anzeigeschlafZulassen()
                self?.verzoegerungNachziehen()
            }
        }

        oeffnen(url: url, abSekunden: abSekunden, container: container)
    }

    /// Der eigentliche Aufbau — auch der Weg zurueck nach einem Netzwechsel.
    private func oeffnen(url: URL, abSekunden: Double, container: String?) {
        // **Die Bildzaehlung gehoert dem Medium.** Ueberlebte sie den Aufbau,
        // verglich `bildfluss` die neue Zaehlung mit der alten (T1-M5).
        letzteBilder = nil
        letzteBytes = nil
        bilderStehenSeit = nil
        erstbildLauf = 0
        erstbildVorher = nil
        erstbildGesehen = false
        // Nebenher, ohne auf sie zu warten: wie VLCs Sockets den Server
        // erreichen. Nur fürs Protokoll, siehe `Netzprobe`.
        Netzprobe.starten(url)
        // **Hinter einem Vorposten holt die App den Strom selbst** (Issue #4):
        // VLC kann keine eigenen Header senden. Ohne eingetragene Header
        // kommt die Adresse unverändert zurück. AirPlay spricht weiter direkt
        // mit dem Server und bleibt hinter einem Vorposten deshalb stumm.
        let vlcAdresse = Stromweiterleiter.gemeinsam.adresse(fuer: url)
        if vlcAdresse != url {
            Protokoll.schreib("[VLC] Strom über den Weiterleiter (Header: \(Eigenkoepfe.namen(Eigenkoepfe.fuer(url))))")
        }
        guard let medium = VLCMedia(url: vlcAdresse) else {
            Self.log.error("Medium ließ sich nicht öffnen: \(url.ohneGeheimnis, privacy: .public)")
            Protokoll.schreib("[VLC] Medium ließ sich nicht öffnen")
            startFehlerGemeldet?("Medium ließ sich nicht öffnen")
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
        // **Die Stufe kommt aus den Einstellungen, die Zahlen aus dem Paket.**
        // 16 MiB bleibt die Vorgabe; wer eine wackelige Leitung hat, stellt
        // hoeher und bezahlt es mit laengerem Anlaufen nach jedem Sprung.
        medium.addOption(":prefetch-buffer-size=\(puffer.prefetchKiB)")
        if let vorlauf = puffer.netzvorlaufMillisekunden, url.isFileURL == false {
            // Nur bei erhoehter Stufe gesetzt — siehe die Messung weiter unten,
            // warum das im Normalfall nichts bringt und Spruenge verteuert.
            medium.addOption(":network-caching=\(vorlauf)")
        }

        // **Nach einer laengeren Pause ist die Verbindung weg.**
        //
        // Am 08.09.2026 zweimal mitgeschrieben: 25 Sekunden pausiert, und
        // beim Fortsetzen steht `local stream N error: Cancellation (0x8)`
        // im Protokoll -- der Server hat den untaetigen Strom abgeraeumt.
        // VLC baut daraufhin alles neu auf (PCR zuruecksetzen, neu suchen,
        // puffern), und weil iOS im Hintergrund zusaetzlich die
        // Dekodersitzung entwertet hatte (`kVTInvalidSessionErr`), dauert
        // das rund zwei Sekunden.
        //
        // `http-reconnect` laesst VLC den Abriss selbst auffangen, statt ihn
        // als Stromende zu behandeln. Es aendert nichts, solange die
        // Verbindung haelt.
        if url.isFileURL == false {
            medium.addOption(":http-reconnect")
        }

        // **Entflechten: `bob` statt `x` — und nur, wo VLC Halbbilder erkennt.**
        //
        // DVD-Rips (MPEG-2, 720×576, interlaced) ruckelten auf Apple TV und
        // iPhone, 4K-HEVC nicht. VLC 4 entflechtet von selbst (`deinterlace`
        // -1), sobald ein Bild als interlaced markiert ist, und `auto` heisst
        // im Filter **`x`** (deinterlace.c, SetFilterMethod), nicht yadif2x.
        // Das laeuft auf der CPU nach dem Dekoder. MPEG-2 selbst geht in
        // unserem VLCKit immer ueber avcodec: `libmpeg2` ist nicht gebaut,
        // VideoToolbox hat MPEG-2 abgeschaltet (decoder.c, `#if 0`).
        //
        // Gemessen am 15.09.2026 gegen 61784e2 auf dem Mac (M1 Max, derselbe Bau,
        // nachgebaute Datei: MPEG-2 TFF 5 Mbit/s, AC-3 5.1, VobSub, MKV), je
        // 30 s, auf die Effizienzkerne gedrosselt (`taskpolicy -c background`):
        //
        //     Modus          dekodiert  gezeigt  verloren
        //     x (Vorgabe)    24,7/s     12,9–13,2   346–352
        //     bob            24,8/s     15,0        295
        //     linear         24,7/s     14,7        301
        //     aus            24,8–25,0  13,9–16,8   243–335
        //     x ohne VobSub  25,1/s     12,7        371
        //
        // Der Dekoder haelt immer Schritt; verloren geht es dahinter. Der
        // Untertitel kostet nichts Messbares. `x` ist das teuerste der
        // Verfahren, `bob` holt etwa den Abstand zu „aus" zurueck, ohne
        // Kammbilder stehen zu lassen. Ungedrosselt liegen alle Varianten bei
        // 25/s und 8–15 % eines Kerns — der Mac zeigt den Unterschied nur mit
        // Bremse, und ein Teil des Verlusts liegt auch mit „aus" noch in der
        // Ausgabe.
        //
        // **Warum pauschal gesetzt:** der Modus greift nur, wenn VLC ein Bild
        // als interlaced erkennt. HEVC/4K ist progressiv und nimmt den Filter
        // nie — dort aendert sich nichts.
        //
        // **Gesetzt wird er an der Bibliothek (`bibliothek`), nicht hier.**
        // Hier stand `medium.addOption(":deinterlace-mode=bob")`, und das
        // griff nie: der Filter haengt am vout, und der erbt vom Player, nicht
        // vom Eingang — dieselbe Falle wie bei `--no-drop-late-frames`.
        // Nachgemessen 25.09.2026 an MPEG-2 und H.264 1080i50 (TS): mit der
        // Medienoption meldet VLC 4 wie VLC 3 „using x deinterlace method",
        // mit der Bibliotheksoption „using bob" und doppelt so viele
        // gezeigte Bilder (Halbbild je Bild). Die Tabelle oben lag also im
        // Rauschen: gemessen wurde zweimal `x`.

        // **Am Vorrat lag es nicht -- nachgemessen, nicht vermutet.**
        //
        // Hier stand kurz `:network-caching=10000`, weil VLCs Voreinstellung
        // von 1000 ms duenn aussah und ein anderer Client elf Sekunden Vorrat
        // anzeigt. Die Messung am Geraet hat das erledigt: gelesen minus
        // entpackt ergab **211 Sekunden**. Der `prefetch`-Filter oben haelt
        // 16 MiB, und das sind bei dieser Bitrate dreieinhalb Minuten Inhalt.
        // Der Zeitvorlauf haette daran nichts geaendert, aber jeden Sprung
        // teurer gemacht.
        //
        // Was „Eingang 0 kbit/s" beim stehenden Bild wirklich hiess: nicht
        // „es kommt nichts", sondern „es muss gerade nichts kommen". Der
        // Engpass liegt hinter dem Demuxer, nicht davor.


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

        // **Pausiert oeffnen, im Stillstand springen, dann fortsetzen.**
        //
        // Das ist der Weg, der den Anfang der Folge nie zeigt und nie hoeren
        // laesst — nicht, weil er ihn verdeckt, sondern weil er ihn gar nicht
        // erst ausgibt. Gemessen war vorher: VLC `started` bei +0,41 s, unser
        // Sprung bei +1,00 s, Daten von der Zielstelle bei +1,12 s. Die
        // 0,85 s dazwischen waren Bild und Ton von Sekunde null, und der
        // alte Riegel („vor dem ersten Bild verpufft ein Sprung") hat genau
        // das erzwungen: er wartete auf `time > 0`, also auf laufende Ausgabe.
        //
        // Was VLC 4 wirklich tut (libvlc/vlc, geprueft am Quelltext):
        //
        // - `:start-paused` kommt ueber input_item_ApplyOptions am Eingang an
        //   (input.c:249) und pausiert ihn zu Beginn von MainLoop (input.c:647).
        // - Waehrend des Pufferns wird die Pause aufgeschoben (input.c:1755)
        //   und am Puffer-Ende **vor** der Freigabe der Dekoder angewandt
        //   (es_out.c:1268–1285). Kein Bild, kein Sample wird ausgegeben.
        // - Ein Sprung im Pausenzustand wird ausgefuehrt; danach wird an der
        //   Zielstelle gepuffert, und spaeter erzeugte Dekoder erben die Pause
        //   (es_out.c:1288, decoder.c:436). Der Ton bleibt still.
        // - Fortsetzen ueber `player.play()`: VLCKit ruft bei `Paused` direkt
        //   set_pause(0). **Nur bei gemeldetem Paused** — vorher waere play()
        //   ein Leerlauf (vlc_player_Start: schon gestartet, nicht pausiert),
        //   und die aufgeschobene Pause liesse den Spieler danach stehen.
        //
        // `:start-time` war die falsche Abkuerzung: es verschiebt die
        // Zeitachse (i_stop += i_start, input.c:916), VLC meldet dann die
        // Restlaenge. Der Ton-Rueckhalt ueber die Lautstaerke war nie wirksam:
        // vor dem ersten Ton gibt es keinen Tonausgang, vlc_player_aout_
        // SetVolume gibt -1 zurueck (aout.c:137) und VLCKit ignoriert das.
        // Beides bleibt als Rueckfall stehen, traegt aber nichts mehr.
        // **Software-Dekoder nach der zweiten Erstbild-Rettung**, oder von
        // Anfang an für MPEG-4 Part 2 — siehe ``Erstbild/softwareOption`` und
        // ``Erstbild/softwareVonAnfang(bildcodec:methode:)``.
        var codec: String? = softwareDekoder ? Erstbild.softwareOption : nil
        #if DEBUG
        if let zwang = Self.testZwang, !softwareDekoder || zwang.auchSoftware { codec = zwang.option }
        for zusatz in Self.testZusatz { medium.addOption(zusatz) }
        #endif
        if let codec {
            medium.addOption(codec)
            Protokoll.schreib("[Bild] Dekoderwahl \(codec)")
        }

        // **Keine eigene Uhr** (`clock-master=input` brachte 2× auf 0,3 s,
        // aber am iPhone setzte der Ton alle ~3 s aus, 27.09.2026 —
        // zurückgenommen). Die Tonuhr bleibt; ein Tempowechsel braucht damit
        // rund 2 s (`Tempolauf`).

        let pausiertStarten = abSekunden > 1
        if pausiertStarten {
            medium.addOption(":start-paused")
        }

        startposition = abSekunden
        erstStelle = pausiertStarten ? abSekunden : nil
        // Aus einer Übergabe stumm auch ohne Sprung — der Ton blendet dann
        // auf, sobald eingesteuert ist (`tonFreigebenFallsFaellig`).
        tonZurueckhalten(erstStelle != nil || Self.uebergabeAufblenden)
        melder.neuBeginnen()
        Protokoll.schreib("[VLC] Öffne \(url.lastPathComponent), Startposition \(Int(abSekunden)) s"
            + (pausiertStarten ? " (pausiert, Sprung im Stillstand)" : ""))
        // **Externe Untertitel** (T1-H4): VLC sucht über HTTP keine
        // Nachbardateien, der Server nennt sie aber. Vorrang 0, damit VLC
        // keine davon selbst einschaltet — das entscheidet `Spurregel`.
        for datei in untertiteldateien {
            let gehaengt = medium.addSlave(VLCMediaSlave(url: Stromweiterleiter.gemeinsam.adresse(fuer: datei.adresse), type: .subtitle, priority: 0))
            Protokoll.schreib("[Spuren] Datei \(datei.index) angehängt \(gehaengt), Merkmal \(datei.merkmal ?? "—")")
        }
        if Startmessung.an {
            // VLC zählt seine Bilder sonst nur alle 250 ms nach — zu grob für
            // eine Lücke von ein, zwei Bildern.
            medium.addOption(":stats-min-report-interval=20")
        }
        for option in spurOptionen() { medium.addOption(option) }
        startmessungBeginnen()
        Startmessung.geteilt.marke("Öffne (ab \(Int(abSekunden)) s\(pausiertStarten ? ", pausiert" : ""))")
        player.media = medium
        player.play()
        refreshPiPState()

        startsprung = pausiertStarten ? abSekunden : nil
        startsprungSeit = pausiertStarten ? Date() : nil
        zielGesehenBei = nil
        letzterStartsprungBefehl = .distantPast
        startwacht?.invalidate()
        if pausiertStarten {
            // 50 ms, damit Sprung und Fortsetzen ohne fuehlbare Verzoegerung
            // greifen. Der Takt lebt nur, bis der Start abgeschlossen ist.
            startwacht = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startsprungPruefen(anlass: "Takt") }
            }
        }
    }

    /// Die Spurwahl nach ``Spurregel`` als Medienoptionen.
    ///
    /// Geprüft am VLC-Quelltext (es_out.c, `EsOutSelect`): `audio-track` und
    /// `sub-track` sind „ausdrückliche“ Wünsche und schlagen die Vorauswahl
    /// der Datei; gezählt wird je Art in Anlegereihenfolge. Für „keine
    /// Untertitel“ gibt es keine Zahl — `sub-track=-1` heißt „VLC wählt“, und
    /// dann gewinnt die Standardspur der Matroska. Eine Kennung, die es nicht
    /// gibt (`sub-track-id=aus`), ist ebenfalls ausdrücklich und passt auf
    /// nichts: VLC schaltet keinen Untertitel selbst ein. Eine spätere Wahl
    /// von Hand geht mit Nachdruck durch und ist davon nicht betroffen.
    private func spurOptionen() -> [String] {
        guard let w = spurwunsch else { return [] }
        let stroeme = w.quelle?.mediaStreams ?? []
        guard !stroeme.isEmpty else { return [] }
        let gedaechtnis = Spurgedaechtnis()
        let tonIndex = Spurregel.ton(stroeme: stroeme,
                                     gemerkt: w.titel.flatMap { gedaechtnis.ton(fuer: $0) },
                                     wunschsprache: w.ton,
                                     serverVorgabe: w.quelle?.defaultAudioStreamIndex)
        let wahl = Spurregel.untertitel(stroeme: stroeme,
                                        gemerkt: w.titel.flatMap { gedaechtnis.untertitel(fuer: $0) },
                                        serverVorgabe: w.quelle?.defaultSubtitleStreamIndex,
                                        automatisch: w.automatisch, tonindex: tonIndex,
                                        tonwunsch: w.ton, wunschsprache: w.untertitel)
        let lage = Spurzuordnung.startpositionen(stroeme: stroeme, ton: tonIndex, untertitel: wahl)
        var optionen: [String] = []
        if let ton = lage.ton { optionen.append(":audio-track=\(ton)") }
        if let untertitel = lage.untertitel {
            optionen.append(":sub-track=\(untertitel)")
        } else {
            optionen.append(":sub-track-id=aus")
        }
        Protokoll.schreib("[Spuren] beim Öffnen: Ton \(tonIndex.map(String.init) ?? "Datei") · Untertitel \(wahl)"
            + " → \(optionen.joined(separator: " "))")
        return optionen
    }

    // MARK: - Pausierter Start

    /// Die Zielstelle, solange der pausierte Start noch laeuft.
    private var startsprung: Double?
    private var startsprungSeit: Date?
    private var letzterStartsprungBefehl = Date.distantPast
    private var startwacht: Timer?

    /// Laenger als das darf ein Start nicht pausiert bleiben. Danach wird
    /// fortgesetzt, wo auch immer der Strom steht — ein stehender Spieler
    /// ist schlimmer als ein falscher Einstieg.
    private static let startsprungFrist: TimeInterval = 20

    /// Treibt den pausierten Start voran: Sprung anstossen, bis die Uhr in
    /// der Naehe ist; fortsetzen, sobald VLC pausiert meldet.
    ///
    /// Der Sprungbefehl geht in VLCs Warteschlange und wird waehrend des
    /// Pufferns zurueckgestellt, nicht verworfen (input.c, ControlPop mit
    /// b_postpone_seek); Wiederholungen werden dort zusammengefasst
    /// (ControlGetReducedIndexLocked). Vor dem ersten Zustandswechsel gibt es
    /// noch keinen Eingang, dann verpufft der Befehl — deshalb wird er im
    /// Takt erneut geschickt, bis er ankommt.
    private func startsprungPruefen(anlass: String) {
        guard let ziel = startsprung else { startwacht?.invalidate(); startwacht = nil; return }
        let stelle = positionSeconds
        let zustand = player.state
        let seit = startsprungSeit.map { Date().timeIntervalSince($0) } ?? 0

        if seit > Self.startsprungFrist {
            Protokoll.schreib("[Start] \(Int(seit)) s pausiert, Ziel \(Int(ziel)) s nicht erreicht (bei \(Int(stelle)) s) — fortsetzen trotzdem")
            startsprungAbschliessen(fortsetzen: zustand == .paused)
            return
        }

        if stelle < ziel - 10 {
            if Date().timeIntervalSince(letzterStartsprungBefehl) > 0.25,
               zustand != .stopped, zustand != .error {
                letzterStartsprungBefehl = Date()
                player.time = VLCTime(int: Int32(clamping: Int(ziel * 1000)))
                Protokoll.schreib("[Start] Sprung auf \(Int(ziel)) s angestossen (\(anlass), Zustand \(VLCMediaPlayerStateToString(zustand)), Uhr \(Int(stelle)) s)")
            }
            return
        }

        // Uhr ist am Ziel. Fortsetzen, sobald VLC wirklich pausiert ist —
        // vorher ist play() ein Leerlauf, siehe oeffnen().
        if zustand == .paused {
            Protokoll.schreib("[Start] am Ziel (\(Int(stelle)) s) und pausiert → fortsetzen, \(String(format: "%.2f", seit)) s nach dem Öffnen")
            startsprungAbschliessen(fortsetzen: true)
            return
        }

        // **`Playing` heisst hier noch nichts.** Gemessen im Simulator: VLC
        // meldet Playing bei +0,405 s, die aufgeschobene Pause greift erst
        // bei +0,699 s (am Puffer-Ende, input.c:1755 / es_out.c:1268). Wer
        // bei Playing abschliesst, laesst den Spieler danach pausiert stehen
        // — genau das ist beim ersten Versuch passiert. Der einzige Beweis,
        // dass wirklich gespielt wird, ist eine Uhr, die vom Ziel aus
        // weiterlaeuft; im Pausenzustand steht sie.
        if zustand == .playing {
            if let vorher = zielGesehenBei {
                if stelle > vorher + 0.5 {
                    Protokoll.schreib("[Start] am Ziel und die Uhr laeuft (\(Int(stelle)) s) — ohne Pause abgeschlossen")
                    startsprungAbschliessen(fortsetzen: false)
                }
            } else {
                zielGesehenBei = stelle
            }
        }
    }

    /// Erste am Ziel gemeldete Uhrzeit im Zustand Playing — siehe oben.
    private var zielGesehenBei: Double?

    private func startsprungAbschliessen(fortsetzen: Bool) {
        startwacht?.invalidate()
        startwacht = nil
        startsprung = nil
        startsprungSeit = nil
        zielGesehenBei = nil
        startposition = nil
        erstStelle = nil
        Startmessung.geteilt.marke("Startsprung abgeschlossen, fortsetzen: \(fortsetzen)")
        tonZurueckhalten(false)
        if fortsetzen { player.play() }
    }

    // MARK: Startmessung — Bildfluss der ersten Sekunden

    private var messtakt: Timer?
    private var messSchlag: Date?
    private var messBilder: UInt64 = 0
    private var messSpaet: UInt64 = 0
    private var messVerloren: UInt64 = 0
    private var messTonVerloren: UInt64 = 0

    /// Tastet alle 10 ms ab, solange ``Startmessung`` misst: steht der
    /// Hauptlauf (der Takt kommt zu spät), und zählt VLC verspätete oder
    /// verworfene Bilder und Tonblöcke. Am Ende die Zahlen der Videoschicht.
    ///
    /// **Keine Bildlücken mehr.** VLCs Zähler kommen vom Eingangsfaden und
    /// hängen mit ihm (28.09.: nach jeder „Lücke“ drei, vier Bilder auf
    /// einmal). Das angezeigte Bild der Schicht (`displayedPixelBuffer()`)
    /// taugt auch nicht: es meldete Standbilder, die niemand sah, und keins
    /// dort, wo es ruckelte.
    private func startmessungBeginnen() {
        messtakt?.invalidate()
        messtakt = nil
        guard Startmessung.an else { return }
        Startmessung.geteilt.beginnen()
        messSchlag = nil
        messBilder = 0
        messSpaet = 0
        messVerloren = 0
        messTonVerloren = 0
        let takt = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startmessungTakt() }
        }
        RunLoop.main.add(takt, forMode: .common)
        messtakt = takt
    }

    private func startmessungTakt() {
        let jetzt = Date()
        guard !endgueltigGestoppt, Startmessung.geteilt.millisekunden != nil else {
            messtakt?.invalidate()
            messtakt = nil
            Protokoll.schreib("[Start] Messung zu Ende · gezeigt \(messBilder), spät \(messSpaet), verloren \(messVerloren), Ton verloren \(messTonVerloren)")
            Self.videoschicht(in: layer)?.sampleBufferRenderer.loadVideoPerformanceMetrics { werte in
                guard let werte else { return }
                Protokoll.schreib("[Start] Schicht: \(werte.totalNumberOfFrames) Bilder,"
                    + " verworfen \(werte.numberOfDroppedFrames), beschädigt \(werte.numberOfCorruptedFrames)")
            }
            return
        }
        if let vorher = messSchlag {
            let luecke = jetzt.timeIntervalSince(vorher)
            if luecke > 0.05 { Startmessung.geteilt.marke("Hauptlauf stand \(Int(luecke * 1000)) ms") }
        }
        messSchlag = jetzt
        guard let stat = player.media?.statistics else { return }
        if stat.displayedPictures != messBilder {
            if messBilder == 0 {
                Startmessung.geteilt.marke("erstes Bild gezeigt · Uhr \(player.time.intValue) ms")
            }
            messBilder = stat.displayedPictures
        }
        if stat.latePictures != messSpaet || stat.lostPictures != messVerloren
            || stat.lostAudioBuffers != messTonVerloren {
            messSpaet = stat.latePictures
            messVerloren = stat.lostPictures
            messTonVerloren = stat.lostAudioBuffers
            Startmessung.geteilt.marke("VLC zählt spät \(messSpaet) · verloren \(messVerloren)"
                + " · Ton verloren \(messTonVerloren) · gezeigt \(stat.displayedPictures)")
        }
    }

    /// Die `AVSampleBufferDisplayLayer`, die VLC unter die Fläche hängt.
    private static func videoschicht(in wurzel: CALayer?) -> AVSampleBufferDisplayLayer? {
        guard let wurzel else { return nil }
        if let schicht = wurzel as? AVSampleBufferDisplayLayer { return schicht }
        for kind in wurzel.sublayers ?? [] {
            if let schicht = videoschicht(in: kind) { return schicht }
        }
        return nil
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

    /// Wird gerufen, sobald **VLC selbst** umschaltet — nicht, wenn wir es
    /// verlangen. Der Abspielknopf hängt daran; siehe `zustandGewechselt`.
    var laeuftGemeldet: ((Bool) -> Void)?

    /// Wird bei jedem Sprung von aussen gerufen, mit der Zielstelle — damit
    /// der Server ihn sofort erfaehrt (Audit 16.09., T1-N1), egal ueber welchen
    /// der vielen Wege gesprungen wurde. Das interne Nachfassen eines Sprungs
    /// meldet nicht.
    var sprungGemeldet: ((Double) -> Void)?

    /// Bricht VLC ab, bevor das erste Bild da ist (Datei nicht lesbar, Strom
    /// nicht erreichbar, Medium nicht zu öffnen), meldet das hier den Grund.
    /// Die Oberfläche zeigt dann eine Meldung statt endlos Schwarz.
    var startFehlerGemeldet: ((String) -> Void)?

    func pause() {
        if pausiertSeit == nil { pausiertSeit = Date() }
        player.pause()
        refreshPiPState()
    }

    /// **Seit wann angehalten ist** — für ``Pausenruecksprung``. Gesetzt beim
    /// Anhalten, auch wenn VLC von selbst anhält (Bild-im-Bild, ein Anruf);
    /// gelöscht, sobald es wieder läuft.
    private var pausiertSeit: Date?

    /// **Wie das Bild in die Flaeche gelegt wird -- ganz oder formatfuellend.**
    ///
    /// `Smaller` legt das ganze Bild hinein und laesst Balken stehen, `Larger`
    /// fuellt die Flaeche und schneidet ab. Beides ohne Verzerren; ein
    /// dritter Zustand waere nur eine falsche Streckung, deshalb gibt es
    /// zwei.
    ///
    /// Nicht ueber `videoAspectRatio`: das setzt ein Seitenverhaeltnis und
    /// zieht das Bild darauf, statt es zu beschneiden. Gesichter werden dabei
    /// breit, und genau das will niemand.
    func bildfuellend(_ an: Bool) {
        player.videoFitMode = an ? .larger : .smaller
    }

    /// Die Bildgroesse des Stroms in Pixeln, `zero` bevor das erste Bild da
    /// ist. Wird gebraucht, um auszurechnen, wie weit zwischen „ganz hinein"
    /// und „ganz ausfuellen" liegt.
    var videoSize: CGSize { player.videoSize }
    /// **Vor dem Weiterspielen die Tonsitzung aktivieren.**
    ///
    /// Nach einer Unterbrechung (Wecker, Stoppuhr, Anruf) ist sie inaktiv.
    /// Die automatische Fortsetzung in `Wiedergabezentrale` zog sie schon
    /// nach — der Abspielknopf nicht. Kam kein automatisches Ende der
    /// Unterbrechung (ein Wecker meldet es oft gar nicht), drückte man selbst,
    /// und VLC startete den Ton auf der inaktiven Sitzung: ein paar Sekunden
    /// Stille, dann setzte er verspätet ein (17.09.2026, Stoppuhr).
    /// `setActive(true)` auf einer schon aktiven Sitzung kostet nichts.
    ///
    /// **`ruecksprung`: nach langer Pause ein Stück zurück** (1.0.5). Die
    /// Stelle wird gesetzt, solange VLC noch steht, und erst dann gespielt —
    /// das erste neue Bild ist schon das von fünf Sekunden früher, ein
    /// sichtbares Zurückspringen gibt es nicht. Wann, entscheidet
    /// ``Pausenruecksprung``. Nur auf Wunsch der Oberfläche: SyncPlay, die
    /// Rückkehr von AirPlay und das Ende des Schrubbens rufen ohne. Gibt das
    /// Ziel zurück, damit die Anzeige es im selben Moment übernimmt.
    @discardableResult
    func resume(ruecksprung: Bool = false) -> Double? {
        let seit = pausiertSeit
        pausiertSeit = nil
        var ziel: Double?
        if ruecksprung, !startsprungOffen,
           let z = Pausenruecksprung.ziel(position: positionSeconds, pausiertSeit: seit,
                                          jetzt: Date(), inGruppe: false) {
            Protokoll.schreib("[VLC] Fortsetzen nach \(Int(Date().timeIntervalSince(seit ?? Date()))) s Pause"
                + " — vorher auf \(Int(z)) s")
            seek(toSeconds: z)
            ziel = z
        }
        #if os(iOS) || os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Protokoll.schreib("[Ton] Sitzung vor dem Weiterspielen nicht aktivierbar: "
                + error.localizedDescription)
        }
        #endif
        player.play()
        refreshPiPState()
        return ziel
    }

    /// Ein Startsprung, der noch nicht angekommen ist — dann steht die Stelle
    /// noch nicht, und ein Rücksprung davon aus ginge ins Leere.
    private var startsprungOffen: Bool { startsprung != nil }

    func stop() {
        absichtlichBeendet = true
        endgueltigGestoppt = true
        tonZurueckhalten(false)
        wachhund?.invalidate()
        wachhund = nil
        startwacht?.invalidate()
        startwacht = nil
        startsprung = nil
        player.stop()
        // **Die Ansicht muss danach wirklich gehen koennen.** `drawable` haelt
        // laut VLCKit-Header stark, `player` haelt die Ansicht also fest, und
        // die Ansicht den `player` — ein Kreis. Nachgemessen: eine Ansicht mit
        // `drawable = self` lebt nach `stop()` weiter, ohne den Verweis nicht.
        //
        // Mit ihr lebte die Netzwache weiter. Legte sich der Rechner schlafen,
        // riss das Netz ab und `streckeGewechselt` merkte die letzte Stelle
        // vor; beim Aufwachen baute `neuVerbinden` den Strom wieder auf und
        // spielte — Ton aus einem Player, der laengst geschlossen war.
        //
        // `stop()` ist endgueltig (siehe `endgueltigGestoppt`); ein
        // Folgenwechsel laeuft ueber `play(url:)` auf derselben Ansicht und
        // kommt hier nicht vorbei. Deshalb darf die Netzwache hier enden.
        netzwache.cancel()
        wartetAufNetz = false
        player.drawable = nil
        // **Und die Rueckrufe los — sonst bleibt der ganze Player im Speicher.**
        //
        // Der Kreis oben ist damit nicht ganz weg: VLC 4 behaelt den letzten
        // Videoausgang fuer das naechste Medium, und dessen Flaeche haelt die
        // Ansicht fest, bis der `VLCMediaPlayer` geht — und den haelt die
        // Ansicht. Gemessen im iOS-Simulator: nach zwoelfmal Oeffnen und
        // Schliessen lebten zwoelf `VLCPlayerView`. Das kostet wenig. Teuer
        // war, was an ihr hing: die Rueckrufe fassen `PlayerScreen` und
        // damit dessen ganzen Zustand — `Wiedergabezentrale`, Vorschaubilder,
        // `Fernziel`, `Schirmtakt`, je Oeffnen einmal mehr. Nach `stop()` ruft
        // hier ohnehin niemand mehr etwas: „spielt" und „angehalten" kommen
        // nicht mehr, und ein Folgenwechsel geht ueber `play(url:)`.
        onWiederherstellung = nil
        laeuftGemeldet = nil
        sprungGemeldet = nil
        startFehlerGemeldet = nil
        spurenGemeldet = nil
        #if os(iOS)
        onPiPAvailable = nil
        onPiPStateChanged = nil
        #endif
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

    /// **Kommen die Kanäle durch, oder mischt jemand still auf Stereo?**
    ///
    /// Swiftfin meldet, dass ihr VLCKit-Player 5.1 auf Stereo mischt, während
    /// ihr nativer Player alle Kanäle liefert (jellyfin/Swiftfin#2199, offen);
    /// Streamyfin hatte bei 7.1 gar keinen Ton (#1515). Für eine App, die
    /// niemals transkodieren will, wäre ein stiller Downmix im Client der
    /// peinlichste Fehler: der Server liefert Direct Play, und wir werfen die
    /// Kanäle weg, ohne dass es jemand sieht.
    ///
    /// **Die Zeile ist erst am Fernseher aussagekräftig.** Am iPhone hat der
    /// Lautsprecher zwei Kanäle, und zwei am Ausgang sind dort richtig —
    /// dasselbe Ergebnis bedeutet dort also nichts. Erst wenn die Route mehr
    /// könnte (HDMI am Apple TV, ein AirPlay-Empfänger), sagt ein Stereo-
    /// Ausgang etwas aus.
    func kanaeleNachmessen() {
        // **Zwei verschiedene Spurlisten, und das ist kein Versehen.**
        // `player.audioTracks` sagt, was *gewaehlt* ist — nur dort gibt es
        // `isSelected` und einen Namen. `media.audioTracks` beschreibt die
        // *Datei* und traegt als einzige die Kanalzahl, dafuer keinen Namen.
        // Statt beide ueber einen bruechigen Namensvergleich zu verheiraten,
        // steht hier schlicht beides untereinander: was gewaehlt ist, und was
        // die Datei ueberhaupt anbietet.
        let gewaehlt = player.audioTracks.first(where: \.isSelected)?.trackName ?? "—"
        let spuren = (player.media?.audioTracks ?? []).map { spur -> String in
            let sprache = spur.language ?? spur.trackDescription ?? "?"
            return "\(sprache) \(spur.audio?.channelsNumber ?? 0)ch"
        }.joined(separator: ", ")

        #if os(macOS)
        Protokoll.schreib("[Kanäle] gewählt: \(gewaehlt) · Datei: \(spuren)")
        #else
        let sitzung = AVAudioSession.sharedInstance()
        let ausgang = sitzung.currentRoute.outputs.first
        Protokoll.schreib("[Kanäle] gewählt: \(gewaehlt) · Datei: \(spuren)"
            + " · Ausgang \(ausgang?.portType.rawValue ?? "—")"
            + " nimmt \(ausgang?.channels?.count ?? 0)"
            + ", könnte \(sitzung.maximumOutputNumberOfChannels)")
        #endif
    }

    // MARK: Spurwahl (Audit 16.09., Stufe 4)

    /// Serie oder Film, für den eine Handwahl gemerkt wird. Setzt
    /// ``wendeSprachenAn(ton:untertitel:automatisch:quelle:titel:)`` bei jedem
    /// Start und Folgenwechsel.
    private var spurTitel: String?
    /// Die Server-Angaben zur laufenden Datei — `MediaStream`s und Vorgaben.
    private var spurQuelle: MediaSource?
    /// Untertiteldateien, die am Medium hängen. Vor `play(url:)` gesetzt,
    /// und nach einem Neuaufbau wieder angehängt.
    private var untertiteldateien: [Untertiteldatei] = []
    /// Eine gewählte Untertiteldatei, deren Spur VLC noch nicht meldet.
    private var offenerUntertitel: Int?
    private var gemeldeteSpuren = Spurindizes()
    /// Die Spurwahl vor einem Neuaufbau, bis der neue Strom laeuft.
    private var spurenNachAufbau: Spurindizes?

    /// Nach einem Neuaufbau die Spurwahl von vorher wieder setzen.
    ///
    /// Die Spuren sind erst da, wenn der Strom laeuft; deshalb hier und nicht
    /// in `neuVerbinden`. Untertitel `nil` heisst „aus", nicht „egal" - genau
    /// der Fall, der vorher verloren ging.
    private func spurenWiederSetzen() {
        guard let vorher = spurenNachAufbau else { return }
        spurenNachAufbau = nil
        let ton = player.audioTracks, text = player.textTracks
        let z = zuordnung(ton: ton, untertitel: text)
        if let index = vorher.ton, let position = z.tonposition(index: index), position < ton.count {
            ton[position].isSelectedExclusively = true
        }
        if let index = vorher.untertitel, let position = z.untertitelposition(index: index),
           position < text.count {
            text[position].isSelectedExclusively = true
        } else if vorher.untertitel == nil {
            player.deselectAllTextTracks()
        }
        Protokoll.schreib("[Spuren] nach Neuaufbau wieder gesetzt: Ton \(vorher.ton.map(String.init) ?? "—"), "
            + "Untertitel \(vorher.untertitel.map(String.init) ?? "aus")")
    }

    /// Die laufenden Spuren als Jellyfin-Index, bei jeder Änderung — für
    /// Start- und Fortschrittsmeldung (T3 #8).
    var spurenGemeldet: ((Spurindizes) -> Void)?

    #if DEBUG
    /// Fuer die Probe `-spurlauf` (tvOS), sonst unbenutzt.
    static weak var zuletzt: VLCPlayerView?
    #endif

    /// MD5 der Adresse als Hex — so benennt libVLC die Spuren einer
    /// nachgeladenen Datei (siehe ``Abspielerspur/zusatzkennung``).
    static func untertitelmerkmal(_ adresse: URL) -> String {
        Insecure.MD5.hash(data: Data(adresse.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func abspielerspur(_ spur: VLCMediaPlayer.Track) -> Abspielerspur {
        Abspielerspur(kennung: spur.trackId, name: spur.trackName, sprache: spur.language,
                      codec: Technikangaben.codecname(vlcKennung: spur.codec),
                      kanaele: spur.audio.map { Int($0.channelsNumber) })
    }

    private func zuordnung(ton: [VLCMediaPlayer.Track], untertitel: [VLCMediaPlayer.Track]) -> Spurzuordnung {
        Spurzuordnung.bilden(ton: ton.map(Self.abspielerspur),
                             untertitel: untertitel.map(Self.abspielerspur),
                             stroeme: spurQuelle?.mediaStreams ?? [],
                             dateien: untertiteldateien)
    }

    /// Wählt Ton- und Untertitelspur nach ``Spurregel``: Handwahl je Serie,
    /// Einstellungen, Server-Vorgaben, erzwungene Untertitel.
    ///
    /// Entschieden wird über Jellyfins Index; wo die Spur in VLC liegt, sagt
    /// ``Spurzuordnung``. Vorher ging beides über den Spurnamen (T1-N4), und
    /// der Ton wurde gar nicht gemerkt (T1-M1).
    func wendeSprachenAn(ton: String, untertitel: String, automatisch: Bool,
                         quelle: MediaSource?, titel: String?) {
        spurTitel = titel
        spurQuelle = quelle
        let stroeme = quelle?.mediaStreams ?? []
        let tonspuren = player.audioTracks
        let utspuren = player.textTracks
        let z = zuordnung(ton: tonspuren, untertitel: utspuren)
        let gedaechtnis = Spurgedaechtnis()
        // Nur der Stand *vor* der Wahl: VLC wendet eine Spurwahl im
        // Eingangsfaden an, Millisekunden bis Zehntelsekunden später. Ein
        // „nachher“ direkt danach zeigt noch den alten Stand (28.09.: „audio/2
        // → audio/2“, obwohl gerade auf eine andere Tonspur umgeschaltet
        // wurde). Was angefordert wird, steht in eigenen Zeilen.
        Startmessung.geteilt.marke("Spuren vorher · Ton \(tonspuren.first(where: \.isSelected)?.trackId ?? "—")"
            + " · Untertitel \(utspuren.first(where: \.isSelected)?.trackId ?? "—")")

        var tonIndex = Spurregel.ton(stroeme: stroeme,
                                     gemerkt: titel.flatMap { gedaechtnis.ton(fuer: $0) },
                                     wunschsprache: ton,
                                     serverVorgabe: quelle?.defaultAudioStreamIndex)
        // **Nur wählen, was nicht schon läuft.** Beim Start ist die gewünschte
        // Spur meist schon die der Datei; sie trotzdem neu zu setzen, schickt
        // eine Spurwahl durch Player und Eingang, mitten in den ersten
        // Bildern — für nichts.
        if let gesucht = tonIndex, let position = z.tonposition(index: gesucht) {
            if !tonspuren[position].isSelected {
                Startmessung.geteilt.marke("Tonwechsel nach dem Start → \(tonspuren[position].trackId) (Jellyfin \(gesucht))")
                tonspuren[position].isSelectedExclusively = true
            }
        } else {
            // Nicht zuzuordnen: der alte Weg über den Namen, sonst die Datei.
            if !ton.isEmpty, let treffer = tonspuren.first(where: { Sprache.passt($0.trackName, zu: ton) }),
               !treffer.isSelected {
                Startmessung.geteilt.marke("Tonwechsel angefordert → \(treffer.trackId) (nach Name)")
                treffer.isSelectedExclusively = true
            }
            tonIndex = tonspuren.firstIndex(where: \.isSelected).flatMap { z.ton[$0] }
        }

        let wahl = Spurregel.untertitel(stroeme: stroeme,
                                        gemerkt: titel.flatMap { gedaechtnis.untertitel(fuer: $0) },
                                        serverVorgabe: quelle?.defaultSubtitleStreamIndex,
                                        automatisch: automatisch, tonindex: tonIndex,
                                        tonwunsch: ton, wunschsprache: untertitel)
        Protokoll.schreib("[Spuren] Ton \(tonIndex.map(String.init) ?? "Datei") · Untertitel \(wahl)"
            + " · Vorgaben \(quelle?.defaultAudioStreamIndex.map(String.init) ?? "—")/"
            + "\(quelle?.defaultSubtitleStreamIndex.map(String.init) ?? "—")"
            + " · Zuordnung Ton \(z.ton) Untertitel \(z.untertitel)"
            + " · Kennungen \(utspuren.map(\.trackId))")
        untertitelSetzen(wahl, spuren: utspuren, zuordnung: z)
        spurindizesMelden(Spurindizes(ton: tonIndex, untertitel: untertitelindex(wahl)))
        seitenverhaeltnisPruefen(quelle)
    }

    /// **Anamorphes Matroska aus ffmpeg: VLC 4 staucht das Bild** — siehe
    /// ``Seitenverhaeltnis``. Dann gilt Jellyfins Anzeigeverhältnis.
    /// Zurückgesetzt wird in `oeffnen`, sonst erbte die nächste Folge es.
    private func seitenverhaeltnisPruefen(_ quelle: MediaSource?) {
        guard let bild = quelle?.mediaStreams?.first(where: { $0.type == "Video" }),
              let spur = player.videoTracks.first(where: \.isSelected) ?? player.videoTracks.first,
              let video = spur.video,
              let soll = Seitenverhaeltnis.korrektur(
                  sar: (UInt32(video.sourceAspectRatio), UInt32(video.sourceAspectRatioDenominator)),
                  breite: bild.width ?? 0, hoehe: bild.height ?? 0, anzeige: bild.aspectRatio)
        else { return }
        player.videoAspectRatio = soll
        Startmessung.geteilt.marke("Seitenverhältnis gesetzt")
        Protokoll.schreib("[Bild] VLC meldet \(video.sourceAspectRatio):\(video.sourceAspectRatioDenominator)"
            + " fuer \(bild.width ?? 0)x\(bild.height ?? 0) \(bild.aspectRatio ?? "?") — Anzeige auf \(soll) gesetzt")
    }

    private func untertitelindex(_ wahl: Spurregel.Untertitel) -> Int {
        if case .strom(let index) = wahl { return index }
        return -1
    }

    private func untertitelSetzen(_ wahl: Spurregel.Untertitel, spuren: [VLCMediaPlayer.Track],
                                  zuordnung z: Spurzuordnung) {
        offenerUntertitel = nil
        guard case .strom(let index) = wahl else {
            // Aktiv abschalten: die Datei bringt oft eine eigene Vorauswahl mit.
            // Ist keine gewählt, gibt es nichts abzuschalten.
            if spuren.contains(where: \.isSelected) {
                Startmessung.geteilt.marke("Untertitel abgeschaltet")
                player.deselectAllTextTracks()
            }
            return
        }
        if let position = z.untertitelposition(index: index) {
            if !spuren[position].isSelected { spuren[position].isSelectedExclusively = true }
        } else {
            player.deselectAllTextTracks()
            if untertiteldateien.contains(where: { $0.index == index }) {
                // Die Datei ist angehängt, aber noch nicht gelesen.
                offenerUntertitel = index
                Protokoll.schreib("[Spuren] Untertiteldatei \(index) noch nicht da, wartet")
            } else {
                Protokoll.schreib("[Spuren] Untertitel \(index) nicht zuzuordnen, bleibt aus")
            }
        }
    }

    /// VLC meldet eine neue Untertitelspur — vielleicht die gewählte Datei.
    func offenenUntertitelSetzen() {
        guard let index = offenerUntertitel else { return }
        let spuren = player.textTracks
        let z = zuordnung(ton: player.audioTracks, untertitel: spuren)
        guard let position = z.untertitelposition(index: index) else { return }
        offenerUntertitel = nil
        spuren[position].isSelectedExclusively = true
        Protokoll.schreib("[Spuren] Untertiteldatei \(index) nachgereicht")
        spurindizesMelden(Spurindizes(ton: gemeldeteSpuren.ton, untertitel: index))
    }

    private func spurindizesMelden(_ neu: Spurindizes) {
        guard neu != gemeldeteSpuren else { return }
        gemeldeteSpuren = neu
        spurenGemeldet?(neu)
    }

    /// Von Hand gewählt: gilt sofort und für die ganze Serie (T1-M1).
    func waehleTonspur(_ spur: VLCMediaPlayer.Track) {
        spur.isSelectedExclusively = true
        let spuren = player.audioTracks
        let z = zuordnung(ton: spuren, untertitel: [])
        let position = spuren.firstIndex { $0.trackId == spur.trackId }
        let index = position.flatMap { z.ton[$0] }
        if let spurTitel {
            let stroeme = spurQuelle?.mediaStreams ?? []
            let abdruck = index.flatMap { i in stroeme.first { $0.type == "Audio" && $0.index == i } }
                .map { Spurabdruck(strom: $0, in: stroeme, name: spur.trackName) }
                ?? Spurabdruck(spur: Self.abspielerspur(spur))
            Spurgedaechtnis().merkeTon(abdruck, fuer: spurTitel)
            Protokoll.schreib("[Spuren] Ton von Hand: \(index.map(String.init) ?? "?") \(abdruck)")
        }
        spurindizesMelden(Spurindizes(ton: index, untertitel: gemeldeteSpuren.untertitel))
    }

    /// `nil` schaltet Untertitel ab.
    ///
    /// Hier — und nur hier — wird die Wahl für die Serie gemerkt: die Tafel
    /// ist der einzige Weg, auf dem ein Mensch die Untertitelspur anfasst.
    func waehleUntertitel(_ spur: VLCMediaPlayer.Track?) {
        offenerUntertitel = nil
        guard let spur else {
            if let spurTitel { Spurgedaechtnis().merkeUntertitel(.aus, fuer: spurTitel) }
            player.deselectAllTextTracks()
            Protokoll.schreib("[Spuren] Untertitel von Hand: aus")
            spurindizesMelden(Spurindizes(ton: gemeldeteSpuren.ton, untertitel: -1))
            return
        }
        spur.isSelectedExclusively = true
        let spuren = player.textTracks
        let z = zuordnung(ton: [], untertitel: spuren)
        let index = spuren.firstIndex { $0.trackId == spur.trackId }.flatMap { z.untertitel[$0] }
        if let spurTitel {
            let stroeme = spurQuelle?.mediaStreams ?? []
            let abdruck = index.flatMap { i in stroeme.first { $0.type == "Subtitle" && $0.index == i } }
                .map { Spurabdruck(strom: $0, in: stroeme, name: spur.trackName) }
                ?? Spurabdruck(spur: Self.abspielerspur(spur))
            Spurgedaechtnis().merkeUntertitel(.spur(abdruck), fuer: spurTitel)
            Protokoll.schreib("[Spuren] Untertitel von Hand: \(index.map(String.init) ?? "?") \(abdruck)")
        }
        spurindizesMelden(Spurindizes(ton: gemeldeteSpuren.ton, untertitel: index))
    }

    /// Namen für die Untertitelliste, je `trackId`.
    ///
    /// VLCs Spurname, außer der Server weiß mehr: eine nachgeladene Datei
    /// heißt bei VLC nur „Track 1", und zwei Spuren namens „Deutsch" sind
    /// nicht auseinanderzuhalten (T1-N4). Dann Sprache, Format und ob sie
    /// erzwungen oder eine eigene Datei ist.
    func untertitelnamen() -> [String: String] {
        let spuren = player.textTracks
        let z = zuordnung(ton: [], untertitel: spuren)
        let stroeme = spurQuelle?.mediaStreams ?? []
        var namen: [String: String] = [:]
        for (position, spur) in spuren.enumerated() {
            let doppelt = spuren.filter { $0.trackName == spur.trackName }.count > 1
            guard let index = z.untertitel[position],
                  let strom = stroeme.first(where: { $0.type == "Subtitle" && $0.index == index }),
                  doppelt || strom.isExternal == true || strom.isHearingImpaired == true else {
                namen[spur.trackId] = spur.trackName
                continue
            }
            let teile: [String?] = [
                strom.sprachname ?? spur.trackName,
                Technikangaben.codecname(strom.codec),
                strom.isForced == true ? String(localized: "Erzwungen") : nil,
                strom.isHearingImpaired == true ? String(localized: "Hörgeschädigt") : nil,
                strom.isExternal == true ? String(localized: "Datei") : nil,
            ]
            namen[spur.trackId] = teile.compactMap { $0 }.joined(separator: " · ")
        }
        return namen
    }


    /// 1.0 ist normal. VLC nimmt Werte zwischen 0,25 und 4.
    var tempo: Float {
        get { player.rate }
        set { player.rate = newValue; refreshPiPState() }
    }

    // MARK: - Verzögerung

    /// Untertitel und Ton gegen das Bild verschoben — nur hier, nur lokal.
    /// SyncPlay sieht davon nichts: die Gruppe gleicht Filmzeit ab, und die
    /// ändert sich dadurch nicht.
    var untertitelVerzoegerung = Verzoegerung.null {
        didSet { if untertitelVerzoegerung != oldValue { verzoegerungNachziehen() } }
    }
    var tonVerzoegerung = Verzoegerung.null {
        didSet { if tonVerzoegerung != oldValue { verzoegerungNachziehen() } }
    }

    /// Vor jedem `play` auf einen anderen Titel: dieselbe Serie behält den
    /// Wert, alles andere beginnt bei null (`Verzoegerung.fuerNeuenTitel`).
    func verzoegerungFuerNeuenTitel(alterTitel: String, alteSerie: String?,
                                    neuerTitel: String, neueSerie: String?) {
        untertitelVerzoegerung = .fuerNeuenTitel(untertitelVerzoegerung, alterTitel: alterTitel,
                                                 alteSerie: alteSerie, neuerTitel: neuerTitel,
                                                 neueSerie: neueSerie)
        tonVerzoegerung = .fuerNeuenTitel(tonVerzoegerung, alterTitel: alterTitel,
                                          alteSerie: alteSerie, neuerTitel: neuerTitel,
                                          neueSerie: neueSerie)
    }

    /// **VLC vergisst die Verzögerung mit jedem neuen Medium** — auch nach
    /// einem Neuaufbau, und vor `play` gesetzt kommt sie gar nicht an
    /// (gemessen, siehe `Verzoegerung`). Deshalb nicht einmal setzen, sondern
    /// nachsetzen, sobald VLC etwas anderes liest: beim Ändern, bei
    /// „spielt" und im Sekundentakt des Wachhunds.
    private func verzoegerungNachziehen() {
        guard player.media != nil else { return }
        let text = player.currentVideoSubTitleDelay, ton = player.currentAudioPlaybackDelay
        if untertitelVerzoegerung.weichtAb(vonMikrosekunden: text) {
            player.currentVideoSubTitleDelay = untertitelVerzoegerung.mikrosekunden
            Startmessung.geteilt.marke("Untertitelverzögerung gesetzt")
            Protokoll.schreib("[Verzögerung] Untertitel \(untertitelVerzoegerung.millisekunden) ms"
                + " gesetzt, VLC liest \(player.currentVideoSubTitleDelay) µs")
        }
        if tonVerzoegerung.weichtAb(vonMikrosekunden: ton) {
            player.currentAudioPlaybackDelay = tonVerzoegerung.mikrosekunden
            Startmessung.geteilt.marke("Tonverzögerung gesetzt")
            Protokoll.schreib("[Verzögerung] Ton \(tonVerzoegerung.millisekunden) ms"
                + " gesetzt, VLC liest \(player.currentAudioPlaybackDelay) µs")
        }
    }

    // MARK: - Position

    /// Aktuelle Position in Sekunden.
    var positionSeconds: Double { Double(player.time.intValue) / 1000 }

    /// Gesamtlaenge in Sekunden. 0, solange VLC die Datei noch liest.
    ///
    /// **Nennt VLC keine, gilt die des Servers.** libVLC 4 kennt bei MPEG-TS
    /// ueber HTTP nie eine Laenge (``MediaSource/laufzeitSekunden``) — ohne
    /// sie gab es keinen Balken und keine Fortschrittsmeldung. Die Quelle ist
    /// erst mit den Spuren da; bis dahin bleibt es bei 0 wie vorher.
    var durationSeconds: Double {
        guard let ms = player.media?.length.intValue, ms > 0 else {
            return spurQuelle?.laufzeitSekunden ?? 0
        }
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
        // **Am Eingang begrenzt.** Ein Ziel aus NaN oder unendlich (eine
        // Laufzeit von null, durch die geteilt wurde) liess weiter unten
        // `Int(sekunden * 1000)` abstuerzen — die Umwandlung prueft nicht.
        guard let seconds = Sprungziel.sekunden(seconds) else {
            Protokoll.schreib("[VLC] Sprungziel ohne Zahl verworfen")
            return
        }
        melder.sprungJetzt()
        sprungAusloesen(auf: seconds, ueberZeit: zeitsetzenBesser)
        sprungBeobachten(ziel: seconds)
        refreshPiPState()
        sprungGemeldet?(seconds)
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


    /// Relativ springen.
    ///
    /// **Ist der vorige Sprung noch unterwegs, zählt sein Ziel**
    /// (17.09.2026, iPhone): „Intro überspringen", gleich danach „30 s vor" —
    /// und die Wiedergabe sprang zurück an das Ende des Intros. Zwei Gründe:
    /// `jump(withOffset:)` rechnet von VLCs eigener, noch alter Zeit, und
    /// `sprungNachmessen` wachte weiter über das **alte** Ziel, sah die
    /// Wiedergabe 30 s daneben und sprang „zur Rettung" dorthin zurück. Jetzt
    /// springt ein Sprung auf einen offenen absolut vom offenen Ziel aus, und
    /// nachgemessen wird das neue Ziel.
    func jump(seconds: Int32) {
        melder.sprungJetzt()
        if let offen = offenesZiel {
            let ziel = max(offen + Double(seconds), 0)
            Protokoll.schreib("[VLC] Sprung um \(seconds) s vom offenen Ziel \(Int(offen)) s")
            sprungAusloesen(auf: ziel, ueberZeit: zeitsetzenBesser)
            sprungBeobachten(ziel: ziel)
            refreshPiPState()
            sprungGemeldet?(ziel)
            return
        }
        let zeile = "[VLC] Sprung um \(seconds) s von \(Int(positionSeconds)) s"
        Self.log.info("\(zeile, privacy: .public)")
        let ziel = positionSeconds + Double(seconds)
        player.jump(withOffset: seconds * 1000, completion: {})
        refreshPiPState()
        sprungGemeldet?(ziel)
    }
}

extension VLCMediaPlayer.Track {
    /// „Deutsch · AAC · 5.1" statt VLCs rohem Spurnamen.
    ///
    /// **Bewusst nicht über Jellyfins `MediaStream`-Liste**, obwohl die schon
    /// hübsch formatiert ist: die Position in VLCs Spurliste müsste dafür zur
    /// Position in Jellyfins Liste passen, und ein Fehltreffer zeigte eine
    /// falsche Sprache — schlimmer als der rohe Name. Alles kommt von der Spur.
    /// Identität und Vergleich bleiben bei `trackName`.
    var huebscherName: String {
        let libvlcName = codecName()
        return Technikangaben.tonspurname(
            sprache: language,
            codec: Technikangaben.codecname(vlcKennung: codec) ?? (libvlcName.isEmpty ? nil : libvlcName),
            kanaele: audio.map { Int($0.channelsNumber) }
        ) ?? trackName
    }
}


/// Beobachtet VLCs Zustand — bewusst ohne Actor-Isolation, weil VLCKit aus
/// einem eigenen Thread meldet.
/// Leitet VLCs eigene Meldungen in dieselbe Datei wie unsere — und in den
/// Speicher, aus dem ein Nutzer sein Protokoll teilt. Im ausgelieferten Bau
/// nur ab Warnung: dort stehen VLCs Verbindungsfehler, und mehr soll dort
/// keine Last machen.
///
/// **Gefiltert, nicht vollstaendig.** Auf `debug` schreibt VLC hunderte Zeilen
/// je Sekunde; ungefiltert waere die Datei nach Sekunden an ihrer Grenze und
/// das Protokollieren selbst der Engpass. Durchgelassen wird, was die Frage
/// beantwortet, wo die Wartezeit herkommt: Zugriffsschicht, Demuxer, Puffer,
/// Decoder — dazu alles, was VLC selbst als Fehler oder Warnung einstuft.
final class Dateiprotokoll: NSObject, VLCLogging, @unchecked Sendable {
    /// **Die Stufe ist selbst eine Last, kein blosser Filter.**
    ///
    /// Auf `debug` meldet VLC waehrend der Wiedergabe hunderte Zeilen je
    /// Sekunde, und jede laeuft hier durch `print`, eine Sperre und einen
    /// Dateischreibvorgang. Wer damit misst, wie gleichmaessig Bilder auf
    /// den Schirm kommen, misst zu einem guten Teil sich selbst — am
    /// 08.09.2026 sind so vier Messungen am Apple TV entstanden, deren
    /// Ruckeln womoeglich vom Protokollieren stammte.
    ///
    /// `warning` laesst genau das durch, was zur Ausgabe etwas sagt: VLC
    /// stuft verspaetete Bilder und Uhrabweichungen als Warnung ein. Fuer
    /// die Demuxer-Suche, die `debug` braucht, reicht ein gesetzter
    /// Schluessel — dann darf es auch langsam sein.
    #if DEBUG
    private var grundstufe: VLCLogLevel = UserDefaults.standard.bool(forKey: "vlcAusfuehrlich")
        ? .debug : .info
    #else
    private var grundstufe: VLCLogLevel = .warning
    #endif

    /// Im Fenster der ``Startmessung`` auf `debug`: Die Zeilen, die den
    /// Anlauf von Ton und Uhr beschreiben („deferring start", „starting
    /// late", die Latenz des Ausgangs), stuft VLC als `debug` ein. Durch
    /// kommen davon nur ``Startmessung/vlcDebugStichworte`` — der Rest wird
    /// verworfen, bevor er Sperre oder Platte sieht.
    var level: VLCLogLevel {
        get { Startmessung.geteilt.millisekunden != nil ? .debug : grundstufe }
        set { grundstufe = newValue }
    }

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

    /// **Was auf `info` trotzdem durchkommt.**
    ///
    /// Die Stufe steht auf `info`, weil genau dort die eine Zeile faellt, die
    /// sagt, *womit* dekodiert wird -- „using video decoder module ...".
    /// Ohne sie ist nicht zu entscheiden, ob HEVC ueber VideoToolbox laeuft
    /// oder auf der CPU, und beide Faelle sehen von aussen gleich aus.
    /// Geschrieben wird deshalb nur, was diese Frage beantwortet, dazu alles
    /// ab Warnung -- der Rest wird verworfen, bevor er eine Sperre oder die
    /// Platte sieht.
    private static let gesucht = ["decoder module", "using video", "using audio",
                                  "videotoolbox", "hardware", "vout display",
                                  "picture is too late", "clock"]

    func handleMessage(_ nachricht: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let text = nachricht.lowercased()
        guard !Self.flut.contains(where: { text.contains($0) }) else { return }
        let modul = context?.module ?? "?"
        if let ms = Startmessung.geteilt.millisekunden {
            let liste = logLevel == .debug ? Startmessung.vlcDebugStichworte : Startmessung.vlcStichworte
            if liste.contains(where: { text.contains($0) }) {
                Protokoll.schreib("[Start] +\(ms) ms [vlc/\(modul)] \(nachricht)")
                return
            }
        }
        guard logLevel != .debug || grundstufe == .debug else { return }
        let wichtig = logLevel == .error || logLevel == .warning
        guard wichtig || Self.gesucht.contains(where: { text.contains($0) }) else { return }
        Protokoll.schreib("[vlc/\(modul)] \(nachricht)")
    }
}

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
    /// Eine Untertitelspur ist dazugekommen — etwa eine nachgeladene Datei.
    var untertitelHinzu: (() -> Void)?

    func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        guard trackType == .text else { return }
        untertitelHinzu?()
    }
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
                    Task { @MainActor in
                        self?.bildImBildLaeuft = started
                        self?.onPiPStateChanged?(started)
                    }
                }
                self.onPiPAvailable?(window != nil)
            }
        }
    }
}
#endif
