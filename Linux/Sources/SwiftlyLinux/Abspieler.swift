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
final class Abspieler {

    private var kern: OpaquePointer?
    private var spieler: OpaquePointer?
    private var bruecke: OpaquePointer?
    private var bildfeld: Widget!
    private var takt: guint = 0

    /// **Wie viele Bilder die Bruecke seit dem Oeffnen hergegeben hat.**
    /// Nur zum Messen: ohne diese Zahl laesst sich „das Bild bleibt schwarz"
    /// nicht von „das Bild kommt, wird aber nicht gezeichnet" unterscheiden.
    private(set) var geholteBilder = 0

    /// **Wie oft GTKs Taktgeber den Abspieler ueberhaupt gefragt hat.**
    /// Steht diese Zahl still, liegt es nicht an VLC, sondern daran, dass
    /// das Bildfeld keinen Takt mehr bekommt.
    private(set) var takte = 0

    /// Wie die Anzeige das Bild zeigt. Ein `GtkPicture`, sonst nichts.
    var anzeige: Widget! { bildfeld }

    /// Zum Messen: haengt das Bildfeld im Fenster, hat es einen Taktgeber,
    /// und ist der Rueckruf angemeldet?
    var taktlage: String {
        guard let bildfeld else { return "kein Bildfeld" }
        let gemappt = gtk_widget_get_mapped(bildfeld) != 0
        let uhr = gtk_widget_get_frame_clock(bildfeld) != nil
        let eltern = gtk_widget_get_parent(bildfeld) != nil
        return "mapped=\(gemappt ? 1 : 0) uhr=\(uhr ? 1 : 0) eltern=\(eltern ? 1 : 0) id=\(takt)"
    }

    /// **VLC spielt (`true`) oder hat angehalten (`false`)** — aus libVLCs
    /// Ereignissen `Playing`/`Paused`, auf GTKs Faden. Das Gegenstueck zu
    /// `VLCPlayerView.laeuftGemeldet` auf Apple: gemeldet wird, was VLC tut,
    /// nicht was ein Knopf erwartet (Audit 16.09., T2-N1).
    var laufzustand: ((Bool) -> Void)?

    init() {
        // Keine Benutzeroberfläche von VLC, keine eigenen Fenster: wir stellen
        // das Bild selbst dar. `--no-video-title-show` unterdrückt die
        // Einblendung, die VLC sonst über jedes Bild legt.
        var woerter = ["--no-video-title-show", "--quiet"]
        #if DEBUG
        // **Zum Pruefen, ob Module fehlen.** Mit `--quiet` schweigt VLC auch
        // zu „no suitable decoder module"; im Debug-Bau laesst
        // `SWIFTLY_VLC_MELDUNGEN=1` Fehler und Warnungen nach stderr.
        if ProcessInfo.processInfo.environment["SWIFTLY_VLC_MELDUNGEN"] == "1" {
            woerter = ["--no-video-title-show", "--verbose=1"]
        }
        #endif
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

        var argumente: [UnsafePointer<CChar>?] = []
        for wort in woerter { argumente.append(strdup(wort)) }
        kern = libvlc_new(Int32(argumente.count), &argumente)
        for zeiger in argumente { free(UnsafeMutableRawPointer(mutating: zeiger)) }

        bruecke = bildbruecke_neu()
        bildfeld = gtk_picture_new()
        // **Das Bildfeld überlebt seine Seite.** Es wird einmal angelegt und
        // bei jedem Öffnen in eine neue Player-Seite gehängt; wird die alte
        // Seite aus dem Stapel genommen, verliert es seinen Eltern — und damit
        // seine letzte Referenz. Beim zweiten Öffnen läge dann ein
        // freigegebener Zeiger in `anzeige`, und GObject stirbt daran mit
        // einer Adresse, die nach Zufall aussieht. Genau so ist die App
        // abgestürzt, als
        g_object_ref_sink(bildfeld)
        gtk_picture_set_content_fit(OpaquePointer(bildfeld), GTK_CONTENT_FIT_CONTAIN)
        gtk_widget_set_hexpand(bildfeld, 1)
        gtk_widget_set_vexpand(bildfeld, 1)
        // **Und noch einmal, sobald das Bildfeld wieder im Fenster haengt.**
        // ``oeffnen(_:ab:puffer:)`` meldet den Takt an, aber es ist nicht
        // gesagt, dass das Umhaengen davor liegt: wer eine Seite baut,
        // waehrend schon gespielt wird, kaeme sonst wieder ohne Takt heraus.
        // Nur wenn ueberhaupt ein Spieler laeuft — sonst liesse ein Takt
        // ohne Bild GTK jeden Frame umsonst zeichnen.
        beiSignal(bildfeld, "map") { [weak self] in
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
    func oeffnen(_ url: URL, ab: Double, puffer: Pufferstufe) {
        beenden(nurMedium: true)
        geholteBilder = 0
        takte = 0
        guard let kern, let bruecke else { return }
        guard let medium = libvlc_media_new_location(kern, url.absoluteString) else { return }
        // **Die Stelle als Option, nicht als Sprung nach dem Start.** Genau
        // so macht es die iOS-Fassung (`:start-time`), und der Grund steht
        // dort: ein Sprung nach dem Start baut den Strom ein zweites Mal auf.
        if ab > 1 { libvlc_media_add_option(medium, ":start-time=\(Int(ab))") }

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
        bildbruecke_anhaengen(bruecke, spieler)
        if let ereignisse = libvlc_media_player_event_manager(spieler) {
            let ich = Unmanaged.passUnretained(self).toOpaque()
            libvlc_event_attach(ereignisse, libvlc_event_type_t(libvlc_MediaPlayerPlaying.rawValue),
                                laufzustandRuf, ich)
            libvlc_event_attach(ereignisse, libvlc_event_type_t(libvlc_MediaPlayerPaused.rawValue),
                                laufzustandRuf, ich)
        }
        libvlc_media_player_play(spieler)
        bildTaktStarten()
    }

    func abspielen() { spieler.map { libvlc_media_player_set_pause($0, 0) } }
    func anhalten() { spieler.map { libvlc_media_player_set_pause($0, 1) } }
    func umschalten() { laeuft ? anhalten() : abspielen() }

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
        libvlc_media_player_set_time(spieler, libvlc_time_t(max(0, sekunden) * 1000))
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
        return libvlc_media_player_add_slave(spieler, libvlc_media_slave_type_subtitle,
                                             adresse.absoluteString, false) == 0
    }

    /// Tempostufen kommen aus dem Paket (B9), nicht von hier.
    var tempo: Float {
        get { spieler.map { libvlc_media_player_get_rate($0) } ?? 1 }
        set { spieler.map { libvlc_media_player_set_rate($0, newValue) } }
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
    /// keiner Plattform geben soll.
    func bildfuellend(_ an: Bool) {
        guard let bildfeld else { return }
        gtk_picture_set_content_fit(OpaquePointer(bildfeld),
                                    an ? GTK_CONTENT_FIT_COVER : GTK_CONTENT_FIT_CONTAIN)
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
        if takt != 0, let bildfeld {
            gtk_widget_remove_tick_callback(bildfeld, takt)
            takt = 0
        }
        guard let bildfeld else { return }
        takt = gtk_widget_add_tick_callback(bildfeld, bildTakt,
                                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    fileprivate func bildHolen() {
        takte += 1
        guard let bruecke else { return }
        var daten: UnsafePointer<UInt8>?
        var breite: UInt32 = 0, hoehe: UInt32 = 0, zeilentakt: UInt32 = 0
        guard bildbruecke_holen(bruecke, &daten, &breite, &hoehe, &zeilentakt),
              let daten, breite > 0, hoehe > 0 else { return }
        geholteBilder += 1

        let laenge = Int(zeilentakt) * Int(hoehe)
        guard let bytes = g_bytes_new(daten, gsize(laenge)) else { return }
        defer { g_bytes_unref(bytes) }
        guard let textur = gdk_memory_texture_new(Int32(breite), Int32(hoehe),
                                                  GDK_MEMORY_R8G8B8,
                                                  bytes, gsize(zeilentakt)) else { return }
        gtk_picture_set_paintable(OpaquePointer(bildfeld), textur)
        g_object_unref(UnsafeMutableRawPointer(textur))
    }

    // MARK: Schliessen

    func beenden(nurMedium: Bool = false) {
        if let spieler {
            libvlc_media_player_stop(spieler)
            libvlc_media_player_release(spieler)
            self.spieler = nil
        }
        guard !nurMedium else { return }
        if takt != 0, let bildfeld {
            gtk_widget_remove_tick_callback(bildfeld, takt)
            takt = 0
        }
        if let bruecke { bildbruecke_frei(bruecke); self.bruecke = nil }
        if let kern { libvlc_release(kern); self.kern = nil }
        if let bildfeld { g_object_unref(bildfeld); self.bildfeld = nil }
    }
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
        Unmanaged<Abspieler>.fromOpaque(zeiger).takeUnretainedValue().laufzustand?(laeuft)
    }
}

/// Der Taktgeber von GTK. Wie jeder C-Rückruf trägt er die Instanz als Zeiger.
nonisolated(unsafe) private let bildTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    Unmanaged<Abspieler>.fromOpaque(daten).takeUnretainedValue().bildHolen()
    return 1   // G_SOURCE_CONTINUE
}
