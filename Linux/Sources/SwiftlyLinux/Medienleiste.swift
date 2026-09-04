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
    enum Griff { case abspielen, anhalten, umschalten, beenden, weiter, zurueck }

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
    fileprivate static func eintragen(_ bauer: OpaquePointer?, _ name: String,
                                      _ wert: OpaquePointer?) {
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

    init(melden: @escaping (Griff) -> Void) {
        self.melden = melden
        anmelden()
    }

    deinit { abmelden() }

    fileprivate func loesen(_ griff: Griff) { melden(griff) }

    // MARK: Anmelden

    private func anmelden() {
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
            G_BUS_NAME_OWNER_FLAGS_REPLACE, nil, nil, nil, nil)
    }

    private func abmelden() {
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
                     dauer: Double, stelle: Double) {
        self.laeuft = laeuft
        self.titel = titel
        self.untertitel = untertitel
        self.dauer = dauer
        self.stelle = stelle
        guard let bus = verbindung else { return }

        // **Auch hier ist die bequeme Form variadisch und damit gesperrt.**
        // `g_variant_builder_add(b, "{sv}", …)` und `g_variant_new("(…)", …)`
        // gibt es in Swift nicht; die Werte werden einzeln gebaut und
        // zusammengesetzt. Der Wert in `a{sv}` ist eine **Variante**, nicht
        // der nackte Wert — ohne `g_variant_new_variant` passt der Typ nicht.
        let bauer = Medienleiste.mitTyp("a{sv}") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(bauer) }
        Medienleiste.eintragen(bauer, "PlaybackStatus",
                               g_variant_new_string(laeuft ? "Playing" : "Paused"))
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
    fileprivate func metadaten() -> OpaquePointer? {
        let bauer = Medienleiste.mitTyp("a{sv}") { g_variant_builder_new($0) }
        defer { g_variant_builder_unref(bauer) }
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
    // „Raise" holt das Fenster nach vorn; „Quit" beendet die App. Beides
    // beantworten wir, ohne etwas zu tun — sonst meldet die Umgebung einen
    // Fehler, und manche blenden den Eintrag daraufhin aus.
    default: break
    }
    if let aufruf { g_dbus_method_invocation_return_value(aufruf, nil) }
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
        return g_variant_new_string(leiste.laeuft ? "Playing" : "Paused")
    case "Metadata":            return leiste.metadaten()
    case "Position":            return g_variant_new_int64(gint64(leiste.stelle * 1_000_000))
    case "CanPlay", "CanPause", "CanSeek", "CanControl", "CanGoNext":
        return g_variant_new_boolean(1)
    case "CanGoPrevious":       return g_variant_new_boolean(0)
    default:                    return nil
    }
}
