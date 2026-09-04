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

    /// Wie die Anzeige das Bild zeigt. Ein `GtkPicture`, sonst nichts.
    var anzeige: Widget! { bildfeld }

    init() {
        // Keine Benutzeroberfläche von VLC, keine eigenen Fenster: wir stellen
        // das Bild selbst dar. `--no-video-title-show` unterdrückt die
        // Einblendung, die VLC sonst über jedes Bild legt.
        var argumente: [UnsafePointer<CChar>?] = []
        for wort in ["--no-xlib", "--no-video-title-show", "--quiet"] {
            argumente.append(strdup(wort))
        }
        kern = libvlc_new(Int32(argumente.count), &argumente)
        for zeiger in argumente { free(UnsafeMutableRawPointer(mutating: zeiger)) }

        bruecke = bildbruecke_neu()
        bildfeld = gtk_picture_new()
        gtk_picture_set_content_fit(OpaquePointer(bildfeld), GTK_CONTENT_FIT_CONTAIN)
        gtk_widget_set_hexpand(bildfeld, 1)
        gtk_widget_set_vexpand(bildfeld, 1)
        VLCFassung.text = String(cString: libvlc_get_version())
    }

    deinit { beenden() }

    // MARK: Steuern

    func oeffnen(_ url: URL, ab: Double) {
        beenden(nurMedium: true)
        guard let kern, let bruecke else { return }
        guard let medium = libvlc_media_new_location(kern, url.absoluteString) else { return }
        // **Die Stelle als Option, nicht als Sprung nach dem Start.** Genau
        // so macht es die iOS-Fassung (`:start-time`), und der Grund steht
        // dort: ein Sprung nach dem Start baut den Strom ein zweites Mal auf.
        if ab > 1 { libvlc_media_add_option(medium, ":start-time=\(Int(ab))") }
        spieler = libvlc_media_player_new_from_media(medium)
        libvlc_media_release(medium)
        guard let spieler else { return }
        bildbruecke_anhaengen(bruecke, spieler)
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

    // MARK: Bild

    /// **Jedes Einzelbild einmal abholen, nicht öfter.** Der Taktgeber von GTK
    /// schlägt im Rhythmus des Bildschirms; kam seit dem letzten Mal nichts
    /// Neues, gibt die Brücke `false` zurück und es passiert nichts.
    private func bildTaktStarten() {
        guard takt == 0 else { return }
        takt = gtk_widget_add_tick_callback(bildfeld, bildTakt,
                                            Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    fileprivate func bildHolen() {
        guard let bruecke else { return }
        var daten: UnsafePointer<UInt8>?
        var breite: UInt32 = 0, hoehe: UInt32 = 0, zeilentakt: UInt32 = 0
        guard bildbruecke_holen(bruecke, &daten, &breite, &hoehe, &zeilentakt),
              let daten, breite > 0, hoehe > 0 else { return }

        let laenge = Int(zeilentakt) * Int(hoehe)
        guard let bytes = g_bytes_new(daten, gsize(laenge)) else { return }
        defer { g_bytes_unref(bytes) }
        guard let textur = gdk_memory_texture_new(Int32(breite), Int32(hoehe),
                                                  GDK_MEMORY_R8G8B8,
                                                  bytes, gsize(zeilentakt)) else { return }
        gtk_picture_set_paintable(OpaquePointer(bildfeld), OpaquePointer(textur))
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
