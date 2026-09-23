import CGtk
import Foundation
import JellyfinKit

/// **„Intro überspringen", „Abspann überspringen", „Nächste Folge"** — der
/// Chip des Players, mit Countdown als Füllung von links.
///
/// Es gibt ihn zweimal: im Fuß der Steuerung, wo er immer stand, und als
/// eigene Ebene über dem Bild, die bei zugeklappter Steuerung von selbst
/// erscheint (Stufe 3, 16.09.2026: „Bei Netflix poppt der Button zur
/// richtigen Zeit auf"). Vorlage ist der Mac: `Chip(fuellung:)` in
/// `Sources/macOS/Macbausteine.swift`, die Einblendung in
/// `Sources/macOS/PlayerScreen.swift` (`karteDa`, `angebotChip`).
///
/// Wann was steht, entscheidet das Paket — ``Abschnittslogik`` und
/// ``Angebotsebene``. Hier steht nur die Darstellung.
final class Angebotsknopf {
    private(set) var knopf: Widget!
    private var bild: Widget!
    private var text: Widget!
    private var innen: Widget!
    private var fuellung: Widget!
    private var gezeigt: Knopfangebot = .keiner
    /// Die Füllung als durchgehende Bewegung (`Fuellungsuhr`), am Bildtakt
    /// des Fensters nachgezogen statt im halben Sekundentakt (17.09.2026).
    fileprivate var uhr: Fuellungsuhr?
    private var takt: guint = 0

    init(_ ausloesen: @escaping () -> Void) {
        // **Weiss, dunkle Schrift** — wörtlich die Pille vom Mac
        // (`PlayerScreen.swift:1326`): „die Akzentfarbe gehört im Player
        // allein dem Griff der Leiste beim Ziehen". `aktiv: true` ist hier
        // kein Auswahlzustand, sondern die feste Grundfarbe dieses Chips.
        knopf = chip(uebersetzt("Nächste Folge"), symbol: "media-skip-forward-symbolic", aktiv: true)
        // **Die Füllung reicht bis an den Rand**, also sitzt der seitliche
        // Abstand am Inhalt statt am Knopf; die Kapsel schneidet sie rund.
        gtk_widget_add_css_class(knopf, "swiftly-angebot")
        gtk_widget_set_overflow(knopf, GTK_OVERFLOW_HIDDEN)
        guard let reihe = gtk_widget_get_first_child(knopf) else { return }
        // **Das eigene Zeichen** statt des Systemsymbols (Mac:
        // `forward.end.fill`), dunkel auf der weissen Fläche.
        if let alt = gtk_widget_get_first_child(reihe) { gtk_box_remove(alsBox(reihe), alt) }
        let zeichen = Playerzeichen("weiter", groesse: 16, farbe: (0.043, 0.043, 0.051, 1))
        gtk_box_prepend(alsBox(reihe), zeichen.anzeige)
        bild = zeichen.anzeige
        text = gtk_widget_get_last_child(reihe)
        g_object_ref(UnsafeMutableRawPointer(reihe))
        gtk_button_set_child(alsKnopf(knopf), nil)
        gtk_widget_set_margin_start(reihe, 18)
        gtk_widget_set_margin_end(reihe, 18)
        gtk_box_set_spacing(alsBox(reihe), 8)

        innen = gtk_overlay_new()
        let grund = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        fuellung = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_add_css_class(fuellung, "swiftly-angebotfuellung")
        gtk_widget_set_halign(fuellung, GTK_ALIGN_START)
        gtk_widget_set_visible(fuellung, 0)
        anhaengen(grund, fuellung)
        gtk_overlay_set_child(OpaquePointer(innen), grund)
        gtk_overlay_add_overlay(OpaquePointer(innen), reihe)
        gtk_overlay_set_measure_overlay(OpaquePointer(innen), reihe, 1)
        g_object_unref(UnsafeMutableRawPointer(reihe))
        gtk_button_set_child(alsKnopf(knopf), innen)

        beschriften(knopf, uebersetzt("Nächste Folge"))
        gtk_widget_set_visible(knopf, 0)
        beiSignal(knopf, "clicked", ausloesen)
        // Die Seite räumt den Knopf mit ab; danach zeigt hier nichts mehr hin.
        beiSignal(knopf, "destroy") { [weak self] in
            self?.takt = 0
            self?.knopf = nil; self?.bild = nil; self?.text = nil
            self?.innen = nil; self?.fuellung = nil
        }
    }

    /// Beschriftung, Zeichen und Name für Vorlesehilfen (E8) — nur, wenn sich
    /// das Angebot geändert hat. `countdown` ist der Anteil von 0 bis 1.
    func setzen(_ angebot: Knopfangebot, sichtbar: Bool, fuellung neu: Fuellungsuhr? = nil,
                blende: Bool = false) {
        guard knopf != nil else { return }
        if blende {
            // Bleibt eingehängt und blendet über Deckkraft, mit derselben
            // Übergangszeit wie die Steuerung (`.swiftly-steuerung`, 180 ms).
            let an = sichtbar && angebot.sichtbar
            gtk_widget_set_visible(knopf, angebot.sichtbar || gezeigt.sichtbar ? 1 : 0)
            gtk_widget_set_opacity(knopf, an ? 1 : 0)
            gtk_widget_set_can_target(knopf, an ? 1 : 0)
        } else {
            gtk_widget_set_visible(knopf, sichtbar && angebot.sichtbar ? 1 : 0)
        }
        if angebot.sichtbar, angebot != gezeigt {
            gezeigt = angebot
            gtk_label_set_text(OpaquePointer(text), angebot.beschriftung)
            beschriften(knopf, angebot.beschriftung)
        }
        uhr = neu
        if uhr != nil {
            fuellungZeichnen()
            if takt == 0 {
                takt = gtk_widget_add_tick_callback(knopf, fuellungsTakt,
                                                    Unmanaged.passUnretained(self).toOpaque(), nil)
            }
        } else {
            if takt != 0 { gtk_widget_remove_tick_callback(knopf, takt); takt = 0 }
            gtk_widget_set_visible(fuellung, 0)
        }
    }

    fileprivate func fuellungZeichnen() {
        guard let uhr, innen != nil, gtk_widget_get_width(innen) > 0 else { return }
        gtk_widget_set_visible(fuellung, 1)
        gtk_widget_set_size_request(fuellung,
                                    Int32((Double(gtk_widget_get_width(innen)) * uhr.anteil()).rounded()), -1)
    }
}

nonisolated(unsafe) private let fuellungsTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    Unmanaged<Angebotsknopf>.fromOpaque(daten).takeUnretainedValue().fuellungZeichnen()
    return 1
}

extension App {

    /// Sekunden je Takt — dieselbe Zahl, mit der der Takt läuft.
    static var taktSekunden: Double {
        let t = Wiedergabetakt.taktlaenge.components
        return Double(t.seconds) + Double(t.attoseconds) / 1e18
    }

    /// Ob am Ende von selbst weitergeschaltet wird: eigene Wahl vor
    /// Konto-Einstellung vor „an" (`Weiterschalten`, wie `AppModel` auf Apple).
    var naechsteAutomatisch: Bool {
        Weiterschalten.gilt(eigeneWahl: wahlen.naechsteAutomatischGewaehlt,
                            konto: naechsteAutomatischKonto)
    }

    /// `EnableNextEpisodeAutoPlay` und das Downloadrecht nebenher holen, ohne
    /// Fehlermeldung: kommt nichts, bleibt es bei der eigenen Wahl oder „an"
    /// und beim Recht `.unbekannt`, also erlaubt. **Eine Anfrage fuer beides.**
    func kontovorgabenHolen(_ c: JellyfinClient) {
        Task.detached { [self] in
            let vorgaben = await c.kontovorgaben()
            let konto = vorgaben?.naechsteFolgeAutomatisch
            let recht = vorgaben?.downloadrecht ?? .unbekannt
            let umwandeln = vorgaben?.umwandelnErlaubt ?? true
            aufHauptfaden {
                // Inzwischen ein anderes Konto: dessen Vorgabe kommt selbst.
                guard self.client === c else { return }
                self.naechsteAutomatischKonto = konto
                self.downloadrecht = recht
                self.umwandelnErlaubt = umwandeln
                Protokoll.schreib("[Konto] Nächste Folge automatisch: \(konto.map { String($0) } ?? "nil"), gilt \(self.naechsteAutomatisch), Downloads: \(recht.rawValue)")
                fflush(nil)
                // Die offene Seite hat den Knopf vielleicht schon gebaut.
                self.staffelladeknopfMalen()
            }
        }
    }

    /// Die Steuerung ist zu sehen. Sie blendet über die Deckkraft aus, nicht
    /// über die Sichtbarkeit — sie bleibt dabei ausgelegt.
    /// Der Zustand, nicht die Deckkraft — die ist während einer Blende ein
    /// Zwischenwert.
    private var steuerungDa: Bool {
        spielerSteuerung != nil && steuerungOffen && offeneEbeneArt == nil
    }

    /// **Der Angebotsknopf steht, an einer Stelle, egal ob die Steuerung offen
    /// ist** (Mac: `angebotDa`, 17.09.2026): Überspringen die ersten
    /// sechs Sekunden des Abschnitts, danach nur mit der Steuerung
    /// (`Angebotsebene.knopfdauer`); die Karte bei geschlossener Steuerung, bei offener der
    /// normale Knopf „Nächste Folge". Der Knopf im Fuß hält nur den Platz.
    var angebotDa: Bool {
        guard laufenderTitel != nil, jetzigesAngebot.sichtbar, spielerLadeschirm == nil,
              offeneEbene == nil, !folgenwechsel.laeuft else { return false }
        return angebotsebene.anzeige.sichtbar || (steuerungDa && jetzigesAngebot == .naechsteFolge)
    }

    /// **Die Einblendung steht ohne Steuerung im Bild** — daran hängen die
    /// Tasten (Mac: `karteDa`).
    var angebotImBild: Bool {
        guard laufenderTitel != nil, spielerLadeschirm == nil,
              offeneEbene == nil, !folgenwechsel.laeuft else { return false }
        // Die Karte steht auch über einer nur durch den Zeiger geöffneten Steuerung.
        if case .karte = angebotsebene.anzeige { return true }
        return angebotsebene.anzeige.sichtbar && !steuerungDa
    }

    /// Beide Knöpfe auf den Stand von Angebot und Ebene bringen.
    func angebotNachfuehren() {
        // Die Ebene hoert auf die Steuerung — hier nur Abgleich, weil jedes Ein-
        // und Ausblenden hier vorbeikommt. Ob das Oeffnen die Karte absagt,
        // entscheidet `steuerungZeigen(durch:)`.
        if laufenderTitel != nil { angebotsebene.steuerung(offen: steuerungDa, durch: .nebenbei) }
        var countdown: Double?
        if case let .karte(anteil) = angebotsebene.anzeige { countdown = anteil }
        angebotsuhr.stellen(anteil: countdown,
                            laeuft: spielstand.laeuft && spielerLadeschirm == nil && !amRegler,
                            laenge: angebotsebene.countdownLaenge)
        // Im Fuß nur der Platz: unsichtbar und nicht anklickbar.
        spielerWeiter?.setzen(jetzigesAngebot, sichtbar: true)
        if let fuss = spielerWeiter?.knopf {
            gtk_widget_set_opacity(fuss, 0)
            gtk_widget_set_can_target(fuss, 0)
        }

        guard let ebene = spielerAngebot, ebene.knopf != nil else { return }
        let zeigen = angebotDa
        // **An die Stelle des Knopfs im Fuß.** Geht die Steuerung auf, weil
        // der Zeiger sich zum Knopf bewegt, steht dort derselbe Knopf — der
        // Klick trifft, statt ins Leere zu gehen.
        if zeigen, let fuss = spielerWeiter?.knopf, let rahmen = spielerRahmen,
           gtk_widget_get_visible(fuss) != 0 {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(fuss, rahmen, &r) != 0, r.size.width > 0 {
                let rechts = Double(gtk_widget_get_width(rahmen)) - Double(r.origin.x + r.size.width)
                let unten = Double(gtk_widget_get_height(rahmen)) - Double(r.origin.y + r.size.height)
                gtk_widget_set_margin_end(ebene.knopf, Int32(max(0, rechts).rounded()))
                gtk_widget_set_margin_bottom(ebene.knopf, Int32(max(0, unten).rounded()))
            }
        }
        let vorher = gtk_widget_get_opacity(ebene.knopf) > 0.5 && gtk_widget_get_visible(ebene.knopf) != 0
        ebene.setzen(jetzigesAngebot, sichtbar: zeigen,
                     fuellung: countdown == nil ? nil : angebotsuhr, blende: true)
        if vorher != zeigen {
            Protokoll.schreib("[Angebot] Einblendung \(zeigen ? "an" : "aus"): \(jetzigesAngebot.beschriftung)\(countdown != nil ? " mit Countdown" : "") bei \(Int(spielstand.position)) s, Steuerung \(steuerungDa ? "offen" : "zu")")
            fflush(nil)
        }
    }

    /// Die Ebene über dem Bild anlegen — über der Steuerung, unten rechts.
    func angebotsebeneBauen(in rahmen: Widget!) {
        let ebene = Angebotsknopf { [weak self] in self?.angebotAusfuehren() }
        gtk_widget_set_halign(ebene.knopf, GTK_ALIGN_END)
        gtk_widget_set_valign(ebene.knopf, GTK_ALIGN_END)
        gtk_widget_add_css_class(ebene.knopf, "swiftly-angebotblende")
        // Bis die Lage des Fußknopfs bekannt ist, die Maße des Macs.
        gtk_widget_set_margin_end(ebene.knopf, 28)
        gtk_widget_set_margin_bottom(ebene.knopf, 26 + 38)
        gtk_overlay_add_overlay(OpaquePointer(rahmen), ebene.knopf)
        spielerAngebot = ebene
    }
}
