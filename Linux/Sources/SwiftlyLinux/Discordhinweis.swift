import CGtk
import Foundation
import JellyfinKit

/// **Einmal je Installation: Swiftly hat einen Discord.**
///
/// Aus `Sources/macOS/RootView.swift` (`Discordhinweis`, Commit d3cfccd):
/// nach dem fünften zu Ende geschauten Titel, wenn der Player zu ist, mit
/// anderthalb Sekunden Abstand. Eine Karte unten rechts statt eines
/// Fensters: sie verdeckt nichts, und ein Klick auf das Kreuz nimmt sie für
/// immer weg. **Ohne Bewertungsfrage** — es gibt hier keinen Store; das Paket
/// lässt den Discord dann nicht auf eine nie gestellte Frage warten
/// (`Gemeinschaft.anstoss`, `bewertungMoeglich: false`).
extension App {

    /// Zu Ende geschaut? Zählt für den Discord-Hinweis — je Titel einmal, wie
    /// `PlayerScreen.zaehlen` auf dem Mac: beim Schliessen und beim
    /// Folgenwechsel.
    func fertigZaehlen(_ titel: Item?, position: Double, dauer: Double) {
        guard let titel, gezaehlterTitel != titel.id else { return }
        gezaehlterTitel = titel.id
        guard Bewertungsfrage.zaehltAlsFertig(position: position, dauer: dauer) else { return }
        wahlen.fertigGeschaut += 1
        if Gemeinschaft.anstoss(fertig: wahlen.fertigGeschaut, bewertungZuletzt: nil,
                                fassung: Fassung.nummer,
                                discordGezeigt: wahlen.discordHinweisGezeigt,
                                bewertungMoeglich: false) == .discord {
            // Gleich als gezeigt merken: stürzt die App vorher ab oder wird
            // sie geschlossen, kommt der Hinweis lieber nie als zweimal.
            wahlen.discordHinweisGezeigt = true
            discordHinweisFaellig = true
        }
        wahlen.sichern()
    }

    /// Nach dem Schliessen des Players: ist der Hinweis fällig, kommt er mit
    /// einem Atemzug Abstand — und nur, wenn bis dahin kein Player offen ist.
    func discordHinweisPruefen() {
        guard discordHinweisFaellig else { return }
        discordHinweisFaellig = false
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            aufHauptfaden {
                guard self.laufenderTitel == nil else {
                    self.discordHinweisFaellig = true
                    return
                }
                self.discordkarteZeigen()
            }
        }
    }

    private func discordkarteZeigen() {
        guard discordkarte == nil, let decke = fensterdecke else { return }
        let karte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_add_css_class(karte, "swiftly-discordkarte")
        gtk_widget_set_size_request(karte, 320, -1)
        gtk_widget_set_halign(karte, GTK_ALIGN_END)
        gtk_widget_set_valign(karte, GTK_ALIGN_END)
        gtk_widget_set_margin_end(karte, Int32(Stil.randAbstand))
        gtk_widget_set_margin_bottom(karte, Int32(Stil.randAbstand))

        let kopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        let titel = beschriftung(uebersetzt("Swiftly hat einen Discord"), stil: "swiftly-listentitel")
        gtk_label_set_xalign(OpaquePointer(titel), 0)
        gtk_widget_set_hexpand(titel, 1)
        anhaengen(kopf, titel)
        let zu: Widget! = gtk_button_new_from_icon_name("window-close-symbolic")
        gtk_widget_add_css_class(zu, "swiftly-handlung")
        gtk_widget_set_valign(zu, GTK_ALIGN_START)
        beschriften(zu, uebersetzt("Schließen"))
        beiSignal(zu, "clicked") { [weak self] in self?.discordkarteWeg() }
        anhaengen(kopf, zu)
        anhaengen(karte, kopf)

        let text = beschriftung(uebersetzt("Da kannst du Fragen stellen und Fehler melden. Neue Builds stehen da auch zuerst."),
                                stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(text, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(text), 0)
        anhaengen(karte, text)

        let knopf = hauptknopf(uebersetzt("Discord beitreten"), symbol: "user-available-symbolic")
        gtk_widget_set_size_request(knopf, -1, Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_halign(knopf, GTK_ALIGN_FILL)
        gtk_widget_set_margin_top(knopf, 4)
        beiSignal(knopf, "clicked") { [weak self] in
            imBrowser(Gemeinschaft.discord)
            self?.discordkarteWeg()
        }
        anhaengen(karte, knopf)

        gtk_overlay_add_overlay(OpaquePointer(decke), karte)
        discordkarte = karte
        gtk_widget_set_opacity(karte, 0)
        blenden(karte, auf: 1, dauer: Stil.zeitBlendeHerein)
    }

    /// Nimmt die Karte weg — auch, wenn ein Player aufgeht.
    func discordkarteWeg() {
        guard let karte = discordkarte, let decke = fensterdecke else { return }
        discordkarte = nil
        gtk_overlay_remove_overlay(OpaquePointer(decke), karte)
    }
}
