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
        // **Markup, nicht Text** — die Warnzeilen tragen ihre Farbe selbst.
        gtk_label_set_markup(OpaquePointer(feld), technikschildText())
    }

    private func technikschildText() -> String {
        var zeilen: [String] = []
        let quelle = laufenderPlan?.quelle

        var kopfzeilen: [String] = []
        if let plan = laufenderPlan {
            // **Das Wort traegt die Farbe** (D1): Akzent, wenn nichts
            // umgerechnet wird, sonst Warnorange. Der Mac faerbt es ueber
            // `Technikangaben.gewicht` (`Sources/Shared/Technikschild.swift:133-138`);
            // hier stand es als blanker Text, und ein transkodierender Strom
            // sah aus wie ein sauberer.
            kopfzeilen.append(faerben(Technikangaben.auslieferung(plan.method),
                                      Technikangaben.gewicht(plan.method) == .gut
                                          ? Stil.akzent : Stil.warnung))
            // **Und der Grund steht direkt darunter** (D2). Wer
            // „Transkodiert" liest, will als Naechstes wissen, woran es lag.
            // Diese Zeile fehlte auf Linux ganz — `plan.reasons` wurde in der
            // ganzen Datei nie gelesen.
            if plan.method == .transcode, let grund = plan.reasons.first {
                kopfzeilen.append(faerben(grund.text, Stil.warnung))
            }
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

        guard let w = technikzaehler else {
            return (kopfzeilen + zeilen.map(schutz)).joined(separator: "\n")
        }
        var fertig = kopfzeilen + zeilen.map(schutz)
        fertig.append("")

        // **Nur die Abweichung meldet sich lauter** (D2). Die Schwellen sind
        // die des Macs (`Sources/Shared/Technikschild.swift`) — hier standen
        // dieselben Zahlen, aber alle in derselben Farbe: ein haengender
        // Strom sah aus wie ein sauber laufender.
        let soll = laufenderPlan?.quelle
            .flatMap(Dateiangaben.videospur)?.averageFrameRate
        fertig.append(schutz("\(uebersetzt("Eingang")) \(Technikangaben.bitrate(w.eingang) ?? "—")"))
        fertig.append(schutz("\(uebersetzt("Demuxer")) \(Technikangaben.bitrate(w.demuxer) ?? "—")"))
        // Zwei Bilder Abstand: darunter ist es die Kante des Messfensters und
        // kein Ereignis (`:255-262`).
        let zeigtHinkt = if let ist = w.zeigtProSekunde, let soll { ist < soll - 2 } else { false }
        fertig.append(zeile("\(uebersetzt("Zeigt Ø")) \(zahl(w.zeigtProSekunde)) fps"
                            + " · \(uebersetzt("Gezeigt")) \(w.roh.gezeigt)", warnt: zeigtHinkt))
        // Unter 97 % ist kein Messrauschen mehr — mehr als anderthalb
        // Sekunden auf eine Minute (`:288`).
        fertig.append(zeile("\(uebersetzt("Lauf")) \(anteil(w.laufAnteil))",
                            warnt: (w.laufAnteil ?? 1) < 0.97))
        let dekHinkt = if let ist = w.dekodiertProSekunde, let soll { ist < soll - 2 } else { false }
        fertig.append(zeile("\(uebersetzt("Dekodiert Ø")) \(zahl(w.dekodiertProSekunde)) fps",
                            warnt: dekHinkt))
        fertig.append(zeile("\(uebersetzt("Vorrat")) \(vorratwort(w))", warnt: vorratKnapp(w)))
        fertig.append(zeile("\(uebersetzt("Verworfen")) \(w.roh.verworfen)"
                            + " · \(uebersetzt("Ton weg")) \(w.roh.tonVerloren)",
                            warnt: w.roh.verworfen > 0 || w.roh.tonVerloren > 0))
        fertig.append(zeile("\(uebersetzt("Beschädigt")) \(w.roh.beschaedigt)"
                            + " · \(uebersetzt("Sprünge")) \(w.roh.spruenge)",
                            warnt: w.roh.beschaedigt > 0 || w.roh.spruenge > 0))
        return fertig.joined(separator: "\n")
    }

    /// Eine Zeile in einer bestimmten Farbe.
    private func faerben(_ text: String, _ farbe: String) -> String {
        "<span foreground=\"\(farbe)\">\(schutz(text))</span>"
    }

    /// Eine Zeile im Markup — warnend in Orange, sonst wie der Rest.
    private func zeile(_ text: String, warnt: Bool) -> String {
        warnt ? "<span foreground=\"\(Stil.warnung)\">\(schutz(text))</span>" : schutz(text)
    }

    /// Pango liest `&`, `<` und `>` als Auszeichnung. Ein Dateiname mit
    /// Kaufmanns-Und wuerfe sonst das ganze Schild weg.
    private func schutz(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Unter zwei Sekunden Vorrat wird es knapp (`:358`).
    private func vorratKnapp(_ w: Zaehlwerk) -> Bool {
        guard let quelle = laufenderPlan?.quelle, let bytes = quelle.size, bytes > 0,
              abspieler.dauer > 1,
              let sekunden = w.vorratSekunden(bytesJeSekunde: Double(bytes) / abspieler.dauer)
        else { return false }
        return sekunden < 2
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
