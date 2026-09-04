import CGtk
import Foundation
import JellyfinKit

/// **Der erste sichtbare Beweis, dass Swiftly auf Linux stehen kann.**
///
/// Ein Fenster, eine Adresse, ein Knopf — und dahinter derselbe
/// `JellyfinClient`, den iPhone, iPad, Apple TV und Mac benutzen. Kein
/// nachgebauter Client, keine zweite Wahrheit: `publicSystemInfo()` ist
/// dieselbe Zeile Code wie überall sonst, und `AppModelURLNormalizer` legt
/// hier wie dort fest, ob vor eine Adresse `http` oder `https` gehört.
///
/// **Warum überall `OpaquePointer` steht.** GTK verbirgt den Aufbau seiner
/// Typen; die Kopfdateien deklarieren sie nur vorwärts. Swift sieht deshalb
/// keine Strukturen, sondern undurchsichtige Zeiger — und genau die sind der
/// richtige Weg, mit GTK aus Swift zu sprechen. Das spart die ganze
/// Umdeuterei mit `unsafeBitCast`, die ein erster Anlauf noch hatte.

// MARK: - Zustand

/// **Warum eine Klasse und keine Struktur.**
///
/// GTK ruft aus C zurück, und ein C-Rückruf ist ein nackter Funktionszeiger:
/// er kann nichts einfangen. Was er sehen soll, muss an einer festen Adresse
/// liegen.
final class Oberflaeche {
    var adressfeld: OpaquePointer?
    var knopf: OpaquePointer?
    var standzeile: OpaquePointer?
    var laeuft = false

    /// **Muss auf dem Hauptfaden laufen.** GTK ist nicht nebenläufig; ein
    /// Aufruf aus einer Task würde die Oberfläche irgendwann still zerlegen.
    func zeige(_ text: String) {
        guard let standzeile else { return }
        gtk_label_set_text(standzeile, text)
    }

    func beschaeftigt(_ ja: Bool) {
        laeuft = ja
        guard let knopf else { return }
        gtk_widget_set_sensitive(knopf, ja ? 0 : 1)
        gtk_button_set_label(knopf, ja ? "Verbinde …" : "Verbinden")
    }

    var adresse: String {
        guard let adressfeld else { return "" }
        return gtk_editable_get_text(adressfeld).map { String(cString: $0) } ?? ""
    }
}

nonisolated(unsafe) let oberflaeche = Oberflaeche()

// MARK: - Rückweg vom Hintergrund auf den Hauptfaden

/// `g_idle_add` ist GTKs Weg, aus einem anderen Faden etwas auf dem Hauptfaden
/// erledigen zu lassen. Die Meldung wartet so lange hier.
nonisolated(unsafe) private var wartendeMeldung: String?

nonisolated(unsafe) private let meldungAnzeigen: @convention(c) (gpointer?) -> gboolean = { _ in
    if let text = wartendeMeldung {
        oberflaeche.zeige(text)
        wartendeMeldung = nil
    }
    oberflaeche.beschaeftigt(false)
    return 0   // einmal ausführen, dann abmelden
}

private func melden(_ text: String) {
    wartendeMeldung = text
    g_idle_add(meldungAnzeigen, nil)
}

// MARK: - Verbinden

private func verbinden() {
    guard !oberflaeche.laeuft else { return }

    let eingabe = oberflaeche.adresse.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !eingabe.isEmpty else {
        oberflaeche.zeige("Trag erst eine Adresse ein.")
        return
    }
    // Dieselbe Regel wie auf allen Apple-Plattformen: ohne Schema bekommt eine
    // Adresse `https` vorgesetzt, es sei denn, sie sieht nach Heimnetz aus.
    guard let url = AppModelURLNormalizer.normalize(eingabe) else {
        oberflaeche.zeige("Mit dieser Adresse kann ich nichts anfangen.")
        return
    }

    oberflaeche.beschaeftigt(true)
    oberflaeche.zeige("Frage \(url.absoluteString) …")

    Task.detached {
        let client = JellyfinClient(baseURL: url,
                                    deviceID: "swiftly-linux-probe",
                                    deviceName: "Swiftly auf Linux")
        do {
            let info = try await client.publicSystemInfo()
            let name = info.serverName ?? "ohne Namen"
            let fassung = info.version ?? "unbekannte Fassung"
            melden("Verbunden mit „\(name)“, Jellyfin \(fassung).")
        } catch {
            melden("Ging nicht: \(error.localizedDescription)")
        }
    }
}

nonisolated(unsafe) private let knopfGedrueckt: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    verbinden()
}

// MARK: - Fenster

nonisolated(unsafe) private let fensterAufbauen: @convention(c) (OpaquePointer?, gpointer?) -> Void = { app, _ in
    let fenster = adw_application_window_new(app)
    gtk_window_set_title(fenster, "Swiftly")
    gtk_window_set_default_size(fenster, 560, 400)

    // Senkrechter Stapel, mittig, mit Luft ringsum.
    let stapel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14)
    gtk_widget_set_margin_top(stapel, 40)
    gtk_widget_set_margin_bottom(stapel, 40)
    gtk_widget_set_margin_start(stapel, 40)
    gtk_widget_set_margin_end(stapel, 40)
    gtk_widget_set_valign(stapel, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(stapel, 1)

    let titel = gtk_label_new("Swiftly")
    gtk_widget_add_css_class(titel, "title-1")
    gtk_box_append(stapel, titel)

    let unterzeile = gtk_label_new("Wo steht dein Jellyfin?")
    gtk_widget_add_css_class(unterzeile, "dim-label")
    gtk_box_append(stapel, unterzeile)

    let feld = gtk_entry_new()
    gtk_entry_set_placeholder_text(feld, "tv.beispiel.de")
    gtk_editable_set_text(feld, "tv.paulherter.de")
    gtk_widget_set_margin_top(feld, 8)
    gtk_box_append(stapel, feld)
    oberflaeche.adressfeld = feld

    let knopf = gtk_button_new_with_label("Verbinden")
    gtk_widget_add_css_class(knopf, "suggested-action")
    gtk_widget_add_css_class(knopf, "pill")
    gtk_box_append(stapel, knopf)
    oberflaeche.knopf = knopf

    let stand = gtk_label_new("Noch nichts versucht.")
    gtk_label_set_wrap(stand, 1)
    gtk_label_set_justify(stand, GTK_JUSTIFY_CENTER)
    gtk_widget_add_css_class(stand, "dim-label")
    gtk_widget_set_margin_top(stand, 10)
    gtk_box_append(stapel, stand)
    oberflaeche.standzeile = stand

    // **`g_signal_connect` ist ein Makro** und in Swift unsichtbar. Darunter
    // liegt `g_signal_connect_data` mit null für Daten und Flags.
    g_signal_connect_data(UnsafeMutableRawPointer(knopf), "clicked",
                          unsafeBitCast(knopfGedrueckt, to: GCallback.self),
                          nil, nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(UnsafeMutableRawPointer(feld), "activate",
                          unsafeBitCast(knopfGedrueckt, to: GCallback.self),
                          nil, nil, GConnectFlags(rawValue: 0))

    // Ein AdwApplicationWindow hat keine eigene Titelzeile; die kommt als
    // erstes Kind des Inhalts dazu.
    let inhalt = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_box_append(inhalt, adw_header_bar_new())
    gtk_box_append(inhalt, stapel)
    adw_application_window_set_content(fenster, inhalt)

    gtk_window_present(fenster)
}

// MARK: - Start

let anwendung = adw_application_new("de.paulherter.swiftly", GApplicationFlags(rawValue: 0))
g_signal_connect_data(UnsafeMutableRawPointer(anwendung), "activate",
                      unsafeBitCast(fensterAufbauen, to: GCallback.self),
                      nil, nil, GConnectFlags(rawValue: 0))

let ergebnis = g_application_run(UnsafeMutableRawPointer(anwendung).assumingMemoryBound(to: GApplication.self), 0, nil)
exit(ergebnis)
