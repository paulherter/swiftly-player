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
/// **Der Messmodus: alle Zeilen, ohne Höchsthöhe** (Mac: `@AppStorage
/// ("technikschildMessen")`, gesetzt als Startargument `-technikschildMessen
/// YES`). Kein Schalter in den Einstellungen — das ist Werkzeug für die Suche
/// nach einem Fehler, nicht für Zuschauer. Hier dasselbe Startargument, und
/// weil GTK die Befehlszeile nie sieht (`g_application_run` bekommt `argc` 0),
/// stört es niemanden; ersatzweise `SWIFTLY_TECHNIKSCHILD_MESSEN=1`.
private let technikschildMessen: Bool = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "-technikschildMessen"), i + 1 < a.count,
       ["yes", "true", "1"].contains(a[i + 1].lowercased()) { return true }
    return ProcessInfo.processInfo.environment["SWIFTLY_TECHNIKSCHILD_MESSEN"] == "1"
}()

/// Bis hierhin dürfen Zusatzzeilen das Schild verlängern; die Kernzeilen
/// zählen mit, stehen aber auch darüber hinaus (Mac: `hoechstanteil`).
private let technikschildHoechstanteil = 0.55
/// Die Breite der Spalte — Mac: `.frame(width: 260)`. Ohne sie bricht keine
/// Zeile um, und der Grund liesse sich nicht auf zwei Zeilen kürzen.
private let technikschildBreite: Int32 = 260
/// Zeilenabstand, Mac: `abstand` 4.
private let technikschildAbstand: Int32 = 4

/// Eine Zeile des Schilds. `kern` steht immer; die übrigen kappt die
/// Höchsthöhe in Rangfolge (Mac: `Kappliste`, `kern()`).
private struct Schildzeile {
    enum Art { case kopf, grund, text, linie }
    var art: Art = .text
    var markup = ""
    var kern = false
}

extension App {

    /// Wo das Schild oben beginnt, wenn die Steuerung offen ist: fest unter
    /// der Titelzeile — Mac: `mass.oben + mass.knopf + Stil.kachelAbstand`.
    private var schildOben: Int32 { Playermass.oben + Playermass.knopf + Int32(Stil.kachelAbstand) }

    /// Legt das Schild an oder nimmt es weg.
    func technikschildSetzen(_ an: Bool) {
        if an {
            guard technikschild == nil, spielerRahmen != nil else { return }
            let feld = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            gtk_widget_add_css_class(feld, "swiftly-technikschild")
            let spalte = stapel(GTK_ORIENTATION_VERTICAL, abstand: technikschildAbstand)
            gtk_widget_set_size_request(spalte, technikschildBreite, -1)
            anhaengen(feld, spalte)
            gtk_widget_set_halign(feld, GTK_ALIGN_START)
            gtk_widget_set_valign(feld, GTK_ALIGN_START)
            // Mac: `.padding(.leading, mass.seite)`,
            // `.padding(.top, mass.oben + mass.knopf + Stil.kachelAbstand)`.
            gtk_widget_set_margin_start(feld, Playermass.seite)
            // **Nichts abfangen.** Das Schild liegt ueber dem Bild und darf
            // keinen Klick schlucken, der der Steuerung gilt.
            gtk_widget_set_can_target(feld, 0)
            technikschild = feld
            gtk_overlay_add_overlay(OpaquePointer(spielerRahmen), feld)
            // **Direkt auf dem Film** (Mac, 22.09.2026): unter Titel, Knöpfen
            // und Leiste und damit auch unter den Ebenen und dem stehenden
            // Titel. GTK kennt kein „nach hinten legen", also vor die
            // Steuerung einhängen. Die Abdunklung ist hier Teil der
            // Steuerung (`.swiftly-steuerung`), das Schild liegt also unter
            // ihr — auf dem Mac liegt es darüber.
            if let davor = spielerSteuerung ?? offeneEbene ?? spielerTitelstand {
                gtk_widget_insert_before(feld, spielerRahmen, davor)
            }
            technikschildLage(sofort: true)
            technikschildNachfuehren()
        } else {
            if let feld = technikschild, spielerRahmen != nil {
                gtk_overlay_remove_overlay(OpaquePointer(spielerRahmen), feld)
            }
            technikschild = nil
            technikzaehler = nil
        }
    }

    /// **Es gleitet mit der Steuerung** (Mac, 22.09.2026): offen unter der
    /// Titelzeile, zu an den oberen Rand, wo sie stand — um `knopf +
    /// kachelAbstand` nach oben. Bewegung statt Blende, dieselbe Kurve und
    /// Dauer wie die Steuerung (`steuerungSichtbarkeit`, `titelstandNachfuehren`).
    /// Reduzierte Bewegung fragt Linux nirgends ab, also gibt es hier keinen
    /// Sonderweg.
    func technikschildLage(dauer: Double? = nil, sofort: Bool = false) {
        guard let feld = technikschild else { return }
        let offen = steuerungOffen && offeneEbeneArt == nil
        let ziel = schildOben - (offen ? 0 : Playermass.knopf + Int32(Stil.kachelAbstand))
        schildGleiten(feld, auf: ziel, dauer: sofort ? 0 : dauer ?? (offen ? 0.18 : 0.34),
                      kennlinie: dauer != nil || offen ? .easeOut : .easeInOut)
    }

    /// Wird im Wiedergabetakt gerufen — 500 ms, derselbe wie ueberall.
    func technikschildNachfuehren() {
        guard let feld = technikschild, let spalte = gtk_widget_get_first_child(feld) else { return }
        technikzaehler = abspieler.zaehlwerte.flatMap {
            Zaehlwerk($0, stelle: abspieler.position, laeuft: abspieler.laeuft,
                      vorher: technikzaehler)
        }
        leeren(spalte)
        let zeilen = technikschildZeilen()
        var widgets: [(Widget, Bool)] = []
        for z in zeilen {
            let w = schildWidget(z)
            anhaengen(spalte, w)
            widgets.append((w, z.kern))
        }
        // **Die Kernzeilen stehen immer, gekappt wird nur der Rest** (Mac:
        // `Kappliste`). Die Zusatzzeilen nimmt die Spalte von oben, solange
        // sie in 55 % der Höhe unter der Titelzeile passen, und hört bei der
        // ersten auf, die nicht mehr passt. Kein Scrollen.
        guard !technikschildMessen, let rahmen = spielerRahmen else { return }
        // Die angebotene Höhe ist die des Mac-Schilds: Rahmen minus der Lage
        // oben minus dem Innenabstand (10 oben, 10 unten).
        let angebot = Double(gtk_widget_get_height(rahmen) - schildOben - 20)
        guard angebot > 0 else { return }
        let grenze = angebot * technikschildHoechstanteil
        var summe = 0.0
        var voll = false
        for (w, kern) in widgets {
            var natuerlich: Int32 = 0
            gtk_widget_measure(w, GTK_ORIENTATION_VERTICAL, technikschildBreite,
                               nil, &natuerlich, nil, nil)
            let neu = summe + (summe == 0 ? 0 : Double(technikschildAbstand)) + Double(natuerlich)
            if !kern && (voll || neu > grenze) {
                voll = true
                gtk_widget_set_visible(w, 0)
                continue
            }
            summe = neu
        }
    }

    private func schildWidget(_ z: Schildzeile) -> Widget {
        if z.art == .linie {
            // **Eine Haarlinie, kein Abstand.** Darüber die Datei, darunter
            // was beim Laufen hochzählt. Mac: 150 × 1, senkrecht `abstand / 2`.
            let l = trennlinie()!
            gtk_widget_set_size_request(l, 150, 1)
            gtk_widget_set_halign(l, GTK_ALIGN_START)
            gtk_widget_set_margin_top(l, technikschildAbstand / 2)
            gtk_widget_set_margin_bottom(l, technikschildAbstand / 2)
            return l
        }
        let l: Widget = beschriftung("")
        gtk_label_set_markup(OpaquePointer(l), z.markup)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_wrap(OpaquePointer(l), 1)
        gtk_label_set_wrap_mode(OpaquePointer(l), PANGO_WRAP_WORD_CHAR)
        // Ohne das wuenscht sich ein umbrechendes Label die Breite seines
        // ganzen Textes, und die Spalte liefe hinaus. So gilt ihre Breite.
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        if z.art == .kopf { gtk_widget_add_css_class(l, "swiftly-technikkopf") }
        // Zwei Zeilen reichen für Art und Codec; der Rest der Klammer wird
        // gekürzt, ausserhalb des Messmodus (Mac: `lineLimit(messen ? nil : 2)`).
        if z.art == .grund, !technikschildMessen {
            gtk_label_set_lines(OpaquePointer(l), 2)
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        }
        return l
    }

    /// Die Zeilen in der Rangfolge des Macs (`Sources/Shared/Technikschild.swift`,
    /// `body`): Kern immer, alles für die Fehlersuche nur im Messmodus.
    private func technikschildZeilen() -> [Schildzeile] {
        let messen = technikschildMessen
        var zeilen: [Schildzeile] = []
        let plan = laufenderPlan
        let quelle = plan?.quelle
        let video = quelle.flatMap(Dateiangaben.videospur)
        let ton = quelle.flatMap { Dateiangaben.tonspuren($0).first }
        let untertitel = quelle.flatMap { Dateiangaben.untertitelspuren($0).first }

        if let plan {
            // **Das Wort traegt die Farbe** (D1): Akzent, wenn nichts
            // umgerechnet wird, sonst Warnorange.
            zeilen.append(Schildzeile(art: .kopf, markup: faerben(
                Technikangaben.auslieferung(plan.method),
                Technikangaben.gewicht(plan.method) == .gut ? Stil.akzent : Stil.warnung),
                kern: true))
            // **Und der Grund steht direkt darunter** (D2): wer
            // „Transkodiert" liest, will als Naechstes wissen, woran es lag.
            if plan.method == .transcode, let grund = plan.reasons.first {
                zeilen.append(Schildzeile(art: .grund, markup: faerben(grund.text, Stil.warnung),
                                          kern: true))
            }
        }

        // Codec, Auflösung und HDR-Art; die Bildrate nur im Messmodus.
        let bild = [
            Technikangaben.codecname(video?.codec),
            Technikangaben.bildzeile(breite: video?.width, hoehe: video?.height,
                                     tiefe: nil, umfang: nil),
            Technikangaben.dynamik(video),
            messen ? Technikangaben.bildrate(video?.bildrate).map { "\($0) fps" } : nil
        ].compactMap { $0 }
        if !bild.isEmpty {
            zeilen.append(angabe(uebersetzt("Bild"), bild.joined(separator: " · ")))
        }
        if let name = Technikangaben.codecname(ton?.codec) {
            var t = name
            if let k = Technikangaben.kanalwort(ton?.channels) { t += " · \(k)" }
            if let s = Technikangaben.sprache(ton?.language) { t += " · \(s)" }
            zeilen.append(angabe(uebersetzt("Ton"), t))
        }
        if let name = Technikangaben.codecname(untertitel?.codec) {
            var t = name
            if let s = Technikangaben.sprache(untertitel?.language) { t += " · \(s)" }
            zeilen.append(angabe(uebersetzt("Untertitel"), t))
        }
        // Container, Grösse und was die Datei im Mittel braucht.
        let jeSekunde = bytesJeSekunde()
        if let quelle, let c = Dateiangaben.container(quelle) {
            let t = Technikangaben.bitrate(jeSekunde.map { $0 * 8 }).map { "\(c) · Ø \($0)" } ?? c
            zeilen.append(angabe(uebersetzt("Datei"), t))
        }

        let w = technikzaehler
        if let w {
            // **Wie viel Vorrat vor der Nadel liegt, und was ankommt.**
            // Unter zwei Sekunden wird es knapp.
            let sekunden = jeSekunde.flatMap { w.vorratSekunden(bytesJeSekunde: $0) }
            var teile: [String] = []
            if let sekunden { teile.append(komma(sekunden) + " s") }
            if messen { teile.append("\(w.vorratBytes / 1024) KiB") }
            teile.append("\(uebersetzt("Eingang")) \(Technikangaben.bitrate(w.eingang) ?? "—")")
            zeilen.append(angabe(uebersetzt("Puffer"), teile.joined(separator: " · "),
                                 auffaellig: (sekunden ?? .infinity) < 2))
            // Ausserhalb des Messmodus nur, wenn etwas verloren ging.
            let verlust = w.roh.verworfen > 0 || w.roh.tonVerloren > 0
            if messen || verlust {
                zeilen.append(messzeile("\(uebersetzt("Verworfen")) \(w.roh.verworfen)"
                                        + " · \(uebersetzt("Ton weg")) \(w.roh.tonVerloren)",
                                        auffaellig: verlust))
            }
        }

        guard messen else { return zeilen }
        // Wo im Film wir stehen — damit ein Bildschirmfoto eine Stelle nennt.
        if abspieler.dauer > 1 {
            zeilen.append(messzeile("\(uebersetzt("Stelle")) \(Spielzeit.text(abspieler.position))"
                                    + " / \(Spielzeit.text(abspieler.dauer))", auffaellig: false))
        }
        guard let w else { return zeilen }
        zeilen.append(Schildzeile(art: .linie))
        let soll = video?.bildrate
        zeilen.append(messzeile("\(uebersetzt("Demuxer")) \(Technikangaben.bitrate(w.demuxer) ?? "—")",
                                auffaellig: false))
        // Zwei Bilder Abstand: darunter ist es die Kante des Messfensters und
        // kein Ereignis.
        let zeigtHinkt = if let ist = w.zeigtProSekunde, let soll { ist < soll - 2 } else { false }
        zeilen.append(messzeile("\(uebersetzt("Zeigt Ø")) \(zahl(w.zeigtProSekunde)) fps"
                                + " · \(uebersetzt("Gezeigt")) \(w.roh.gezeigt)", auffaellig: zeigtHinkt))
        // Unter 97 % ist kein Messrauschen mehr.
        zeilen.append(messzeile("\(uebersetzt("Lauf")) \(anteil(w.laufAnteil))",
                                auffaellig: (w.laufAnteil ?? 1) < 0.97))
        let dekHinkt = if let ist = w.dekodiertProSekunde, let soll { ist < soll - 2 } else { false }
        zeilen.append(messzeile("\(uebersetzt("Dekodiert Ø")) \(zahl(w.dekodiertProSekunde)) fps",
                                auffaellig: dekHinkt))
        zeilen.append(messzeile("\(uebersetzt("Beschädigt")) \(w.roh.beschaedigt)"
                                + " · \(uebersetzt("Sprünge")) \(w.roh.spruenge)",
                                auffaellig: w.roh.beschaedigt > 0 || w.roh.spruenge > 0))
        return zeilen
    }

    /// Eine Angabe für Zuschauer: Name leise, Wert hell. Fällt sie auf,
    /// steht sie ganz in `warnung` — wie `messzeile`. Kernzeile.
    private func angabe(_ name: String, _ wert: String, auffaellig: Bool = false) -> Schildzeile {
        if auffaellig {
            var z = messzeile("\(name) \(wert)", auffaellig: true)
            z.kern = true
            return z
        }
        return Schildzeile(markup: faerben(name, Stil.schriftLeise) + faerben(" \(wert)", Stil.schrift),
                           kern: true)
    }

    /// Eine Zusatzzeile — leise, oder warnend in Orange.
    private func messzeile(_ text: String, auffaellig: Bool) -> Schildzeile {
        Schildzeile(markup: faerben(text, auffaellig ? Stil.warnung : Stil.schriftLeise))
    }

    /// Groesse durch Laufzeit. `nil`, solange eins davon fehlt.
    private func bytesJeSekunde() -> Double? {
        guard let bytes = laufenderPlan?.quelle?.size, bytes > 0,
              abspieler.dauer > 1 else { return nil }
        return Double(bytes) / abspieler.dauer
    }

    /// Ein Stück Text in einer bestimmten Farbe.
    private func faerben(_ text: String, _ farbe: String) -> String {
        "<span foreground=\"\(farbe)\">\(schutz(text))</span>"
    }

    /// Pango liest `&`, `<` und `>` als Auszeichnung. Ein Dateiname mit
    /// Kaufmanns-Und wuerfe sonst das ganze Schild weg.
    private func schutz(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func komma(_ wert: Double) -> String {
        String(format: "%.1f", wert).replacingOccurrences(of: ".", with: ",")
    }

    private func zahl(_ w: Double?) -> String {
        guard let w else { return "—" }
        return komma(w)
    }

    private func anteil(_ w: Double?) -> String {
        guard let w else { return "—" }
        return "\(Int((w * 100).rounded())) %"
    }
}

// MARK: - Gleiten

/// Ein Lauf der oberen Kante. Je Widget gilt nur der jüngste — ein neuer
/// löst den alten ab, vom **jetzigen** Stand aus, wie bei `blenden`.
private final class Gleitlauf {
    let von: Double, nach: Double, dauer: Double
    let kennlinie: Kennlinie
    let nummer: Int
    let beginn = Date()
    init(von: Double, nach: Double, dauer: Double, kennlinie: Kennlinie, nummer: Int) {
        self.von = von; self.nach = nach; self.dauer = dauer
        self.kennlinie = kennlinie; self.nummer = nummer
    }
}

nonisolated(unsafe) private var gleitstand: [UnsafeMutableRawPointer: Int] = [:]
nonisolated(unsafe) private var gleitzaehler = 0

nonisolated(unsafe) private let gleitTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { widget, _, daten in
    guard let widget, let daten else { return 0 }
    let l = Unmanaged<Gleitlauf>.fromOpaque(daten).takeUnretainedValue()
    let schluessel = UnsafeMutableRawPointer(widget)
    guard gleitstand[schluessel] == l.nummer else { return 0 }
    let t = min(Date().timeIntervalSince(l.beginn) / l.dauer, 1)
    let wert = l.von + (l.nach - l.von) * l.kennlinie.wert(t)
    gtk_widget_set_margin_top(widget, Int32(wert.rounded()))
    if t >= 1 {
        gleitstand[schluessel] = nil
        return 0
    }
    return 1
}

nonisolated(unsafe) private let gleitFreigeben: @convention(c) (gpointer?) -> Void = { daten in
    guard let daten else { return }
    Unmanaged<Gleitlauf>.fromOpaque(daten).release()
}

/// Schiebt die obere Kante im Bildtakt des Fensters. Ist das Widget nicht
/// abgebildet, gilt der Wert sofort — dort gäbe es keinen Takt.
private func schildGleiten(_ widget: Widget, auf ziel: Int32, dauer: Double, kennlinie: Kennlinie) {
    let schluessel = UnsafeMutableRawPointer(widget)
    gleitzaehler += 1
    let nummer = gleitzaehler
    gleitstand[schluessel] = nummer
    let von = gtk_widget_get_margin_top(widget)
    guard dauer > 0, von != ziel, gtk_widget_get_mapped(widget) != 0 else {
        gleitstand[schluessel] = nil
        gtk_widget_set_margin_top(widget, ziel)
        return
    }
    let lauf = Gleitlauf(von: Double(von), nach: Double(ziel), dauer: dauer,
                         kennlinie: kennlinie, nummer: nummer)
    _ = gtk_widget_add_tick_callback(widget, gleitTakt,
                                     Unmanaged.passRetained(lauf).toOpaque(), gleitFreigeben)
}
