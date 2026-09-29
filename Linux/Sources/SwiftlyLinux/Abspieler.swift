import CBildbruecke
import CGtk
import CVLC
import Foundation
import JellyfinKit

/// **Der Abspieler.** libVLC des Systems, kein VLCKit.
///
/// Auf iPhone, iPad, Apple TV und Mac liegt VLCKit als XCFramework bei; unter
/// Linux ist libVLC eine Systembibliothek. Was entscheidet, **ob**
/// transkodiert wird, ist auf allen fünf Plattformen dasselbe: das
/// `DeviceProfile` im Paket. Verschieden ist nur, wer die Datei abspielt.
///
/// **Hier läuft libVLC 3, auf Apple libVLC 4.** Das ist kein Versehen: VLC 4
/// ist auf Arch nicht paketiert, und der eine Unterschied, den es für uns
/// macht, spricht sogar für 3 — der Sprungfehler in MKV ohne Cues ist eine
/// **Regression von VLC 4**, auf 3 gibt es ihn nicht. Deshalb steht hier auch
/// kein `:demux=mkv_trusted`: das ist die Abhilfe für genau jenen Fehler.
///
/// Das Bild kommt über ``Bildbruecke`` aus dem C-Teil. Warum das nicht in
/// Swift steht, begründet `bildbruecke.h`.
final class Abspieler: @unchecked Sendable {

    private var kern: OpaquePointer?
    private var spieler: OpaquePointer?
    private var bruecke: OpaquePointer?
    private var bildfeld: Widget!
    /// **Das HDR-Bild.** Eine `GtkGLArea` neben dem `GtkPicture`: HDR kommt
    /// als YUV zu zehn Bit an und wird auf der Grafikkarte auf SDR abgebildet
    /// (`hdrbild.h`). Sichtbar ist immer nur eines von beiden.
    private var glfeld: Widget!
    /// Haelt Bildfeld und GL-Feld; das ist, was die Spielerseite einhaengt.
    private var huelle: Widget!
    private var hdr: OpaquePointer?
    /// `HDRBILD_PQ`/`HDRBILD_HLG` fuer den laufenden Titel, 0 auf dem RGB-Weg.
    private var hdrKennlinie: Int32 = 0
    private var fuellend = false
    /// Groesse des GL-Rahmenpuffers in Geraetepunkten, aus dem Signal `resize`.
    fileprivate var glBreite: Int32 = 0
    fileprivate var glHoehe: Int32 = 0
    private var hdrFehlerGemeldet = false
    private var takt: guint = 0

    /// **Wie viele Bilder die Bruecke seit dem Oeffnen hergegeben hat.**
    /// Nur zum Messen: ohne diese Zahl laesst sich „das Bild bleibt schwarz"
    /// nicht von „das Bild kommt, wird aber nicht gezeichnet" unterscheiden.
    private(set) var geholteBilder = 0
    /// GTK ist auf `GskCairoRenderer` zurueckgefallen — siehe
    /// ``rendererMelden()``.
    private(set) var zeichnetOhneGPU = false

    /// **Wie oft GTKs Taktgeber den Abspieler ueberhaupt gefragt hat.**
    /// Steht diese Zahl still, liegt es nicht an VLC, sondern daran, dass
    /// das Bildfeld keinen Takt mehr bekommt.
    private(set) var takte = 0
    #if DEBUG
    private var holdauer = 0.0
    private var zuletztGemeldet = 0
    #endif

    /// Wie die Anzeige das Bild zeigt. Ein `GtkPicture`, sonst nichts.
    var anzeige: Widget! { huelle }

    /// Zum Messen: haengt das Bildfeld im Fenster, hat es einen Taktgeber,
    /// und ist der Rueckruf angemeldet?
    var taktlage: String {
        guard let huelle else { return "kein Bildfeld" }
        let gemappt = gtk_widget_get_mapped(huelle) != 0
        let uhr = gtk_widget_get_frame_clock(huelle) != nil
        let eltern = gtk_widget_get_parent(huelle) != nil
        return "mapped=\(gemappt ? 1 : 0) uhr=\(uhr ? 1 : 0) eltern=\(eltern ? 1 : 0) id=\(takt)"
    }

    /// **VLC spielt (`true`) oder hat angehalten (`false`)** — aus libVLCs
    /// Ereignissen `Playing`/`Paused`, auf GTKs Faden. Das Gegenstueck zu
    /// `VLCPlayerView.laeuftGemeldet` auf Apple: gemeldet wird, was VLC tut,
    /// nicht was ein Knopf erwartet (Audit 16.09., T2-N1).
    var laufzustand: ((Bool) -> Void)?
    /// Stopp, Ende oder Fehler **des laufenden Mediums** — nicht eines, das
    /// ``beenden(nurMedium:)`` absichtlich angehalten hat (dessen Ereignis
    /// kommt spaeter an und traegt einen anderen Spieler). Wahr heisst: VLC
    /// meldete einen Fehler. Auf dem Hauptfaden.
    var abgerissen: ((Bool) -> Void)?

    /// Ist `quelle` der Spieler, der gerade laeuft?
    fileprivate func istLaufend(_ quelle: UInt) -> Bool {
        UInt(bitPattern: spieler.map { UnsafeMutableRawPointer($0) }) == quelle
    }

    init() {
        // Keine Benutzeroberfläche von VLC, keine eigenen Fenster: wir stellen
        // das Bild selbst dar. `--no-video-title-show` unterdrückt die
        // Einblendung, die VLC sonst über jedes Bild legt.
        var woerter = ["--no-video-title-show", "--quiet"]
        // **Der Schalter gilt in jedem Bau**, nicht nur im Debug: wer einen
        // Fehler meldet, hat den ausgelieferten. Mit `--quiet` schweigt VLC
        // auch zu „no suitable decoder module", und genau solche Saetze
        // fehlten am 20.09.2026 im Protokoll eines Testers.
        if ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1" {
            woerter = ["--no-video-title-show", "--verbose=1"]
        }
        #if DEBUG
        // **Zum Pruefen, ob Module fehlen.** Mit `--quiet` schweigt VLC auch
        // zu „no suitable decoder module"; im Debug-Bau laesst
        // `SWIFTLY_VLC_MELDUNGEN=1` Fehler und Warnungen nach stderr.
        if ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1" {
            woerter = ["--no-video-title-show", "--verbose=1"]
        }
        #endif
        // **Keine Bilder vorab wegwerfen** (Apple `d7e4a6f`, `VLCPlayer.bibliothek`).
        // Alte DVD-Rips ruckelten: der vout wirft ein Bild weg, sobald es nach
        // einer Schaetzung aus dem Hoechstwert von Filter- und Renderdauer zu
        // spaet kaeme, und eine einzige Zeitspitze kostet so ganze Bilder.
        // Gemessen wurde auf Apple; hier laeuft jedes Bild ebenfalls ueber
        // die CPU zu uns. **An der Bibliothek, nicht am Medium** — am Medium
        // wirkt die Option dort nachweislich nicht. In libVLC 3.0.23 auf
        // cachy vorhanden (`vlc -H --advanced`).
        woerter.append("--no-drop-late-frames")
        // **Entflechten mit `bob`, ebenfalls an der Bibliothek** (Apple
        // `VLCPlayerView.bibliothek`). Stand am Medium und griff dort nie:
        // libVLC 3.0.23 meldete bei 1080i50 trotzdem „using x deinterlace
        // method", mit `--deinterlace-mode=bob` hier „using bob" (gemessen
        // 25.09.2026). Greift nur, wo VLC Halbbilder erkennt.
        woerter.append("--deinterlace-mode=bob")
        woerter += Untertitelstil.vlcOptionen()

        #if os(Linux)
        // Sagt VLC, dass es Xlib nicht anfassen soll — wir zeichnen selbst.
        // Unter Windows kennt VLC die Angabe nicht und beschwert sich.
        woerter.insert("--no-xlib", at: 0)
        #endif

        #if os(Windows)
        // **libVLC findet seine Module nicht von selbst.** Auf Linux liegen
        // sie an einem festen Ort im System; unter Windows liegen sie neben
        // der DLL, und danach sucht libVLC nur, wenn es aus seinem eigenen
        // Verzeichnis geladen wurde. Ohne den Hinweis startet der Abspieler
        // ohne einen einzigen Dekoder — das Bild bliebe schwarz, ohne
        // Fehlermeldung.
        if ProcessInfo.processInfo.environment["VLC_PLUGIN_PATH"] == nil,
           let selbst = Plattform.programmpfad {
            let module = URL(fileURLWithPath: selbst)
                .deletingLastPathComponent()
                .appendingPathComponent("plugins").path
            if FileManager.default.fileExists(atPath: module) {
                module.withCString { _ = g_setenv("VLC_PLUGIN_PATH", $0, 1) }
            }
        }
        #endif

        // **`libvlc_new` gehoert nicht auf den Hauptfaden.**
        //
        // Es liest die Modulliste ein — unter Windows hunderte DLLs im
        // `plugins`-Ordner, und beim ersten Mal sieht der Virenwaechter jede
        // davon an. Im Protokoll eines Testers vom 20.09.2026 stand dafuer
        // `[Hauptfaden] VLC anhalten hat 13030 ms gebraucht`, und zwar beim
        // **ersten** Abspielen, wo es gar nichts anzuhalten gab: der Aufruf
        // griff auf `App.abspieler` zu, und weil das ein `lazy var` ist, lief
        // in diesem Augenblick dieser Konstruktor. Dreizehn Sekunden stand
        // das Fenster, bevor der Druck auf „Abspielen" ueberhaupt bearbeitet
        // wurde.
        //
        // Der Kern entsteht deshalb nebenlaeufig. Wer vorher oeffnen will,
        // hinterlegt seinen Auftrag; er laeuft, sobald der Kern steht.
        let werte = woerter
        Task.detached { [self] in
            #if DEBUG
            // **Damit der Wartefall einmal wahr wird.** Auf einem schnellen
            // Rechner steht der Kern nach 0,1 s, und der Zweig „Titel wartet"
            // waere nie gelaufen — geprueft ist er dann nicht.
            if let langsam = ProcessInfo.processInfo.environment["SWIFTLY_VLC_LANGSAM"],
               let s = UInt64(langsam) { try? await Task.sleep(nanoseconds: s * 1_000_000_000) }
            #endif
            var argumente: [UnsafePointer<CChar>?] = []
            for wort in werte { argumente.append(strdup(wort)) }
            let fertig = libvlc_new(Int32(argumente.count), &argumente)
            for zeiger in argumente { free(UnsafeMutableRawPointer(mutating: zeiger)) }
            let adresse = UInt(bitPattern: fertig.map { UnsafeMutableRawPointer($0) })
            aufHauptfaden {
                self.kern = adresse == 0 ? nil : OpaquePointer(UnsafeMutableRawPointer(bitPattern: adresse)!)
                if self.kern == nil {
                    // **Ohne Kern wartete ein Titel fuer immer.** `oeffnen`
                    // legte ihn als wartenden Auftrag ab, der Auftrag rief
                    // `oeffnen`, und das legte ihn wieder ab — der Nutzer sah
                    // den Ladeschleier, im Protokoll stand nichts.
                    self.kaputt = true
                    Protokoll.schreib("[Player] FEHLER: libVLC liess sich nicht starten"
                        + " (VLC_PLUGIN_PATH, fehlende Module?)")
                } else {
                    self.vlcMeldungenAnschliessen()
                    Protokoll.schreib("[Player] VLC bereit")
                }
                let wartet = self.wartenderAuftrag
                self.wartenderAuftrag = nil
                wartet?()
            }
        }
        bruecke = bildbruecke_neu()
        bildfeld = gtk_picture_new()
        glfeld = gtk_gl_area_new()
        huelle = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        hdr = hdrbild_neu()
        // **Das Bildfeld überlebt seine Seite** — genauer die Huelle, in der
        // es mit dem GL-Feld steckt. Es wird einmal angelegt und
        // bei jedem Öffnen in eine neue Player-Seite gehängt; wird die alte
        // Seite aus dem Stapel genommen, verliert es seinen Eltern — und damit
        // seine letzte Referenz. Beim zweiten Öffnen läge dann ein
        // freigegebener Zeiger in `anzeige`, und GObject stirbt daran mit
        // einer Adresse, die nach Zufall aussieht. Genau so ist die App
        // abgestürzt, als
        g_object_ref_sink(huelle)
        gtk_picture_set_content_fit(OpaquePointer(bildfeld), GTK_CONTENT_FIT_CONTAIN)
        for feld in [huelle, bildfeld, glfeld] {
            gtk_widget_set_hexpand(feld, 1)
            gtk_widget_set_vexpand(feld, 1)
        }
        gtk_box_append(alsBox(huelle), bildfeld)
        gtk_box_append(alsBox(huelle), glfeld)
        gtk_widget_set_visible(glfeld, 0)
        glFeldAnschliessen()
        // **Und noch einmal, sobald das Bildfeld wieder im Fenster haengt.**
        // ``oeffnen(_:ab:puffer:)`` meldet den Takt an, aber es ist nicht
        // gesagt, dass das Umhaengen davor liegt: wer eine Seite baut,
        // waehrend schon gespielt wird, kaeme sonst wieder ohne Takt heraus.
        // Nur wenn ueberhaupt ein Spieler laeuft — sonst liesse ein Takt
        // ohne Bild GTK jeden Frame umsonst zeichnen.
        beiSignal(huelle, "map") { [weak self] in
            guard let self, self.spieler != nil else { return }
            self.bildTaktStarten()
        }
    }

    deinit { beenden() }

    // MARK: Steuern

    /// **Der Puffer als Pflichtangabe, nicht als Vorgabewert.**
    ///
    /// Auf dem Fernseher ist genau diese Falle einmal aufgegangen: die Stufe
    /// wurde beim Oeffnen gesetzt und beim Folgenwechsel vergessen, und die
    /// naechste Folge lief still mit der alten. Ohne Standardwert kann keine
    /// der drei Aufrufstellen sie auslassen — der Uebersetzer fragt nach.
    /// Was laufen soll, sobald ``kern`` steht — hoechstens eines, das
    /// juengste gewinnt. Wer zweimal tippt, will den zweiten Titel.
    private var wartenderAuftrag: (() -> Void)?
    /// `libvlc_new` hat nichts geliefert. Siehe ``init()``.
    private var kaputt = false
    private var wartetSeit: Date?

    /// Steht der Kern? Der Ladeschirm sagt es dem Zuschauer, statt ihn vor
    /// eine schwarze Fläche zu setzen.
    var bereit: Bool { kern != nil }

    /// - Parameter softwareDekoder: gleich ohne Hardware dekodieren —
    ///   ``PlaybackPlan/softwareDekoder`` (MPEG-4 Part 2, XviD/DivX).
    /// - Parameter kennlinie: PQ oder HLG laut Server
    ///   (``Farbauskunft/kennlinie(quelle:)``), `nil` fuer SDR. Pflicht, aus
    ///   demselben Grund wie der Puffer: ein vergessenes HDR ist wieder das
    ///   ausgewaschene Bild.
    func oeffnen(_ url: URL, ab: Double, puffer: Pufferstufe, pausiert: Bool = false,
                 softwareDekoder: Bool = false, kennlinie: Farbumfang.Kennlinie?) {
        if kern == nil, kaputt {
            Protokoll.schreib("[Player] kein VLC, Titel kann nicht spielen")
            aufHauptfaden { [weak self] in self?.abgerissen?(true) }
            return
        }
        pausiertSeit = nil
        guard kern != nil else {
            Protokoll.schreib("[Player] VLC noch nicht bereit, Titel wartet")
            if wartetSeit == nil { wartetSeit = Date() }
            wartenderAuftrag = { [self] in
                oeffnen(url, ab: ab, puffer: puffer, pausiert: pausiert,
                        softwareDekoder: softwareDekoder, kennlinie: kennlinie)
            }
            return
        }
        // **Wie lange der erste Titel auf VLC gewartet hat.** Beim ersten Mal
        // auf einem Rechner sieht der Virenwaechter jede Modul-DLL an; danach
        // liegt alles im Zwischenspeicher des Systems. Ohne diese Zahl ist
        // „dauert beim ersten Mal laenger" eine Erzaehlung und keine Messung.
        if let seit = wartetSeit {
            wartetSeit = nil
            Protokoll.schreib(String(format: "[Player] wartete %.1f s auf VLC",
                                     Date().timeIntervalSince(seit)))
        }
        beenden(nurMedium: true)
        geholteBilder = 0
        takte = 0
        #if DEBUG
        holdauer = 0; zuletztGemeldet = 0
        #endif
        sprungBei = nil
        guard let kern, let bruecke else { return }
        // Hinter einem Vorposten holt die App den Strom selbst: libVLC kann
        // keine eigenen Header senden (Issue #4). Ohne Header unverändert.
        let vlcAdresse = Stromweiterleiter.gemeinsam.adresse(fuer: url)
        if vlcAdresse != url { Protokoll.schreib("[Player] Strom über den Weiterleiter") }
        guard let medium = libvlc_media_new_location(kern, vlcAdresse.absoluteString) else { return }
        // **Die Stelle als Option, nicht als Sprung nach dem Start.** Genau
        // so macht es die iOS-Fassung (`:start-time`), und der Grund steht
        // dort: ein Sprung nach dem Start baut den Strom ein zweites Mal auf.
        if ab > 1 { libvlc_media_add_option(medium, ":start-time=\(Int(ab))") }
        // Entflechten: `--deinterlace-mode=bob` steht an der Bibliothek (oben,
        // `woerter`) — als Medienoption griff es nicht.

        // Nach dem Aufwachen an der Stelle neu aufbauen, **ohne** loszuspielen,
        // wenn vorher angehalten war.
        if pausiert { libvlc_media_add_option(medium, ":start-paused") }

        // **XviD/DivX ohne Hardware** (``Erstbild/softwareOptionenDesktop``):
        // Hardware-Dekoder nehmen MPEG-4 Part 2 an und scheitern an
        // Advanced-Simple-Profile-Material — auf Apple blieb das Bild stehen.
        if softwareDekoder {
            for option in Erstbild.softwareOptionenDesktop { libvlc_media_add_option(medium, option) }
        }

        // **Zwei Optionen vom Netzweg, wortgleich von der Apple-Fassung.**
        //
        // `prefetch-buffer-size` haelt in der Vorgabe 16 MiB voraus — bei den
        // Bitraten hier gut drei Minuten Inhalt. Auf dem iPhone ist daran
        // nachgemessen worden, dass es am Vorrat *nicht* lag (211 Sekunden
        // gefuellt). Seit dem 10.09.2026 ist es waehlbar: fuer eine Leitung,
        // die *schwankt*, fehlte am Vorrat nichts — fuer eine, die auch mal
        // *ganz weg* ist, schon. Die Stufen stehen im Paket, damit hier und
        // auf den Apple-Fassungen dieselben drei Zahlen gelten.
        //
        // `http-reconnect` faengt den Abriss nach einer laengeren Pause auf.
        // Am 08.09.2026 zweimal mitgeschrieben: 25 Sekunden pausiert, und
        // beim Fortsetzen raeumt der Server den untaetigen Strom ab; ohne
        // die Option behandelt VLC das als Stromende und baut alles neu auf.
        // Solange die Verbindung haelt, aendert sie nichts.
        //
        // Beide sind in dem libVLC 3 vorhanden, das hier laeuft — in
        // `libprefetch_plugin.so` und `libhttp_plugin.so` nachgesehen, nicht
        // aus der Dokumentation der Fassung 4 uebernommen.
        if !url.isFileURL {
            libvlc_media_add_option(medium, ":prefetch-buffer-size=\(puffer.prefetchKiB)")
            libvlc_media_add_option(medium, ":http-reconnect")
            // **Nur ab der zweiten Stufe.** Bei `normal` bliebe hier VLCs
            // eigener Standardwert stehen; ihn ausdruecklich noch einmal zu
            // setzen sieht nach Absicht aus und aendert nichts.
            if let vorlauf = puffer.netzvorlaufMillisekunden {
                libvlc_media_add_option(medium, ":network-caching=\(vorlauf)")
            }
        }
        spieler = libvlc_media_player_new_from_media(medium)
        libvlc_media_release(medium)
        guard let spieler else { return }
        bildwegWaehlen(kennlinie)
        bildbruecke_anhaengen(bruecke, spieler)
        if let ereignisse = libvlc_media_player_event_manager(spieler) {
            let ich = Unmanaged.passUnretained(self).toOpaque()
            libvlc_event_attach(ereignisse, libvlc_event_type_t(libvlc_MediaPlayerPlaying.rawValue),
                                laufzustandRuf, ich)
            libvlc_event_attach(ereignisse, libvlc_event_type_t(libvlc_MediaPlayerPaused.rawValue),
                                laufzustandRuf, ich)
            // **Die uebrigen Zustaende nur fuers Protokoll.** Am 20.09.2026
            // stand im Protokoll eines Testers keine einzige Zeile aus dem
            // Player — es war nicht zu sagen, ob VLC ueberhaupt aufgemacht
            // hat, ob es puffert oder ob es mit einem Fehler stehenblieb.
            // Ohne diese Zeilen ist der naechste Bericht wieder blind.
            for zustand in [libvlc_MediaPlayerOpening, libvlc_MediaPlayerBuffering,
                            libvlc_MediaPlayerStopped, libvlc_MediaPlayerEndReached,
                            libvlc_MediaPlayerEncounteredError] {
                libvlc_event_attach(ereignisse, libvlc_event_type_t(zustand.rawValue),
                                    zustandRuf, ich)
            }
        }
        Protokoll.schreib("[Player] oeffne \(url.isFileURL ? "Datei" : "Netz")"
            + " \(url.pathExtension.isEmpty ? "ohne Endung" : url.pathExtension)"
            + ", ab \(Int(ab)) s, Puffer \(puffer)"
            + (softwareDekoder ? ", Dekoder Software" : ""))
        libvlc_media_player_play(spieler)
        bildTaktStarten()
        rendererMelden()
    }

    /// **Womit GTK zeichnet — einmal je Titel ins Protokoll.**
    ///
    /// Steht dort `GskCairoRenderer`, laeuft das Zeichnen auf der CPU: jedes
    /// Bild wird dann in Software auf Fenstergroesse gerechnet, und bei
    /// 1080p25 ist der Hauptfaden damit ausgelastet. Genau das erklaert, warum
    /// ein Fenster sich nicht mehr verschieben laesst und warum Arbeit, die
    /// im Leerlauf haengt, nicht mehr drankommt. Mit `GskGLRenderer` oder
    /// `GskNglRenderer` macht das die Grafikkarte.
    ///
    /// Eine Zeile je Titel, kein Dauerlaerm — und sie beantwortet eine Frage,
    /// die sonst nur ein Blick auf den fremden Rechner beantwortet.
    private func rendererMelden() {
        guard let huelle, let fenster = gtk_widget_get_native(huelle),
              let zeichner = gtk_native_get_renderer(fenster) else { return }
        let name = g_type_name_from_instance(
            unsafeBitCast(zeichner, to: UnsafeMutablePointer<GTypeInstance>.self))
        let klar = name.map { String(cString: $0) } ?? "unbekannt"
        Protokoll.schreib("[Player] Zeichenwerk \(klar)")
        // **Der Rueckfall auf Cairo wird genannt, nicht nur verzeichnet.**
        // Ist der GL-/EGL-Kontext ungueltig (alter Treiber, VM, Fernsitzung),
        // zeichnet GTK mit der CPU: jedes Videobild geht dann durch Cairo,
        // das Fenster stockt, und bei einem Tester blieb so der Ladeschleier
        // liegen. Im Protokoll stand das bisher als eine Zeile unter vielen.
        // Jetzt als Warnung mit dem Weg, den man selbst probieren kann, und
        // im Technikschild (``Technikschild``) sichtbar.
        zeichnetOhneGPU = klar.contains("Cairo")
        if zeichnetOhneGPU {
            Protokoll.schreib("[Player] WARNUNG: GTK zeichnet ohne Grafikbeschleunigung (Cairo)."
                + " GL/EGL nicht verfuegbar; Probe: GSK_RENDERER=ngl oder =gl setzen")
        }
    }

    /// **Was VLC selbst zu melden hat, in unser Protokoll.**
    ///
    /// Ohne das schweigt libVLC (`--quiet`) oder schreibt nach stderr, wo es
    /// unter Windows niemand findet. Nur auf ausdruecklichen Wunsch, denn
    /// VLCs Zeilen koennen die volle Abspieladresse tragen — und die traegt
    /// bei Jellyfin den Zugangsschluessel. Deshalb wird jede Zeile vorher
    /// entschaerft; wer ein Protokoll weiterschickt, gibt seinen Schluessel
    /// nicht mit.
    private func vlcMeldungenAnschliessen() {
        guard ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1",
              let kern else { return }
        vlcspur_an(kern, vlcLogRuf)
        Protokoll.schreib("[Player] VLC-Meldungen an")
    }

    /// Schaltet den Ton um. Wahr heisst: jetzt stumm; `nil`, wenn nichts
    /// laeuft. **Gelesen, dann gesetzt** statt `toggle`: ohne Tonausgabe
    /// (Geraet gerade gewechselt) meldet VLC -1, und `toggle` taete dann
    /// nichts, waehrend der Hinweis „Ton aus" sagte.
    func stummUmschalten() -> Bool? {
        guard let spieler else { return nil }
        let neu = libvlc_audio_get_mute(spieler) != 1
        libvlc_audio_set_mute(spieler, neu ? 1 : 0)
        return neu
    }

    func abspielen() { spieler.map { libvlc_media_player_set_pause($0, 0) } }
    func anhalten() {
        if pausiertSeit == nil { pausiertSeit = Date() }
        spieler.map { libvlc_media_player_set_pause($0, 1) }
    }
    func umschalten() { laeuft ? anhalten() : abspielen() }

    /// **Seit wann angehalten ist** — für ``Pausenruecksprung`` (iOS
    /// `VLCPlayerView.pausiertSeit`). Gesetzt beim Anhalten, auch wenn VLC
    /// von selbst anhält; gelöscht, sobald es wieder läuft, und mit jedem
    /// neuen Medium.
    private(set) var pausiertSeit: Date?

    #if DEBUG
    /// Für das ``Fernsteuerpult``: so tun, als stünde es seit `sekunden`.
    func pausiertSeitVorstellen(_ sekunden: Double) {
        pausiertSeit = Date().addingTimeInterval(-sekunden)
    }
    #endif

    /// Vom Laufzustand nachgeführt (``laufzustandRuf``).
    fileprivate func laufzustandVermerken(_ laeuft: Bool) {
        if laeuft { pausiertSeit = nil } else if pausiertSeit == nil { pausiertSeit = Date() }
    }

    var laeuft: Bool {
        guard let spieler else { return false }
        return libvlc_media_player_is_playing(spieler) != 0
    }

    /// Sekunden. libVLC rechnet in Millisekunden.
    var position: Double {
        guard let spieler else { return 0 }
        let t = libvlc_media_player_get_time(spieler)
        return t > 0 ? Double(t) / 1000 : 0
    }

    var dauer: Double {
        guard let spieler else { return 0 }
        let l = libvlc_media_player_get_length(spieler)
        return l > 0 ? Double(l) / 1000 : 0
    }

    var zeigtBild: Bool {
        guard let spieler else { return false }
        return libvlc_media_player_has_vout(spieler) > 0
    }

    var hatTonspuren: Bool { !tonspuren.isEmpty }

    /// **Steuert VLC gerade ein?** `Zeitannahme.bildDa` zieht dann die
    /// längere Frist von 25 Sekunden statt der kurzen — ohne diese Auskunft
    /// gilt das erste Bild als da, bevor es da ist, und damit meldet die App
    /// dem Server einen Start, den es noch nicht gibt.
    var stelltEin: Bool {
        guard let spieler else { return false }
        return libvlc_media_player_get_state(spieler) == libvlc_Buffering
    }

    func setzeZeit(_ sekunden: Double) {
        guard let spieler else { return }
        // **Jeder Sprung ins Protokoll, mit dem Bildzaehler.**
        //
        // Ein Tester meldete am 20.09.2026: vorwaerts springen bringt kein
        // Bild, rueckwaerts schon. Ob nach einem Sprung ueberhaupt neue
        // Bilder an der Bruecke ankommen, ist die Frage, die das entscheidet
        // — und ohne den Zaehler daneben ist sie nicht zu beantworten.
        let von = position
        Protokoll.schreib(String(format: "[Player] springe %@ auf %.0f s (von %.0f s, Bilder bisher %d)",
                                 sekunden >= von ? "vor" : "zurueck", max(0, sekunden), von, geholteBilder))
        sprungBei = geholteBilder
        sprungSeit = Date()
        libvlc_media_player_set_time(spieler, libvlc_time_t(max(0, sekunden) * 1000))
    }

    /// Der Bildstand beim letzten Sprung — ``Spieler`` meldet danach einmal,
    /// wie viele dazugekommen sind.
    private(set) var sprungBei: Int?
    private var sprungSeit = Date.distantPast

    /// Wie viele Bilder seit dem letzten Sprung dazukamen, und danach
    /// zuruecksetzen. `nil`, wenn kein Sprung offen ist.
    /// **Erst nach einer Sekunde.** Der Takt kommt unter Umstaenden zehn
    /// Millisekunden nach dem Sprung, und dann steht dort „0 Bilder dazu",
    /// auch wenn alles in Ordnung ist. Die Zahl soll eine Auskunft sein,
    /// keine Falle fuer den Naechsten, der sie liest.
    func sprungbilanz() -> Int? {
        guard let bei = sprungBei, Date().timeIntervalSince(sprungSeit) >= 1 else { return nil }
        sprungBei = nil
        return geholteBilder - bei
    }

    /// Sprungweiten kommen aus den Einstellungen (B2), nicht von hier.
    func springen(_ sekunden: Double) {
        setzeZeit(max(0, position + sekunden))
    }

    // MARK: Spuren

    struct Spur { let kennung: Int32; let name: String }

    var tonspuren: [Spur] { spuren(libvlc_audio_get_track_description) }
    var untertitelspuren: [Spur] { spuren(libvlc_video_get_spu_description) }

    private func spuren(
        _ holen: (OpaquePointer?) -> UnsafeMutablePointer<libvlc_track_description_t>?
    ) -> [Spur] {
        guard let spieler else { return [] }
        guard let erste = holen(spieler) else { return [] }
        defer { libvlc_track_description_list_release(erste) }
        var liste: [Spur] = []
        var zeiger: UnsafeMutablePointer<libvlc_track_description_t>? = erste
        while let jetzt = zeiger {
            let name = jetzt.pointee.psz_name.map { String(cString: $0) } ?? "—"
            liste.append(Spur(kennung: jetzt.pointee.i_id, name: name))
            zeiger = jetzt.pointee.p_next
        }
        return liste
    }

    func setzeTonspur(_ kennung: Int32) {
        spieler.map { libvlc_audio_set_track($0, kennung) }
    }

    func setzeUntertitel(_ kennung: Int32) {
        spieler.map { libvlc_video_set_spu($0, kennung) }
    }

    var tonspur: Int32 { spieler.map { libvlc_audio_get_track($0) } ?? -1 }
    var untertitelspur: Int32 { spieler.map { libvlc_video_get_spu($0) } ?? -1 }

    /// Was libVLC über eine Spur weiß, das die Beschreibungsliste nicht
    /// hergibt: Codec als Fourcc, Sprache, Kanäle.
    struct Spurangabe { let codec: UInt32; let sprache: String?; let kanaele: Int? }

    /// **Über das Medium, nicht über die Beschreibungsliste.** libVLC 3 kennt
    /// keine `libvlc_media_player_get_track`-Objekte wie 4; die Angaben stehen
    /// am Medium, verbunden über dieselbe `i_id`.
    func spurangaben() -> [Int32: Spurangabe] {
        guard let spieler, let medium = libvlc_media_player_get_media(spieler) else { return [:] }
        defer { libvlc_media_release(medium) }
        var feld: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_track_t>?>?
        let anzahl = libvlc_media_tracks_get(medium, &feld)
        guard anzahl > 0, let feld else { return [:] }
        defer { libvlc_media_tracks_release(feld, anzahl) }
        var angaben: [Int32: Spurangabe] = [:]
        for i in 0..<Int(anzahl) {
            guard let spur = feld[i]?.pointee else { continue }
            let sprache = spur.psz_language.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            let kanaele = spur.i_type == libvlc_track_audio ? spur.audio.map { Int($0.pointee.i_channels) } : nil
            angaben[spur.i_id] = Spurangabe(codec: spur.i_codec, sprache: sprache, kanaele: kanaele)
        }
        return angaben
    }

    /// **Eine Untertiteldatei nachladen, ohne sie einzuschalten.** Gewählt
    /// wird danach über ``setzeUntertitel(_:)``, wie jede andere Spur.
    @discardableResult
    func untertiteldateiAnhaengen(_ adresse: URL) -> Bool {
        guard let spieler else { return false }
        let vlcAdresse = Stromweiterleiter.gemeinsam.adresse(fuer: adresse)
        return libvlc_media_player_add_slave(spieler, libvlc_media_slave_type_subtitle,
                                             vlcAdresse.absoluteString, false) == 0
    }

    /// Tempostufen kommen aus dem Paket (B9), nicht von hier.
    var tempo: Float {
        get { spieler.map { libvlc_media_player_get_rate($0) } ?? 1 }
        set { spieler.map { libvlc_media_player_set_rate($0, newValue) } }
    }

    // MARK: Verzoegerung

    /// Untertitel und Ton gegen das Bild verschoben — nur lokal, SyncPlay
    /// sieht davon nichts (Vorlage: `VLCPlayerView`, Abschnitt Verzoegerung).
    /// Der Abspieler lebt so lange wie die App; ``App/spielerOeffnen`` setzt
    /// die Werte je Titel ueber ``verzoegerungFuerNeuenTitel``.
    var untertitelVerzoegerung = Verzoegerung.null {
        didSet { if untertitelVerzoegerung != oldValue { verzoegerungNachziehen() } }
    }
    var tonVerzoegerung = Verzoegerung.null {
        didSet { if tonVerzoegerung != oldValue { verzoegerungNachziehen() } }
    }

    /// Vor jedem Oeffnen eines anderen Titels: dieselbe Serie behaelt den
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

    /// **Nachsetzen, nicht einmal setzen.** Linux legt je Medium einen neuen
    /// libVLC-Spieler an, der bei 0 beginnt; und wie VLC 4 auf Apple nimmt
    /// er den Wert vor dem Abspielen womoeglich nicht an. Deshalb beim
    /// Aendern, bei „spielt" und im Sekundentakt des Spielers — immer dann,
    /// wenn libVLC etwas anderes liest als gewollt.
    func verzoegerungNachziehen() {
        guard let spieler else { return }
        let text = Int(libvlc_video_get_spu_delay(spieler))
        let ton = Int(libvlc_audio_get_delay(spieler))
        if untertitelVerzoegerung.weichtAb(vonMikrosekunden: text) {
            libvlc_video_set_spu_delay(spieler, Int64(untertitelVerzoegerung.mikrosekunden))
            Protokoll.schreib("[Verzögerung] Untertitel \(untertitelVerzoegerung.millisekunden) ms"
                + " gesetzt, VLC liest \(libvlc_video_get_spu_delay(spieler)) µs")
        }
        if tonVerzoegerung.weichtAb(vonMikrosekunden: ton) {
            libvlc_audio_set_delay(spieler, Int64(tonVerzoegerung.mikrosekunden))
            Protokoll.schreib("[Verzögerung] Ton \(tonVerzoegerung.millisekunden) ms"
                + " gesetzt, VLC liest \(libvlc_audio_get_delay(spieler)) µs")
        }
    }

    // MARK: Zaehlwerk

    /// **VLCs Zaehler, roh — gerechnet wird im Paket.**
    ///
    /// `libvlc_media_get_stats` fuehrt dieselben Summen, die VLCKit auf den
    /// Apple-Fassungen liefert; die Rechnung darueber liegt in
    /// ``JellyfinKit/Zaehlwerk`` und ist damit nur einmal da.
    ///
    /// Das Medium wird ueber den Spieler geholt und danach wieder
    /// freigegeben: `libvlc_media_player_get_media` erhoeht den Zaehler, und
    /// ohne das Gegenstueck bliebe bei jedem Abruf eine Referenz stehen — im
    /// Halbsekundentakt waere das ein Leck, das niemandem auffiele.
    var zaehlwerte: Zaehlwerk.Rohwerte? {
        guard let spieler, let medium = libvlc_media_player_get_media(spieler) else { return nil }
        defer { libvlc_media_release(medium) }
        var s = libvlc_media_stats_t()
        guard libvlc_media_get_stats(medium, &s) != 0 else { return nil }
        // Die Felder sind vorzeichenbehaftet; negativ waere Schrott, und der
        // Riegel dagegen steht im Paket. Hier wird nur nicht unter null
        // gerechnet.
        func u(_ v: Int32) -> UInt64 { v > 0 ? UInt64(v) : 0 }
        func u(_ v: UInt64) -> UInt64 { v }
        return Zaehlwerk.Rohwerte(
            gelesen: u(s.i_read_bytes), entpackt: u(s.i_demux_read_bytes),
            gezeigt: u(s.i_displayed_pictures), verworfen: u(s.i_lost_pictures),
            zuSpaet: 0,
            videoBloecke: u(s.i_decoded_video), tonBloecke: u(s.i_decoded_audio),
            tonGespielt: u(s.i_played_abuffers), tonVerloren: u(s.i_lost_abuffers),
            beschaedigt: u(s.i_demux_corrupted), spruenge: u(s.i_demux_discontinuity))
    }

    // MARK: Bild

    /// **Ganzes Bild oder formatfuellend — und warum es hier anders geht als
    /// auf den Apple-Fassungen.**
    ///
    /// Dort setzt VLCKit `videoFitMode`, weil VLC dort selbst zeichnet. Hier
    /// zeichnet VLC gar nicht: die Einzelbilder kommen ueber `bildbruecke`
    /// als Textur herein und werden von einem `GtkPicture` eingepasst.
    /// `libvlc_video_set_crop_geometry` griffe also ins Leere.
    ///
    /// Das richtige Mittel ist deshalb GTKs eigenes: `CONTAIN` legt das ganze
    /// Bild hinein und laesst Balken stehen, `COVER` fuellt und schneidet ab.
    /// Beides ohne Verzerren — `FILL` waere genau die Streckung, die es auf
    /// keiner Plattform geben soll. Das GL-Feld fuer HDR passt genauso ein
    /// (`hdrbild_zeichnen`).
    func bildfuellend(_ an: Bool) {
        guard let bildfeld else { return }
        fuellend = an
        gtk_picture_set_content_fit(OpaquePointer(bildfeld),
                                    an ? GTK_CONTENT_FIT_COVER : GTK_CONTENT_FIT_CONTAIN)
        if let glfeld { gtk_gl_area_queue_render(alsGL(glfeld)) }
    }


    /// **Jedes Einzelbild einmal abholen, nicht öfter.** Der Taktgeber von GTK
    /// schlägt im Rhythmus des Bildschirms; kam seit dem letzten Mal nichts
    /// Neues, gibt die Brücke `false` zurück und es passiert nichts.
    /// **Bei jedem Oeffnen neu anmelden, nicht nur beim ersten.**
    ///
    /// Der Takt haengt am Bildfeld, und das Bildfeld zieht beim naechsten
    /// Titel auf die neue Spielerseite um. Hier stand
    /// `guard takt == 0 else { return }` — solange das Widget seinen
    /// Taktgeber ueber den Umzug rettet, faellt das nicht auf; tut es das
    /// nicht, bleibt es fuer immer ohne. Das ist kein Zustand, auf den sich
    /// bauen laesst, also wird der Rueckruf jedes Mal frisch angemeldet.
    ///
    /// **Die Ursache vom 20.09.2026 war das nicht** — dort verlor das Bild
    /// seinen Eltern ganz (siehe ``Spieler/spielerSeiteBauen``), und ohne
    /// Fenster nuetzt auch ein frischer Rueckruf nichts. Die Zeile bleibt
    /// als das, was sie ist: eine Annahme weniger.
    private func bildTaktStarten() {
        if takt != 0, let huelle {
            gtk_widget_remove_tick_callback(huelle, takt)
            takt = 0
        }
        guard let huelle else { return }
        takt = gtk_widget_add_tick_callback(huelle, bildTakt,
                                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    fileprivate func bildHolen() {
        takte += 1
        #if DEBUG
        // **Zum Pruefen der Wache selbst.** `SWIFTLY_BREMSE=300` haelt den
        // Hauptfaden bei jedem Bild auf und muss die Taktluecken-Meldung
        // ausloesen. Eine Wache, die nie angeschlagen hat, ist keine.
        if let bremse = ProcessInfo.processInfo.environment["SWIFTLY_BREMSE"],
           let ms = UInt32(bremse), ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
        let begonnen = ContinuousClock.now
        defer {
            let d = ContinuousClock.now - begonnen
            holdauer += Double(d.components.attoseconds) / 1e15   // ms
            if geholteBilder > 0, geholteBilder % 100 == 0, geholteBilder != zuletztGemeldet {
                zuletztGemeldet = geholteBilder
                Protokoll.schreib(String(format: "[Bild] %d Bilder, %.2f ms je Bild im Schnitt",
                                         geholteBilder, holdauer / Double(geholteBilder)))
            }
        }
        #endif
        guard let bruecke else { return }
        var stand = Bildstand()
        guard bildbruecke_holen(bruecke, &stand), stand.breite > 0, stand.hoehe > 0 else { return }
        geholteBilder += 1
        guard stand.art == Int32(BILDART_RGB24) else {
            hdrBildLaden(&stand)
            return
        }
        guard let daten = stand.ebene.0 else { return }
        let breite = stand.breite, hoehe = stand.hoehe, zeilentakt = stand.takt.0

        let laenge = Int(zeilentakt) * Int(hoehe)
        guard let bytes = g_bytes_new(daten, gsize(laenge)) else { return }
        defer { g_bytes_unref(bytes) }
        guard let textur = gdk_memory_texture_new(Int32(breite), Int32(hoehe),
                                                  GDK_MEMORY_R8G8B8,
                                                  bytes, gsize(zeilentakt)) else { return }
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        g_object_unref(UnsafeMutableRawPointer(textur))
    }

    // MARK: HDR

    /// **RGB oder YUV zu zehn Bit — vor dem Start, fuer genau diesen Titel.**
    ///
    /// VLC rechnet auf dem RGB-Weg mit swscale um und laesst die Kennlinie
    /// stehen: PQ-Werte, als sRGB gezeigt, sind das flaue, blasse Bild, das
    /// ein Nutzer neben mpv gesehen hat. Tonemapping kann libVLC 3 nur in
    /// seiner eigenen OpenGL-Ausgabe, nicht in den Rohbild-Rueckrufen, die
    /// wir benutzen. Also bildet der Shader in `hdrbild.c` HDR selbst ab.
    ///
    /// SDR bleibt auf dem RGB-Weg, unveraendert. Ohne brauchbares GL (VM,
    /// Fernsitzung) auch HDR — flau, aber mit Bild. `SWIFTLY_HDR=aus`
    /// erzwingt den alten Weg zum Vergleich.
    private func bildwegWaehlen(_ kennlinie: Farbumfang.Kennlinie?) {
        guard let bruecke, let bildfeld, let glfeld else { return }
        var weg: Int32 = 0
        if let kennlinie {
            if ProcessInfo.processInfo.environment["SWIFTLY_HDR"] == "aus" {
                Protokoll.schreib("[Player] HDR (\(kennlinie)) ohne Tonemapping: SWIFTLY_HDR=aus")
            } else if !Abspieler.glTauglich() {
                Protokoll.schreib("[Player] HDR (\(kennlinie)) ohne Tonemapping: kein GL")
            } else {
                weg = kennlinie == .hlg ? Int32(HDRBILD_HLG) : Int32(HDRBILD_PQ)
                Protokoll.schreib("[Player] HDR (\(kennlinie)): Tonemapping auf der Grafikkarte")
            }
        }
        hdrKennlinie = weg
        bildbruecke_hdr(bruecke, weg != 0)
        gtk_widget_set_visible(glfeld, weg != 0 ? 1 : 0)
        gtk_widget_set_visible(bildfeld, weg != 0 ? 0 : 1)
    }

    /// **Kann dieser Rechner den Shader ueberhaupt?** Einmal je Lauf in einem
    /// eigenen GL-Kontext geprueft — bevor VLC das Format erfaehrt. Stellte
    /// sich das erst am GL-Feld heraus, liefe der Titel schon in YUV, und
    /// das Bild bliebe schwarz statt nur flau.
    nonisolated(unsafe) private static var glGeprueft: Bool?
    private static func glTauglich() -> Bool {
        if let glGeprueft { return glGeprueft }
        var tauglich = false
        defer { glGeprueft = tauglich }
        guard let anzeige = gdk_display_get_default() else { return false }
        var fehler: UnsafeMutablePointer<GError>?
        guard let kontext = gdk_display_create_gl_context(anzeige, &fehler) else {
            glFehlerMelden("kein GL-Kontext", fehler)
            return false
        }
        defer { g_object_unref(UnsafeMutableRawPointer(kontext)) }
        guard gdk_gl_context_realize(kontext, &fehler) != 0 else {
            glFehlerMelden("GL-Kontext nicht bereit", fehler)
            return false
        }
        gdk_gl_context_make_current(kontext)
        defer { gdk_gl_context_clear_current() }
        guard let probe = hdrbild_neu() else { return false }
        defer { hdrbild_frei(probe) }
        tauglich = hdrbild_einrichten(probe, gdk_gl_context_get_use_es(kontext) != 0)
        if !tauglich {
            Protokoll.schreib("[Player] HDR-Shader: \(String(cString: hdrbild_fehler(probe)))")
        }
        hdrbild_aufgeben(probe)
        return tauglich
    }

    private static func glFehlerMelden(_ was: String, _ fehler: UnsafeMutablePointer<GError>?) {
        let grund = fehler.flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "?"
        Protokoll.schreib("[Player] HDR: \(was) (\(grund))")
        if let fehler { g_error_free(fehler) }
    }

    private func glFeldAnschliessen() {
        guard let glfeld else { return }
        let feld = alsGL(glfeld)
        gtk_gl_area_set_auto_render(feld, 0)
        gtk_gl_area_set_has_depth_buffer(feld, 0)
        let ich = Unmanaged.passUnretained(self).toOpaque()
        g_signal_connect_data(UnsafeMutableRawPointer(glfeld), "render",
                              unsafeBitCast(glZeichnenRuf, to: GCallback.self), ich, nil,
                              GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(glfeld), "resize",
                              unsafeBitCast(glGroesseRuf, to: GCallback.self), ich, nil,
                              GConnectFlags(rawValue: 0))
        g_signal_connect_data(UnsafeMutableRawPointer(glfeld), "unrealize",
                              unsafeBitCast(glAbbauRuf, to: GCallback.self), ich, nil,
                              GConnectFlags(rawValue: 0))
    }

    /// Ein HDR-Bild in die Texturen. Laeuft im Takt, wie der RGB-Weg; ohne
    /// Kontext (Feld noch nicht im Fenster) wird das Bild uebersprungen.
    private func hdrBildLaden(_ stand: inout Bildstand) {
        guard let glfeld, let hdr, hdrKennlinie != 0,
              gtk_widget_get_realized(glfeld) != 0 else { return }
        let feld = alsGL(glfeld)
        gtk_gl_area_make_current(feld)
        guard gtk_gl_area_get_error(feld) == nil,
              let kontext = gtk_gl_area_get_context(feld) else { return }
        if !hdrbild_hochladen(hdr, &stand, gdk_gl_context_get_use_es(kontext) != 0),
           !hdrFehlerGemeldet {
            hdrFehlerGemeldet = true
            Protokoll.schreib("[Player] HDR-Bild nicht geladen: \(String(cString: hdrbild_fehler(hdr)))")
        }
        gtk_gl_area_queue_render(feld)
    }

    fileprivate func glZeichnen(_ kontext: OpaquePointer?) {
        guard let hdr else { return }
        let es = kontext.map { gdk_gl_context_get_use_es($0) != 0 } ?? false
        hdrbild_zeichnen(hdr, glBreite, glHoehe, fuellend, hdrKennlinie, 0, es)
    }

    fileprivate func glFeldAbbauen() {
        guard let glfeld, let hdr, gtk_widget_get_realized(glfeld) != 0 else { return }
        gtk_gl_area_make_current(alsGL(glfeld))
        if gtk_gl_area_get_error(alsGL(glfeld)) == nil { hdrbild_aufgeben(hdr) }
    }

    // MARK: Schliessen

    func beenden(nurMedium: Bool = false) {
        if !nurMedium { wartenderAuftrag = nil }
        if let spieler {
            libvlc_media_player_stop(spieler)
            libvlc_media_player_release(spieler)
            self.spieler = nil
        }
        guard !nurMedium else { return }
        if takt != 0, let huelle {
            gtk_widget_remove_tick_callback(huelle, takt)
            takt = 0
        }
        if let bruecke { bildbruecke_frei(bruecke); self.bruecke = nil }
        if let kern { libvlc_release(kern); self.kern = nil }
        // Bildfeld und GL-Feld gehoeren der Huelle; mit ihr gehen sie.
        // Die GL-Objekte gibt vorher ``glFeldAbbauen()`` frei (Signal
        // `unrealize`), `hdr` selbst haelt keinen Kontext mehr.
        if let huelle {
            g_object_unref(huelle)
            self.huelle = nil; self.bildfeld = nil; self.glfeld = nil
        }
        if let hdr { hdrbild_frei(hdr); self.hdr = nil }
    }
}

@inline(__always) private func alsGL(_ w: Widget) -> UnsafeMutablePointer<GtkGLArea> {
    UnsafeMutableRawPointer(w).assumingMemoryBound(to: GtkGLArea.self)
}

/// `render` bringt den Kontext mit und will ein `gboolean` zurueck; wahr
/// heisst „gezeichnet, nichts weiter".
nonisolated(unsafe) private let glZeichnenRuf: @convention(c) (
    UnsafeMutablePointer<GtkGLArea>?, OpaquePointer?, gpointer?
) -> gboolean = { _, kontext, daten in
    guard let daten else { return 0 }
    Unmanaged<Abspieler>.fromOpaque(daten).takeUnretainedValue().glZeichnen(kontext)
    return 1
}

/// `resize` meldet die Groesse des Rahmenpuffers in Geraetepunkten.
nonisolated(unsafe) private let glGroesseRuf: @convention(c) (
    UnsafeMutablePointer<GtkGLArea>?, Int32, Int32, gpointer?
) -> Void = { _, breite, hoehe, daten in
    guard let daten else { return }
    let abspieler = Unmanaged<Abspieler>.fromOpaque(daten).takeUnretainedValue()
    abspieler.glBreite = breite
    abspieler.glHoehe = hoehe
}

/// `unrealize`: der Kontext geht, die GL-Objekte vorher mit ihm.
nonisolated(unsafe) private let glAbbauRuf: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, gpointer?
) -> Void = { _, daten in
    guard let daten else { return }
    Unmanaged<Abspieler>.fromOpaque(daten).takeUnretainedValue().glFeldAbbauen()
}

/// libVLCs Ereignis kommt auf VLCs eigenem Faden. **Hier nichts von libVLC
/// rufen** (das hielte VLCs Ereignisschloss) — nur die Adresse und den
/// Zustand auf GTKs Faden tragen. Der Abspieler lebt so lange wie die App.
nonisolated(unsafe) private let laufzustandRuf: @convention(c) (
    UnsafePointer<libvlc_event_t>?, UnsafeMutableRawPointer?
) -> Void = { ereignis, daten in
    guard let ereignis, let daten else { return }
    let laeuft = ereignis.pointee.type == libvlc_event_type_t(libvlc_MediaPlayerPlaying.rawValue)
    let adresse = UInt(bitPattern: daten)
    aufHauptfaden {
        guard let zeiger = UnsafeMutableRawPointer(bitPattern: adresse) else { return }
        let abspieler = Unmanaged<Abspieler>.fromOpaque(zeiger).takeUnretainedValue()
        if laeuft { abspieler.verzoegerungNachziehen() }
        abspieler.laufzustandVermerken(laeuft)
        abspieler.laufzustand?(laeuft)
    }
}

/// **VLCs Zustaende ins Protokoll.** Wie ``laufzustandRuf`` auf VLCs Faden:
/// hier nichts von libVLC rufen, nur die Nummer weitertragen.
nonisolated(unsafe) private let zustandRuf: @convention(c) (
    UnsafePointer<libvlc_event_t>?, UnsafeMutableRawPointer?
) -> Void = { ereignis, daten in
    guard let ereignis else { return }
    func ist(_ art: libvlc_event_e) -> Bool {
        ereignis.pointee.type == libvlc_event_type_t(art.rawValue)
    }
    let name: String
    if ist(libvlc_MediaPlayerOpening)               { name = "oeffnet" }
    else if ist(libvlc_MediaPlayerStopped)          { name = "angehalten" }
    else if ist(libvlc_MediaPlayerEndReached)       { name = "Ende erreicht" }
    else if ist(libvlc_MediaPlayerEncounteredError) { name = "FEHLER" }
    else if ist(libvlc_MediaPlayerBuffering)        { name = "puffert" }
    else { name = "Zustand \(ereignis.pointee.type)" }
    // **Puffern kommt im Hundertstelschritt.** Nur die Randwerte melden,
    // sonst steht das Protokoll voll mit einer Zahl, die sich um 0,4 hebt.
    if ist(libvlc_MediaPlayerBuffering) {
        let stand = ereignis.pointee.u.media_player_buffering.new_cache
        guard stand <= 0.1 || stand >= 100 else { return }
        aufHauptfaden { Protokoll.schreib("[Player] puffert \(Int(stand)) %") }
        return
    }
    let ende = ist(libvlc_MediaPlayerStopped) || ist(libvlc_MediaPlayerEndReached)
        || ist(libvlc_MediaPlayerEncounteredError)
    let fehler = ist(libvlc_MediaPlayerEncounteredError)
    let quelle = UInt(bitPattern: ereignis.pointee.p_obj)
    let adresse = UInt(bitPattern: daten)
    aufHauptfaden {
        Protokoll.schreib("[Player] \(name)")
        guard ende else { return }
        Wachhalter.freigeben()
        guard let zeiger = UnsafeMutableRawPointer(bitPattern: adresse) else { return }
        let abspieler = Unmanaged<Abspieler>.fromOpaque(zeiger).takeUnretainedValue()
        if abspieler.istLaufend(quelle) { abspieler.abgerissen?(fehler) }
    }
}

/// **VLCs eigene Meldungen** — die Zeile kommt fertig formatiert aus der
/// C-Schicht (`vlcspur_an`), weil `va_list` sich in Swift nicht als
/// `@convention(c)` schreiben laesst. Laeuft auf VLCs Faden.
///
/// Der Zugangsschluessel wird herausgeschnitten, bevor die Zeile steht: VLC
/// nennt beim Oeffnen die volle Adresse, und die traegt bei Jellyfin den
/// Schluessel. Ein Protokoll wird weitergeschickt; der Schluessel nicht.
nonisolated(unsafe) private let vlcLogRuf: @convention(c) (
    UnsafePointer<CChar>?
) -> Void = { zeile in
    guard let zeile else { return }
    var text = String(cString: zeile)
    for schluessel in ["api_key=", "X-Emby-Token=", "ApiKey=", "Token="] {
        while let von = text.range(of: schluessel) {
            let rest = text[von.upperBound...]
            let bis = rest.firstIndex(where: { "&? \n\"".contains($0) }) ?? rest.endIndex
            text.replaceSubrange(von.lowerBound..<bis, with: schluessel + "…")
            if bis == rest.endIndex { break }
        }
    }
    let fertig = text
    aufHauptfaden { Protokoll.schreib("[VLC] " + fertig) }
}

/// Der Taktgeber von GTK. Wie jeder C-Rückruf trägt er die Instanz als Zeiger.
nonisolated(unsafe) private let bildTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    Unmanaged<Abspieler>.fromOpaque(daten).takeUnretainedValue().bildHolen()
    return 1   // G_SOURCE_CONTINUE
}

/// **Wie Textuntertitel aussehen** — dieselben Werte wie auf Apple
/// (`Untertitelstil` in `Sources/Shared/VLCPlayer.swift`, dort die
/// Begruendung): Inter SemiBold, weiss, feine Kontur, leichter Schatten,
/// 78 % von VLCs Vorgabegroesse. Hier laeuft libVLC 3; `sub-margin` bleibt
/// weg, weil VLC 3 den Text ohnehin hoeher setzt als VLC 4.
///
/// **Die Schrift muss VLC selbst finden.** libVLC 3 fragt fontconfig mit
/// einer eigenen Konfiguration (`FcInitLoadConfigAndFonts`), die
/// `schriften_laden` aus `Stil.swift` nicht sieht — mitgebrachte Schriften
/// gibt es fuer VLC also nicht. Deshalb eine kleine Konfiguration, die die
/// des Systems einbindet und unseren Ordner dazulegt, per
/// `FONTCONFIG_FILE`. Wer die Variable selbst gesetzt hat, behaelt sie.
///
/// **Unter Windows** sucht VLC Schriften ueber GDI und die Registry, nicht
/// ueber fontconfig; eine mitgelieferte Datei ist dort unerreichbar. Segoe UI
/// Semibold liegt jedem Windows bei und ist der naechste Verwandte.
enum Untertitelstil {
    static func vlcOptionen() -> [String] {
        #if os(Windows)
        let schrift = "Segoe UI Semibold"
        #else
        let schrift = schriftFuerVLC() ? "Inter 18pt SemiBold" : "Sans"
        #endif
        return [
            "--freetype-font=\(schrift)",
            "--freetype-color=16777215",
            "--freetype-outline-thickness=3",
            "--freetype-outline-opacity=230",
            "--freetype-shadow-opacity=120",
            "--freetype-shadow-distance=0.04",
            "--freetype-shadow-angle=-70",
            "--sub-text-scale=78",
        ]
    }

    #if !os(Windows)
    private static func schriftFuerVLC() -> Bool {
        let dm = FileManager.default
        guard let ordner = Plattform.mitgeliefert("Schriften"),
              dm.fileExists(atPath: ordner + "/Inter-SemiBold.ttf") else { return false }
        if ProcessInfo.processInfo.environment["FONTCONFIG_FILE"] != nil { return false }
        let system = "/etc/fonts/fonts.conf"
        guard dm.fileExists(atPath: system) else { return false }
        let zwischen = URL(fileURLWithPath: String(cString: g_get_user_cache_dir()))
            .appendingPathComponent("swiftly")
        let datei = zwischen.appendingPathComponent("untertitel-fonts.conf")
        let inhalt = """
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
            <fontconfig>
              <include ignore_missing="yes">\(system)</include>
              <dir>\(ordner)</dir>
            </fontconfig>
            """
        do {
            try dm.createDirectory(at: zwischen, withIntermediateDirectories: true)
            try inhalt.write(to: datei, atomically: true, encoding: .utf8)
        } catch {
            Protokoll.schreib("[Untertitel] fontconfig-Datei nicht geschrieben: \(error)")
            return false
        }
        datei.path.withCString { _ = g_setenv("FONTCONFIG_FILE", $0, 1) }
        return true
    }
    #endif
}
