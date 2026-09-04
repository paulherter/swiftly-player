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

// MARK: - Umwandlung zwischen GTKs Typen

/// **GTK kennt keine Vererbung, es hat Zeigerkunst.**
///
/// Jede Funktion nimmt den Typ, für den sie gedacht ist — `gtk_box_append`
/// will eine Box, `gtk_button_set_label` einen Knopf —, aber jedes `*_new()`
/// gibt ein `GtkWidget*` zurück. In C erledigen Makros das Umdeuten; in Swift
/// gibt es die nicht, also stehen die Umwandlungen hier einmal beisammen.
///
/// Welche Typen Swift überhaupt benennen kann, ist nicht zu erraten: `GtkBox`,
/// `GtkButton` und `GtkEntry` ja, `GtkLabel` und `GtkEditable` nein — die
/// kommen als undurchsichtige Zeiger herein. Herausgefunden am 04.09.2026,
/// indem der Übersetzer selbst nach den erwarteten Typen gefragt wurde,
/// nachdem drei Anläufe daran gescheitert waren.
typealias Widget = UnsafeMutablePointer<GtkWidget>

@inline(__always) private func alsBox(_ w: Widget!) -> UnsafeMutablePointer<GtkBox>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkBox>.self)
}
@inline(__always) private func alsKnopf(_ w: Widget!) -> UnsafeMutablePointer<GtkButton>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkButton>.self)
}
@inline(__always) private func alsFeld(_ w: Widget!) -> UnsafeMutablePointer<GtkEntry>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkEntry>.self)
}
@inline(__always) private func alsFenster(_ w: Widget!) -> UnsafeMutablePointer<GtkWindow>! {
    unsafeBitCast(w, to: UnsafeMutablePointer<GtkWindow>.self)
}

// MARK: - Zustand

/// **Warum eine Klasse und keine Struktur.**
///
/// GTK ruft aus C zurück, und ein C-Rückruf ist ein nackter Funktionszeiger:
/// er kann nichts einfangen. Was er sehen soll, muss an einer festen Adresse
/// liegen.
final class Oberflaeche {
    fileprivate var adressfeld: Widget?
    fileprivate var knopf: Widget?
    fileprivate var standzeile: Widget?
    var laeuft = false

    /// **Muss auf dem Hauptfaden laufen.** GTK ist nicht nebenläufig; ein
    /// Aufruf aus einer Task würde die Oberfläche irgendwann still zerlegen.
    func zeige(_ text: String) {
        guard let standzeile else { return }
        gtk_label_set_text(OpaquePointer(standzeile), text)
    }

    func beschaeftigt(_ ja: Bool) {
        laeuft = ja
        guard let knopf else { return }
        gtk_widget_set_sensitive(knopf, ja ? 0 : 1)
        gtk_button_set_label(alsKnopf(knopf), ja ? "Verbinde …" : "Verbinden")
    }

    var adresse: String {
        guard let adressfeld else { return "" }
        return gtk_editable_get_text(OpaquePointer(adressfeld)).map { String(cString: $0) } ?? ""
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

nonisolated(unsafe) private let ausgeloest: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { _, _ in
    verbinden()
}

/// `g_signal_connect` ist ein Makro und in Swift unsichtbar. Darunter liegt
/// `g_signal_connect_data`; die Hülle hier spart die immer gleichen Nullen.
private func beiSignal(_ ziel: UnsafeMutableRawPointer!, _ name: String,
                       _ rueckruf: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void) {
    g_signal_connect_data(ziel, name, unsafeBitCast(rueckruf, to: GCallback.self),
                          nil, nil, GConnectFlags(rawValue: 0))
}

// MARK: - Fenster

nonisolated(unsafe) private let fensterAufbauen: @convention(c) (UnsafeMutableRawPointer?, gpointer?) -> Void = { app, _ in
    let anwendung = app!.assumingMemoryBound(to: GtkApplication.self)
    let fenster: Widget! = adw_application_window_new(anwendung)
    gtk_window_set_title(alsFenster(fenster), "Swiftly")
    gtk_window_set_default_size(alsFenster(fenster), 560, 400)

    // Senkrechter Stapel, mittig, mit Luft ringsum.
    let stapel: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14)
    gtk_widget_set_margin_top(stapel, 40)
    gtk_widget_set_margin_bottom(stapel, 40)
    gtk_widget_set_margin_start(stapel, 40)
    gtk_widget_set_margin_end(stapel, 40)
    gtk_widget_set_valign(stapel, GTK_ALIGN_CENTER)
    gtk_widget_set_vexpand(stapel, 1)

    let titel: Widget! = gtk_label_new("Swiftly")
    gtk_widget_add_css_class(titel, "title-1")
    gtk_box_append(alsBox(stapel), titel)

    let unterzeile: Widget! = gtk_label_new("Wo steht dein Jellyfin?")
    gtk_widget_add_css_class(unterzeile, "dim-label")
    gtk_box_append(alsBox(stapel), unterzeile)

    let feld: Widget! = gtk_entry_new()
    gtk_entry_set_placeholder_text(alsFeld(feld), "tv.beispiel.de")
    gtk_editable_set_text(OpaquePointer(feld), "tv.paulherter.de")
    gtk_widget_set_margin_top(feld, 8)
    gtk_box_append(alsBox(stapel), feld)
    oberflaeche.adressfeld = feld

    let knopf: Widget! = gtk_button_new_with_label("Verbinden")
    gtk_widget_add_css_class(knopf, "suggested-action")
    gtk_widget_add_css_class(knopf, "pill")
    gtk_box_append(alsBox(stapel), knopf)
    oberflaeche.knopf = knopf

    let stand: Widget! = gtk_label_new("Noch nichts versucht.")
    gtk_label_set_wrap(OpaquePointer(stand), 1)
    gtk_label_set_justify(OpaquePointer(stand), GTK_JUSTIFY_CENTER)
    gtk_widget_add_css_class(stand, "dim-label")
    gtk_widget_set_margin_top(stand, 10)
    gtk_box_append(alsBox(stapel), stand)
    oberflaeche.standzeile = stand

    beiSignal(UnsafeMutableRawPointer(knopf), "clicked", ausgeloest)
    beiSignal(UnsafeMutableRawPointer(feld), "activate", ausgeloest)

    // Ein AdwApplicationWindow hat keine eigene Titelzeile; die kommt als
    // erstes Kind des Inhalts dazu.
    let inhalt: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    gtk_box_append(alsBox(inhalt), adw_header_bar_new())
    gtk_box_append(alsBox(inhalt), stapel)
    adw_application_window_set_content(
        unsafeBitCast(fenster, to: UnsafeMutablePointer<AdwApplicationWindow>.self), inhalt)

    gtk_window_present(alsFenster(fenster))
}

// MARK: - Start

let anwendung = adw_application_new("de.paulherter.swiftly", GApplicationFlags(rawValue: 0))
beiSignal(UnsafeMutableRawPointer(anwendung), "activate", fensterAufbauen)

let ergebnis = g_application_run(
    unsafeBitCast(anwendung, to: UnsafeMutablePointer<GApplication>.self), 0, nil)
exit(ergebnis)
