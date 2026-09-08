import CGtk
import Foundation
import JellyfinKit

/// **Das Technikschild — eine Auskunft, die stehenbleibt.**
///
/// Woertlich die Fassung von `Sources/Shared/Technikschild.swift`, nur in GTK
/// gezeichnet. Die Zahlen kommen aus ``JellyfinKit/Zaehlwerk`` und die
/// Formulierungen aus ``JellyfinKit/Technikangaben`` — beides liegt im Paket,
/// damit die Plattformen nicht auseinanderlaufen.
///
/// **Eine Zeile fehlt hier, und das ist kein Versehen:** „zu spaet" gibt es
/// nicht. `libvlc_media_stats_t` fuehrt keine verspaeteten Bilder; VLCKit
/// liefert sie ueber `latePictures`, die C-Schnittstelle nicht. Eine Null
/// hinzuschreiben waere eine Aussage, die wir nicht haben.
extension App {

    /// Legt das Schild an oder nimmt es weg.
    func technikschildSetzen(_ an: Bool) {
        if an {
            guard technikschild == nil, spielerRahmen != nil else { return }
            let feld = beschriftung("", stil: "swiftly-technikschild")
            gtk_label_set_xalign(OpaquePointer(feld), 0)
            gtk_label_set_yalign(OpaquePointer(feld), 0)
            gtk_widget_set_halign(feld, GTK_ALIGN_START)
            gtk_widget_set_valign(feld, GTK_ALIGN_START)
            gtk_widget_set_margin_top(feld, 22)
            gtk_widget_set_margin_start(feld, 22)
            // **Nichts abfangen.** Das Schild liegt ueber dem Bild und darf
            // keinen Klick schlucken, der der Steuerung gilt.
            gtk_widget_set_can_target(feld, 0)
            technikschild = feld
            gtk_overlay_add_overlay(OpaquePointer(spielerRahmen), feld)
            technikschildNachfuehren()
        } else {
            if let feld = technikschild, spielerRahmen != nil {
                gtk_overlay_remove_overlay(OpaquePointer(spielerRahmen), feld)
            }
            technikschild = nil
            technikzaehler = nil
        }
    }

    /// Wird im Wiedergabetakt gerufen — 500 ms, derselbe wie ueberall.
    func technikschildNachfuehren() {
        guard let feld = technikschild else { return }
        technikzaehler = abspieler.zaehlwerte.flatMap {
            Zaehlwerk($0, stelle: abspieler.position, laeuft: abspieler.laeuft,
                      vorher: technikzaehler)
        }
        gtk_label_set_text(OpaquePointer(feld), technikschildText())
    }

    private func technikschildText() -> String {
        var zeilen: [String] = []
        let quelle = laufenderPlan?.quelle

        if let plan = laufenderPlan {
            zeilen.append(Technikangaben.auslieferung(plan.method))
        }
        if let video = quelle.flatMap(Dateiangaben.videospur) {
            var t = ""
            if let c = Technikangaben.codecname(video.codec) { t = c }
            if let f = Technikangaben.bildrate(video.averageFrameRate) {
                t += t.isEmpty ? f : " · \(f) fps"
            }
            if !t.isEmpty { zeilen.append("\(uebersetzt("Bild")) \(t)") }
        }
        if let ton = quelle.flatMap({ Dateiangaben.tonspuren($0).first }) {
            var t = ""
            if let c = Technikangaben.codecname(ton.codec) { t = c }
            if let k = ton.channels.flatMap(Technikangaben.kanalwort) {
                t += t.isEmpty ? k : " · \(k)"
            }
            if !t.isEmpty { zeilen.append("\(uebersetzt("Ton")) \(t)") }
        }
        zeilen.append("\(uebersetzt("Stelle")) \(Spielzeit.text(abspieler.position))"
                      + " / \(Spielzeit.text(abspieler.dauer))")

        guard let w = technikzaehler else { return zeilen.joined(separator: "\n") }
        zeilen.append("")

        zeilen.append("\(uebersetzt("Eingang")) \(Technikangaben.bitrate(w.eingang) ?? "—")")
        zeilen.append("\(uebersetzt("Demuxer")) \(Technikangaben.bitrate(w.demuxer) ?? "—")")
        zeilen.append("\(uebersetzt("Zeigt Ø")) \(zahl(w.zeigtProSekunde)) fps"
                      + " · \(uebersetzt("Gezeigt")) \(w.roh.gezeigt)")
        zeilen.append("\(uebersetzt("Lauf")) \(anteil(w.laufAnteil))")
        zeilen.append("\(uebersetzt("Dekodiert Ø")) \(zahl(w.dekodiertProSekunde)) fps")
        zeilen.append("\(uebersetzt("Vorrat")) \(vorratwort(w))")
        zeilen.append("\(uebersetzt("Verworfen")) \(w.roh.verworfen)"
                      + " · \(uebersetzt("Ton weg")) \(w.roh.tonVerloren)")
        zeilen.append("\(uebersetzt("Beschädigt")) \(w.roh.beschaedigt)"
                      + " · \(uebersetzt("Sprünge")) \(w.roh.spruenge)")
        return zeilen.joined(separator: "\n")
    }

    private func zahl(_ w: Double?) -> String {
        guard let w else { return "—" }
        return String(format: "%.1f", w).replacingOccurrences(of: ".", with: ",")
    }

    private func anteil(_ w: Double?) -> String {
        guard let w else { return "—" }
        return "\(Int((w * 100).rounded())) %"
    }

    /// Der Fuellstand in Sekunden, gerechnet aus dem Bedarf der Datei.
    private func vorratwort(_ w: Zaehlwerk) -> String {
        let kib = "\(w.vorratBytes / 1024) KiB"
        guard let quelle = laufenderPlan?.quelle, let bytes = quelle.size, bytes > 0 else {
            return kib
        }
        let dauer = abspieler.dauer
        guard dauer > 1 else { return kib }
        let sekunden = w.vorratSekunden(bytesJeSekunde: Double(bytes) / dauer)
        guard let sekunden else { return kib }
        return String(format: "%.1f", sekunden).replacingOccurrences(of: ".", with: ",")
            + " s · " + kib
    }
}
