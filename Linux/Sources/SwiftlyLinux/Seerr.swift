import CGtk
import Foundation
import JellyfinKit

/// **Seerr — anfordern, was der Server nicht hat.**
///
/// Der Client liegt im Paket (`JellyfinKit.SeerrClient`) und ist
/// plattformunabhaengig; hier steht nur die Oberflaeche. Auf den
/// Apple-Fassungen ist das `Seerrmodell` plus vier Ansichten — die Aufteilung
/// ist dieselbe, nur in GTK gezeichnet.
extension App {

    /// Der Zugang, einmal aus der Ablage geholt.
    func seerrLaden() {
        seerrzugang = Speicher.seerrLesen()
        seerrclient = seerrzugang.map { SeerrClient(zugang: $0) }
    }

    var seerrDa: Bool { seerrclient != nil }

    // MARK: Einstellungen

    /// **Adresse und Schluessel, mehr braucht es nicht.**
    ///
    /// Woertlich die Felder der Apple-Fassung (`SeerrEinstellungenView`):
    /// die Adresse des Dienstes und ein API-Schluessel. Geprueft wird mit
    /// `gilt()`, damit ein Tippfehler hier auffaellt und nicht erst, wenn
    /// jemand etwas anfordern will.
    func seerrSeiteBauen(_ block: Widget!) {
        anhaengen(block, seerrKopf())

        let hinweis = beschriftung(
            uebersetzt("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_widget_set_margin_bottom(hinweis, 18)
        anhaengen(block, hinweis)

        let adresse: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(adresse), "seerr.example.com")
        if let z = seerrzugang { gtk_editable_set_text(OpaquePointer(adresse), z.adresse.absoluteString) }
        anhaengen(block, feldzeile(uebersetzt("Adresse"), adresse))

        let benutzer: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(benutzer), uebersetzt("Benutzername"))
        gtk_editable_set_text(OpaquePointer(benutzer), benutzername)
        anhaengen(block, feldzeile(uebersetzt("Benutzername"), benutzer))

        let passwort: Widget! = gtk_entry_new()
        gtk_entry_set_visibility(alsFeld(passwort), 0)
        gtk_entry_set_placeholder_text(alsFeld(passwort), uebersetzt("Passwort"))
        anhaengen(block, feldzeile(uebersetzt("Passwort"), passwort))

        // **Das Passwort wird nicht gesichert** — nur die Sitzung, die Seerr
        // dafuer ausstellt. Woertlich die Zusage der Apple-Fassung, und sie
        // steht dort wie hier sichtbar auf der Seite, nicht nur im Quelltext.
        let zusage = beschriftung(
            uebersetzt("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(zusage), 0)
        gtk_widget_add_css_class(zusage, "dim-label")
        anhaengen(block, zusage)

        let stand = beschriftung("", stil: "swiftly-zweitzeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(stand), 0)
        gtk_widget_set_margin_top(stand, 12)
        gtk_widget_set_visible(stand, 0)
        anhaengen(block, stand)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_set_margin_top(reihe, 20)
        let standKiste = Zeigerkiste(stand)
        let aKiste = Zeigerkiste(adresse)
        let bKiste = Zeigerkiste(benutzer)
        let pKiste = Zeigerkiste(passwort)

        let verbinden = hauptknopf(uebersetzt("Verbinden"), symbol: "object-select-symbolic")
        beiSignal(verbinden, "clicked") { [weak self] in
            guard let self else { return }
            let roh = String(cString: gtk_editable_get_text(OpaquePointer(aKiste.widget)))
            let b = String(cString: gtk_editable_get_text(OpaquePointer(bKiste.widget)))
            let pw = String(cString: gtk_editable_get_text(OpaquePointer(pKiste.widget)))
            // **Eine Eingabe ergibt mehrere Adressen.** `Seerr.adressen` faechert
            // sie auf (mit und ohne Schema, mit und ohne Port) — dieselbe Regel
            // wie auf den Apple-Fassungen, im Paket und dort getestet.
            let adressen = Seerr.adressen(aus: roh)
            guard !adressen.isEmpty else {
                self.seerrStandZeigen(standKiste, uebersetzt("Diese Adresse ergibt keine."))
                return
            }
            guard !b.isEmpty, !pw.isEmpty else {
                self.seerrStandZeigen(standKiste, uebersetzt("Benutzername und Passwort fehlen"))
                return
            }
            self.seerrStandZeigen(standKiste, uebersetzt("Verbinde …"))
            Task.detached {
                var letzter: String?
                for url in adressen {
                    do {
                        let neu = try await SeerrClient.anmelden(an: url, benutzer: b, passwort: pw)
                        aufHauptfaden {
                            self.seerrzugang = neu
                            self.seerrclient = SeerrClient(zugang: neu)
                            Speicher.seerrSchreiben(neu)
                            // Das Passwortfeld wird geleert, sobald es nicht
                            // mehr gebraucht wird.
                            gtk_editable_set_text(OpaquePointer(pKiste.widget), "")
                            self.seerrStandZeigen(standKiste, uebersetzt("Verbunden"))
                        }
                        return
                    } catch {
                        letzter = error.localizedDescription
                    }
                }
                // **Erst festhalten, dann hinueberreichen.** Eine
                // veraenderliche Variable ueber die Fadengrenze zu greifen
                // laesst Swift 6 nicht zu — und zu Recht: der Block laeuft
                // spaeter.
                let meldung = letzter ?? uebersetzt("Keine Verbindung")
                aufHauptfaden {
                    self.seerrStandZeigen(standKiste, meldung)
                }
            }
        }
        anhaengen(reihe, verbinden)

        if seerrzugang != nil {
            let weg = nebenknopf("user-trash-symbolic", name: uebersetzt("Verbindung trennen"))
            beiSignal(weg, "clicked") { [weak self] in
                guard let self else { return }
                self.seerrzugang = nil
                self.seerrclient = nil
                Speicher.seerrSchreiben(nil)
                gtk_editable_set_text(OpaquePointer(aKiste.widget), "")
                gtk_editable_set_text(OpaquePointer(pKiste.widget), "")
                self.seerrStandZeigen(standKiste, uebersetzt("Getrennt"))
            }
            anhaengen(reihe, weg)
        }
        anhaengen(block, reihe)
    }

    /// Eigener Kopf statt `unterseitenkopf` — das ist dort privat, und eine
    /// Kopie der Datei waere schlimmer als drei Zeilen hier.
    private func seerrKopf() -> Widget! {
        let l = beschriftung(uebersetzt("Seerr"), stil: "swiftly-unterkopf")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_widget_set_margin_bottom(l, 10)
        return l
    }

    private func seerrStandZeigen(_ kiste: Zeigerkiste, _ text: String) {
        gtk_label_set_text(OpaquePointer(kiste.widget), text)
        gtk_widget_set_visible(kiste.widget, 1)
    }

    /// Beschriftung ueber dem Feld — die Form der uebrigen Einstellungen.
    private func feldzeile(_ titel: String, _ feld: Widget!) -> Widget! {
        let stapelchen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 6)
        gtk_widget_set_margin_bottom(stapelchen, 14)
        let l = beschriftung(titel, stil: "swiftly-zweitzeile")
        gtk_label_set_xalign(OpaquePointer(l), 0)
        anhaengen(stapelchen, l)
        anhaengen(stapelchen, feld)
        return stapelchen
    }
}
