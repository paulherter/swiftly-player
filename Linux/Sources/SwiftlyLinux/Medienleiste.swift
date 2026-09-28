import CGtk
import Foundation

/// **Die Medientasten und der Eintrag in der Systemleiste.**
///
/// Auf Apple leistet das `MPRemoteCommandCenter` samt „Now Playing" — der
/// Sperrbildschirm zeigt Titel und Bild, die Tasten am Gerät halten an und
/// springen weiter. Unter Linux gibt es dafür kein Rahmenwerk, sondern einen
/// **Standard**: `org.mpris.MediaPlayer2` auf dem Sitzungsbus. Jede
/// Arbeitsumgebung — KDE, GNOME, Sway mit `playerctl` — bindet ihre
/// Medientasten daran und zeigt darüber ihre Wiedergabekachel.
///
/// **Zwei Schnittstellen, nicht eine.** `MediaPlayer2` beschreibt die App
/// selbst (Name, ob sie sich schliessen und nach vorn holen lässt),
/// `MediaPlayer2.Player` die Wiedergabe. Wer nur die zweite anmeldet, taucht
/// nirgends auf: die Umgebungen suchen nach der ersten.
///
/// **Eigenschaften ändern sich nicht von selbst.** D-Bus hat kein Nachfragen
/// im Takt; wer nicht `PropertiesChanged` sendet, dessen Kachel zeigt für
/// immer „Pausiert". Deshalb ``standMelden(laeuft:titel:untertitel:dauer:)``
/// nach jeder Änderung.
///
/// `@unchecked Sendable` mit derselben Begründung wie überall hier: angefasst
/// wird sie nur auf GTKs Hauptfaden, und der ist derselbe, auf dem GDBus
/// zurückruft.
final class Medienleiste: @unchecked Sendable {

    /// Was die Leiste auslöst. Dieselben Griffe wie am Knopf.
    /// `vorholen` und `schliessen` sind MPRIS' `Raise` und `Quit`: die Leiste
    /// sagt `CanRaise`/`CanQuit`, also muessen sie auch etwas tun.
    ///
    /// `schlaeft` und `aufgewacht` sind keine Tasten, kommen aber auf demselben
    /// Weg: unter Linux von logind (`PrepareForSleep`), unter Windows als
    /// `WM_POWERBROADCAST` an die Fensterprozedur der Medientasten.
    enum Griff { case abspielen, anhalten, umschalten, beenden, weiter, zurueck,
                      vorholen, schliessen, schlaeft, aufgewacht }

    /// **`GVariantType` und `GDBusConnection` sind unvollstaendige Typen** und
    /// kommen in Swift als `OpaquePointer` an — dieselbe Falle wie bei
    /// `GtkOverlay` und `GtkAccessible`.
    ///
    /// **`G_VARIANT_TYPE` ist ein Makro** — in C ein blosser Cast von
    /// `const char*` auf `const GVariantType*`. In Swift gibt es das nicht;
    /// `g_variant_type_new` legt stattdessen eine Kopie an, die wieder frei
    /// werden muss.
    /// Legt einen Eintrag `{sv}` an. Der Wert wird in eine Variante gepackt —
    /// das verlangt der Typ `a{sv}`.
    fileprivate static func eintragen(_ bauer: UnsafeMutablePointer<GVariantBuilder>?,
                                      _ name: String, _ wert: OpaquePointer?) {
        guard let wert else { return }
        g_variant_builder_add_value(bauer, g_variant_new_dict_entry(
            g_variant_new_string(name), g_variant_new_variant(wert)))
    }

    private static func typ(_ text: String) -> OpaquePointer? {
        g_variant_type_new(text)
    }

    static func mitTypOeffentlich<E>(_ text: String,
                                     _ tun: (OpaquePointer?) -> E) -> E {
        mitTyp(text, tun)
    }

    private static func mitTyp<E>(_ text: String,
                                  _ tun: (OpaquePointer?) -> E) -> E {
        let t = typ(text)
        defer { if let t { g_variant_type_free(t) } }
        return tun(t)
    }

    private var verbindung: OpaquePointer?
    private var name: guint = 0
    private var stamm: guint = 0
    private var spieler: guint = 0
    private let melden: (Griff) -> Void

    fileprivate var laeuft = false
    fileprivate var titel = ""
    fileprivate var untertitel = ""
    fileprivate var dauer: Double = 0
    fileprivate var stelle: Double = 0
    /// **Das Bild fuer die Kachel der Umgebung.** Der Mac setzt dafuer
    /// `MPMediaItemPropertyArtwork` (`Sources/Shared/Wiedergabezentrale.swift:210`);
    /// MPRIS kennt `mpris:artUrl`, und die Zeile fehlte hier ganz — die
    /// Kachel in der Systemleiste stand ohne Plakat da.
    fileprivate var bild = ""

    init(melden: @escaping (Griff) -> Void) {
        self.melden = melden
        anmelden()
    }

    deinit {
        abmelden()
        medientasten_abmelden()
        tastenziel = nil
    }

    fileprivate func loesen(_ griff: Griff) { melden(griff) }

    /// Ob „weiter" etwas zu tun hat — siehe `CanGoNext`.
    fileprivate var hatNaechste = false
    func naechsteMelden(_ ja: Bool) { hatNaechste = ja }

    // MARK: Anmelden

    private var systembus: OpaquePointer?
    private var schlafabo: guint = 0

    /// **Ruhezustand und Aufwachen, von logind.** Kurz vor dem Schlafen
    /// sendet es `PrepareForSleep(true)`, nach dem Aufwachen
    /// `PrepareForSleep(false)` — auf dem Systembus, nicht dem der Sitzung.
    /// Ohne das lief ein Film nach dem Aufwachen stumm oder gar nicht
    /// weiter: die Tonausgabe war neu verhandelt, der Strom zum Server
    /// abgerissen, und die App wusste von beidem nichts.
    private func schlafAnmelden() {
        #if !os(Windows)
        var fehler: UnsafeMutablePointer<GError>?
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &fehler) else {
            if let fehler { g_error_free(fehler) }
            return
        }
        systembus = bus
        schlafabo = g_dbus_connection_signal_subscribe(
            bus, "org.freedesktop.login1", "org.freedesktop.login1.Manager",
            "PrepareForSleep", "/org/freedesktop/login1", nil,
            GDBusSignalFlags(rawValue: 0), schlafRuf,
            Unmanaged.passUnretained(self).toOpaque(), nil)
        #endif
    }

    private func anmelden() {
        schlafAnmelden()
        var fehler: UnsafeMutablePointer<GError>?
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &fehler) else {
            // **Still.** Ohne Sitzungsbus — in einer abgeschotteten Umgebung,
            // in einem Bauknecht — gibt es keine Medientasten, und das ist
            // kein Grund, die App anzuhalten.
            if let fehler { g_error_free(fehler) }
            return
        }
        verbindung = bus

        guard let knoten = g_dbus_node_info_new_for_xml(Medienleiste.beschreibung, &fehler) else {
            if let fehler { g_error_free(fehler) }
            return
        }
        defer { g_dbus_node_info_unref(knoten) }

        var tisch = GDBusInterfaceVTable()
        tisch.method_call = mprisAufruf
        tisch.get_property = mprisLesen
        tisch.set_property = nil

        let ich = Unmanaged.passUnretained(self).toOpaque()
        stamm = g_dbus_connection_register_object(
            bus, "/org/mpris/MediaPlayer2",
            g_dbus_node_info_lookup_interface(knoten, "org.mpris.MediaPlayer2"),
            &tisch, ich, nil, nil)
        spieler = g_dbus_connection_register_object(
            bus, "/org/mpris/MediaPlayer2",
            g_dbus_node_info_lookup_interface(knoten, "org.mpris.MediaPlayer2.Player"),
            &tisch, ich, nil, nil)

        // **Der Name muss die Kennung tragen.** Zwei Fassungen derselben App
        // dürfen nebeneinander laufen; der Zusatz hinter dem Punkt trennt sie.
        name = g_bus_own_name_on_connection(
            bus, "org.mpris.MediaPlayer2.swiftly",
            GBusNameOwnerFlags(rawValue: 1), nil, nil, nil, nil)   // REPLACE
    }

    private func abmelden() {
        if let systembus, schlafabo != 0 {
            g_dbus_connection_signal_unsubscribe(systembus, schlafabo)
            schlafabo = 0
        }
        guard let bus = verbindung else { return }
        if stamm != 0 { g_dbus_connection_unregister_object(bus, stamm) }
        if spieler != 0 { g_dbus_connection_unregister_object(bus, spieler) }
        if name != 0 { g_bus_unown_name(name) }
        verbindung = nil
    }

    // MARK: Melden

    /// Sagt der Umgebung, was gerade läuft. **Nach jeder Änderung**, sonst
    /// bleibt ihre Kachel auf dem alten Stand stehen.
    func standMelden(laeuft: Bool, titel: String, untertitel: String,
                     dauer: Double, stelle: Double, bild: String = "") {
        self.laeuft = laeuft
        self.titel = titel
        self.untertitel = untertitel
        self.dauer = dauer
        self.stelle = stelle
        self.bild = bild
        guard let bus = verbindung else { return }

        // **Auch hier ist die bequeme Form variadisch und damit gesperrt.**
        // `g_variant_builder_add(b, "{sv}", …)` und `g_variant_new("(…)", …)`
        // gibt es in Swift nicht; die Werte werden einzeln gebaut und
        // zusammengesetzt. Der Wert in `a{sv}` ist eine **Variante**, nicht
        // der nackte Wert — ohne `g_variant_new_variant` passt der Typ nicht.
        let bauer = Medienleiste.mitTyp("a{sv}") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(bauer) }
        Medienleiste.eintragen(bauer, "PlaybackStatus",
                               g_variant_new_string(status))
        Medienleiste.eintragen(bauer, "Metadata", metadaten())

        let leer = Medienleiste.mitTyp("as") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(leer) }

        var kinder: [OpaquePointer?] = [
            g_variant_new_string("org.mpris.MediaPlayer2.Player"),
            g_variant_builder_end(bauer),
            g_variant_builder_end(leer)
        ]
        let inhalt = kinder.withUnsafeMutableBufferPointer {
            g_variant_new_tuple($0.baseAddress, 3)
        }
        g_dbus_connection_emit_signal(bus, nil, "/org/mpris/MediaPlayer2",
                                      "org.freedesktop.DBus.Properties",
                                      "PropertiesChanged", inhalt, nil)
    }

    /// Die Angaben, die die Kachel anzeigt.
    /// **Ohne Titel ist nichts pausiert, sondern nichts da.** Hier stand
    /// nach dem Schliessen des Players „Paused" mit leerem Titel — die
    /// Medienkachel der Arbeitsumgebung blieb dann mit einer leeren Zeile
    /// stehen, bis die App ging. MPRIS kennt dafuer `Stopped` und die
    /// Spur `NoTrack`.
    fileprivate var status: String {
        titel.isEmpty ? "Stopped" : (laeuft ? "Playing" : "Paused")
    }

    fileprivate func metadaten() -> OpaquePointer? {
        let bauer = Medienleiste.mitTyp("a{sv}") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(bauer) }
        guard !titel.isEmpty else {
            Medienleiste.eintragen(bauer, "mpris:trackid",
                                   g_variant_new_object_path("/org/mpris/MediaPlayer2/TrackList/NoTrack"))
            return g_variant_builder_end(bauer)
        }
        // Eine Kennung ist Pflicht; ohne sie halten manche Umgebungen den
        // Eintrag für unfertig und zeigen ihn gar nicht.
        Medienleiste.eintragen(bauer, "mpris:trackid",
                               g_variant_new_object_path("/de/paulherter/swiftly/titel"))
        Medienleiste.eintragen(bauer, "mpris:length",
                               g_variant_new_int64(gint64(dauer * 1_000_000)))
        Medienleiste.eintragen(bauer, "xesam:title", g_variant_new_string(titel))
        if !untertitel.isEmpty {
            let liste = Medienleiste.mitTyp("as") { g_variant_builder_new($0) }
            defer { g_variant_builder_unref(liste) }
            g_variant_builder_add_value(liste, g_variant_new_string(untertitel))
            Medienleiste.eintragen(bauer, "xesam:artist", g_variant_builder_end(liste))
        }
        if !bild.isEmpty {
            Medienleiste.eintragen(bauer, "mpris:artUrl", g_variant_new_string(bild))
        }
        return g_variant_builder_end(bauer)
    }

    /// Was auf dem Bus steht. Nur, was die Umgebungen wirklich lesen.
    private static let beschreibung = """
    <node>
      <interface name="org.mpris.MediaPlayer2">
        <method name="Raise"/>
        <method name="Quit"/>
        <property name="CanQuit" type="b" access="read"/>
        <property name="CanRaise" type="b" access="read"/>
        <property name="HasTrackList" type="b" access="read"/>
        <property name="Identity" type="s" access="read"/>
        <property name="DesktopEntry" type="s" access="read"/>
        <property name="SupportedUriSchemes" type="as" access="read"/>
        <property name="SupportedMimeTypes" type="as" access="read"/>
      </interface>
      <interface name="org.mpris.MediaPlayer2.Player">
        <method name="Play"/>
        <method name="Pause"/>
        <method name="PlayPause"/>
        <method name="Stop"/>
        <method name="Next"/>
        <method name="Previous"/>
        <property name="PlaybackStatus" type="s" access="read"/>
        <property name="Metadata" type="a{sv}" access="read"/>
        <property name="Position" type="x" access="read"/>
        <property name="CanPlay" type="b" access="read"/>
        <property name="CanPause" type="b" access="read"/>
        <property name="CanSeek" type="b" access="read"/>
        <property name="CanControl" type="b" access="read"/>
        <property name="CanGoNext" type="b" access="read"/>
        <property name="CanGoPrevious" type="b" access="read"/>
      </interface>
    </node>
    """
}

// MARK: - Die beiden Rückrufe

nonisolated(unsafe) private let mprisAufruf: @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, OpaquePointer?,
    OpaquePointer?, gpointer?
) -> Void = { _, _, _, _, name, _, aufruf, daten in
    guard let daten, let name else { return }
    let leiste = Unmanaged<Medienleiste>.fromOpaque(daten).takeUnretainedValue()
    switch String(cString: name) {
    case "Play":      leiste.loesen(.abspielen)
    case "Pause":     leiste.loesen(.anhalten)
    case "PlayPause": leiste.loesen(.umschalten)
    case "Stop":      leiste.loesen(.beenden)
    case "Next":      leiste.loesen(.weiter)
    case "Previous":  leiste.loesen(.zurueck)
    // „Raise" holt das Fenster nach vorn, „Quit" schliesst es. Beides wurde
    // quittiert, ohne etwas zu tun — waehrend `CanRaise`/`CanQuit` wahr
    // meldeten: ein Klick auf die Kachel holte die App nicht hervor.
    case "Raise":     leiste.loesen(.vorholen)
    case "Quit":      leiste.loesen(.schliessen)
    default: break
    }
    if let aufruf { g_dbus_method_invocation_return_value(aufruf, nil) }
}

/// logind: `PrepareForSleep(b)` — wahr vor dem Schlafen, falsch danach.
nonisolated(unsafe) private let schlafRuf: @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, OpaquePointer?, gpointer?
) -> Void = { _, _, _, _, _, werte, daten in
    guard let daten, let werte, let wert = g_variant_get_child_value(werte, 0) else { return }
    let schlaeft = g_variant_get_boolean(wert) != 0
    g_variant_unref(wert)
    Unmanaged<Medienleiste>.fromOpaque(daten).takeUnretainedValue()
        .loesen(schlaeft ? .schlaeft : .aufgewacht)
}

nonisolated(unsafe) private let mprisLesen: @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?, gpointer?
) -> OpaquePointer? = { _, _, _, _, name, _, daten in
    guard let daten, let name else { return nil }
    let leiste = Unmanaged<Medienleiste>.fromOpaque(daten).takeUnretainedValue()
    switch String(cString: name) {
    case "Identity":            return g_variant_new_string("Swiftly")
    case "DesktopEntry":        return g_variant_new_string("de.paulherter.swiftly")
    case "CanQuit", "CanRaise": return g_variant_new_boolean(1)
    case "HasTrackList":        return g_variant_new_boolean(0)
    case "SupportedUriSchemes", "SupportedMimeTypes":
        let leer = Medienleiste.mitTypOeffentlich("as") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(leer) }
        return g_variant_builder_end(leer)
    case "PlaybackStatus":
        return g_variant_new_string(leiste.status)
    case "Metadata":            return leiste.metadaten()
    case "Position":            return g_variant_new_int64(gint64(leiste.stelle * 1_000_000))
    case "CanPlay", "CanPause", "CanControl":
        return g_variant_new_boolean(1)
    // **Was nicht geht, wird auch nicht behauptet.** `CanSeek` stand auf
    // wahr, und `Seek`/`SetPosition` gibt es in der Beschreibung gar nicht —
    // ein Aufruf aus der Umgebung lief ins Leere und wurde trotzdem als
    // Erfolg quittiert. Der Mac hat dort echte Befehle
    // (`Sources/Shared/Wiedergabezentrale.swift:412-419`); bis es die hier
    // auch gibt, sagt die Kachel die Wahrheit.
    case "CanSeek":             return g_variant_new_boolean(0)
    // **Und „weiter" nur, wenn es eine naechste Folge gibt.** Der Mac setzt
    // `nextTrackCommand.isEnabled = griffe?.naechste != nil`; hier stand fest
    // wahr, und der Knopf in der Systemleiste war bei einem Film aktiv.
    case "CanGoNext":           return g_variant_new_boolean(leiste.hatNaechste ? 1 : 0)
    case "CanGoPrevious":       return g_variant_new_boolean(0)
    default:                    return nil
    }
}

// MARK: - Medientasten der Tastatur

import CMedientasten

/// **Wohin die Tastendrücke gehen.** Der Rückruf kommt aus C und kann nichts
/// einfangen; die Verbindung zur Leiste steht deshalb hier.
nonisolated(unsafe) private var tastenziel: ((Medienleiste.Griff) -> Void)?

private let tastenrueckruf: @convention(c) (Int32) -> Void = { kennung in
    let griff: Medienleiste.Griff
    switch kennung {
    case 1:  griff = .beenden
    case 2:  griff = .weiter
    case 3:  griff = .zurueck
    case 4:  griff = .schlaeft
    case 5:  griff = .aufgewacht
    default: griff = .umschalten
    }
    tastenziel?(griff)
}

extension Medienleiste {

    /// Hängt die Medientasten der Tastatur an das Fenster.
    ///
    /// **Auf Linux tut das nichts** — dort meldet ``anmelden()`` die App auf
    /// dem Sitzungsbus an, und die Arbeitsumgebung schickt die Tasten von
    /// selbst. Unter Windows gibt es keinen solchen Dienst: die Tasten kommen
    /// als `WM_APPCOMMAND` an das Vordergrundfenster, und für den Hintergrund
    /// muss man sie eigens anmelden. Beides braucht eine eigene
    /// Fensterprozedur, und die steht in ``CMedientasten``.
    ///
    /// Die Aufrufstelle bleibt dadurch frei von Verzweigungen: auf beiden
    /// Plattformen dieselbe Zeile, nur mit verschiedener Wirkung.
    func anFenster(_ fenster: Widget) {
        // `GtkNative` ist eine Schnittstelle, kein Typ — sie kommt in Swift
        // als `OpaquePointer` an, dieselbe Falle wie bei `GtkOverlay`.
        guard let flaeche = gtk_native_get_surface(OpaquePointer(fenster)) else { return }
        tastenziel = { [weak self] griff in self?.loesen(griff) }
        medientasten_anmelden(UnsafeMutableRawPointer(flaeche), tastenrueckruf)
    }
}
