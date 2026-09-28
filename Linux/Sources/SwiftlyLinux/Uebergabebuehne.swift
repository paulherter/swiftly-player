import CGtk
import Foundation
import JellyfinKit

/// **Der laufende Stand einer Übergabe** — Empfänger oder Abgeber, zwischen
/// Klick bzw. Stopp und abgeräumter Bühne.
final class Uebergabelauf {
    enum Rolle { case empfaenger, abgeber }

    let rolle: Rolle
    let reduziert: Bool
    /// Wie am Mac: ein Schreibtisch trägt die Maße des Mac.
    let masse = Uebergabekarte.mac
    let beginn = g_get_monotonic_time()
    var titelID: String?

    /// Die Ebene über allem, als Überzug der ``App/fensterdecke``.
    var buehne: Widget!
    var grund: Widget!
    var schwarz: Widget!
    var fest: Widget!
    var karte: Widget!
    var bild: Widget!
    var zeilen: Widget!
    var linie: Widget!
    var balken: Widget!
    var takt: guint = 0
    /// Die Eckenstufe, die gerade als Klasse an der Karte hängt.
    var ecke = -1
    var schirm = (breite: 0.0, hoehe: 0.0)

    var von = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    var ruhe = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    var voll = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    /// Wann der (letzte) Flug begann — nach einer Größenänderung neu.
    var flugAb = Uebergabekarte.kartenStart

    // Empfänger
    var bereit: Double?
    var zoomAb: Double?
    var zoomVon = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    var zoomSchwung = Uebergabekarte.Lage(x: 0, y: 0, breite: 0)
    var linieAb: Double?
    var abgebrochen = false

    // Abgeber
    /// Seitenverhältnis des abgehenden Bilds (Breite durch Höhe).
    var seiten = 16.0 / 9
    var richtung = Uebergabekarte.Richtung.oben
    var raus = 0.0
    /// Ab hier blendet der Grund auf die Seite aus (der Player ist zu).
    var grundAusAb: Double?

    init(rolle: Rolle, reduziert: Bool, titelID: String?) {
        self.rolle = rolle
        self.reduziert = reduziert
        self.titelID = titelID
    }

    /// Sekunden seit dem Klick (Empfänger) bzw. dem Stopp (Abgeber).
    var jetzt: Double { Double(g_get_monotonic_time() - beginn) / 1_000_000 }
}

/// **„Hier weiterschauen" als Karte** (Entwurf B, Paul 27.09.2026) — die
/// Linux- und Windows-Fassung von `Sources/Shared/Uebergabebuehne.swift`.
///
/// **Empfänger:** Klick aufs Abzeichen — die Seite tritt zurück, eine Karte
/// mit dem Folgenbild wächst aus dem Abzeichen in die Mitte, Titel und Folge
/// darunter; sie schwebt, bis der Player darunter sein erstes Bild hat, und
/// zoomt dann aufs ganze Bild.
///
/// **Abgeber:** das Spiegelbild — das stehende Bild schrumpft zur Karte,
/// schwebt kurz und fliegt hinaus (zum größeren Gerät nach oben, zum
/// kleineren nach unten, ``Uebergabekarte/abflugNachOben(von:nach:)``); dann
/// schließt der Player unter der Bühne.
///
/// Alle Zeiten und Federn kommen aus dem Paket (``Uebergabekarte``). Bewegt
/// werden **nur Lage, Größe und Deckkraft**, im Takt des Fensters
/// (`gtk_widget_add_tick_callback`); die Ecke folgt der Größe in ganzen
/// Stufen als Klasse. Die Stufen des Ablaufs hängen an der Uhr
/// (``nachFrist(_:_:)``), nicht am Bildtakt — der setzt aus, wenn das
/// Fenster nicht zeichnet. Mit reduzierter Bewegung wird nur überblendet.
extension App {

    /// Wie dieses Gerät im Übernahme-Hinweis heißt — für die Abflugrichtung
    /// drüben zählt es als Schreibtisch wie ein Mac.
    static var uebergabeName: String { Plattform.system }

    // MARK: Empfänger

    /// **Beim Klick** — noch bevor das Netz gefragt ist.
    func uebergabeStarten(titel: Item?) {
        uebergabeAbraeumen()
        let lauf = Uebergabelauf(rolle: .empfaenger, reduziert: bewegungReduziert(),
                                 titelID: titel?.id)
        guard uebergabeBuehneBauen(lauf) else { return }
        let (b, h) = lauf.schirm
        lauf.voll = Uebergabekarte.vollbild(breite: b, hoehe: h)
        lauf.ruhe = Uebergabekarte.ruhelage(breite: b, hoehe: h, masse: lauf.masse)
        lauf.von = lauf.ruhe
        // Aus dem Abzeichen, so breit wie am Mac (32).
        if !lauf.reduziert, let decke = fensterdecke, let zeile = uebernahmezeile {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(zeile, decke, &r) != 0, r.size.width > 0 {
                lauf.von = .init(x: Double(r.origin.x + r.size.width / 2),
                                 y: Double(r.origin.y + r.size.height / 2), breite: 32)
            }
        }
        if let titel {
            uebergabeZeilenSetzen(lauf, titel)
            if let url = uebergabeKartenbild(titel) {
                bildLaden(lauf.bild, url: url, schluessel: Bildschluessel.fuer(url),
                          sofort: true, kante: 1280)
            }
        }
        uebergabe = lauf
        uebergabeTaktStarten(lauf)
        uebergabeZeit(lauf, lauf.reduziert ? "blendet auf (reduziert)" : "wächst aus dem Abzeichen")

        // Die Ladelinie nur, wenn das Bild bei 0,75 s noch fehlt.
        nachFrist(Uebergabekarte.ladelinieAb) { [weak self] in
            guard let self, self.uebergabe === lauf, lauf.zoomAb == nil, !lauf.reduziert,
                  Uebergabekarte.ladelinie(bereit: lauf.bereit) else { return }
            lauf.linieAb = lauf.jetzt
            self.uebergabeZeit(lauf, "Ladelinie")
        }
    }

    /// **Der Player steht** (unsichtbar unter der Karte). Ab hier wartet die
    /// Karte höchstens ``Uebergabekarte/hoechstensWarten`` aufs erste Bild.
    func uebergabeSpielerKommt(_ itemID: String) {
        guard let lauf = uebergabe, lauf.rolle == .empfaenger, !lauf.abgebrochen else { return }
        lauf.titelID = itemID
        uebergabeZeit(lauf, "Player geöffnet")
        nachFrist(Uebergabekarte.hoechstensWarten) { [weak self] in
            guard let self, self.uebergabe === lauf, lauf.zoomAb == nil, !lauf.abgebrochen else { return }
            self.uebergabeZeit(lauf, "kein erstes Bild — Karte gibt trotzdem frei")
            self.uebergabeZoomen(lauf, bereit: lauf.jetzt)
        }
    }

    /// **Das erste Bild steht** — jetzt zoomt die Karte (frühestens bei
    /// ``Uebergabekarte/schweben``) und gibt das Bild frei.
    func uebergabeBildDa(_ itemID: String) {
        guard let lauf = uebergabe, lauf.rolle == .empfaenger, !lauf.abgebrochen,
              lauf.zoomAb == nil, itemID == lauf.titelID else { return }
        uebergabeZeit(lauf, "erstes Bild")
        uebergabeZoomen(lauf, bereit: lauf.jetzt)
    }

    /// Der Player ging zu, bevor die Karte ihn freigab.
    func uebergabeSpielerWeg(_ itemID: String) {
        guard let lauf = uebergabe, lauf.rolle == .empfaenger, lauf.zoomAb == nil,
              itemID == lauf.titelID else { return }
        uebergabeAbbrechen("Player geschlossen")
    }

    /// **Die Übergabe ist gescheitert** (Stopp abgelehnt) oder der Player
    /// wurde während des Wartens geschlossen: die Bühne blendet aus.
    func uebergabeAbbrechen(_ grund: String) {
        guard let lauf = uebergabe, lauf.rolle == .empfaenger, !lauf.abgebrochen else { return }
        lauf.abgebrochen = true
        uebergabeZeit(lauf, "abgebrochen: \(grund)")
        if lauf.takt != 0 { gtk_widget_remove_tick_callback(lauf.buehne, lauf.takt); lauf.takt = 0 }
        blenden(lauf.buehne, auf: 0, dauer: Uebergabekarte.blende, kennlinie: .easeInOut)
        nachFrist(Uebergabekarte.blende + 0.05) { [weak self] in
            guard let self, self.uebergabe === lauf else { return }
            self.uebergabeAbraeumen()
        }
    }

    private func uebergabeZoomen(_ lauf: Uebergabelauf, bereit t: Double) {
        lauf.bereit = t
        let z = lauf.reduziert ? t : Uebergabekarte.zoomBeginn(bereit: t)
        lauf.zoomAb = z
        let dauer: Double
        if lauf.reduziert {
            dauer = Uebergabekarte.blendeAus + 0.05
        } else {
            // Aus Lage **und Schwung** der wartenden Karte — kein Halt.
            lauf.zoomVon = Uebergabekarte.warten(z, von: lauf.von, nach: lauf.ruhe, ab: lauf.flugAb)
            lauf.zoomSchwung = Uebergabekarte.schwung(z, von: lauf.von, nach: lauf.ruhe, ab: lauf.flugAb)
            dauer = Uebergabekarte.ende
        }
        uebergabeZeit(lauf, "Zoom ab +\(Int(z * 1000)) ms")
        nachFrist(max(0, z + dauer - lauf.jetzt) + 0.02) { [weak self] in
            guard let self, self.uebergabe === lauf else { return }
            self.uebergabeZeit(lauf, "fertig")
            self.uebergabeAbraeumen()
        }
    }

    private func empfaengerBild(_ lauf: Uebergabelauf, _ t: Double) {
        let lage: Uebergabekarte.Lage
        if lauf.reduziert {
            lage = lauf.ruhe
            gtk_widget_set_opacity(lauf.grund, uebergabeLinear(t, 0, Uebergabekarte.blende))
            let an = uebergabeLinear(t, Uebergabekarte.kartenStart,
                                     Uebergabekarte.kartenStart + Uebergabekarte.blende)
            gtk_widget_set_opacity(lauf.karte, an)
            gtk_widget_set_opacity(lauf.zeilen, an)
            if let z = lauf.zoomAb {
                gtk_widget_set_opacity(lauf.buehne,
                                       1 - uebergabeLinear(t, z, z + Uebergabekarte.blendeAus))
            }
        } else {
            gtk_widget_set_opacity(lauf.grund, Uebergabekarte.seitendeckung(t))
            if let z = lauf.zoomAb, t >= z {
                let u = t - z
                lage = Uebergabekarte.zoom(u, von: lauf.zoomVon, schwung: lauf.zoomSchwung,
                                           nach: lauf.voll)
                gtk_widget_set_opacity(lauf.karte, 1)
                gtk_widget_set_opacity(lauf.schwarz, uebergabeLinear(u, 0, Uebergabekarte.schwarzDauer))
                gtk_widget_set_opacity(lauf.buehne, Uebergabekarte.buehnendeckung(nachZoom: u))
            } else {
                lage = Uebergabekarte.warten(t, von: lauf.von, nach: lauf.ruhe, ab: lauf.flugAb)
                gtk_widget_set_opacity(lauf.karte, Uebergabekarte.kartendeckung(t))
            }
            gtk_widget_set_opacity(lauf.zeilen, Uebergabekarte.zeilendeckung(t, zoomAb: lauf.zoomAb))
        }
        uebergabeKarteSetzen(lauf, lage, hoehe: lage.hoehe)

        // Die Ladelinie: blendet ein, ein Balken von 30 % fährt durch.
        if let ab = lauf.linieAb {
            let deckung = uebergabeLinear(t, ab, ab + Uebergabekarte.ladelinieEinblenden)
            gtk_widget_set_opacity(lauf.linie, deckung)
            let b = lauf.ruhe.breite, w = b * 0.3
            let anteil = ((t - ab) / Uebergabekarte.ladelinieTakt).truncatingRemainder(dividingBy: 1)
            gtk_fixed_move(alsFest(lauf.linie), lauf.balken, -w + anteil * (b + w), 0)
        }
    }

    // MARK: Abgeber

    /// **Die Wiedergabe geht an ein anderes Gerät.** Die Stelle geht sofort
    /// an den Server — drüben wird auf sie gewartet —, das Bild steht, geht
    /// als Karte ab, und erst wenn sie draußen ist, schließt der Player.
    ///
    /// **Die Karte liegt über allem**, auch über der Steuerung: sie ist ein
    /// Überzug der Fensterdecke, nicht Teil des Players. Ein fast schwarzes
    /// Standbild zählt nicht — dann fliegt das Folgenbild (am iPhone kam am
    /// 27.09. ein schwarzes Standbild heraus).
    func uebergabeAbgeben(an ziel: String) {
        guard let titel = laufenderTitel, uebergabe?.rolle != .abgeber else { return }
        uebergabeAbraeumen()
        let lauf = Uebergabelauf(rolle: .abgeber, reduziert: bewegungReduziert(), titelID: titel.id)
        uebergabeZeit(lauf, "an \(ziel)\(lauf.reduziert ? " (reduziert)" : "")")

        // **Die Stelle sofort**, nicht erst beim Schließen in knapp zwei
        // Sekunden: das andere Gerät wartet höchstens anderthalb auf sie.
        // Danach meldet dieser Player nichts mehr — auch die Pause nicht,
        // die gleich folgt (``laufzustandGemeldet(laeuft:)`` fragt `meldetitel`).
        if spielstand.startGemeldet, let client, let plan = laufenderPlan {
            let ticks = Int64(spielstand.position * 10_000_000)
            let konto = benutzerID
            spielstand.startGemeldet = false
            meldetitel = nil
            Task.detached { [self] in
                await self.meldeStopp(client, titel: titel, plan: plan, ticks: ticks, konto: konto)
            }
        }
        taktBeenden()
        abspieler.anhalten()

        // Das stehende Bild — die Textur, die das Bildfeld gerade zeigt.
        var standbild: OpaquePointer?
        if let feld = abspieler.anzeige, let p = gtk_picture_get_paintable(OpaquePointer(feld)) {
            g_object_ref(UnsafeMutableRawPointer(p))
            standbild = p
            if let hell = Self.helligkeit(p), hell < 0.04 {
                uebergabeZeit(lauf, "Standbild schwarz (Helligkeit \(String(format: "%.3f", hell))) — Folgenbild")
                g_object_unref(UnsafeMutableRawPointer(p))
                standbild = nil
            } else {
                uebergabeZeit(lauf, "Standbild da")
            }
        }
        let folgenbild = standbild == nil ? uebergabeKartenbild(titel) : nil
        guard standbild != nil || folgenbild != nil, uebergabeBuehneBauen(lauf) else {
            if let standbild { g_object_unref(UnsafeMutableRawPointer(standbild)) }
            uebergabeZeit(lauf, "weder Standbild noch Folgenbild — Player schließt wie sonst")
            spielerSchliessen()
            return
        }
        if let standbild {
            gtk_picture_set_paintable(OpaquePointer(lauf.bild), standbild)
            let w = Double(gdk_texture_get_width(standbild)), h = Double(gdk_texture_get_height(standbild))
            if w > 0, h > 0 { lauf.seiten = w / h }
            g_object_unref(UnsafeMutableRawPointer(standbild))
        } else if let folgenbild {
            bildLaden(lauf.bild, url: folgenbild, schluessel: Bildschluessel.fuer(folgenbild),
                      sofort: true, kante: 1280)
            uebergabeZeit(lauf, "Folgenbild")
        }
        uebergabeZeilenSetzen(lauf, titel)

        // Wo das Video stand: eingepasst in die Bildfläche, nach dem Bild selbst.
        let (sb, sh) = lauf.schirm
        var rahmen = (x: 0.0, y: 0.0, b: sb, h: sh)
        if let feld = abspieler.anzeige, let decke = fensterdecke {
            var r = graphene_rect_t()
            if gtk_widget_compute_bounds(feld, decke, &r) != 0, r.size.width > 1, r.size.height > 1 {
                rahmen = (Double(r.origin.x), Double(r.origin.y), Double(r.size.width), Double(r.size.height))
            }
        }
        let vb = min(rahmen.b, rahmen.h * lauf.seiten)
        lauf.voll = .init(x: rahmen.x + rahmen.b / 2, y: rahmen.y + rahmen.h / 2, breite: vb)
        lauf.ruhe = Uebergabekarte.ruhelage(breite: sb, hoehe: sh, masse: lauf.masse)
        let oben = Uebergabekarte.abflugNachOben(von: Self.uebergabeName, nach: ziel)
        lauf.richtung = oben ? .oben : .unten
        if lauf.reduziert {
            lauf.raus = Uebergabekarte.blendeAus
        } else {
            lauf.raus = Uebergabekarte.abgangRaus(voll: lauf.voll, karte: lauf.ruhe, richtung: lauf.richtung)
            uebergabeZeit(lauf, "fliegt nach \(oben ? "oben" : "unten"), draußen nach \(Int(lauf.raus * 1000)) ms")
        }
        // Deckend ab dem ersten Bild: vom Player ist nichts mehr zu sehen.
        gtk_widget_set_opacity(lauf.grund, 1)
        gtk_widget_set_opacity(lauf.schwarz, 1)
        gtk_widget_set_opacity(lauf.karte, 1)
        uebergabe = lauf
        uebergabeTaktStarten(lauf)
        uebergabeZeit(lauf, "Bühne deckt den Player ab ihrem ersten Bild")

        // Karte draußen: der Player schließt unter der Bühne, dann blendet
        // der Grund auf die Seite aus.
        let schliessdauer = 0.5
        nachFrist(lauf.raus) { [weak self] in
            guard let self, self.uebergabe === lauf else { return }
            self.uebergabeZeit(lauf, "Karte draußen — Player schließt unter der Bühne")
            if self.laufenderTitel?.id == titel.id { self.spielerSchliessen() }
            lauf.grundAusAb = lauf.jetzt + schliessdauer
        }
        nachFrist(lauf.raus + schliessdauer + Uebergabekarte.blende + 0.1) { [weak self] in
            guard let self, self.uebergabe === lauf else { return }
            self.uebergabeZeit(lauf, "fertig")
            self.uebergabeAbraeumen()
        }
    }

    private func abgeberBild(_ lauf: Uebergabelauf, _ t: Double) {
        let lage: Uebergabekarte.Lage
        if lauf.reduziert {
            lage = lauf.voll
            let aus = 1 - uebergabeLinear(t, 0, Uebergabekarte.blendeAus)
            gtk_widget_set_opacity(lauf.karte, aus)
            gtk_widget_set_opacity(lauf.schwarz, aus)
        } else {
            lage = Uebergabekarte.abgang(t, voll: lauf.voll, karte: lauf.ruhe, richtung: lauf.richtung)
            // Spiegel des Empfängers: Schwarz geht, wenn die Karte schrumpft.
            gtk_widget_set_opacity(lauf.schwarz, 1 - uebergabeLinear(
                t, Uebergabekarte.abgangStart, Uebergabekarte.abgangStart + Uebergabekarte.schwarzDauer))
            gtk_widget_set_opacity(lauf.zeilen, Uebergabekarte.abgangZeilendeckung(t))
        }
        if let g = lauf.grundAusAb {
            gtk_widget_set_opacity(lauf.grund, 1 - uebergabeLinear(t, g, g + Uebergabekarte.blende))
        }
        uebergabeKarteSetzen(lauf, lage, hoehe: lage.breite / lauf.seiten)
    }

    /// Mittlere Helligkeit 0…1 an 16 × 16 Punkten.
    private static func helligkeit(_ textur: OpaquePointer) -> Double? {
        let w = Int(gdk_texture_get_width(textur)), h = Int(gdk_texture_get_height(textur))
        guard w > 0, h > 0 else { return nil }
        var punkte = [UInt8](repeating: 0, count: w * h * 4)
        punkte.withUnsafeMutableBufferPointer {
            gdk_texture_download(textur, $0.baseAddress, gsize(w * 4))
        }
        // `gdk_texture_download` liefert B, G, R, A.
        let n = 16
        var summe = 0.0
        for j in 0 ..< n {
            for i in 0 ..< n {
                let x = (2 * i + 1) * w / (2 * n), y = (2 * j + 1) * h / (2 * n)
                let o = (y * w + x) * 4
                summe += 0.0722 * Double(punkte[o]) + 0.7152 * Double(punkte[o + 1])
                    + 0.2126 * Double(punkte[o + 2])
            }
        }
        return summe / Double(n * n) / 255
    }

    // MARK: Bühne

    /// Grund, Schwarz und darüber ein `GtkFixed` mit Karte und Zeilen — als
    /// oberster Überzug der Fensterdecke, ohne Treffer und Fokus.
    private func uebergabeBuehneBauen(_ lauf: Uebergabelauf) -> Bool {
        guard let decke = fensterdecke else { return false }
        let b = Double(gtk_widget_get_width(decke)), h = Double(gtk_widget_get_height(decke))
        guard b > 1, h > 1 else { return false }
        lauf.schirm = (b, h)

        let buehne: Widget! = gtk_overlay_new()
        gtk_widget_set_can_target(buehne, 0)
        gtk_widget_set_can_focus(buehne, 0)
        let grund = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(grund, "swiftly-uebergabegrund")
        gtk_widget_set_opacity(grund, 0)
        gtk_overlay_set_child(OpaquePointer(buehne), grund)
        let schwarz = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(schwarz, "swiftly-uebergabeschwarz")
        gtk_widget_set_opacity(schwarz, 0)
        gtk_overlay_add_overlay(OpaquePointer(buehne), schwarz)
        // **Ein `GtkFixed` gibt seinen Kindern die Mindestgröße** — die Karte
        // ist genau so groß, wie der Bildtakt sie anfordert, und liegt auf
        // Bruchteilen eines Punkts. Was aus dem Fenster fliegt, schneidet es ab.
        let fest: Widget! = gtk_fixed_new()
        gtk_widget_set_overflow(fest, GTK_OVERFLOW_HIDDEN)
        gtk_overlay_add_overlay(OpaquePointer(buehne), fest)

        let karte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(karte, "swiftly-uebergabekarte")
        gtk_widget_set_overflow(karte, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_opacity(karte, 0)
        let bild: Widget! = gtk_picture_new()
        gtk_picture_set_can_shrink(OpaquePointer(bild), 1)
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
        gtk_widget_set_hexpand(bild, 1)
        gtk_widget_set_vexpand(bild, 1)
        anhaengen(karte, bild)
        gtk_fixed_put(alsFest(fest), karte, 0, 0)

        // Titel und Folge, links bündig in Kartenbreite; oben die Ladelinie.
        let zeilen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(zeilen, Int32(lauf.masse.breite), -1)
        gtk_widget_set_opacity(zeilen, 0)
        let linie: Widget! = gtk_fixed_new()
        gtk_widget_add_css_class(linie, "swiftly-uebergabelinie")
        gtk_widget_set_overflow(linie, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_size_request(linie, Int32(lauf.masse.breite), 2)
        gtk_widget_set_opacity(linie, 0)
        let balken = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        gtk_widget_add_css_class(balken, "swiftly-uebergabebalken")
        gtk_widget_set_size_request(balken, Int32((lauf.masse.breite * 0.3).rounded()), 2)
        gtk_fixed_put(alsFest(linie), balken, 0, 0)
        anhaengen(zeilen, linie)
        gtk_fixed_put(alsFest(fest), zeilen, 0, 0)

        gtk_overlay_add_overlay(OpaquePointer(decke), buehne)

        lauf.buehne = buehne
        lauf.grund = grund
        lauf.schwarz = schwarz
        lauf.fest = fest
        lauf.karte = karte
        lauf.bild = bild
        lauf.zeilen = zeilen
        lauf.linie = linie
        lauf.balken = balken
        return true
    }

    /// „The Mentalist" und „Staffel 6 · Folge 7" (Apple `Uebergabestil.zeilen`).
    private func uebergabeZeilenSetzen(_ lauf: Uebergabelauf, _ titel: Item) {
        var oben = titel.name
        var unter: String?
        if let serie = titel.seriesName, !serie.isEmpty {
            oben = serie
            if let s = titel.parentIndexNumber, let f = titel.indexNumber {
                unter = String(format: uebersetzt("Staffel %lld · Folge %lld"), s, f)
            } else {
                unter = titel.name
            }
        }
        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: Int32((lauf.masse.abstand * 0.25).rounded()))
        gtk_widget_set_margin_top(text, Int32((lauf.masse.abstand * 0.35).rounded()))
        let paare: [(String?, String)] = [(oben, "swiftly-uebergabetitel"), (unter, "swiftly-uebergabeunter")]
        for (wort, stil) in paare {
            guard let wort else { continue }
            let l = beschriftung(wort, stil: stil)
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(OpaquePointer(l), 1)
            anhaengen(text, l)
        }
        anhaengen(lauf.zeilen, text)
    }

    /// **Das Bild der Karte** — bei Folgen das Bild der Folge (es zeigt,
    /// *wo* man ist), sonst das Querbild des Titels (Apple
    /// `Uebernahmemodell.kartenbildURL`).
    func uebergabeKartenbild(_ titel: Item) -> URL? {
        guard let adressen else { return nil }
        if titel.seriesId != nil, let marke = titel.imageTags?["Primary"] {
            return adressen.bauen(itemID: titel.id, marke: marke, mass: .hoechstensBreit(1280))
        }
        return Bildwahl.quer(titel, adressen: adressen, breite: 1280)?.url
    }

    /// Lage und Größe der Karte, die Zeilen darunter, die Ecke als Stufe.
    private func uebergabeKarteSetzen(_ lauf: Uebergabelauf, _ l: Uebergabekarte.Lage, hoehe: Double) {
        let w = max(1, l.breite.rounded()), h = max(1, hoehe.rounded())
        gtk_widget_set_size_request(lauf.karte, Int32(w), Int32(h))
        gtk_fixed_move(alsFest(lauf.fest), lauf.karte, l.x - w / 2, l.y - h / 2)
        gtk_fixed_move(alsFest(lauf.fest), lauf.zeilen, l.x - lauf.masse.breite / 2,
                       Uebergabekarte.zeilenOben(l, masse: lauf.masse))
        let stufe = min(max(Int(Uebergabekarte.ecke(l, masse: lauf.masse, voll: lauf.voll).rounded()), 0), 12)
        if stufe != lauf.ecke {
            if lauf.ecke >= 0 { gtk_widget_remove_css_class(lauf.karte, "swiftly-uebergabeecke-\(lauf.ecke)") }
            gtk_widget_add_css_class(lauf.karte, "swiftly-uebergabeecke-\(stufe)")
            lauf.ecke = stufe
        }
    }

    private func uebergabeTaktStarten(_ lauf: Uebergabelauf) {
        _ = uebergabeSchritt()
        lauf.takt = gtk_widget_add_tick_callback(lauf.buehne, uebergabeTakt,
                                                 Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Ein Bild der Übergabe — im Takt des Fensters.
    fileprivate func uebergabeSchritt() -> Bool {
        guard let lauf = uebergabe, !lauf.abgebrochen, let decke = fensterdecke else { return false }
        let t = lauf.jetzt
        // **Das Fenster ändert seine Größe** (Vollbild an oder aus): die Bühne
        // folgt von selbst, die Karte fliegt von dort, wo sie gerade ist, in
        // die neue Ruhelage (Apple `neuAusrichten`).
        let b = Double(gtk_widget_get_width(decke)), h = Double(gtk_widget_get_height(decke))
        if b > 1, h > 1, b != lauf.schirm.breite || h != lauf.schirm.hoehe {
            lauf.schirm = (b, h)
            if lauf.rolle == .empfaenger {
                let alteRuhe = lauf.ruhe
                lauf.voll = Uebergabekarte.vollbild(breite: b, hoehe: h)
                lauf.ruhe = Uebergabekarte.ruhelage(breite: b, hoehe: h, masse: lauf.masse)
                if !lauf.reduziert, lauf.zoomAb == nil {
                    lauf.von = Uebergabekarte.flug(t, von: lauf.von, nach: alteRuhe, ab: lauf.flugAb)
                    lauf.flugAb = t
                }
                uebergabeZeit(lauf, "Größe \(Int(b))×\(Int(h))")
            }
        }
        switch lauf.rolle {
        case .empfaenger: empfaengerBild(lauf, t)
        case .abgeber: abgeberBild(lauf, t)
        }
        return true
    }

    func uebergabeAbraeumen() {
        guard let lauf = uebergabe else { return }
        uebergabe = nil
        if lauf.takt != 0 { gtk_widget_remove_tick_callback(lauf.buehne, lauf.takt); lauf.takt = 0 }
        if let decke = fensterdecke, let buehne = lauf.buehne {
            gtk_overlay_remove_overlay(OpaquePointer(decke), buehne)
        }
    }

    private func uebergabeZeit(_ lauf: Uebergabelauf, _ was: String) {
        let wer = lauf.rolle == .empfaenger ? "Karte" : "Abgang"
        Protokoll.schreib("[Uebergabe] \(wer) +\(Int(lauf.jetzt * 1000)) ms \(was)")
    }
}

private func uebergabeLinear(_ t: Double, _ a: Double, _ b: Double) -> Double {
    min(max((t - a) / (b - a), 0), 1)
}

nonisolated(unsafe) private let uebergabeTakt: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, daten in
    guard let daten else { return 0 }
    let app = Unmanaged<App>.fromOpaque(daten).takeUnretainedValue()
    let weiter = app.uebergabeSchritt()
    if !weiter, let lauf = app.uebergabe { lauf.takt = 0 }
    return weiter ? 1 : 0
}
