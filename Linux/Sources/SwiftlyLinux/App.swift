import CGtk
import Foundation
import CVLC
import JellyfinKit

/// **Swiftly auf Linux.**
///
/// Anmeldung, gemerkte Sitzung, Startseite mit echten Postern — und dahinter
/// derselbe `JellyfinClient`, den iPhone, iPad, Apple TV und Mac benutzen.
/// Kein nachgebauter Client, keine zweite Wahrheit.
///
/// Was hier neu ist, ist ausschließlich die Oberfläche. Alles, was entscheidet
/// — welche Adresse gilt, was der Server bekommt, wann fortgesetzt wird —
/// liegt in `JellyfinKit` und ist auf allen fünf Plattformen dieselbe Datei.
/// **`@unchecked Sendable` mit demselben Grund wie ``Zeigerkiste``.**
///
/// Swift kann nicht wissen, dass GTK alles auf einem einzigen Faden abarbeitet
/// — für den Übersetzer ist diese Klasse voller roher Zeiger, die überall
/// gleichzeitig angefasst werden könnten. Die Zusicherung gilt, weil jeder
/// Zugriff aus einer Task über ``aufHauptfaden`` zurückkommt und damit wieder
/// auf demselben Faden landet. Wer hier eine Methode ergänzt, die aus einer
/// Task heraus direkt an die Oberfläche geht, bricht sie.
final class App: @unchecked Sendable {

    // Fenster und die zwei Seiten darin.
    var fenster: Widget!
    var seiten: Widget!          // GtkStack
    private var anmeldeseite: Widget!
    private var startseite: Widget!

    // Anmeldung, zwei Schritte
    private var anmeldeschritte: Widget!     // GtkStack: server -> konto
    private var serverfeld: Widget!
    private var verbindeknopf: Widget!
    private var serverstand: Widget!
    private var serverzeile: Widget!
    private var fassungszeile: Widget!
    private var serverURL: URL?
    private var benutzerfeld: Widget!
    private var passwortfeld: Widget!
    private var kontenreihe: Widget!
    private var schnellknopf: Widget!
    /// Der Client des Servers, mit dem gerade angemeldet wird.
    private var anmeldeclient: JellyfinClient?
    private var anmeldeknopf: Widget!
    private var anmeldestand: Widget!
    private var meldetGerade = false

    // Startseite
    var bereich: Bereich = .start
    private var reihenstapel: Widget!
    var kopfzeile: Widget!

    var client: JellyfinClient?
    var adressen: Bildadresse?
    /// Läuft nur beim Start und blendet danach weg.
    var startanimation: Startanimation?
    var startbild: Widget!

    // MARK: - Aufbau

    func aufbauen(anwendung: UnsafeMutablePointer<GtkApplication>!) {
        fenster = gtk_application_window_new(anwendung)
        // **Was unter dem Zeiger steht.** In der Leiste las man „SwiftlyLinux
        // Swiftly": das erste kommt vom Programmnamen, den GLib aus der
        // Binärdatei nimmt, das zweite vom Fenstertitel. Der Anwendungsname
        // heisst jetzt so wie die App, und der Titel trägt den Zusatz.
        Zeichenwerk.einrichten()
        g_set_application_name("Swiftly")
        g_set_prgname("swiftly")
        gtk_window_set_title(alsFenster(fenster), "for Jellyfin")
        gtk_window_set_icon_name(alsFenster(fenster), Zeichenwerk.kennung)
        gtk_window_set_default_size(alsFenster(fenster), 1100, 760)
        // **Unter 900 × 560 geht das Raster nicht mehr auf** — Seitenleiste
        // plus zwei Kachelspalten plus Ränder. Dieselbe Grenze wie auf dem
        // Mac; ohne sie liess sich das Fenster auf Briefmarkengrösse ziehen.
        gtk_widget_set_size_request(fenster, Int32(Stil.fensterMinBreite),
                                    Int32(Stil.fensterMinHoehe))

        seiten = gtk_stack_new()
        gtk_stack_set_transition_type(OpaquePointer(seiten), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_widget_set_vexpand(seiten, 1)

        anmeldeseite = anmeldungBauen()
        startseite = startseiteBauen()
        gtk_stack_add_named(OpaquePointer(seiten), anmeldeseite, "anmeldung")
        gtk_stack_add_named(OpaquePointer(seiten), startseite, "start")

        kopfzeile = gtk_header_bar_new()
        gtk_window_set_titlebar(alsFenster(fenster), kopfzeile)
        let inhalt = stapel(GTK_ORIENTATION_VERTICAL)
        anhaengen(inhalt, seiten)

        // **Die Startanimation liegt *über* der Oberfläche, nicht neben ihr.**
        //
        // Der erste Anlauf gab ihr eine eigene Stapelseite. Das ist auch so
        // nicht richtig — ein `GtkStack` legt nur sein sichtbares Kind aus,
        // die Hauptansicht bekäme also nie eine Grösse. Als Überzug stellt
        // sich die Frage nicht: darunter wird die ganze Zeit normal
        // ausgelegt, und die Animation deckt es nur zu.
        //
        // **Das schwarze Fenster kam aber von woanders**, und das hat mich
        // fünf Anläufe gekostet: die App stürzte beim zweiten Bild ab, an
        // einer Cairo-Zusicherung. Nicht die Übergabe war kaputt, es gab
        // hinterher schlicht keinen Prozess mehr. Siehe ``Startanimation``.
        let decke: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(decke), inhalt)
        // `SWIFTLY_START=0` schaltet sie ab — zum Messen, was sie kostet.
        if ProcessInfo.processInfo.environment["SWIFTLY_START"] != "0",
           let lauf = Startanimation(fertig: { [weak self] in self?.startbildWeg() }) {
            startanimation = lauf
            let grund = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            gtk_widget_add_css_class(grund, "swiftly-startgrund")
            anhaengen(grund, lauf.anzeige)
            startbild = grund
            gtk_overlay_add_overlay(OpaquePointer(decke), grund)
            // **Spätestens dann geht es weiter, egal was die Animation
            // macht** — dieselbe Frist wie auf Apple (3,5 s).
            //
            // `[self]`, nicht `[weak self]`: die App lebt in einer globalen
            // Referenz bis zum Ende, und ein schwacher Verweis wäre in der
            // verschachtelten Sendable-Hülle ohnehin nicht zu fassen.
            Task.detached { [self] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                aufHauptfaden { self.startanimation?.abschliessen() }
            }
        }
        gtk_window_set_child(alsFenster(fenster), decke)

        tastenEinrichten()
        // **Die Medientasten der Tastatur.** Unter Linux gibt es dafür kein
        // Rahmenwerk, sondern einen Standard auf dem Sitzungsbus; siehe
        // ``Medienleiste``.
        // `[self]`, nicht `[weak self]`: die App lebt in einer globalen
        // Referenz, und ein schwacher Verweis waere in der verschachtelten
        // Sendable-Huelle ohnehin nicht zu fassen.
        medienleiste = Medienleiste { [self] griff in
            aufHauptfaden { self.medienGriff(griff) }
        }
        VLCFassung.text = String(cString: libvlc_get_version())
        // **D8: die Startseite holt ihre Reihen neu, wenn die App in den
        // Vordergrund kommt** — mit Frist, damit ein Wechsel hin und her nicht
        // jedes Mal lädt. Die Frist steht im Paket, nicht hier.
        beiEigenschaft(UnsafeMutableRawPointer(fenster), "notify::is-active") { [weak self] in
            guard let self, self.client != nil,
                  gtk_window_is_active(alsFenster(self.fenster)) != 0 else { return }
            if Auffrischung.faelligBeiRueckkehr(zuletzt: self.zuletztGeladen,
                                                jetzt: Date()) {
                self.startseiteLaden()
            }
        }
        // **Der zuletzt benutzte Server steht schon im Feld.** Nach dem
        // Abmelden war es leer, und man tippte die Adresse von Hand.
        if Speicher.lesen() == nil, let merk = Speicher.gemerkterServer() {
            gtk_editable_set_text(OpaquePointer(serverfeld), merk.serverURL.absoluteString)
            serverstandZeigen(merk.servername.map { String(format: uebersetzt("Zuletzt: %@"), $0) } ?? "")
        }
        gtk_window_present(alsFenster(fenster))
        // **Erst jetzt gibt es eine Fensterfläche.** Vorher hat das Fenster
        // kein Gegenstück im Fenstersystem, und ohne das lassen sich die
        // Medientasten nicht anmelden. Auf Linux tut die Zeile nichts — dort
        // erledigt das der Sitzungsbus.
        medienleiste?.anFenster(fenster)
        // Die Animation fährt selbst los, sobald ihre Fläche aufgelegt ist —
        // siehe ``Startanimation/losfahren()``. Von hier aus wäre es zu früh.

        // Gemerkte Sitzung: gleich weiter zur Startseite, ohne Nachfragen.
        if let abgelegt = Speicher.lesen() {
            sitzungUebernehmen(serverURL: abgelegt.serverURL,
                               token: abgelegt.token,
                               benutzerID: abgelegt.benutzerID,
                               benutzername: abgelegt.benutzername,
                               servername: abgelegt.servername)
        }
    }

    /// Die Animation ist durch: die Decke blendet weg, darunter steht alles
    /// längst fertig.
    private func startbildWeg() {
        guard startanimation != nil, let bild = startbild else {
            return
        }
        startanimation = nil
        gtk_widget_set_can_target(bild, 0)
        sanft(auf: bild, von: 1, nach: 0) { gtk_widget_set_opacity(bild, $0) }
        // **Das Verschwinden darf nicht am Bildtakt hängen.**
        //
        // `sanft` blendet über `gtk_widget_add_tick_callback` — und genau der
        // sprang hier schon einmal nicht an. Springt er wieder nicht an,
        // bleibt die Deckkraft auf eins und der schwarze Deckel liegen: die
        // App startet dann in ein schwarzes Fenster. Der Wecker nimmt ihn
        // hinterher in jedem Fall weg. Blendet es weich, sieht man ihn nicht;
        // blendet es nicht, ist er trotzdem fort.
        // Der Zeiger geht über eine Fadengrenze, also in die Kiste.
        let kiste = gehalten(bild)
        Task.detached {
            try? await Task.sleep(nanoseconds: 340_000_000)
            aufHauptfaden {
                defer { losgelassen(kiste) }
                gtk_widget_set_opacity(kiste.widget, 0)
                gtk_widget_set_visible(kiste.widget, 0)
            }
        }
        // **Die Decke bleibt hängen, sie wird nicht abgeräumt.** Ein Widget
        // wegzunehmen, während sein Bildtakt noch aussteht, ist die vierte
        // Falle. Unsichtbar und ohne Treffer kostet es nichts, und die
        // Animation gibt ihren Speicher selbst frei, sobald der Takt sich
        // abmeldet.
    }

    // MARK: - Anmeldung

    private func anmeldungBauen() -> Widget! {
        // **Zwei Schritte, wie auf allen anderen Plattformen.** Erst die
        // Adresse und verbinden, dann das Konto. Der Mac führt dafür
        // `AppModel.Phase` — disconnected, needsLogin(serverName:version:),
        // ready —, und dieselbe Reihenfolge gilt hier. Ein eigener Ablauf pro
        // Plattform wäre genau die Abweichung, die `VERHALTEN.md` verbietet:
        // verschieden sein dürfen Eingabeart und Fenstergröße, nicht der Weg.
        anmeldeschritte = gtk_stack_new()
        gtk_stack_set_transition_type(OpaquePointer(anmeldeschritte),
                                      GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT)
        gtk_stack_add_named(OpaquePointer(anmeldeschritte), serverSchrittBauen(), "server")
        gtk_stack_add_named(OpaquePointer(anmeldeschritte), kontoSchrittBauen(), "konto")
        return anmeldeschritte
    }

    /// Schritt eins: wo steht der Server?
    ///
    /// **Die Abstände sind abgeschrieben, nicht abgeschätzt.** Sie stehen in
    /// `Sources/macOS/RootView.swift` als `.padding(.top, …)` an genau diesen
    /// Stellen: Marke, 40 Luft, Frage, 24, Feld, 24, Knopf. Ein `GtkBox` mit
    /// `abstand` würde sie alle gleich machen — deshalb steht der Abstand
    /// hier bei jedem Kind einzeln als oberer Rand.
    private func serverSchrittBauen() -> Widget! {
        let mitte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_valign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(mitte, GTK_ALIGN_CENTER)

        anhaengen(mitte, Stil.wortmarke(hoehe: 44))

        let frage = beschriftung(uebersetzt("Wo steht dein Jellyfin-Server?"),
                                 stil: "swiftly-koerper")
        gtk_widget_add_css_class(frage, "dim-label")
        gtk_widget_set_margin_top(frage, 40)
        anhaengen(mitte, frage)

        // Die Weltkugel im Feld — auf dem Mac steht dort `Image("globe")`.
        serverfeld = eingabezeile(symbol: "network-server-symbolic", platzhalter: "tv.beispiel.de")
        gtk_widget_set_margin_top(serverfeld, 24)
        anhaengen(mitte, serverfeld)

        serverstand = meldezeile()
        anhaengen(mitte, serverstand)

        verbindeknopf = hauptknopf(uebersetzt("Verbinden"))
        gtk_widget_set_margin_top(verbindeknopf, 24)
        gtk_widget_set_sensitive(verbindeknopf, 0)
        anhaengen(mitte, verbindeknopf)

        beiSignal(verbindeknopf, "clicked") { [weak self] in self?.verbinden() }
        beiSignal(serverfeld, "activate") { [weak self] in self?.verbinden() }
        // Der Mac blendet den Knopf aus, solange das Feld leer ist
        // (`.disabled(adresse.isEmpty)`). Dasselbe hier, nur muss GTK bei
        // jeder Änderung gefragt werden statt einmal beim Auswerten.
        beiSignal(serverfeld, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(self.verbindeknopf,
                                     self.text(self.serverfeld).isEmpty ? 0 : 1)
        }
        return mitte
    }

    /// Schritt zwei: welches Konto?
    ///
    /// Marke, 34, Servername, 4, Fassung, 28, Benutzer, 10, Passwort, 24,
    /// Knopf — aus `AnmeldeView` auf dem Mac.
    /// Holt die öffentlichen Konten und prüft, ob der Server Quick Connect
    /// anbietet. Beides ist eine Auskunft des Servers, keine Einstellung.
    private func kontenHolen(_ c: JellyfinClient) {
        anmeldeclient = c
        Task.detached { [self] in
            async let konten = try? await c.oeffentlicheBenutzer()
            async let schnell = await c.quickConnectVerfuegbar()
            let (liste, moeglich) = await (konten ?? [], schnell)
            // **Die Adresse vor dem Hauptfaden holen.** `benutzerbild` gehört
            // dem Client-Actor; im Aufbau der Kachel wäre es ein Zugriff von
            // aussen.
            var gesammelt: [(OeffentlicherBenutzer, URL?)] = []
            for benutzer in liste.prefix(6) {
                gesammelt.append((benutzer, await c.benutzerbild(benutzer, kante: 128)))
            }
            let bilder = gesammelt
            aufHauptfaden {
                gtk_widget_set_visible(self.schnellknopf, moeglich ? 1 : 0)
                leeren(self.kontenreihe)
                gtk_widget_set_visible(self.kontenreihe, liste.isEmpty ? 0 : 1)
                for (benutzer, bild) in bilder {
                    anhaengen(self.kontenreihe, self.kontenkachel(benutzer, bild: bild))
                }
                // **Bei genau einem Konto steht der Name schon da.** Dann
                // fehlt nur noch das Passwort.
                if liste.count == 1 {
                    gtk_editable_set_text(OpaquePointer(self.benutzerfeld), liste[0].name)
                }
            }
        }
    }

    /// Ein Konto als Bild mit Namen darunter.
    private func kontenkachel(_ benutzer: OeffentlicherBenutzer,
                              bild url: URL?) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kachel")
        let saeule = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        let (kaefig, bild) = gerahmtesBild(breite: 64, hoehe: 64, stil: "swiftly-rund")
        if let url {
            bildLaden(bild, url: url, schluessel: "konto-\(benutzer.id)", sofort: true)
        } else {
            zeichenLegen(kaefig, serie: false)
        }
        anhaengen(saeule, kaefig)
        let name = beschriftung(benutzer.name, stil: "swiftly-zweitzeile")
        gtk_widget_set_halign(name, GTK_ALIGN_CENTER)
        anhaengen(saeule, name)
        gtk_button_set_child(alsKnopf(knopf), saeule)
        beiSignal(knopf, "clicked") { [weak self] in
            guard let self else { return }
            gtk_editable_set_text(OpaquePointer(self.benutzerfeld), benutzer.name)
            gtk_widget_grab_focus(self.passwortfeld)
        }
        return knopf
    }

    /// **Anmelden mit einem Code, ohne Passwort.**
    ///
    /// Der Server nennt einen sechsstelligen Code; wer ihn auf einem schon
    /// angemeldeten Gerät freigibt, meldet dieses hier an. Der Vorgang läuft,
    /// bis er freigegeben oder abgebrochen wird.
    private func schnellanmeldung() {
        guard let c = anmeldeclient else { return }
        Task.detached { [self] in
            guard let vorgang = try? await c.quickConnectStarten() else {
                aufHauptfaden { self.anmeldestandZeigen(uebersetzt("Der Server hat keinen Code gegeben.")) }
                return
            }
            aufHauptfaden {
                self.anmeldestandZeigen(String(format: uebersetzt("Code %@ — auf einem angemeldeten Gerät freigeben"), vorgang.code))
            }
            // Höchstens fünf Minuten warten; danach ist der Code ohnehin tot.
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard (try? await c.quickConnectFreigegeben(vorgang)) == true else { continue }
                guard let sitzung = try? await c.anmeldenMitQuickConnect(vorgang) else { break }
                let name = sitzung.userName
                aufHauptfaden {
                    guard let url = self.serverURL else { return }
                    let servername = gtk_label_get_text(OpaquePointer(self.serverzeile))
                        .map { String(cString: $0) }
                    Speicher.schreiben(.init(serverURL: url,
                                             token: sitzung.accessToken,
                                             benutzerID: sitzung.userID,
                                             benutzername: name,
                                             servername: servername))
                    self.anmeldestandZeigen("")
                    self.sitzungUebernehmen(serverURL: url,
                                            token: sitzung.accessToken,
                                            benutzerID: sitzung.userID,
                                            benutzername: name,
                                            servername: servername)
                }
                return
            }
            aufHauptfaden { self.anmeldestandZeigen(uebersetzt("Der Code ist abgelaufen.")) }
        }
    }

    private func kontoSchrittBauen() -> Widget! {
        let mitte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_valign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(mitte, GTK_ALIGN_CENTER)

        anhaengen(mitte, Stil.wortmarke(hoehe: 44))

        serverzeile = beschriftung("", stil: "swiftly-titel")
        gtk_widget_set_margin_top(serverzeile, 34)
        anhaengen(mitte, serverzeile)

        fassungszeile = beschriftung("", stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(fassungszeile, "swiftly-leise")
        gtk_widget_set_margin_top(fassungszeile, 4)
        anhaengen(mitte, fassungszeile)

        // **„Wer schaut?"** — die öffentlichen Konten des Servers, mit Bild.
        // Der Mac holt sie und wählt bei genau einem den Namen vor
        // (`Shared/RootView.swift:217`); hier stand nur ein leeres Textfeld,
        // in das man seinen Namen zeichengenau tippen musste.
        kontenreihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        gtk_widget_set_halign(kontenreihe, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(kontenreihe, 26)
        gtk_widget_set_visible(kontenreihe, 0)
        anhaengen(mitte, kontenreihe)

        benutzerfeld = eingabezeile(symbol: "avatar-default-symbolic",
                                    platzhalter: uebersetzt("Benutzername"))
        gtk_widget_set_margin_top(benutzerfeld, 28)
        anhaengen(mitte, benutzerfeld)

        passwortfeld = eingabezeile(symbol: "channel-secure-symbolic",
                                    platzhalter: uebersetzt("Passwort"), geheim: true)
        gtk_widget_set_margin_top(passwortfeld, 10)
        anhaengen(mitte, passwortfeld)

        anmeldestand = meldezeile()
        anhaengen(mitte, anmeldestand)

        anmeldeknopf = hauptknopf(uebersetzt("Anmelden"))
        gtk_widget_set_margin_top(anmeldeknopf, 24)
        gtk_widget_set_sensitive(anmeldeknopf, 0)
        anhaengen(mitte, anmeldeknopf)

        // Der Mac kommt über die Fensterampel zurueck; hier braucht es einen
        // Weg im Bild, sonst sitzt man auf dem falschen Server fest.
        // **Quick Connect als Anmeldeweg.** Bisher gab es hier nur die
        // Gegenrichtung — einen fremden Code freigeben. Wer sich anmelden
        // will, ohne sein Passwort zu tippen, konnte es nicht.
        schnellknopf = gtk_button_new_with_label(uebersetzt("Mit Code anmelden"))
        gtk_widget_add_css_class(schnellknopf, "swiftly-flach")
        gtk_widget_set_margin_top(schnellknopf, 10)
        gtk_widget_set_halign(schnellknopf, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(schnellknopf, 0)
        beiSignal(schnellknopf, "clicked") { [weak self] in self?.schnellanmeldung() }
        anhaengen(mitte, schnellknopf)

        let zurueck: Widget! = gtk_button_new_with_label(uebersetzt("Anderer Server"))
        gtk_widget_add_css_class(zurueck, "swiftly-flach")
        gtk_widget_set_margin_top(zurueck, 14)
        gtk_widget_set_halign(zurueck, GTK_ALIGN_CENTER)
        anhaengen(mitte, zurueck)

        beiSignal(anmeldeknopf, "clicked") { [weak self] in self?.anmelden() }
        beiSignal(passwortfeld, "activate") { [weak self] in self?.anmelden() }
        beiSignal(benutzerfeld, "activate") { [weak self] in
            guard let self else { return }
            gtk_widget_grab_focus(self.passwortfeld)
        }
        beiSignal(benutzerfeld, "changed") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(self.anmeldeknopf,
                                     self.text(self.benutzerfeld).isEmpty ? 0 : 1)
        }
        beiSignal(zurueck, "clicked") { [weak self] in
            guard let self else { return }
            gtk_stack_set_visible_child_name(OpaquePointer(self.anmeldeschritte), "server")
        }
        return mitte
    }

    /// Die Fehlerzeile unter den Feldern: 12 Zeilenschrift in `warnung`,
    /// mittig, auf Blockbreite umbrechend. Sie steht immer da und ist leer,
    /// solange nichts schiefging — sonst würde der Knopf beim ersten Fehler
    /// nach unten springen.
    private func meldezeile() -> Widget! {
        let l = beschriftung("", stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(l, "swiftly-warnung")
        gtk_widget_set_size_request(l, Int32(Stil.anmeldeBreite), -1)
        gtk_widget_set_margin_top(l, 12)
        gtk_widget_set_visible(l, 0)
        return l
    }

    func text(_ feld: Widget!) -> String {
        gtk_editable_get_text(OpaquePointer(feld)).map { String(cString: $0) } ?? ""
    }

    /// **Eine leere Beschriftung ist nicht null hoch.** GTK gibt ihr trotzdem
    /// eine Zeile, und mit dem oberen Rand stünde der Knopf dauerhaft 29
    /// Punkt zu tief — auf dem Mac erscheint der Fehlerblock erst, wenn es
    /// einen gibt. Also aus- und einblenden statt Text leeren.
    private func meldung(_ zeile: Widget!, _ s: String) {
        gtk_label_set_text(OpaquePointer(zeile), s)
        gtk_widget_set_visible(zeile, s.isEmpty ? 0 : 1)
    }

    private func serverstandZeigen(_ s: String) { meldung(serverstand, s) }

    private func anmeldestandZeigen(_ s: String) { meldung(anmeldestand, s) }

    // MARK: Schritt eins — verbinden

    private func verbinden() {
        guard !meldetGerade else { return }
        let eingabe = text(serverfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eingabe.isEmpty else { serverstandZeigen(uebersetzt("Trag erst eine Adresse ein.")); return }

        // Dieselbe Regel wie überall: ohne Schema bekommt eine Adresse
        // `https` vorgesetzt, außer sie sieht nach Heimnetz aus.
        guard let url = AppModelURLNormalizer.normalize(eingabe) else {
            serverstandZeigen(uebersetzt("Mit dieser Adresse kann ich nichts anfangen."))
            return
        }

        meldetGerade = true
        gtk_widget_set_sensitive(verbindeknopf, 0)
        gtk_button_set_label(alsKnopf(verbindeknopf), uebersetzt("Verbinde …"))
        serverstandZeigen(String(format: uebersetzt("Frage %@ …"), url.absoluteString))

        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung, deviceName: Geraet.name)
            do {
                let info = try await c.publicSystemInfo()
                let name = info.serverName ?? url.host() ?? uebersetzt("Server")
                let fassung = info.version ?? "?"
                aufHauptfaden {
                    self.verbindenFertig()
                    self.serverURL = url
                    // **Sie wurde geholt und weggeworfen.** `serverfassung`
                    // stand in den Einstellungen und im Profil und war immer
                    // leer, weil niemand sie je gesetzt hat.
                    self.serverfassung = fassung
                    Speicher.serverMerken(.init(serverURL: url, servername: name,
                                                fassung: fassung))
                    gtk_label_set_text(OpaquePointer(self.serverzeile), name)
                    gtk_label_set_text(OpaquePointer(self.fassungszeile), "Jellyfin \(fassung)")
                    self.serverstandZeigen("")
                    gtk_stack_set_visible_child_name(OpaquePointer(self.anmeldeschritte), "konto")
                    gtk_widget_grab_focus(self.benutzerfeld)
                    self.kontenHolen(c)
                }
            } catch {
                aufHauptfaden {
                    self.verbindenFertig()
                    self.serverstandZeigen(lesbarerFehler(error))
                }
            }
        }
    }

    private func verbindenFertig() {
        meldetGerade = false
        gtk_widget_set_sensitive(verbindeknopf, 1)
        gtk_button_set_label(alsKnopf(verbindeknopf), uebersetzt("Verbinden"))
    }

    // MARK: Schritt zwei — anmelden

    private func anmelden() {
        guard !meldetGerade, let url = serverURL else { return }
        let benutzer = text(benutzerfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        let passwort = text(passwortfeld)
        guard !benutzer.isEmpty else { anmeldestandZeigen(uebersetzt("Trag einen Benutzernamen ein.")); return }

        meldetGerade = true
        gtk_widget_set_sensitive(anmeldeknopf, 0)
        gtk_button_set_label(alsKnopf(anmeldeknopf), uebersetzt("Melde an …"))
        anmeldestandZeigen("")

        let servername = gtk_label_get_text(OpaquePointer(serverzeile)).map { String(cString: $0) }

        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung, deviceName: Geraet.name)
            do {
                let sitzung = try await c.authenticate(username: benutzer, password: passwort)
                Speicher.schreiben(.init(serverURL: url,
                                         token: sitzung.accessToken,
                                         benutzerID: sitzung.userID,
                                         benutzername: benutzer,
                                         servername: servername))
                aufHauptfaden {
                    self.anmeldungFertig()
                    gtk_editable_set_text(OpaquePointer(self.passwortfeld), "")
                    self.sitzungUebernehmen(serverURL: url,
                                            token: sitzung.accessToken,
                                            benutzerID: sitzung.userID,
                                            benutzername: benutzer,
                                            servername: servername)
                }
            } catch {
                aufHauptfaden {
                    self.anmeldungFertig()
                    self.anmeldestandZeigen(lesbarerFehler(error))
                }
            }
        }
    }

    private func anmeldungFertig() {
        meldetGerade = false
        gtk_widget_set_sensitive(anmeldeknopf, 1)
        gtk_button_set_label(alsKnopf(anmeldeknopf), uebersetzt("Anmelden"))
    }

    private func sitzungUebernehmen(serverURL: URL, token: String, benutzerID: String,
                                    benutzername: String, servername: String?) {
        let c = JellyfinClient(baseURL: serverURL,
                               deviceID: Geraet.kennung,
                               deviceName: Geraet.name)
        adressen = Bildadresse(basis: serverURL, token: token)
        self.benutzerID = benutzerID
        sitzungAnzeigen(benutzername: benutzername, servername: servername)
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "start")

        // **`JellyfinClient` ist ein Akteur.** Die Sitzung einzusetzen geht
        // deshalb nur mit `await`; erst danach darf geladen werden.
        let sitzung = Session(accessToken: token, userID: benutzerID,
                              userName: benutzername, serverURL: serverURL)
        Task.detached { [self] in
            await c.setSession(sitzung)
            aufHauptfaden {
                self.client = c
                self.geladen = [.start]
                self.startseiteLaden()
                self.bibliothekenLaden()
                // **Erst hier, nicht früher.** `client` wird oben noch nicht
                // gesetzt — es geht über den Akteur und ist erst nach
                // `setSession` da. Alles, was mit `guard let client` beginnt,
                // stieg vorher stumm wieder aus: die Fernsteuerung meldete
                // ihre Fähigkeiten nie, und deshalb sah das iPhone die
                // Linux-Sitzung nicht als bedienbar. Der Übernahmetakt fiel
                // nicht auf, weil er ohnehin alle zehn Sekunden fragt und
                // sich damit selbst heilte.
                self.serverstandHolen()
                self.fernsteuerungStarten()
                self.uebernahmetaktStarten()
            }
        }
    }

    // MARK: - Das Fenster nach der Anmeldung

    private var titelzeile: Widget!
    var inhalt: Widget!            // GtkStack: start / filme / serien / suche
    /// Die Bühne: ein `GtkFixed`, auf dem die Listenebene und die beiden
    /// Detailebenen übereinanderliegen. Sie schneidet ab, was hinausragt.
    var buehne: Widget!
    /// Welche Ebene gerade obenauf liegt.
    var obenAuf: Widget!
    /// Die zuletzt gemeldete Grösse der Bühne.
    var buehnenBreite: Int32 = -1
    var buehnenHoehe: Int32 = -1
    private var bereichsknoepfe: [Widget?] = []
    private var bibliotheksrubrik: Widget!
    private var bibliotheksliste: Widget!
    private var profilbild: Widget!
    private var profilname: Widget!
    private var profilserver: Widget!
    private var filmeraster: Widget!
    private var serienraster: Widget!
    private var suchfeld: Widget!
    private var suchraster: Widget!
    private var suchleer: Widget!
    private var filmezahl: Widget!
    private var serienzahl: Widget!
    var geladen: Set<Bereich> = []
    /// Filter und Sortierung, je Bereich getrennt. Auf dem Mac merkt sich
    /// jeder Bereich seinen Stand — wer zwischen Filmen und Serien wechselt,
    /// findet zurück, wo er war.
    private var filter: [Bereich: Bibliotheksfilter] = [:]
    private var sortierung: [Bereich: Sortierung] = [:]
    private var chipzeilen: [Bereich: Widget] = [:]
    var benutzerID = ""
    var suchtakt = 0

    // MARK: Seitenstapel
    //
    /// **Je Bereich ein eigener Stapel**, wie `Navigator` auf dem Mac: wer
    /// zwischen Filmen und Serien wechselt, findet zurück, wo er war.
    var seitenstapel: [Bereich: [Item]] = [:]
    /// Die Staffel, mit der eine Serienseite öffnet — gesetzt, wenn der Weg
    /// über eine Folge führte (A8).
    var startStaffel: String?
    /// Wohin der Hauptknopf der offenen Detailseite zeigt, und welche Staffel
    /// dort gewählt ist. Die Mehr-Liste braucht beides — ohne sie liesse sich
    /// „Folge von vorn" und „Staffel als gesehen" nicht anbieten.
    var offenesZiel: Spielziel?
    var offeneStaffel: Item?
    /// Die Hinweiszeile der Detailseite.
    var hinweisfeld: Widget!
    /// Wohin der Dateiauszug kommt, sobald der Plan da ist.
    var dateiraum: Widget!
    var hinweistakt = 0
    /// Welche Unterseite offen ist (Profil, Quick Connect, …) — `nil`, wenn
    /// keine. Sie leben nicht im Bereichsstapel: auf dem Mac liegen sie
    /// ebenfalls quer dazu.
    var offeneUnterseite: Unterseite?
    var offeneListe: Werteauswahl?
    var wahlen = Wahlen.lesen()
    var benutzername = ""
    var servername = ""
    var serverfassung = ""
    /// Was im Raster schon steht, und wie viel der Server insgesamt hat —
    /// für das Nachladen beim Blättern.
    var filmeItems: [Item] = []
    var serienItems: [Item] = []
    var filmeGesamt = 0
    var serienGesamt = 0
    var rasterLaedt: Set<Bereich> = []
    var filmeLader: Widget!
    var serienLader: Widget!
    /// Die Fernsteuerung über Jellyfins Socket. Ohne sie meldet der Server
    /// `SupportsRemoteControl: false` und blendet im Dashboard die Knöpfe aus.
    var fernsteuerung: Fernsteuerung?
    /// Medientasten und die Wiedergabekachel der Arbeitsumgebung.
    var medienleiste: Medienleiste?
    private var uebernahmezeile: Widget!
    private var uebernahmetitel: Widget!
    private var uebernahmezeichen: Widget!
    private var uebernahmeangebote: [Fremdsitzung] = []
    private var uebernahmelauf: Task<Void, Never>?
    /// Vorspann- und Abspannmarken des laufenden Titels, vom Server.
    var abschnitte: [Abschnitt] = []
    var jetzigesAngebot: Knopfangebot = .keiner
    /// Ob der Nutzer auf der offenen Detailseite schon etwas gewählt hat.
    /// Die zuletzt aufgeklappte Tafel des Mehr-Knopfs. Sie wird beim nächsten
    /// Klick gelöst — sonst hängen sie sich am Knopf auf.
    var offeneTafel: Widget?
    var detailBeruehrt = false
    /// Was zuletzt bei „Verbindung prüfen" herauskam.
    var pruefergebnis = ""
    /// **Staffeln und Folgen, einmal geholt.**
    ///
    /// Der Mac hat dafür `Seriencache`: wer eine Serienseite verlässt und
    /// zurückkommt, sieht sie sofort stehen. Auf Linux wurde jedes Mal neu
    /// geholt, mit „Lade …" davor — bei einer Serie, die man mehrmals am
    /// Abend öffnet, ist das jedes Mal dieselbe Wartezeit.
    var staffelspeicher: [String: [Item]] = [:]
    var folgenspeicher: [String: [Item]] = [:]

    // MARK: Spieler
    /// **Erst beim ersten Abspielen.** Der Abspieler legt ein `GtkPicture`
    /// an, und ``App`` entsteht als globale Referenz — also **bevor**
    /// `g_application_run` GTK hochgefahren hat. Ein Widget vor `gtk_init`
    /// ist ein Absturz in libgtk, ohne eine Zeile eigenen Codes im Rückweg.
    lazy var abspieler = Abspieler()
    var laufenderTitel: Item?
    var laufenderPlan: PlaybackPlan?
    var spielstand = Wiedergabetakt.Stand()
    var seitOeffnen = Date()
    var spielertakt: guint = 0
    var steuerungstakt = 0
    var spielerSteuerung: Widget!
    var spielerZeit: Widget!
    var spielerRest: Widget!
    var spielerRegler: Widget!
    var spielerAbspielzeichen: Abspielzeichen?
    var spielerWeiter: Widget!
    var spielerSpurknopf: Widget!
    var spielerVollknopf: Widget!
    var spielerLadeschirm: Widget!
    /// Bis wann VLCs Zeit nicht übernommen wird — nach jedem Sprung.
    var sprungBis = Date.distantPast
    /// Ob gerade am Zeitregler gezogen wird.
    var amRegler = false
    var spielerWarnung: Widget!
    var spielerWarntext: Widget!
    /// Die beiden Kreispfeile. Sie tragen die Sprungweite als Zahl und
    /// müssen sie nachziehen, wenn sie sich in den Einstellungen ändert.
    var spielerZurueckZeichen: Sprungzeichen?
    var spielerVorZeichen: Sprungzeichen?
    /// Die Sprunganzeige am Bildrand.
    var spielerSprungLinks: Sprungzeichen?
    var spielerSprungRechts: Sprungzeichen?
    var sprungtakt = 0
    var spielerRahmen: Widget!
    var spurtafel: Widget!
    var schlafminuten: Int?
    var schlaftakt = 0

    // MARK: Bibliotheken (D9)
    /// Was der Server an Bibliotheken hat. **Ab zwei derselben Gattung** wird
    /// zwischen ihnen gewählt; bei einer erscheint kein Umschalter.
    var sichten: [Item] = []
    var gewaehlteBibliothek: [Bereich: String] = [:]
    /// Wann die Startseite zuletzt geladen hat — für D8.
    var zuletztGeladen: Date?
    /// **Die Detailseite hat zwei Scheiben, nicht eine.**
    ///
    /// Ein `GtkStack` bewegt sich zwischen *verschiedenen* Kindern. Wer
    /// dasselbe Kind leert und neu füllt, bekommt keine Bewegung — und genau
    /// so stand es hier: von der Startseite auf einen Film schob es, von
    /// einem Film auf die Serie dahinter nicht. Zwei Scheiben, abwechselnd
    /// gefüllt, machen aus jedem Schritt einen Wechsel.
    var detailscheiben: [Widget] = []
    var detailscheibe = 0
    var detailhuelle: Widget! { detailscheiben[detailscheibe] }
    /// Wird beim Blättern gebraucht, um den Titel in der Kopfleiste
    /// einzublenden — dieselbe Rechnung wie `Detailkopf.staerke` auf dem Mac.
    var detailkopfTitel: Widget!
    var detailkopfLeiste: Widget!
    var detailkopfVerlauf: Widget!

    /// **Seitenleiste links, Inhalt rechts** — der Aufbau des Macs.
    ///
    /// Auf dem Mac liegt die Seitenleiste über die volle Fensterhöhe, die
    /// Fensterampel schwebt darüber, und `Stil.ampelHoehe` hält ihr oben 40
    /// Punkt frei. Unter Wayland gehört die Titelzeile dem Fenster und nicht
    /// uns; die Leiste beginnt deshalb unter einer schmalen Kopfzeile, die
    /// dieselbe Farbe trägt wie die Leiste. Das ist die eine Abweichung, die
    /// sich nicht wegräumen lässt, ohne die Fensterknöpfe zu verlieren.
    private func startseiteBauen() -> Widget! {
        let quer = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 0)
        anhaengen(quer, seitenleisteBauen())

        inhalt = gtk_stack_new()
        // Der Bereichswechsel blendet über — auf dem Mac „Fade Through",
        // 200 ms hinaus und 260 ms herein. GTK kennt nur eine Dauer für
        // beides; 220 liegt dazwischen.
        gtk_stack_set_transition_type(OpaquePointer(inhalt), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(OpaquePointer(inhalt), 220)
        gtk_widget_set_hexpand(inhalt, 1)
        gtk_widget_set_vexpand(inhalt, 1)

        gtk_stack_add_named(OpaquePointer(inhalt), startbereichBauen(), "start")
        gtk_stack_add_named(OpaquePointer(inhalt), rasterseiteBauen(.filme), "filme")
        gtk_stack_add_named(OpaquePointer(inhalt), rasterseiteBauen(.serien), "serien")
        gtk_stack_add_named(OpaquePointer(inhalt), sucheBauen(), "suche")

        // **Die Detailseite legt sich auf, sie tritt nicht daneben.**
        //
        // Ein `GtkStack` schiebt beim Wechsel *beide* Kinder um die volle
        // Breite — das sieht aus, als lägen die Seiten nebeneinander. Der Mac
        // schiebt die neue Seite über die alte, und die darunter wandert nur
        // ein knappes Drittel mit. Dafür braucht es eine eigene Bühne.
        //
        // `GtkFixed` ist die einzige GTK-Kiste, die ihre Kinder frei
        // verschiebt, und `gtk_fixed_move` ändert dabei nur den Vorsatz,
        // nicht die Grösse — die Seite wird also nicht bei jedem Bild neu
        // umbrochen.
        buehne = gtk_fixed_new()
        gtk_widget_set_overflow(buehne, GTK_OVERFLOW_HIDDEN)
        gtk_fixed_put(alsFest(buehne), inhalt, 0, 0)
        for _ in 0..<2 {
            let scheibe: Widget! = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            detailscheiben.append(scheibe)
            gtk_fixed_put(alsFest(buehne), scheibe, 0, 0)
            gtk_widget_set_visible(scheibe, 0)
        }
        obenAuf = inhalt

        // **Ein `GtkFixed` gibt seinen Kindern die Wunschgrösse, nicht die
        // eigene** (Falle 1). Eine Seite ist innen ein Scroller und wünscht
        // sich fast nichts — sie fiele in sich zusammen. Also muss ihr jemand
        // die Grösse sagen, und dafür muss sie erst einmal jemand kennen.
        //
        // Die Zeichenfläche ist dieser Jemand: als **Hauptkind** einer
        // Überlagerung bekommt sie immer die volle Fläche, und ihr Signal
        // `resize` nennt sie. Gemalt wird darauf nichts.
        let masz: Widget! = gtk_drawing_area_new()
        gtk_widget_add_css_class(masz, "swiftly-blank")
        gtk_widget_set_hexpand(masz, 1)
        gtk_widget_set_vexpand(masz, 1)
        beiGroesse(masz) { [weak self] breite, hoehe in
            guard let self else { return }
            // **Nur wenn sich wirklich etwas geändert hat.**
            //
            // `gtk_widget_set_size_request` meldet eine neue Auslegung an —
            // auch dann, wenn derselbe Wert noch einmal gesetzt wird. Die
            // neue Auslegung teilt der Zeichenfläche wieder eine Grösse zu,
            // die meldet wieder, und das geht im Bildtakt weiter: **eine
            // Schleife, die sich selbst füttert.** Gemessen: 92 % Dauerlast,
            // schon auf dem Anmeldebildschirm, und ein Fenster, das nicht
            // mehr zum Zeichnen kam.
            guard breite != self.buehnenBreite || hoehe != self.buehnenHoehe else { return }
            self.buehnenBreite = breite
            self.buehnenHoehe = hoehe
            for ebene in [self.inhalt!] + self.detailscheiben {
                gtk_widget_set_size_request(ebene, breite, hoehe)
            }
        }

        let rahmen: Widget! = gtk_overlay_new()
        gtk_widget_set_hexpand(rahmen, 1)
        gtk_widget_set_vexpand(rahmen, 1)
        gtk_overlay_set_child(OpaquePointer(rahmen), masz)
        gtk_overlay_add_overlay(OpaquePointer(rahmen), buehne)
        anhaengen(quer, rahmen)

        titelzeile = beschriftung("", stil: "swiftly-zweitzeile")
        return quer
    }

    // MARK: Tastenkürzel

    /// **Dieselben Kürzel wie auf dem Mac**, nur mit Strg statt Befehl:
    /// 1 Start, 2 Filme, 3 Serien, F Suche. Sie stehen in
    /// `Sources/macOS/SwiftlyApp.swift` als `Kommandoknopf`.
    ///
    /// Auf dem Mac hängen sie in der Menüleiste; die gibt es hier nicht, also
    /// horcht das Fenster selbst. `GtkShortcutController` wäre der gehobene
    /// Weg, verlangt aber Aktionen mit Namen — für vier Tasten ist ein
    /// Tastenhorcher weniger Apparat.
    private func tastenEinrichten() {
        let horcher = gtk_event_controller_key_new()
        // **Erfassungsphase, nicht Blasenphase.**
        //
        // In der Blasenphase bekommt erst das fokussierte Widget die Taste.
        // Beim Öffnen des Players liegt der Fokus auf dem ersten Knopf oben —
        // und die Leertaste drückt ihn, statt anzuhalten. Wer vorher irgendwo
        // hingeklickt hatte, sah den Fehler nicht.
        //
        // Dieselbe Falle wie beim Scrollen, dort mit demselben Mittel gelöst.
        // Ungelesene Tasten reicht der Rückruf weiter, es geht also nichts
        // verloren — im Suchfeld tippt es sich weiter wie zuvor.
        gtk_event_controller_set_propagation_phase(horcher, GTK_PHASE_CAPTURE)
        g_signal_connect_data(UnsafeMutableRawPointer(horcher), "key-pressed",
                              unsafeBitCast(tasteGedrueckt, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(),
                              nil, GConnectFlags(rawValue: 0))
        gtk_widget_add_controller(fenster, horcher)
    }

    /// Wahr heißt: verbraucht, nicht weiterreichen.
    func taste(_ wert: UInt32, strg: Bool) -> Bool {
        // **Die Kürzel unter den Knöpfen müssen stimmen.**
        //
        // Unter den drei Knöpfen des Players stehen „←", „Leertaste" und „→"
        // — sie standen dort, ohne dass eine dieser Tasten etwas tat. Ein
        // Hinweis, der nicht stimmt, ist schlimmer als keiner.
        //
        // Dieselben vier wie auf dem Mac (`PlayerScreen` 242–247), ohne
        // Zusatztaste: Leertaste hält an, die Pfeile springen, Escape geht
        // zurück. Vollbild gibt es unter Wayland nicht als eigenen Zustand,
        // den wir führen — dort schliesst Escape gleich.
        if laufenderTitel != nil, !strg {
            switch wert {
            case 0x020:                                    // Leertaste
                abspieler.umschalten()
                spielstand.laeuft.toggle()
                spielerAbspielzeichen?.setzen(spielstand.laeuft)
                steuerungZeigen()
                return true
            case 0xFF51:                                   // Pfeil links
                abspieler.springen(-Double(wahlen.zurueckSekunden))
                sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
                spielerZurueckZeichen?.stupsen()
                sprungZeigen(true)
                steuerungZeigen()
                return true
            case 0xFF53:                                   // Pfeil rechts
                abspieler.springen(Double(wahlen.vorSekunden))
                sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
                spielerVorZeichen?.stupsen()
                sprungZeigen(false)
                steuerungZeigen()
                return true
            case 0xFFC8:                                   // F11
                vollbildUmschalten()
                return true
            case 0xFF1B:                                   // Escape
                if gtk_window_is_fullscreen(alsFenster(fenster)) != 0 {
                    gtk_window_unfullscreen(alsFenster(fenster))
                } else {
                    spielerSchliessen()
                }
                return true
            default: break
            }
        }
        guard strg else { return false }
        // GDKs Tastenwerte sind die ASCII-Zeichen; eigene Namen dafür gibt es
        // in Swift nicht, weil sie in GDK Makros sind.
        switch wert {
        case 0x031: zeige(.start)                          // 1
        case 0x032: zeige(.filme)                          // 2
        case 0x033: zeige(.serien)                         // 3
        case 0x066, 0x046:                                 // f / F
            zeige(.suche)
            gtk_widget_grab_focus(suchfeld)
        case 0x05B:                                        // [
            // **Zurück** — der Mac hat es als Cmd+[ im Menü „Gehe zu"
            // (`SwiftlyApp.swift:46`). Ohne das kommt man von einer
            // Unterseite nur über den Pfeil zurück.
            zurueck()
        default: return false
        }
        return true
    }

    // MARK: Kopfzeile

    /// **Die Kopfzeile bleibt leer.**
    ///
    /// Servername und „Abmelden" standen hier, solange es keine Seitenleiste
    /// gab. Auf dem Mac steht beides unten links im Konto, und dorthin ist es
    /// jetzt gewandert. Die Leiste selbst muss bleiben: unter Wayland hängen
    /// die Fensterknöpfe daran, und ohne sie liesse sich das Fenster nicht
    /// mehr schliessen.
    private func kopfzeileFuellen() {
        gtk_header_bar_set_title_widget(OpaquePointer(kopfzeile), titelzeile)
        kopfzeileZeigen(false)
    }

    private func kopfzeileZeigen(_ sichtbar: Bool) {
        gtk_widget_set_visible(titelzeile, sichtbar ? 1 : 0)
    }

    // MARK: Seitenleiste

    private func seitenleisteBauen() -> Widget! {
        let leiste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_add_css_class(leiste, "swiftly-seitenleiste")
        gtk_widget_set_size_request(leiste, Int32(Stil.seitenleisteBreite), -1)
        gtk_widget_set_hexpand(leiste, 0)

        // Marke: 28 hoch, 20 seitlich, 18 Luft darunter — HauptView.swift.
        let marke = Stil.wortmarke(hoehe: 28, links: true)
        gtk_widget_set_margin_start(marke, 20)
        gtk_widget_set_margin_end(marke, 20)
        gtk_widget_set_margin_top(marke, 14)
        gtk_widget_set_margin_bottom(marke, 18)
        anhaengen(leiste, marke)

        // Die vier Bereiche, 2 Abstand, 12 seitlich.
        let bereiche = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_margin_start(bereiche, 12)
        gtk_widget_set_margin_end(bereiche, 12)
        for fall in Bereich.allCases {
            let zeile = seitenleistenzeile(symbol: fall.symbol,
                                           text: fall.beschriftung,
                                           aktiv: fall == bereich)
            beiSignal(zeile, "clicked") { [weak self] in self?.zeige(fall) }
            bereichsknoepfe.append(zeile)
            anhaengen(bereiche, zeile)
        }
        anhaengen(leiste, bereiche)

        bibliotheksrubrik = rubrik(uebersetzt("Bibliotheken"))
        gtk_widget_set_margin_top(bibliotheksrubrik, 26)
        gtk_widget_set_margin_bottom(bibliotheksrubrik, 8)
        gtk_widget_set_margin_start(bibliotheksrubrik, 12)
        gtk_widget_set_margin_end(bibliotheksrubrik, 12)
        gtk_widget_set_visible(bibliotheksrubrik, 0)
        anhaengen(leiste, bibliotheksrubrik)

        bibliotheksliste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_margin_start(bibliotheksliste, 12)
        gtk_widget_set_margin_end(bibliotheksliste, 12)
        anhaengen(leiste, bibliotheksliste)

        anhaengen(leiste, luft())
        // **Was auf einem anderen Gerät läuft, steht neben dem Konto.**
        //
        // Genau dort, wo man ohnehin hinsieht — dieselbe Stelle wie das
        // Abzeichen auf iPhone und Fernseher, nur in der Form dieser Leiste
        // (`macOS/HauptView.swift:473`). Sichtbar wird sie nur, wenn es
        // wirklich etwas zu übernehmen gibt.
        uebernahmezeile = uebernahmezeileBauen()
        gtk_widget_set_visible(uebernahmezeile, 0)
        anhaengen(leiste, uebernahmezeile)
        anhaengen(leiste, trennlinie())
        anhaengen(leiste, profilzeileBauen())
        return leiste
    }

    /// Wer angemeldet ist, und wo. Unten in der Leiste — 40 hoch, Bild 26,
    /// Name 14 halbfett, Server 11 sehr leise.
    /// Die Zeile „Hier weiterschauen".
    ///
    /// **Mass für Mass vom Mac** (`Macbausteine.Uebernahmezeile`): 40 hoch,
    /// 10 innen, Zeichen 26 breit im Akzent, darunter Titel und Folge in 11
    /// auf sehr leiser Schrift. Der Kasten trägt Akzent zu 6 % mit einem Rand
    /// zu 18 %, schwebend 12 und 35.
    ///
    /// Zuerst stand hier der Titel oben und „läuft auf iPhone" darunter. Das
    /// sagt, **was** läuft — der Mac sagt, **was man tun kann**, und stellt
    /// den Titel darunter. Bei einem Angebot ist das die richtige Reihenfolge.
    private func uebernahmezeileBauen() -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-uebernahme")
        gtk_widget_set_margin_start(knopf, 12)
        gtk_widget_set_margin_end(knopf, 12)
        gtk_widget_set_margin_bottom(knopf, 4)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        uebernahmezeichen = gtk_image_new_from_icon_name("phone-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(uebernahmezeichen), 13)
        gtk_widget_set_size_request(uebernahmezeichen, 26, -1)
        anhaengen(reihe, uebernahmezeichen)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let oben = beschriftung(uebersetzt("Hier weiterschauen"), stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(oben), 0)
        gtk_label_set_ellipsize(OpaquePointer(oben), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(oben), 1)
        anhaengen(text, oben)
        uebernahmetitel = beschriftung("", stil: "swiftly-uebernahmezeile")
        gtk_label_set_xalign(OpaquePointer(uebernahmetitel), 0)
        gtk_label_set_ellipsize(OpaquePointer(uebernahmetitel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(uebernahmetitel), 1)
        anhaengen(text, uebernahmetitel)
        gtk_widget_set_hexpand(text, 1)
        anhaengen(reihe, text)

        gtk_button_set_child(alsKnopf(knopf), reihe)
        beiSignal(knopf, "clicked") { [weak self] in self?.uebernehmen() }
        beschriften(knopf, uebersetzt("Wiedergabe übernehmen"))
        return knopf
    }

    /// **Welches Zeichen zu welchem Gerät.** Die Entscheidung, *welches*
    /// Gerät es ist, liegt im Paket — hier steht nur, wie Adwaita es nennt.
    private func geraetezeichen(_ art: Fremdsitzung.Geraeteart) -> String {
        switch art {
        case .telefon:   "phone-symbolic"
        case .tablet:    "tablet-symbolic"
        case .rechner:   "computer-symbolic"
        case .fernseher: "video-display-symbolic"
        case .unbekannt: "media-playback-start-symbolic"
        }
    }

    /// **Fragt regelmässig, was anderswo läuft.**
    ///
    /// Ein Takt statt eines einmaligen Blicks: die andere Sitzung fängt an,
    /// während diese App schon offen ist, und ein Angebot, das erst nach dem
    /// nächsten Start erscheint, ist keins. Zehn Sekunden — der Server meldet
    /// den Fortschritt ohnehin in dem Takt.
    func uebernahmetaktStarten() {
        uebernahmelauf?.cancel()
        uebernahmelauf = Task.detached { [self] in
            while !Task.isCancelled {
                await self.uebernahmeFragen()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func uebernahmeFragen() async {
        guard let client, !benutzerID.isEmpty else { return }
        let sitzungen = await client.fremdsitzungen()
        let angebote = Uebernahme.angebote(aus: sitzungen,
                                           eigeneGeraeteID: Geraet.kennung,
                                           eigeneBenutzerID: benutzerID)
        aufHauptfaden {
            self.uebernahmeangebote = angebote
            self.uebernahmeZeigen()
        }
    }

    private func uebernahmeZeigen() {
        guard let zeile = uebernahmezeile else { return }
        // **Nicht, während hier selbst etwas läuft.** Dann wäre das Angebot
        // eine Einladung, sich selbst zu unterbrechen.
        guard laufenderTitel == nil, let erste = uebernahmeangebote.first,
              let titel = erste.laeuft else {
            gtk_widget_set_visible(zeile, 0)
            return
        }
        _ = titel
        gtk_label_set_text(OpaquePointer(uebernahmetitel), erste.titelzeile)
        gtk_image_set_from_icon_name(OpaquePointer(uebernahmezeichen),
                                     geraetezeichen(erste.geraeteart))
        gtk_widget_set_visible(zeile, 1)
    }

    /// **Erst drüben beenden, dann hier starten** — und den Fehler nicht
    /// schlucken. Läuft es dort weiter, während hier dasselbe beginnt, stehen
    /// zwei Tonspuren im Raum und niemand versteht, warum.
    ///
    /// **Beenden, nicht anhalten.** Pausiert bleibt die Verbindung offen, die
    /// Sitzung steht weiter in der Übersicht, und auf dem anderen Gerät liegt
    /// der Player noch über allem. Die Stelle ist vorher gelesen, sie geht
    /// dabei nicht verloren.
    private func uebernehmen() {
        guard let client, let sitzung = uebernahmeangebote.first,
              let titel = sitzung.laeuft else { return }
        let ab = sitzung.stand?.stelle ?? 0
        gtk_widget_set_visible(uebernahmezeile, 0)
        Task.detached { [self] in
            do { try await client.fremdbefehl(.beenden, an: sitzung.id) }
            catch {
                aufHauptfaden {
                    self.uebernahmeangebote = []
                    self.anmeldestandZeigen(lesbarerFehler(error))
                }
                return
            }
            aufHauptfaden {
                self.uebernahmeangebote = []
                self.starte(titel, ab: ab)
            }
        }
    }

    private func profilzeileBauen() -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-profil")
        raender(knopf, 12)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)

        let (bildkaefigChen, bild) = gerahmtesBild(breite: 26, hoehe: 26,
                                                   stil: "swiftly-profilbild")
        profilbild = bild
        gtk_widget_set_valign(bildkaefigChen, GTK_ALIGN_CENTER)
        anhaengen(reihe, bildkaefigChen)

        let namen = stapel(GTK_ORIENTATION_VERTICAL, abstand: 1)
        gtk_widget_set_valign(namen, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(namen, 1)
        profilname = beschriftung("—", stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(profilname), 0)
        gtk_label_set_ellipsize(OpaquePointer(profilname), PANGO_ELLIPSIZE_END)
        anhaengen(namen, profilname)
        profilserver = beschriftung("", stil: "swiftly-rubrik")
        gtk_widget_add_css_class(profilserver, "swiftly-leise")
        gtk_label_set_xalign(OpaquePointer(profilserver), 0)
        gtk_label_set_ellipsize(OpaquePointer(profilserver), PANGO_ELLIPSIZE_END)
        anhaengen(namen, profilserver)
        anhaengen(reihe, namen)

        gtk_button_set_child(alsKnopf(knopf), reihe)
        // Auf dem Mac führt die Zeile aufs Profil; „Abmelden" liegt dort eine
        // Ebene tiefer.
        beiSignal(knopf, "clicked") { [weak self] in self?.unterseiteOeffnen(.profil) }
        return knopf
    }

    /// Wie eine Seite den Platz wechselt.
    ///
    /// Auf dem Mac ist das `Stil.zeitSeitenschub` — `easeInOut`, 0,45 s —
    /// mit der Regel „tiefer gehen schiebt von rechts, zurück schiebt nach
    /// rechts hinaus". Ein Bereichswechsel dagegen blendet über („Fade
    /// Through"), weil er nicht tiefer führt, sondern daneben.
    enum Schub { case tiefer, zurueck, ohne }

    /// Legt eine Ebene obenauf und schiebt sie dabei herein.
    ///
    /// Der Mac nimmt `Stil.zeitSeitenschub` — `easeInOut`, 0,45 s. Die neue
    /// Seite legt sich über die alte; die alte wandert **ein knappes Drittel**
    /// nach links mit und bleibt liegen. Zurück läuft es rückwärts: die obere
    /// Seite schiebt sich nach rechts hinaus und gibt die darunter frei.
    ///
    /// Wer wen überdeckt, entscheidet die Reihenfolge im `GtkFixed` — beim
    /// Vorwärtsschub muss die neue Ebene oben liegen, beim Zurückschub die
    /// alte, weil sie diejenige ist, die sich bewegt.
    func schieben(zu ziel: Widget!, richtung: Schub) {
        let alt: Widget! = obenAuf
        obenAuf = ziel
        gtk_widget_set_visible(ziel, 1)
        guard alt != ziel else { return }

        let fest = alsFest(buehne)
        let breite = Double(gtk_widget_get_width(buehne))
        guard richtung != .ohne, breite > 1 else {
            gtk_fixed_move(fest, ziel, 0, 0)
            gtk_widget_set_visible(alt, 0)
            return
        }

        gtk_widget_insert_before(richtung == .tiefer ? ziel : alt, buehne, nil)
        Schubsperre.beginnen()
        let teiler = Double(max(gtk_widget_get_scale_factor(buehne), 1))
        // Auf ganze Gerätepunkte, aus demselben Grund wie beim Scrollen: eine
        // Kante auf einem halben Punkt wird geglättet und säumt.
        func rasten(_ x: Double) -> Double { (x * teiler).rounded() / teiler }

        laufen(auf: buehne, dauer: Stil.zeitSeitenschub) { e in
            if richtung == .tiefer {
                gtk_fixed_move(fest, ziel, rasten(breite * (1 - e)), 0)
                gtk_fixed_move(fest, alt, rasten(-breite * Stil.schubMitgabe * e), 0)
                gtk_widget_set_opacity(alt, 1 - Stil.schubSchleier * e)
            } else {
                gtk_fixed_move(fest, alt, rasten(breite * e), 0)
                gtk_fixed_move(fest, ziel, rasten(-breite * Stil.schubMitgabe * (1 - e)), 0)
                gtk_widget_set_opacity(ziel, 1 - Stil.schubSchleier * (1 - e))
            }
        } fertig: {
            gtk_fixed_move(fest, ziel, 0, 0)
            gtk_fixed_move(fest, alt, 0, 0)
            gtk_widget_set_opacity(ziel, 1)
            gtk_widget_set_opacity(alt, 1)
            gtk_widget_set_visible(alt, 0)
            Schubsperre.beenden()
        }
    }

    /// Zeigt einen Bereich — im Stapel überblendet, auf der Bühne geschoben.
    func bereichZeigen(_ kennung: String, schub: Schub) {
        gtk_stack_set_visible_child_name(OpaquePointer(inhalt), kennung)
        schieben(zu: inhalt, richtung: schub)
    }

    /// Nimmt die freie Detailscheibe und leert sie.
    func naechsteScheibe() -> Widget! {
        detailscheibe = 1 - detailscheibe
        leeren(detailhuelle)
        return detailhuelle
    }

    /// Schaltet den Bereich um und färbt die Zeilen nach.
    func zeige(_ neu: Bereich) {
        bereich = neu
        for (i, fall) in Bereich.allCases.enumerated() {
            guard let knopf = bereichsknoepfe[i] else { continue }
            if fall == neu { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(knopf, "swiftly-aktiv") }
        }
        // **Der Stapel entscheidet, was zu sehen ist.** Liegt auf diesem
        // Bereich eine Detailseite, kommt sie zurück — nicht die Liste.
        if let oben = seitenstapel[neu]?.last {
            detailZeigen(oben, schub: .ohne)
        } else {
            bereichZeigen(neu.kennung, schub: .ohne)
        }
        // **Wer auf „Suche" geht, will tippen.** Der Mac setzt den Fokus beim
        // Erscheinen der Seite; hier ging es nur über Strg+F.
        if neu == .suche { gtk_widget_grab_focus(suchfeld) }
        // **Jeder Bereich lädt einmal.** Auf dem Mac bleiben die Stände der
        // Bereiche liegen; wer zwischen Filmen und Serien wechselt, wartet
        // nur beim ersten Mal.
        guard !geladen.contains(neu) else { return }
        geladen.insert(neu)
        switch neu {
        case .start:  startseiteLaden()
        case .filme:  rasterLaden(.filme)
        case .serien: rasterLaden(.serien)
        case .suche:  break
        }
    }

    // MARK: Inhaltsseiten

    /// Der gemeinsame Rahmen jeder Seite: oben 52, seitlich 24 — `inhaltOben`
    /// und `randAbstand` vom Mac.
    private func seitenrahmen(_ kind: Widget!) -> Widget! {
        let scroller = seitenscroller()
        gtk_widget_set_margin_top(kind, Int32(Stil.inhaltOben))
        gtk_widget_set_margin_start(kind, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(kind, Int32(Stil.randAbstand))
        gtk_widget_set_margin_bottom(kind, Int32(Stil.randAbstand))
        gtk_scrolled_window_set_child(OpaquePointer(scroller), kind)
        return scroller
    }

    /// Eine Seitenüberschrift mit der Zahl rechts — „Filme … 7".
    private func seitenkopf(_ titel: String, zahl: inout Widget!) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        let t = beschriftung(titel, stil: "swiftly-titel-gross")
        gtk_label_set_xalign(OpaquePointer(t), 0)
        gtk_widget_set_hexpand(t, 1)
        anhaengen(reihe, t)
        zahl = beschriftung("", stil: "swiftly-koerper")
        gtk_widget_add_css_class(zahl, "swiftly-leise")
        gtk_widget_set_valign(zahl, GTK_ALIGN_CENTER)
        anhaengen(reihe, zahl)
        return reihe
    }

    /// **Die Startseite bekommt seitlich keinen Rand.**
    ///
    /// Paul hat es gesehen: an beiden Kanten standen schwarze Balken, und die
    /// Kacheln verschwanden 24 Punkt vor dem Fensterrand. Der Grund war der
    /// Rand hier — er schneidet die waagerechte Blätterfläche mit ab.
    ///
    /// Auf dem Mac trägt nicht die Seite den Rand, sondern die Reihe **innen**
    /// (`Blätterreihe.rand`): die Kacheln beginnen unter der Überschrift und
    /// blättern trotzdem bis an die Fensterkante. Genau so hier.
    private func startbereichBauen() -> Widget! {
        reihenstapel = stapel(GTK_ORIENTATION_VERTICAL, abstand: Int32(Stil.reihenAbstand))
        // **Derselbe Scroller wie überall.** Hier stand ein blanker
        // `GtkScrolledWindow` — ohne Regel, also mit GTKs Vorgabe
        // `AUTOMATIC`: die Systemleiste rechts, genau die, die auf keiner
        // Seite auftauchen soll. `seitenscroller` setzt `EXTERNAL` (scrollen
        // ja, Leiste nein) und hängt das weiche Laufen dran.
        let scroller = seitenscroller()
        gtk_widget_set_margin_top(reihenstapel,
                                  Int32(Stil.inhaltOben + Stil.reihenkopfAusgleich))
        gtk_widget_set_margin_bottom(reihenstapel, Int32(Stil.randAbstand))
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihenstapel)
        return scroller
    }

    private func rasterseiteBauen(_ was: Bereich) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 20)
        var zahl: Widget!
        anhaengen(block, seitenkopf(was.beschriftung, zahl: &zahl))

        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        chipzeilen[was] = zeile
        anhaengen(block, zeile)
        chipsFuellen(was)

        let raster = rasterBauen()
        anhaengen(block, raster)
        let lader = beschriftung(uebersetzt("Lade …"), stil: "swiftly-koerper")
        gtk_widget_add_css_class(lader, "swiftly-leise")
        gtk_widget_set_halign(lader, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(lader, 40)
        gtk_widget_set_visible(lader, 0)
        anhaengen(block, lader)
        if was == .filme { filmeraster = raster; filmezahl = zahl; filmeLader = lader }
        else { serienraster = raster; serienzahl = zahl; serienLader = lader }

        let rahmen = seitenrahmen(block)
        // **Am unteren Rand wird nachgeladen** (`edge-reached` — das Signal
        // bringt die Kante mit, also wieder ein eigener Rückruf, Falle 2).
        randMelden(rahmen) { [weak self] in self?.rasterNachladen(was) }
        return rahmen
    }

    /// **Filter links, Sortierung rechts** — die Anordnung des Macs.
    ///
    /// Beide Listen kommen aus `JellyfinKit.Bibliotheksfilter` und
    /// `Sortierung`. Dort steht auch, was sie beim Server bedeuten, und dass
    /// „Ungesehen" bewusst den eigenen Schalter braucht statt Jellyfins
    /// `Filters=IsUnplayed` — das arbeitet bei Serien auf Folgenebene.
    /// Die Bibliotheken einer Gattung.
    func bibliotheken(fuer was: Bereich) -> [Item] {
        let art = was == .filme ? "movies" : "tvshows"
        return sichten.filter { $0.collectionType == art }
    }

    func chipsFuellen(_ was: Bereich) {
        guard let zeile = chipzeilen[was] else { return }
        leeren(zeile)
        let jetztFilter = filter[was] ?? .alle
        let jetztSort = sortierung[was] ?? .name

        // **Die Bibliothekswahl steht vorn, und nur ab zwei** (D9). Als Chips
        // wie Filter und Sortierung daneben — ein aufklappendes Menü wäre ein
        // Standardsteuerelement (E4).
        let meine = bibliotheken(fuer: was)
        if meine.count > 1 {
            let gewaehlteID = gewaehlteBibliothek[was] ?? meine[0].id
            for bib in meine {
                let c = chip(bib.name, aktiv: bib.id == gewaehlteID)
                beiSignal(c, "clicked") { [weak self] in
                    guard let self, bib.id != gewaehlteID else { return }
                    self.gewaehlteBibliothek[was] = bib.id
                    self.chipsFuellen(was)
                    self.rasterLaden(was)
                }
                anhaengen(zeile, c)
            }
            let strich: Widget! = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
            gtk_widget_add_css_class(strich, "swiftly-trennlinie")
            gtk_widget_set_size_request(strich, 1, 18)
            gtk_widget_set_valign(strich, GTK_ALIGN_CENTER)
            gtk_widget_set_margin_start(strich, 4)
            gtk_widget_set_margin_end(strich, 4)
            anhaengen(zeile, strich)
        }

        for fall in Bibliotheksfilter.allCases {
            let c = chip(fall.beschriftung, aktiv: fall == jetztFilter)
            beiSignal(c, "clicked") { [weak self] in
                guard let self else { return }
                self.filter[was] = fall
                self.chipsFuellen(was)
                self.rasterLaden(was)
            }
            anhaengen(zeile, c)
        }

        anhaengen(zeile, luftQuer())

        for fall in Sortierung.allCases {
            let c = chip(fall.beschriftung, symbol: fall == jetztSort
                         ? "object-select-symbolic" : nil, aktiv: fall == jetztSort)
            beiSignal(c, "clicked") { [weak self] in
                guard let self else { return }
                self.sortierung[was] = fall
                self.chipsFuellen(was)
                self.rasterLaden(was)
            }
            anhaengen(zeile, c)
        }
    }

    private func sucheBauen() -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 20)
        var unbenutzt: Widget!
        anhaengen(block, seitenkopf(uebersetzt("Suche"), zahl: &unbenutzt))

        suchfeld = eingabezeile(symbol: "system-search-symbolic", platzhalter: uebersetzt("Suchen"))
        // Auf der Suchseite geht das Feld über die Inhaltsbreite, nicht über
        // die 360 des Anmeldeblocks.
        gtk_widget_set_size_request(suchfeld, -1, Int32(Stil.feldHoehe))
        gtk_widget_set_halign(suchfeld, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(suchfeld, 1)
        anhaengen(block, suchfeld)

        suchraster = rasterBauen()
        anhaengen(block, suchraster)
        // **Leer ist eine Auskunft.** Ohne sie steht die Seite still da, und
        // man weiss nicht, ob gesucht wurde oder nichts da ist.
        suchleer = leerzustand("system-search-symbolic", uebersetzt("Nichts gefunden"),
                               uebersetzt("Andere Schreibweise? Die Suche findet Filme und Serien."))
        gtk_widget_set_visible(suchleer, 0)
        anhaengen(block, suchleer)
        beiSignal(suchfeld, "activate") { [weak self] in self?.suchen() }
        beiSignal(suchfeld, "changed") { [weak self] in self?.sucheAngestossen() }
        return seitenrahmen(block)
    }

    /// **Eine Scrollfläche ohne Leiste, dafür mit weichem Lauf.**
    ///
    /// Die senkrechte Leiste braucht niemand — gescrollt wird am Rad, und ein
    /// Balken über dem Inhalt ist dasselbe Ärgernis wie der waagerechte in
    /// den Reihen. `EXTERNAL` heisst: scrollen ja, Leiste nein.
    ///
    /// Das weiche Laufen macht ``weichesScrollen``; GTK springt am Rad sonst
    /// von Rastpunkt zu Rastpunkt.
    func seitenscroller() -> Widget! {
        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        weichesScrollen(scroller)
        return scroller
    }

    /// Zeigt oder verbirgt die Ladeanzeige über einem Raster.
    ///
    /// Beim Wechsel von Filter, Sortierung oder Bibliothek stand das alte
    /// Raster still da, bis das neue eintraf — es sah aus, als hätte der
    /// Klick nichts getan.
    func rasterLaderZeigen(_ was: Bereich, _ an: Bool) {
        let lader = was == .filme ? filmeLader : serienLader
        guard let lader else { return }
        gtk_widget_set_visible(lader, an ? 1 : 0)
    }

    /// **Leer ist eine Auskunft, kein leerer Kasten.** Symbol, Satz,
    /// Erklärzeile — die Form vom Mac (`Leerzustand`).
    func leerzustand(_ symbol: String, _ titel: String, _ text: String) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)
        gtk_widget_set_halign(block, GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(block, 100)
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 34)
        gtk_widget_add_css_class(bild, "swiftly-sehrleise")
        anhaengen(block, bild)
        let t = beschriftung(titel, stil: "swiftly-kacheltitel")
        gtk_widget_set_halign(t, GTK_ALIGN_CENTER)
        anhaengen(block, t)
        let u = beschriftung(text, stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(u, "swiftly-leise")
        gtk_label_set_justify(OpaquePointer(u), GTK_JUSTIFY_CENTER)
        gtk_widget_set_halign(u, GTK_ALIGN_CENTER)
        anhaengen(block, u)
        return block
    }

    /// Ein umbrechendes Raster. GTKs `GtkFlowBox` kann genau das, was auf dem
    /// Mac ein `LazyVGrid` mit fester Spaltenbreite tut.
    func rasterBauen() -> Widget! {
        let raster: Widget! = gtk_flow_box_new()
        gtk_flow_box_set_selection_mode(OpaquePointer(raster), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(OpaquePointer(raster), 1)
        gtk_flow_box_set_column_spacing(OpaquePointer(raster), UInt32(Stil.kachelAbstand))
        gtk_flow_box_set_row_spacing(OpaquePointer(raster), UInt32(Stil.reihenAbstand))
        gtk_flow_box_set_min_children_per_line(OpaquePointer(raster), 2)
        gtk_flow_box_set_max_children_per_line(OpaquePointer(raster), 10)
        gtk_widget_set_valign(raster, GTK_ALIGN_START)
        return raster
    }

    func rasterFuellen(_ raster: Widget!, _ items: [Item]) {
        while let kind = gtk_flow_box_get_child_at_index(OpaquePointer(raster), 0) {
            gtk_flow_box_remove(OpaquePointer(raster),
                                unsafeBitCast(kind, to: Widget.self))
        }
        for item in items {
            gtk_flow_box_insert(OpaquePointer(raster), rasterkachel(item), -1)
        }
    }

    // MARK: Laden

    /// **Ohne die taucht die Sitzung im Dashboard auf, laesst sich aber nicht
    /// bedienen.** Es fehlen zwei Dinge, nicht eins: die Faehigkeitsmeldung,
    /// mit der der Server ueberhaupt erst Knoepfe anzeigt, und der Socket, ueber
    /// den die Befehle dann ankommen. Beides liegt im Paket und wurde von
    /// Linux nie benutzt — die Fassung war von aussen nicht steuerbar und
    /// nicht uebernehmbar.
    func fernsteuerungStarten() {
        guard let client else { return }
        Task.detached {
            try? await client.faehigkeitenMelden()
            guard let fern = try? await client.fernsteuerung() else { return }
            aufHauptfaden { self.fernsteuerung = fern }
            await fern.starten { befehl in
                aufHauptfaden { self.fernbefehlAusfuehren(befehl) }
            }
        }
    }

    /// Was die Medientaste auslöst. Dieselben Griffe wie am Knopf.
    func medienGriff(_ griff: Medienleiste.Griff) {
        guard laufenderTitel != nil else { return }
        switch griff {
        case .abspielen:  abspieler.abspielen()
        case .anhalten:   abspieler.anhalten()
        case .umschalten: abspieler.umschalten()
        case .beenden:    spielerSchliessen(); return
        case .weiter:     naechsteFolge(); return
        case .zurueck:    break
        }
        spielstand.laeuft = abspieler.laeuft
        spielerAbspielzeichen?.setzen(spielstand.laeuft)
        medienstandMelden()
        steuerungZeigen()
    }

    /// Sagt der Umgebung, was läuft. **Nach jeder Änderung** — D-Bus fragt
    /// nicht von selbst nach, und wer nichts meldet, dessen Kachel steht für
    /// immer auf „Pausiert".
    func medienstandMelden() {
        guard let titel = laufenderTitel else {
            medienleiste?.standMelden(laeuft: false, titel: "", untertitel: "",
                                      dauer: 0, stelle: 0)
            return
        }
        medienleiste?.standMelden(laeuft: spielstand.laeuft,
                                  titel: titel.name,
                                  untertitel: titel.kontextzeile ?? titel.seriesName ?? "",
                                  dauer: spielstand.dauer,
                                  stelle: spielstand.position)
    }

    /// Was ein anderes Geraet hier ausloest. Dieselben Griffe wie am Knopf.
    func fernbefehlAusfuehren(_ befehl: Fernbefehl) {
        guard laufenderTitel != nil else {
            // Ohne laufenden Titel gibt es nichts zu steuern; „stopp" waere
            // sonst ein Schliessen ins Leere.
            return
        }
        switch befehl {
        case .pause:    abspieler.anhalten()
        case .weiter:   abspieler.abspielen()
        case .umschalten: abspieler.umschalten()
        case .stopp:    spielerSchliessen()
        case let .springenAuf(stelle): abspieler.setzeZeit(stelle)
        case .vor:      abspieler.springen(Double(wahlen.vorSekunden))
        case .zurueck:  abspieler.springen(-Double(wahlen.zurueckSekunden))
        case .naechste: naechsteFolge()
        case .vorige:   break
        }
        if befehl != .stopp {
            spielstand.laeuft = abspieler.laeuft
            spielerAbspielzeichen?.setzen(spielstand.laeuft)
            steuerungZeigen()
        }
    }

    /// **Eine abgelaufene Anmeldung fiel bisher gar nicht auf.**
    ///
    /// Der Server antwortet dann mit 401, und weil hier überall `try?` steht,
    /// kam einfach nichts zurück: leere Startseite, leeres Raster, und der
    /// Nutzer sucht den Fehler bei sich. Der Mac fällt auf den
    /// Anmeldebildschirm zurück und sagt, warum
    /// (`Shared/AppModel.swift:789`).
    func sitzungPruefen(_ fehler: any Error) {
        guard let j = fehler as? JellyfinError, case let .http(status, _) = j,
              status == 401 else { return }
        abmelden()
        anmeldestandZeigen(uebersetzt("Die Anmeldung gilt nicht mehr. Bitte neu anmelden."))
    }

    func abmelden() {
        Task.detached { [fernsteuerung] in await fernsteuerung?.beenden() }
        fernsteuerung = nil
        uebernahmelauf?.cancel()
        uebernahmelauf = nil
        uebernahmeangebote = []
        Speicher.loeschen()
        client = nil
        adressen = nil
        geladen.removeAll()
        seitenstapel.removeAll()
        offeneUnterseite = nil
        leeren(reihenstapel)
        gtk_editable_set_text(OpaquePointer(passwortfeld), "")
        anmeldestandZeigen("")
        serverstandZeigen("")
        kopfzeileZeigen(false)
        gtk_stack_set_visible_child_name(OpaquePointer(anmeldeschritte), "server")
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "anmeldung")
    }

    /// Name, Server und Bild unten in der Leiste, dazu die Bibliotheken.
    /// Holt Namen und Fassung des Servers nach — beim Start aus einer
    /// gemerkten Sitzung hat sie niemand gefragt.
    private func serverstandHolen() {
        guard let client else { return }
        Task.detached { [self] in
            guard let info = try? await client.publicSystemInfo() else { return }
            aufHauptfaden {
                self.serverfassung = info.version ?? ""
                if let name = info.serverName, !name.isEmpty {
                    self.servername = name
                    gtk_label_set_text(OpaquePointer(self.profilserver), name)
                }
            }
        }
    }

    private func sitzungAnzeigen(benutzername: String, servername: String?) {
        self.benutzername = benutzername
        self.servername = servername ?? ""
        gtk_label_set_text(OpaquePointer(profilname), benutzername)
        gtk_label_set_text(OpaquePointer(profilserver), servername ?? "")
        if let adressen, !benutzerID.isEmpty,
           let url = adressen.benutzer(benutzerID, kante: 60) {
            bildLaden(profilbild, url: url, schluessel: "benutzer-\(benutzerID)", sofort: true)
        }
    }

    private func bibliothekenLaden() {
        guard let client else { return }
        Task.detached { [self] in
            let sichten = (try? await client.userViews()) ?? []
            aufHauptfaden { self.bibliothekenZeigen(sichten) }
        }
    }

    private func bibliothekenZeigen(_ sichten: [Item]) {
        self.sichten = sichten
        leeren(bibliotheksliste)
        gtk_widget_set_visible(bibliotheksrubrik, sichten.isEmpty ? 0 : 1)
        for sicht in sichten {
            // Der Sammlungstyp bestimmt das Zeichen, wie auf dem Mac.
            let symbol: String
            switch sicht.collectionType {
            case "movies":  symbol = "video-x-generic-symbolic"
            case "tvshows": symbol = "tv-symbolic"
            case "music":   symbol = "folder-music-symbolic"
            default:        symbol = "folder-symbolic"
            }
            let zeile = seitenleistenzeile(symbol: symbol, text: sicht.name, aktiv: false)
            // Eine Bibliothek führt in ihren Bereich und wählt sich dort aus.
            let ziel: Bereich? = sicht.collectionType == "tvshows" ? .serien
                               : sicht.collectionType == "movies" ? .filme : nil
            beiSignal(zeile, "clicked") { [weak self] in
                guard let self, let ziel else { return }
                self.gewaehlteBibliothek[ziel] = sicht.id
                self.geladen.remove(ziel)
                self.zeige(ziel)
                self.chipsFuellen(ziel)
            }
            anhaengen(bibliotheksliste, zeile)
        }
    }

    func startseiteLaden() {
        guard let client else { return }
        zuletztGeladen = Date()
        // **„Lade …" nur beim ersten Mal.** Beim Nachladen (D8, und beim
        // Schliessen des Players) steht schon alles da; es wegzuwerfen und
        // durch ein Wort zu ersetzen, sah aus, als sei die App neu gestartet
        // — dabei ändert sich meist nur ein Fortschrittsbalken. Ersetzt wird
        // erst, wenn die neuen Reihen da sind.
        if gtk_widget_get_first_child(reihenstapel) == nil {
            anhaengen(reihenstapel, beschriftung(uebersetzt("Lade …"), stil: "swiftly-koerper"))
        }

        // Die Wahl vor dem Faden ablesen — `wahlen` gehört dem Hauptfaden.
        let getrennt = wahlen.neuzugaengeGetrennt
        Task.detached { [self] in
            // **Hier wird der Fehler gelesen, nicht verschluckt.** Die
            // Startseite lädt bei jedem Wechsel in den Vordergrund (D8) und
            // ist damit die Stelle, an der eine abgelaufene Anmeldung als
            // Erstes auffällt — vorher kam einfach nichts zurück, und die
            // Seite blieb leer.
            do { _ = try await client.resumeItems(limit: 1) }
            catch { aufHauptfaden { self.sitzungPruefen(error) } }
            async let weiter = try? await client.resumeItems(limit: 20)
            async let naechste = try? await client.nextUp(limit: 20)
            async let neu = try? await client.latest(limit: 20)

            // **Jede Reihe hat ihre eigene Kachelform, und das ist keine
            // Geschmacksfrage.** A2 im Register: „Nächste Folge öffnet die
            // Übersicht, sie startet nicht. Nur ‚Weiterschauen' springt
            // direkt in die Wiedergabe." Waagerecht ist deshalb allein
            // „Weiterschauen" — auf iPhone, Fernseher und Mac genauso.
            let neuzugaenge = await neu ?? []
            // **Neue Filme und neue Serien getrennt, wenn gewünscht.** Eine
            // gemischte Reihe ist die Vorgabe; wer viel neu bekommt, will sie
            // auseinander. Die Zeile fehlte auf Linux ganz.
            let letzte: [(String, Reihenart, [Item])] = getrennt
                ? [(uebersetzt("Neue Filme"), .neu, neuzugaenge.filter { $0.type == "Movie" }),
                   (uebersetzt("Neue Serien"), .neu, neuzugaenge.filter { $0.type != "Movie" })]
                : [(uebersetzt("Zuletzt hinzugefügt"), .neu, neuzugaenge)]
            let reihen: [(String, Reihenart, [Item])] = ([
                (uebersetzt("Weiterschauen"), .weiterschauen, await weiter ?? []),
                (uebersetzt("Nächste Folge"), .naechste, await naechste ?? [])
            ] + letzte).filter { !$0.2.isEmpty }

            aufHauptfaden { self.reihenZeigen(reihen) }
        }
    }

    /// Filme und Serien. **Mit Gattung und rekursiv**, aus demselben Grund,
    /// der in `JellyfinClient.items` steht: sonst kommen bei einer
    /// Serienbibliothek die virtuellen Ordner statt der Serien.
    /// **Nachladen beim Blättern**, statt einmal 500 zu holen.
    ///
    /// Fünfhundert war die Zahl, bei der es „reicht schon" hiess — bei einer
    /// grösseren Sammlung fehlt der Rest schlicht. Der Mac zieht die nächste
    /// Seite, sobald die drittletzte Reihe sichtbar wird
    /// (`Bibliotheksmodell.swift:82`); hier hängt es am unteren Rand des
    /// Scrollers, was dasselbe bedeutet und in GTK ein Signal ist, das es
    /// ohnehin gibt.
    private func rasterNachladen(_ was: Bereich) {
        guard !rasterLaedt.contains(was) else { return }
        let schon = (was == .filme ? filmeItems : serienItems).count
        guard schon > 0, schon < (was == .filme ? filmeGesamt : serienGesamt) else { return }
        rasterLaden(was, ab: schon)
    }

    private func rasterLaden(_ was: Bereich, ab: Int = 0) {
        guard let client else { return }
        rasterLaedt.insert(was)
        if ab == 0 {
            if was == .filme { filmeItems = [] } else { serienItems = [] }
            rasterLaderZeigen(was, true)
        }
        let gattung = was == .filme ? "Movie" : "Series"
        let f = filter[was] ?? .alle
        let sort = sortierung[was] ?? .name
        let meine = bibliotheken(fuer: was)
        let eltern = gewaehlteBibliothek[was] ?? meine.first?.id
        Task.detached { [self] in
            let antwort = try? await client.items(parentID: eltern,
                                                  limit: 100,
                                                  startIndex: ab,
                                                  sortBy: sort.feld,
                                                  sortOrder: sort.richtung,
                                                  filters: f.jellyfinFilter,
                                                  istGesehen: f.istGesehen,
                                                  recursive: true,
                                                  includeItemTypes: [gattung])
            let items = antwort?.items ?? []
            let gesamt = antwort?.totalRecordCount ?? items.count
            aufHauptfaden {
                self.rasterLaedt.remove(was)
                self.rasterLaderZeigen(was, false)
                let raster = was == .filme ? self.filmeraster : self.serienraster
                let zahl = was == .filme ? self.filmezahl : self.serienzahl
                if was == .filme {
                    self.filmeItems += items
                    self.filmeGesamt = gesamt
                    self.rasterFuellen(raster, self.filmeItems)
                } else {
                    self.serienItems += items
                    self.serienGesamt = gesamt
                    self.rasterFuellen(raster, self.serienItems)
                }
                gtk_label_set_text(OpaquePointer(zahl), String(gesamt))
            }
        }
    }

    /// **Gesucht wird beim Tippen, nicht auf Enter.**
    ///
    /// Auf dem Mac hängt die Suche an `.task(id: begriff)`: ab zwei Zeichen
    /// wartet sie 280 ms und bricht ab, sobald weitergetippt wird. Ein
    /// Tastendruck als Auslöser wäre eine Abweichung ohne Grund — Eingabeart
    /// und Entfernung sind hier dieselben wie dort.
    ///
    /// GTK hat kein `Task.isCancelled` für Signale, also zählt ein Takt mit:
    /// nach der Wartezeit sucht nur, wer noch der jüngste ist. Der Vergleich
    /// läuft über ``aufHauptfaden`` und damit auf demselben Faden, auf dem
    /// auch hochgezählt wird — sonst wäre es ein Wettlauf.
    private func sucheAngestossen() {
        suchtakt += 1
        let meins = suchtakt
        let begriff = text(suchfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        guard begriff.count > 1 else {
            rasterFuellen(suchraster, [])
            gtk_widget_set_visible(suchleer, 0)
            return
        }
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            aufHauptfaden {
                guard self.suchtakt == meins else { return }
                self.suchen()
            }
        }
    }

    private func suchen() {
        guard let client else { return }
        let begriff = text(suchfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !begriff.isEmpty else { rasterFuellen(suchraster, []); return }
        Task.detached { [self] in
            let treffer = (try? await client.suche(begriff)) ?? []
            aufHauptfaden {
                self.rasterFuellen(self.suchraster, treffer)
                gtk_widget_set_visible(self.suchleer, treffer.isEmpty ? 1 : 0)
            }
        }
    }

    private func reihenZeigen(_ reihen: [(String, Reihenart, [Item])]) {
        leeren(reihenstapel)
        guard !reihen.isEmpty else {
            // Symbol, Satz, Erklärzeile — dieselbe Form wie auf dem Mac
            // (`Leerzustand`), statt einer einzelnen Textzeile.
            anhaengen(reihenstapel,
                      leerzustand("folder-symbolic", uebersetzt("Hier ist noch nichts"),
                                  uebersetzt("Sobald der Server Titel hat, stehen sie hier.")))
            return
        }
        for (titel, art, titelListe) in reihen {
            anhaengen(reihenstapel, reiheBauen(titel: titel, art: art, items: titelListe))
        }
    }

    /// Eine waagerecht blätternde Reihe. Überschrift 20 halbfett, darunter 10
    /// Luft — `Stil.reihe`.
    ///
    /// **Keine Scrollleiste, sondern zwei Pfeile.** Sie erscheinen, wenn der
    /// Zeiger über der Reihe steht, und nur auf der Seite, zu der es noch
    /// etwas zu sehen gibt. So macht es `Blätterreihe` auf dem Mac; die
    /// Leiste, die GTK von sich aus einblendet, lag über den Titeln.
    ///
    /// Die Pfeile sitzen auf halber **Bildhöhe**, nicht auf halber Reihenhöhe:
    /// unter jedem Bild stehen noch zwei Textzeilen, und mittig über allem
    /// säßen sie rund 45 Punkt zu tief. Die Rechnung `4 + bildHoehe / 2 − 17`
    /// steht wörtlich so auf dem Mac — 4 ist der senkrechte Rand der Reihe,
    /// 17 die halbe Knopfhöhe.
    /// - Parameter rand: Der seitliche Rand. **Null, wenn der Aufrufer schon
    ///   einen setzt** — sonst stehen die Kacheln 48 Punkt eingerückt unter
    ///   einer Überschrift, die bei 24 beginnt. Steht wörtlich so an
    ///   `Blätterreihe` auf dem Mac; genau daran ist es hier aufgefallen.
    func reiheBauen(titel: String, art: Reihenart, items: [Item],
                    rand: Int = Stil.randAbstand) -> Widget! {
        let quer = art == .weiterschauen
        let bildHoehe = quer ? Stil.querHoehe : Stil.kachelHoehe
        let stueck = (quer ? Stil.querBreite : Stil.kachelBreite) + Stil.kachelAbstand

        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)

        let ueberschrift = beschriftung(titel, stil: "swiftly-reihe")
        gtk_label_set_xalign(OpaquePointer(ueberschrift), 0)
        gtk_widget_set_halign(ueberschrift, GTK_ALIGN_START)
        gtk_widget_set_margin_start(ueberschrift, Int32(rand))
        gtk_widget_set_margin_end(ueberschrift, Int32(rand))
        anhaengen(block, ueberschrift)

        let scroller = gtk_scrolled_window_new()
        // `EXTERNAL` heisst: blättern ja, Leiste nein.
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: Int32(Stil.kachelAbstand))
        gtk_widget_set_margin_start(reihe, Int32(rand))
        gtk_widget_set_margin_end(reihe, Int32(rand))
        // Vier Punkt Luft, damit die wachsende Kachel oben nicht abgeschnitten
        // wird — dieselben vier wie auf dem Mac.
        gtk_widget_set_margin_top(reihe, 4)
        gtk_widget_set_margin_bottom(reihe, 4)
        for item in items { anhaengen(reihe, kachelBauen(item, art: art)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)

        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)

        let links = pfeilknopf("go-previous-symbolic", oben: bildHoehe, rechts: false)
        let rechts = pfeilknopf("go-next-symbolic", oben: bildHoehe, rechts: true)
        gtk_overlay_add_overlay(OpaquePointer(ueber), links)
        gtk_overlay_add_overlay(OpaquePointer(ueber), rechts)

        // Den Typ dieser Anpassung benennt niemand — er wird nur gereicht.
        // Ausgepackt gleich hier: sie ist bei einem Scroller nie null, und der
        // Übersetzer hat gefragt.
        let anpassung = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroller))!
        var schwebt = false

        // **Einblenden, nicht erscheinen.** Auf dem Mac liegt eine
        // `.transition(.opacity)` an den Pfeilen. `set_visible` kennt keinen
        // Zwischenzustand — die Deckung schon, und das Stilblatt gibt ihr
        // eine Zeit mit. `can_target` sorgt dafür, dass ein unsichtbarer
        // Pfeil auch keinen Klick schluckt.
        func zeigen(_ knopf: Widget!, _ ja: Bool) {
            gtk_widget_set_opacity(knopf, ja ? 1 : 0)
            gtk_widget_set_can_target(knopf, ja ? 1 : 0)
        }
        func nachfuehren() {
            let wert = gtk_adjustment_get_value(anpassung)
            let seite = gtk_adjustment_get_page_size(anpassung)
            let ganz = gtk_adjustment_get_upper(anpassung)
            zeigen(links, schwebt && wert > 1)
            zeigen(rechts, schwebt && wert + seite < ganz - 1)
        }

        func blaettern(_ richtung: Double) {
            let wert = gtk_adjustment_get_value(anpassung)
            let seite = gtk_adjustment_get_page_size(anpassung)
            let ganz = gtk_adjustment_get_upper(anpassung)
            // Drei Kacheln je Griff — `schrittweite` auf dem Mac.
            let weite = Double(stueck) * 3
            let ziel = max(0, min(ganz - seite, wert + richtung * weite))
            sanft(auf: scroller, von: wert, nach: ziel) {
                gtk_adjustment_set_value(anpassung, $0)
            }
        }

        beiSignal(links, "clicked") { blaettern(-1) }
        beiSignal(rechts, "clicked") { blaettern(1) }
        // **Nicht `edge-reached`.** Das Signal bringt die erreichte Kante mit
        // und verschiebt damit die Nutzdaten — daran ist die App gestorben.
        // `value-changed` an der Anpassung hat die schlichte Form und ist
        // ohnehin das Richtige: es meldet jede Bewegung, nicht nur die ans
        // Ende, also stimmen die Pfeile auch mitten im Blättern.
        beiSignalRoh(UnsafeMutableRawPointer(anpassung), "value-changed") { nachfuehren() }
        beiZeiger(ueber, herein: { schwebt = true; nachfuehren() },
                         hinaus: { schwebt = false; nachfuehren() })
        nachfuehren()

        anhaengen(block, ueber)
        return block
    }

    /// Ein Blätterpfeil, oben auf halber Bildhöhe.
    private func pfeilknopf(_ symbol: String, oben bildHoehe: Int, rechts: Bool) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-pfeil")
        gtk_button_set_child(alsKnopf(knopf), gtk_image_new_from_icon_name(symbol))
        gtk_widget_set_halign(knopf, rechts ? GTK_ALIGN_END : GTK_ALIGN_START)
        gtk_widget_set_valign(knopf, GTK_ALIGN_START)
        gtk_widget_set_margin_top(knopf, Int32(4 + bildHoehe / 2 - 17))
        gtk_widget_set_opacity(knopf, 0)
        gtk_widget_set_can_target(knopf, 0)
        return knopf
    }

    /// **Eine Kachel, drei Bedeutungen.** Was oben steht, was darunter, und
    /// welches Bild — das entscheidet die Reihe, nicht die Kachel.
    ///
    /// Die Zuordnung ist aus `Sources/macOS/HomeView.swift` abgeschrieben:
    ///
    /// | Reihe | Bild | Titel | Zweitzeile |
    /// |---|---|---|---|
    /// | Weiterschauen | quer, 280 × 158 | Serie | `kontextzeile` |
    /// | Nächste Folge | Plakat der Serie | Serie | `folgenkuerzel` |
    /// | Zuletzt hinzugefügt | Plakat | eigener Name | `neuzugangszeile` |
    ///
    /// Bei einer Folge steht oben der **Serienname**, nicht der Folgentitel.
    /// Andersherum war es hier zuerst, und dann steht unter einem Standbild
    /// „Lilien in der Wüste", wo auf dem Mac „The Mentalist" steht.
    private func kachelBauen(_ item: Item, art: Reihenart) -> Widget! {
        let quer = art == .weiterschauen
        let breite = quer ? Stil.querBreite : Stil.kachelBreite
        let hoehe = quer ? Stil.querHoehe : Stil.kachelHoehe

        let (kaefig, bild) = gerahmtesBild(breite: breite, hoehe: hoehe,
                                           stil: "swiftly-plakat")
        // **Welches Bild, entscheidet `Bildwahl` im Paket.** Bei einer Folge
        // hochkant das Plakat der Serie, quer der Hintergrund der Serie mit
        // vier Rückfällen dahinter. Die Begründung zu jeder Stufe steht dort,
        // mit Tests.
        //
        // Und darunter liegt noch eine Stufe, die aus
        // `Sources/Shared/HomeView.swift` stammt: **fehlt das Querbild ganz,
        // tritt das Plakat ein** — beschnitten, aber immer noch das Cover und
        // kein Standbild.
        let hoch = adressen.flatMap {
            Bildwahl.hochkant(item, adressen: $0, maxHoehe: hoehe * 2)
        }
        let adresse: URL? = quer
            ? (adressen.flatMap { Bildwahl.quer(item, adressen: $0, breite: breite * 2)?.url } ?? hoch)
            : hoch
        if let adresse {
            bildLaden(bild, url: adresse, schluessel: adresse.absoluteString)
        } else {
            zeichenLegen(kaefig, serie: item.seriesId != nil || item.type == "Series")
        }

        let (oben, unten): (String, String?) = switch art {
        case .weiterschauen: (item.seriesName ?? item.name, item.kontextzeile)
        case .naechste:      (item.seriesName ?? item.name, item.folgenkuerzel)
        case .neu:           (item.name, item.neuzugangszeile)
        }

        // Der Fortschrittsbalken liegt **in** der Bildhülle, unten, wie auf
        // dem Mac. Nur bei „Weiterschauen" — sonst stünde er unter Titeln,
        // die noch gar nicht angefangen wurden.
        // **Der Balken auf der Querkachel steht immer.** Er ist keine
        // Zierde, sondern die Auskunft, wo man stehengeblieben ist — der Mac
        // zeichnet ihn unabhängig von der Einstellung. Die Einstellung meint
        // die hochkanten Kacheln.
        if quer, let anteil = item.gesehenerAnteil {
            balkenLegen(kaefig, breite: breite, anteil: anteil)
        }
        // **Nur „Weiterschauen" springt direkt in die Wiedergabe** (A1).
        // „Nächste Folge" und „Zuletzt hinzugefügt" öffnen die Übersicht
        // (A2, A3) — was man nicht angefangen hat, will man erst ansehen.
        return kachelhuelle(bild: kaefig, breite: breite, oben: oben, unten: unten,
                            uebersicht: quer ? { [weak self] in self?.oeffne(item) } : nil) {
            [weak self] in
            guard let self else { return }
            if quer { self.starte(item) } else { self.oeffne(item) }
        }
    }

    /// Eine Kachel im Raster — Plakat, Name, Jahr.
    ///
    /// **Sie behält ihre Breite.** Eine `GtkFlowBox` dehnt ihre Kinder über
    /// die Zeile; wer das Fenster zog, sah die Plakate mitwachsen und in
    /// krummen Massen stehen, während sie auf der Startseite fest bei 150
    /// bleiben. Der Mac legt dort ein `LazyVGrid` mit **fester** Spaltenweite
    /// an — der Platz, der übrig bleibt, geht in den Abstand, nicht in die
    /// Kachel. Mittig ausgerichtet kommt genau das heraus.
    private func rasterkachel(_ item: Item) -> Widget! {
        let (kaefig, bild) = gerahmtesBild(breite: Stil.kachelBreite,
                                           hoehe: Stil.kachelHoehe,
                                           stil: "swiftly-plakat")
        if let adresse = adressen.flatMap({ Bildwahl.hochkant(item, adressen: $0,
                                                              maxHoehe: Stil.kachelHoehe * 2) }) {
            bildLaden(bild, url: adresse, schluessel: adresse.absoluteString)
        } else {
            zeichenLegen(kaefig, serie: item.seriesId != nil || item.type == "Series")
        }
        // Jeder Suchtreffer und jede Kachel im Raster führt auf die Seite,
        // keiner startet (A7b).
        let kachel = kachelhuelle(bild: kaefig, breite: Stil.kachelBreite,
                                  oben: item.name,
                                  unten: item.productionYear.map(String.init)) {
            [weak self] in self?.oeffne(item)
        }
        gtk_widget_set_halign(kachel, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(kachel, GTK_ALIGN_START)
        return kachel
    }

    /// **Die Hülle jeder Kachel — und sie ist ein Knopf.**
    ///
    /// Nicht wegen des Klicks (den gibt es hier noch gar nicht), sondern weil
    /// GTK den Zustand `:hover` nur auf Bedienelementen führt. Auf einer
    /// schlichten Box griffe die Vergrößerung im Stilblatt nie.
    ///
    /// Die Abstände stehen in `Macbausteine.Posterkachel`: **8** zwischen Bild
    /// und Text, **1** zwischen Titel und Zweitzeile. Hier standen zuerst
    /// beide auf 8, und der Abstand darunter war doppelt so groß wie auf dem
    /// Mac — Paul hat es sofort gesehen.
    /// Eine Kachel: Bild, Titel, Zweitzeile — und der Rechtsklickweg zur
    /// Übersicht (A6).
    ///
    /// **Wozu er da ist:** „Weiterschauen" springt sofort in die Wiedergabe
    /// (A1). Wer *erst nachsehen* will, worum es geht, hat sonst keinen Weg
    /// zur Seite. Auf dem Mac steht dafür `.contextMenu` (`Macbausteine`),
    /// auf dem Telefon das lange Drücken; hier die rechte Taste.
    ///
    /// `uebersicht` ist `nil`, wo die Kachel ohnehin schon dorthin führt —
    /// ein Menü mit dem einen Eintrag, den der Klick auch tut, ist keiner.
    func kachelhuelle(bild: Widget!, breite: Int, oben: String, unten: String?,
                      uebersicht: (() -> Void)? = nil,
                      auswahl: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-kachel")
        gtk_widget_set_valign(knopf, GTK_ALIGN_START)

        let kachel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        gtk_widget_set_size_request(kachel, Int32(breite), -1)
        anhaengen(kachel, bild)

        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 1)
        anhaengen(text, kacheltitel(oben, stil: "swiftly-kacheltitel"))
        if let unten, !unten.isEmpty {
            let zweite = kacheltitel(unten, stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(zweite, "dim-label")
            anhaengen(text, zweite)
        }
        anhaengen(kachel, text)

        gtk_button_set_child(alsKnopf(knopf), kachel)
        beiSignal(knopf, "clicked", auswahl)

        if let uebersicht {
            let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
            let tafel = tafelAn(knopf)
            gtk_popover_set_child(alsTafel(tafel), liste)
            anhaengen(liste, handlungszeile("dialog-information-symbolic",
                                            uebersetzt("Übersicht öffnen")) {
                gtk_popover_popdown(alsTafel(tafel))
                uebersicht()
            })
            beiRechtsklick(knopf) { gtk_popover_popup(alsTafel(tafel)) }
        }
        return knopf
    }

    /// **Eine Beschriftung zieht die Kachel sonst auf ihre Textlänge.**
    ///
    /// `gtk_label_set_ellipsize` senkt nur die *Mindest*breite; gewünscht
    /// bleibt die volle Zeile. In der Reihe „Weiterschauen" stand deshalb
    /// eine Kachel von 363 Punkt neben lauter 150ern — sie trug den längsten
    /// Titel. `max_width_chars` deckelt auch den Wunsch; die Kachel richtet
    /// sich danach allein nach dem Bild und ihrem eigenen `size_request`.
    private func kacheltitel(_ text: String, stil: String) -> Widget! {
        let l = beschriftung(text, stil: stil)
        gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(l), 1)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        return l
    }

    func kopfzeileEinrichten() { kopfzeileFuellen() }
}

/// Der Tastenhorcher. Wie jeder C-Rückruf kann er nichts einfangen — die App
/// kommt als Zeiger mit, so wie in ``Auftrag``.
nonisolated(unsafe) private let tasteGedrueckt: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, GdkModifierType, gpointer?
) -> gboolean = { _, wert, _, zustand, daten in
    guard let daten else { return 0 }
    let app = Unmanaged<App>.fromOpaque(daten).takeUnretainedValue()
    let strg = (zustand.rawValue & GDK_CONTROL_MASK.rawValue) != 0
    return app.taste(wert, strg: strg) ? 1 : 0
}

/// Wie sich diese App beim Server vorstellt.
///
/// Die Kennung muss über Neustarts gleich bleiben — Jellyfin führt darüber
/// die Geräteliste und die Übernahme der Wiedergabe von einem anderen Gerät.
enum Geraet {
    static let name: String = {
        let rechner = ProcessInfo.processInfo.hostName
        return String(format: uebersetzt("Swiftly auf %@"), rechner)
    }()

    static let kennung: String = {
        let ordner = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/swiftly")
        let datei = ordner.appendingPathComponent("geraet.txt")
        if let vorhanden = try? String(contentsOf: datei, encoding: .utf8),
           !vorhanden.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vorhanden.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let neu = UUID().uuidString
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        try? neu.write(to: datei, atomically: true, encoding: .utf8)
        return neu
    }()
}
