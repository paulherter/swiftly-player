import CGtk
import Foundation
import JellyfinKit

/// **Grosse Raster geben die Bilder weit ausserhalb der Sicht wieder her.**
///
/// Das Raster ist eine `GtkFlowBox`: jede Kachel lebt, solange die Seite
/// lebt, und jede haelt ihre Textur — ein Plakat in doppelter Aufloesung sind
/// gut ein halbes Megabyte. Wer „Filme" mit zweitausend Titeln einmal ganz
/// durchscrollt, hatte danach zweitausend Texturen im Speicher, denn die
/// Grenze in ``Bildspeicher`` gibt nur *ihre* Referenz ab, nicht die der
/// Bildfelder (Audit 27.09., PERFORMANCE #1).
///
/// **Warum nicht gleich `GtkGridView`.** Das waere das richtige Werkzeug —
/// Zellen, die wiederverwendet werden. Aber jede Kachel traegt hier Plakette,
/// Balken, Rechtsklickweg, Vorholen und Bedienhilfenamen, und alles haengt
/// an Widgets, die einmal gebaut werden; das Nachladen, das Leeren, der
/// Fokus und der Fernsteuerbefehl `raster` rechnen mit FlowBox-Kindern.
/// Umbauen hiesse, all das neu zu schreiben, ohne es am Bild pruefen zu
/// koennen. Die Widgets selbst sind klein; was waechst, sind die Texturen —
/// und die holt diese Wache zurueck.
///
/// **Was sie tut:** gedrosselt beim Scrollen jede Kachel ansehen. Mehr als
/// drei Bildschirmhoehen weg: Bild aus dem Feld nehmen. Wieder naeher als
/// anderthalb: neu auflegen — aus dem Texturspeicher sofort, sonst aus dem
/// Bildlager oder von der Platte (``Bildplatte``), der Server wird dafuer
/// nicht gefragt. Die Luecke zwischen beiden Grenzen verhindert, dass eine
/// Kachel am Rand bei jedem Ruck ab- und wieder aufgelegt wird.
final class Kachelbildwache {
    final class Eintrag {
        var bild: Widget?
        let url: URL
        let schluessel: String
        let kante: Int?
        var abgelegt = false
        init(bild: Widget!, url: URL, schluessel: String, kante: Int?) {
            self.bild = bild
            self.url = url
            self.schluessel = schluessel
            self.kante = kante
        }
    }

    private var eintraege: [Eintrag] = []
    private var scroller: Widget?
    private var geplant = false
    private var seitAufraeumen = 0

    /// Wie viele Bilder gerade abgelegt sind — fuers Protokoll.
    var abgelegt: Int { eintraege.lazy.filter(\.abgelegt).count }

    init(scroller: Widget!) {
        self.scroller = scroller
        beiSignal(scroller, "destroy") { [weak self] in
            self?.scroller = nil
            self?.eintraege = []
        }
        if let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller)) {
            beiSignalRoh(UnsafeMutableRawPointer(senkrecht), "value-changed") { [weak self] in
                self?.planen()
            }
        }
    }

    func aufnehmen(_ bild: Widget!, url: URL, schluessel: String, kante: Int?) {
        let eintrag = Eintrag(bild: bild, url: url, schluessel: schluessel, kante: kante)
        // **Auf das Ende hoeren**, sonst zeigt `bild` nach dem Leeren des
        // Rasters auf freigegebenen Speicher.
        beiSignal(bild, "destroy") { [weak eintrag] in eintrag?.bild = nil }
        // Tote Eintraege fallen sonst nur beim Scrollen heraus; wer ohne
        // Scrollen immer neu filtert oder sortiert, haeufte sie an.
        seitAufraeumen += 1
        if seitAufraeumen >= 256 {
            seitAufraeumen = 0
            eintraege.removeAll { $0.bild == nil }
        }
        eintraege.append(eintrag)
    }

    /// Hoechstens alle 150 ms — Scrollen schickt ein Signal je Bild.
    private func planen() {
        guard !geplant else { return }
        geplant = true
        nachFrist(0.15) { [weak self] in
            self?.geplant = false
            self?.pruefen()
        }
    }

    private func pruefen() {
        eintraege.removeAll { $0.bild == nil }
        guard let scroller, !eintraege.isEmpty,
              let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return }
        let sicht = gtk_adjustment_get_page_size(senkrecht)
        guard sicht > 0 else { return }
        let fern = sicht * 3
        let nah = sicht * 1.5
        var rahmen = graphene_rect_t()
        for eintrag in eintraege {
            guard let bild = eintrag.bild,
                  gtk_widget_compute_bounds(bild, scroller, &rahmen) != 0 else { continue }
            // Lage relativ zum sichtbaren Ausschnitt: oben 0, unten `sicht`.
            let oben = Double(rahmen.origin.y)
            let unten = oben + Double(rahmen.size.height)
            let abstand = max(0, -unten, oben - sicht)
            if !eintrag.abgelegt, abstand > fern {
                gtk_picture_set_paintable(OpaquePointer(bild), nil)
                eintrag.abgelegt = true
            } else if eintrag.abgelegt, abstand < nah {
                eintrag.abgelegt = false
                bildLaden(bild, url: eintrag.url, schluessel: eintrag.schluessel,
                          kante: eintrag.kante)
            }
        }
    }
}
