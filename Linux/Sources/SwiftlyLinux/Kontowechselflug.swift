import CGtk
import Foundation
import JellyfinKit

/// **Der laufende Kontowechsel mit Flug** — Stand zwischen Klick und Ruhe.
final class Kontoflug {
    let kurve: Kontowechselkurve?
    let beginn = Date()
    /// Das fliegende Profilbild — eine Ebene über dem ganzen Fenster.
    var flieger: (huelle: Widget, bild: Widget, zeichen: Widget)?
    /// Das Bild, auf das geklickt wurde; es steht leer, solange es fliegt.
    var quelle: Widget?
    /// Der eigentliche Wechsel, einmal.
    var wechseln: (() -> Void)?
    var getauscht = false
    var geploppt = false
    var takt: guint = 0
    /// Bis zum Tausch halten die Reihen der Startseite still.
    var reihenHalten = true
    var wartendeReihen: (reihen: [(String, Reihenart, [Item])], gestoert: Bool)?

    init(kurve: Kontowechselkurve?) { self.kurve = kurve }
    var seit: Double { Date().timeIntervalSince(beginn) }
}

/// **Der Kontowechsel als Bewegung** (Entwurf D, Paul 26.09.2026; Vorlage
/// `Kontowechselflug` am iPhone, seit 1.0.5 auch am Fernseher).
///
/// 1. **Klick** auf ein Konto im Profil: die Seite blendet aus (wie am
///    Fernseher — der Schreibtisch schiebt keine Standbilder weg), der alte
///    Inhalt ist sofort weg, und das Profilbild hebt ab und fliegt im Bogen
///    auf den Kreis unten in der Seitenleiste
///    (``Kontowechselkurve``, dieselben Federn wie am iPhone).
/// 2. **Wechsel** 0,3 s bevor es ruht (``Kontowechselkurve/wechsel``).
/// 3. **Tausch**, wenn es ruht: dort steht das echte Bild; bei der Landung
///    ploppt der Ring.
/// 4. **Reihen**: 30 ms danach gestaffelt, 80 ms je Reihe.
///
/// **Das Profil ist sofort wieder erreichbar**: öffnet es jemand mitten im
/// Flug, geschieht alles Ausstehende auf einmal (``kontoflugAbschliessen``).
/// **Bewegung reduzieren** (`gtk-enable-animations`): kein Flug, nur
/// Überblenden, wie am iPhone.
///
/// Hier stand vorher ein Wechsel an Ort und Stelle: das Profil baute sich
/// neu, Ring und Punkt wanderten zum anderen Konto. Das war die Fassung vor
/// Entwurf D.
extension App {

    func kontoWechselnMitFlug(zu kennung: String, konto: Session, von quelle: Widget!) {
        guard kontoflug == nil else {
            Protokoll.schreib("[Kontowechsel] zweiter Klick ignoriert")
            return
        }
        guard let neu = bund, neu.aktiveKennung != kennung, neu.konto(kennung) != nil else { return }
        let ruhig = bewegungReduziert()

        // Wo das Bild steht und wohin es fliegt — in Punkten der Fensterdecke.
        var kurve: Kontowechselkurve?
        if !ruhig, let decke = fensterdecke, let quelle, let ziel = profilkreise {
            var a = graphene_rect_t(), b = graphene_rect_t()
            if gtk_widget_compute_bounds(quelle, decke, &a) != 0,
               gtk_widget_compute_bounds(ziel, decke, &b) != 0, a.size.width > 0 {
                // Der vordere Kreis steht 2 Punkt im Feld (Ring), 26 gross.
                let zielgroesse = 26.0
                kurve = Kontowechselkurve(
                    von: (Double(a.origin.x + a.size.width / 2), Double(a.origin.y + a.size.height / 2)),
                    groesse: Double(a.size.width),
                    nach: (Double(b.origin.x) + 2 + zielgroesse / 2, Double(b.origin.y) + 2 + zielgroesse / 2),
                    zielgroesse: zielgroesse)
            }
        }
        let flug = Kontoflug(kurve: kurve)
        kontoflug = flug
        flug.wechseln = { [weak self] in self?.kontoWechseln(zu: kennung, imProfilBleiben: false) }
        Protokoll.schreib("[Kontowechsel] 1: klick, flug \(kurve == nil ? "aus" : "an")"
            + (kurve.map { String(format: ", wechsel %.2f s, tausch %.2f s, landung %.2f s", $0.wechsel, $0.tausch, $0.landung) } ?? ""))

        // Das fliegende Bild: dasselbe Bild aus demselben Speicher.
        if let kurve, let decke = fensterdecke {
            let teile = profilzeichen(name: konto.userName, kante: Int(kurve.groesse),
                                      stil: "swiftly-kontoflug", schriftstil: "swiftly-zeichen26")
            profilbildLaden(teile, url: adressen?.benutzer(konto.userID, kante: 200),
                            schluessel: "konto-\(konto.userID)")
            gtk_widget_set_halign(teile.huelle, GTK_ALIGN_START)
            gtk_widget_set_valign(teile.huelle, GTK_ALIGN_START)
            gtk_widget_set_can_target(teile.huelle, 0)
            gtk_overlay_add_overlay(OpaquePointer(decke), teile.huelle)
            flug.flieger = teile
            fliegerSetzen(flug, kurve.lage(0))
            if let quelle { gtk_widget_set_opacity(quelle, 0); flug.quelle = quelle }
            // Das echte Bild unten wartet, bis das fliegende dort ruht.
            if let ziel = profilkreise { gtk_widget_set_opacity(ziel, 0) }
        }

        // Die Seite blendet aus, der alte Inhalt ist sofort weg: der Stapel
        // geht auf den Bereich zurück, die Reihen sind leer.
        if let b = buehne { blenden(b, auf: 0, dauer: ruhig ? Stil.zeitReduziert : 0.2, kennlinie: .easeInOut) }
        nachFrist(ruhig ? Stil.zeitReduziert : 0.22) { [weak self] in
            guard let self, self.kontoflug === flug else { return }
            if let r = self.reihenstapel { leeren(r) }
            Protokoll.schreib("[Kontowechsel] 1b: seite aus, reihen leer")
        }

        // **Die Stufen an der Uhr, die Lage am Bildtakt.** Der Bildtakt
        // setzt aus, wenn das Fenster nicht zeichnet (verdeckt, headless);
        // Wechsel und Tausch sollen trotzdem zu ihrer Zeit kommen.
        let wechsel = kurve?.wechsel ?? 0.15
        let tausch = kurve?.tausch ?? 0.2
        let landung = kurve?.landung
        let ende = kurve.map { max($0.ringEnde, $0.tausch) + 0.1 } ?? 0.3
        nachFrist(wechsel) { [weak self] in
            guard let self, self.kontoflug === flug else { return }
            self.wechselAusfuehren(flug)
        }
        nachFrist(tausch) { [weak self] in
            guard let self, self.kontoflug === flug, !flug.getauscht else { return }
            self.tauschen(flug)
        }
        if let landung {
            nachFrist(landung) { [weak self] in
                guard let self, self.kontoflug === flug, !flug.geploppt else { return }
                self.ringPloppen(flug)
            }
        }
        nachFrist(ende) { [weak self] in self?.kontoflugBeenden(flug) }
        guard kurve != nil, let decke = fensterdecke else { return }
        flug.takt = gtk_widget_add_tick_callback(decke, kontoflugTakt,
                                                 Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Ein Bild des Flugs — im Takt des Fensters; nur die Lage.
    fileprivate func kontoflugSchritt() -> Bool {
        guard let flug = kontoflug, let kurve = flug.kurve, !flug.getauscht else { return false }
        fliegerSetzen(flug, kurve.lage(flug.seit))
        return true
    }

    private func fliegerSetzen(_ flug: Kontoflug, _ lage: (x: Double, y: Double, s: Double)) {
        guard let teile = flug.flieger else { return }
        let s = max(lage.s, 1)
        gtk_widget_set_margin_start(teile.huelle, Int32(max(0, (lage.x - s / 2).rounded())))
        gtk_widget_set_margin_top(teile.huelle, Int32(max(0, (lage.y - s / 2).rounded())))
        // Die Groesse steht an der leeren Box, die das Mass vorgibt.
        if let mass = gtk_widget_get_first_child(teile.huelle) {
            gtk_widget_set_size_request(mass, Int32(s.rounded()), Int32(s.rounded()))
        }
    }

    private func wechselAusfuehren(_ flug: Kontoflug) {
        guard let w = flug.wechseln else { return }
        flug.wechseln = nil
        let a = Date()
        Protokoll.schreib(String(format: "[Kontowechsel] 2: konto wechselt (%.2f s nach klick)", flug.seit))
        w()
        Protokoll.schreib("[Kontowechsel] 2a: wechsel im hauptfaden \(Int(Date().timeIntervalSince(a) * 1000)) ms")
    }

    /// Das Bild ruht: dort steht jetzt das echte, die Seite kommt zurück, und
    /// die Reihen dürfen kommen.
    private func tauschen(_ flug: Kontoflug) {
        flug.getauscht = true
        if let teile = flug.flieger {
            if let decke = fensterdecke { gtk_overlay_remove_overlay(OpaquePointer(decke), teile.huelle) }
            flug.flieger = nil
        }
        if let ziel = profilkreise { gtk_widget_set_opacity(ziel, 1) }
        if let q = flug.quelle { gtk_widget_set_opacity(q, 1); flug.quelle = nil }
        if let b = buehne { blenden(b, auf: 1, dauer: bewegungReduziert() ? Stil.zeitReduziert : 0.26) }
        Protokoll.schreib(String(format: "[Kontowechsel] 4: bild ruht, tausch (%.2f s nach klick)", flug.seit))
        nachFrist(Kontowechselkurve.reihenNachTausch) { [weak self] in
            guard let self else { return }
            self.reihenFreigeben(flug, gestaffelt: true)
        }
    }

    private func reihenFreigeben(_ flug: Kontoflug, gestaffelt: Bool) {
        guard flug.reihenHalten else { return }
        flug.reihenHalten = false
        Protokoll.schreib("[Kontowechsel] 5: reihen duerfen kommen\(flug.wartendeReihen == nil ? " (noch nicht geladen)" : "")")
        if let w = flug.wartendeReihen {
            flug.wartendeReihen = nil
            reihenZeigen(w.reihen, gestoert: w.gestoert, gestaffelt: gestaffelt)
        } else if gestaffelt, bereich == .start {
            // Kommen sie später, kommen sie trotzdem gestaffelt.
            kontoflugStaffelNachzuegler = true
        }
    }

    /// Der Ring ploppt am vorderen Kreis, wenn das Bild landet.
    private func ringPloppen(_ flug: Kontoflug) {
        flug.geploppt = true
        guard let kreise = profilkreise, let vorn = gtk_widget_get_last_child(kreise) else { return }
        gtk_widget_add_css_class(vorn, "swiftly-ringpop")
        let kiste = gehalten(vorn)
        nachFrist(0.8) {
            gtk_widget_remove_css_class(kiste.widget, "swiftly-ringpop")
            losgelassen(kiste)
        }
    }

    private func kontoflugBeenden(_ flug: Kontoflug) {
        guard kontoflug === flug else { return }
        if flug.takt != 0, let decke = fensterdecke { gtk_widget_remove_tick_callback(decke, flug.takt) }
        flug.takt = 0
        kontoflug = nil
        Protokoll.schreib(String(format: "[Kontowechsel] ende (%.2f s)", flug.seit))
    }

    /// **Alles Ausstehende sofort** — das Profil wurde mitten im Flug
    /// geöffnet (iOS `abschliessen`). Das Konto wechselt jetzt, das fliegende
    /// Bild geht, das echte steht, und die Startseite baut ihre Reihen
    /// darunter, ohne Staffel.
    func kontoflugAbschliessen() {
        guard let flug = kontoflug else { return }
        Protokoll.schreib("[Kontowechsel] profil geoeffnet, rest sofort")
        if flug.takt != 0, let decke = fensterdecke { gtk_widget_remove_tick_callback(decke, flug.takt) }
        flug.takt = 0
        wechselAusfuehren(flug)
        if !flug.getauscht {
            flug.getauscht = true
            if let teile = flug.flieger, let decke = fensterdecke {
                gtk_overlay_remove_overlay(OpaquePointer(decke), teile.huelle)
            }
            flug.flieger = nil
            if let ziel = profilkreise { gtk_widget_set_opacity(ziel, 1) }
            if let q = flug.quelle { gtk_widget_set_opacity(q, 1) }
            if let b = buehne { gtk_widget_set_opacity(b, 1) }
        }
        kontoflug = nil
        reihenFreigeben(flug, gestaffelt: false)
    }

    /// **Eine Reihe ploppt ein** (iOS `Reihenauftritt`): 80 ms je Reihe,
    /// Deckkraft linear in 0,22 s, von 14 Punkt tiefer und 96 % Größe. Das
    /// Stilblatt trägt die Kurve; bei „Bewegung reduzieren" schaltet GTK die
    /// Übergänge selbst ab.
    ///
    /// **Die Frist läuft am Bildtakt, nicht an der Uhr.** Hier stand
    /// `nachFrist`: die Klasse ging nach 30 ms + 80 ms je Reihe weg. Das
    /// Bauen der Reihen dauert aber länger — die ersten Fristen waren
    /// abgelaufen, bevor GTK die Reihe ein einziges Mal mit `reihe-vor`
    /// ausgelegt hatte. Ohne Ausgangszustand gibt es keinen Übergang, und die
    /// Reihen standen schlagartig da. Jetzt zählt die Frist ab dem ersten
    /// gezeichneten Bild (``laufen(auf:dauer:linear:schritt:fertig:)``), und
    /// die Klasse fällt frühestens im Bild danach.
    func reiheAuftreten(_ reihe: Widget!, nummer: Int) {
        gtk_widget_add_css_class(reihe, "swiftly-reihenauftritt")
        gtk_widget_add_css_class(reihe, "swiftly-reihe-vor")
        let kiste = gehalten(reihe)
        let verzug = Kontowechselkurve.reihenNachTausch + Double(nummer) * Kontowechselkurve.reihenStaffel
        laufen(auf: reihe, dauer: verzug, linear: true) { _ in } fertig: {
            gtk_widget_remove_css_class(kiste.widget, "swiftly-reihe-vor")
            losgelassen(kiste)
        }
    }
}

nonisolated(unsafe) private let kontoflugTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    let app = Unmanaged<App>.fromOpaque(daten).takeUnretainedValue()
    let weiter = app.kontoflugSchritt()
    if !weiter, let flug = app.kontoflug { flug.takt = 0 }
    return weiter ? 1 : 0
}
