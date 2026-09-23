import CGtk
import Foundation
import JellyfinKit

/// **„Erweitert" — eigene Header für einen Dienst vor dem Server.**
///
/// Cloudflare Access, Authelia, Authentik, Pangolin: wer Jellyfin oder Seerr
/// so absichert, lässt die App nur mit bestimmten Headern durch (Issue #4).
/// Die Vorlage ist `Sources/macOS/MacErweitert.swift`: zugeklappt und leer,
/// damit sich für niemanden sonst etwas ändert; der Wert ist verdeckt wie ein
/// Passwort. Was davon hinausgeht, entscheidet ``Eigenkoepfe/bereinigt(_:)``
/// im Paket, nicht diese Datei.
final class Kopfzeilenleser {
    fileprivate struct Zeile { let reihe: Widget!; let name: Widget!; let wert: Widget! }
    fileprivate var zeilen: [Zeile] = []
    /// Nach dem Abräumen der Seite zeigen die Felder ins Leere — dann liest
    /// der Leser nichts mehr, statt freigegebenen Speicher anzufassen.
    fileprivate var abgeraeumt = false

    /// Was eingetragen ist, schon durch die Schleuse des Pakets.
    func koepfe() -> [Eigenkopf] {
        guard !abgeraeumt else { return [] }
        return Eigenkoepfe.bereinigt(zeilen.map { z in
            Eigenkopf(name: String(cString: gtk_editable_get_text(OpaquePointer(z.name))),
                      wert: String(cString: gtk_editable_get_text(OpaquePointer(z.wert))))
        })
    }
}

/// Den Bereich bauen. `aufgeklappt` für die Einstellungen, wo schon Header
/// stehen können — dann gibt es nichts aufzuklappen.
func erweitertBauen(vorhanden: [Eigenkopf], aufgeklappt: Bool = false,
                    geaendert: @escaping () -> Void = {}) -> (Widget?, Kopfzeilenleser) {
    let leser = Kopfzeilenleser()
    let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
    gtk_widget_set_margin_top(aussen, 10)
    beiSignal(aussen, "destroy") { leser.abgeraeumt = true; leser.zeilen = [] }

    let inhalt = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
    let offen = aufgeklappt || !vorhanden.isEmpty

    if !aufgeklappt {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-flach")
        gtk_widget_set_halign(knopf, GTK_ALIGN_START)
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
        anhaengen(reihe, beschriftung(uebersetzt("Erweitert"), stil: "swiftly-zweitzeile"))
        let pfeil: Widget! = gtk_image_new_from_icon_name(offen ? "pan-down-symbolic" : "pan-end-symbolic")
        anhaengen(reihe, pfeil)
        gtk_button_set_child(alsKnopf(knopf), reihe)
        let ik = Zeigerkiste(inhalt), pk = Zeigerkiste(pfeil)
        beiSignal(knopf, "clicked") {
            let jetzt = gtk_widget_get_visible(ik.widget) == 0
            gtk_widget_set_visible(ik.widget, jetzt ? 1 : 0)
            gtk_image_set_from_icon_name(OpaquePointer(pk.widget),
                                         jetzt ? "pan-down-symbolic" : "pan-end-symbolic")
        }
        anhaengen(aussen, knopf)
    }
    gtk_widget_set_visible(inhalt, offen ? 1 : 0)

    let satz = beschriftung(uebersetzt("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse."),
                            stil: "swiftly-zweitzeile", umbruch: true)
    gtk_widget_add_css_class(satz, "dim-label")
    gtk_label_set_xalign(OpaquePointer(satz), 0)
    anhaengen(inhalt, satz)

    let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
    anhaengen(inhalt, liste)
    let lk = Zeigerkiste(liste)

    func zeileAnlegen(_ k: Eigenkopf?) {
        let reihe = stapel(GTK_ORIENTATION_VERTICAL, abstand: 4)
        let name = eingabezeile(symbol: "tag-symbolic", platzhalter: uebersetzt("Header-Name"), dehnt: true)
        let wert = eingabezeile(symbol: "dialog-password-symbolic", platzhalter: uebersetzt("Wert"),
                                geheim: true, dehnt: true)
        if let k {
            gtk_editable_set_text(OpaquePointer(name), k.name)
            gtk_editable_set_text(OpaquePointer(wert), k.wert)
        }
        let weg = nebenknopf("list-remove-symbolic", name: uebersetzt("Entfernen"))
        let felder = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        anhaengen(felder, name)
        anhaengen(felder, wert)
        anhaengen(felder, weg)
        anhaengen(reihe, felder)
        // Den setzt Swiftly selbst — die Zeile sagt es, statt still nichts
        // zu tun.
        let hinweis = beschriftung(uebersetzt("Den setzt Swiftly selbst."), stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(hinweis, "swiftly-warnung")
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        let hk = Zeigerkiste(hinweis), nk = Zeigerkiste(name)
        let hinweisen: () -> Void = {
            let n = String(cString: gtk_editable_get_text(OpaquePointer(nk.widget)))
            gtk_widget_set_visible(hk.widget, Eigenkoepfe.istGesperrt(n) ? 1 : 0)
        }
        hinweisen()
        beiSignal(name, "changed", hinweisen)
        anhaengen(reihe, hinweis)
        let rk = Zeigerkiste(reihe)
        beiSignal(weg, "clicked") {
            leser.zeilen.removeAll { $0.reihe == rk.widget }
            gtk_box_remove(alsBox(lk.widget), rk.widget)
            geaendert()
        }
        beiSignal(name, "changed", geaendert)
        beiSignal(wert, "changed", geaendert)
        leser.zeilen.append(.init(reihe: reihe, name: name, wert: wert))
        anhaengen(lk.widget, reihe)
    }
    for k in vorhanden { zeileAnlegen(k) }

    let dazu: Widget! = gtk_button_new()
    gtk_widget_add_css_class(dazu, "swiftly-flach")
    gtk_widget_set_halign(dazu, GTK_ALIGN_START)
    let dazuReihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 6)
    anhaengen(dazuReihe, gtk_image_new_from_icon_name("list-add-symbolic"))
    anhaengen(dazuReihe, beschriftung(uebersetzt("Header hinzufügen"), stil: "swiftly-zweitzeile"))
    gtk_button_set_child(alsKnopf(dazu), dazuReihe)
    beiSignal(dazu, "clicked") { zeileAnlegen(nil); geaendert() }
    anhaengen(inhalt, dazu)

    anhaengen(aussen, inhalt)
    return (aussen, leser)
}

extension App {

    /// **Die eigenen Header des aktiven Servers**, in den Einstellungen unter
    /// der Gruppe „Server" — wie auf dem Mac (`MacEigeneKoepfe`) ohne eigene
    /// Seite. „Sichern" erscheint erst, wenn sich etwas geändert hat, und gilt
    /// sofort für jede weitere Anfrage.
    func eigeneKoepfeBauen() -> Widget! {
        let aussen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        guard let server = bund?.serverURL else { return aussen }

        final class Stand { var gesichert: [Eigenkopf] = []; var knopf: Widget!; var leser: Kopfzeilenleser? }
        let stand = Stand()
        stand.gesichert = Eigenkoepfe.eingetragen(fuer: server)
        let (bereich, leser) = erweitertBauen(vorhanden: stand.gesichert) {
            guard let knopf = stand.knopf, let leser = stand.leser else { return }
            gtk_widget_set_visible(knopf, leser.koepfe() != stand.gesichert ? 1 : 0)
        }
        stand.leser = leser
        anhaengen(aussen, bereich)

        let knopf = hauptknopf(uebersetzt("Sichern"), symbol: "object-select-symbolic")
        gtk_widget_set_margin_top(knopf, 14)
        gtk_widget_set_halign(knopf, GTK_ALIGN_START)
        gtk_widget_set_visible(knopf, 0)
        stand.knopf = knopf
        beiSignal(aussen, "destroy") { stand.knopf = nil; stand.leser = nil }
        beiSignal(knopf, "clicked") {
            guard let leser = stand.leser else { return }
            Speicher.koepfeSichern(leser.koepfe(), fuer: server)
            stand.gesichert = Eigenkoepfe.eingetragen(fuer: server)
            if let k = stand.knopf { gtk_widget_set_visible(k, 0) }
        }
        anhaengen(aussen, knopf)
        return aussen
    }
}
