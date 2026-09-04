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

// MARK: - Zustand

/// **Warum eine Klasse und keine Struktur mit `@State`.**
///
/// GTK ruft aus C zurück. Ein C-Rückruf ist ein nackter Funktionszeiger; er
/// kann nichts einfangen. Der übliche Weg ist, einen Zeiger auf ein Objekt
/// mitzugeben und ihn im Rückruf wieder auszupacken — dafür braucht es eine
/// Referenz, die ihre Adresse behält.
final class Oberflaeche {
    var adressfeld: UnsafeMutablePointer<GtkWidget>?
    var knopf: UnsafeMutablePointer<GtkWidget>?
    var standzeile: UnsafeMutablePointer<GtkWidget>?
    var laeuft = false

    /// Setzt den Text der unteren Zeile. **Muss auf dem Hauptfaden laufen** —
    /// GTK ist nicht nebenläufig, und ein Aufruf aus einer Task würde die
    /// Oberfläche irgendwann still zerlegen.
    func zeige(_ text: String) {
        guard let standzeile else { return }
        gtk_label_set_text(unsafeBitCast(standzeile, to: UnsafeMutablePointer<GtkLabel>.self), text)
    }

    func beschaeftigt(_ ja: Bool) {
        laeuft = ja
        if let knopf {
            gtk_widget_set_sensitive(knopf, ja ? 0 : 1)
            gtk_button_set_label(unsafeBitCast(knopf, to: UnsafeMutablePointer<GtkButton>.self),
                                 ja ? "Verbinde …" : "Verbinden")
        }
    }

    var adresse: String {
        guard let adressfeld else { return "" }
        let puffer = gtk_editable_get_text(unsafeBitCast(adressfeld, to: UnsafeMutablePointer<GtkEditable>.self))
        return puffer.map { String(cString: $0) } ?? ""
    }
}

/// Lebt so lange wie das Programm. `nonisolated(unsafe)`, weil GTK ohnehin
/// alles auf einem Faden abarbeitet und Swift das nicht wissen kann.
nonisolated(unsafe) let oberflaeche = Oberflaeche()

// MARK: - Rückweg vom Hintergrund auf den Hauptfaden

/// Was nach einer abgeschlossenen Abfrage angezeigt werden soll.
///
/// `g_idle_add` ist GTKs Weg, aus einem anderen Faden etwas auf dem Hauptfaden
/// erledigen zu lassen. Der Rückruf bekommt einen rohen Zeiger; wir schicken
/// eine Zeichenkette hindurch und packen sie drüben wieder aus.
nonisolated(unsafe) private var wartendeMeldung: String?

private let meldungAnzeigen: @convention(c) (gpointer?) -> gboolean = { _ in
    if let text = wartendeMeldung {
        oberflaeche.zeige(text)
        wartendeMeldung = nil
    }
    oberflaeche.beschaeftigt(false)
    return 0   // G_SOURCE_REMOVE: einmal ausführen, dann abmelden
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

private let knopfGedrueckt: @convention(c) (UnsafeMutablePointer<GtkButton>?, gpointer?) -> Void = { _, _ in
    verbinden()
}

private let feldAbgeschickt: @convention(c) (UnsafeMutablePointer<GtkEntry>?, gpointer?) -> Void = { _, _ in
    verbinden()
}

// MARK: - Fenster

private let fensterAufbauen: @convention(c) (UnsafeMutablePointer<GtkApplication>?, gpointer?) -> Void = { app, _ in
    let fenster = adw_application_window_new(app)

    gtk_window_set_title(unsafeBitCast(fenster, to: UnsafeMutablePointer<GtkWindow>.self), "Swiftly")
    gtk_window_set_default_size(unsafeBitCast(fenster, to: UnsafeMutablePointer<GtkWindow>.self), 560, 380)

    // Senkrechter Stapel, mittig, mit Luft ringsum.
    let stapel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14)
    gtk_widget_set_margin_top(stapel, 40)
    gtk_widget_set_margin_bottom(stapel, 40)
    gtk_widget_set_margin_start(stapel, 40)
    gtk_widget_set_margin_end(stapel, 40)
    gtk_widget_set_valign(stapel, GTK_ALIGN_CENTER)

    let titel = gtk_label_new("Swiftly")
    gtk_widget_add_css_class(titel, "title-1")
    gtk_box_append(unsafeBitCast(stapel, to: UnsafeMutablePointer<GtkBox>.self), titel)

    let unterzeile = gtk_label_new("Wo steht dein Jellyfin?")
    gtk_widget_add_css_class(unterzeile, "dim-label")
    gtk_box_append(unsafeBitCast(stapel, to: UnsafeMutablePointer<GtkBox>.self), unterzeile)

    let feld = gtk_entry_new()
    gtk_entry_set_placeholder_text(unsafeBitCast(feld, to: UnsafeMutablePointer<GtkEntry>.self),
                                   "tv.beispiel.de")
    gtk_editable_set_text(unsafeBitCast(feld, to: UnsafeMutablePointer<GtkEditable>.self),
                          "tv.paulherter.de")
    gtk_widget_set_margin_top(feld, 8)
    gtk_box_append(unsafeBitCast(stapel, to: UnsafeMutablePointer<GtkBox>.self), feld)
    oberflaeche.adressfeld = feld

    let knopf = gtk_button_new_with_label("Verbinden")
    gtk_widget_add_css_class(knopf, "suggested-action")
    gtk_widget_add_css_class(knopf, "pill")
    gtk_box_append(unsafeBitCast(stapel, to: UnsafeMutablePointer<GtkBox>.self), knopf)
    oberflaeche.knopf = knopf

    let stand = gtk_label_new("Noch nichts versucht.")
    gtk_label_set_wrap(unsafeBitCast(stand, to: UnsafeMutablePointer<GtkLabel>.self), 1)
    gtk_label_set_justify(unsafeBitCast(stand, to: UnsafeMutablePointer<GtkLabel>.self), GTK_JUSTIFY_CENTER)
    gtk_widget_add_css_class(stand, "dim-label")
    gtk_widget_set_margin_top(stand, 10)
    gtk_box_append(unsafeBitCast(stapel, to: UnsafeMutablePointer<GtkBox>.self), stand)
    oberflaeche.standzeile = stand

    // **`g_signal_connect` ist ein Makro** und in Swift nicht sichtbar. Der
    // Weg darunter ist `g_signal_connect_data` mit null für Daten und Flags.
    g_signal_connect_data(knopf, "clicked",
                          unsafeBitCast(knopfGedrueckt, to: GCallback.self),
                          nil, nil, GConnectFlags(rawValue: 0))
    g_signal_connect_data(feld, "activate",
                          unsafeBitCast(feldAbgeschickt, to: GCallback.self),
                          nil, nil, GConnectFlags(rawValue: 0))

    // Kopfleiste, sonst hat ein AdwApplicationWindow keine Titelzeile.
    let inhalt = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    let kopf = adw_header_bar_new()
    gtk_box_append(unsafeBitCast(inhalt, to: UnsafeMutablePointer<GtkBox>.self), kopf)
    gtk_widget_set_vexpand(stapel, 1)
    gtk_box_append(unsafeBitCast(inhalt, to: UnsafeMutablePointer<GtkBox>.self), stapel)

    adw_application_window_set_content(
        unsafeBitCast(fenster, to: UnsafeMutablePointer<AdwApplicationWindow>.self), inhalt)

    gtk_window_present(unsafeBitCast(fenster, to: UnsafeMutablePointer<GtkWindow>.self))
}

// MARK: - Start

let anwendung = adw_application_new("de.paulherter.swiftly", G_APPLICATION_DEFAULT_FLAGS)
g_signal_connect_data(anwendung, "activate",
                      unsafeBitCast(fensterAufbauen, to: GCallback.self),
                      nil, nil, GConnectFlags(rawValue: 0))

let ergebnis = g_application_run(unsafeBitCast(anwendung, to: UnsafeMutablePointer<GApplication>.self), 0, nil)
g_object_unref(anwendung)
exit(ergebnis)
