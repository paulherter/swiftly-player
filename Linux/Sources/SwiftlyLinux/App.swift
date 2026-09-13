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
    private var zurueckknopf: Widget!

    // MARK: Weiteres Konto — Zustand der Unterseite

    /// Umgeschaltet auf den Code-Weg. Der Vorgang laeuft erst dann an — sonst
    /// zoege jeder Besuch der Seite einen Code beim Server, den niemand
    /// braucht. Wortgleich zu `perCode` auf dem Mac.
    var kontoPerCode = false
    var kontoCode = ""
    var kontoFehler = ""
    var kontoCodelauf: Task<Void, Never>?
    /// Die Felder der Seite. **Als Felder der Klasse, nicht als Argumente über
    /// die Fadengrenze** — ein `Widget` ist ein roher Zeiger und damit nicht
    /// `Sendable`; angefasst wird es ohnehin nur auf GTKs Hauptfaden.
    var kontoKnopf: Widget!
    var kontoStandfeld: Widget!
    var kontoCodefeld: Widget!

    // Startseite
    var bereich: Bereich = .start
    private var reihenstapel: Widget!
    /// Die gewählten Genres, wenn sie als Chips über den Reihen stehen.
    private var gattungschips: [String] = []
    /// Was zuletzt auf der Startseite stand — das Fernsteuerpult braucht
    /// einen Titel, den es oeffnen kann.
    var letzteStartreihe: [Item] = []
    /// Vom Fernsteuerpult gesetzt: den Reiter der offenen Serienseite wechseln.
    var reiterWaehlen: ((Reiter) -> Void)?
    /// Der zuletzt **voll** geladene Titel der offenen Detailseite. Auf dem
    /// Seitenstapel liegt der magere Listeneintrag; der traegt keine
    /// Besetzung. Nur fuer das ``Fernsteuerpult``.
    var letzterVollerTitel: Item?
    /// Serien, die beim Ueberfahren einer Folgenkachel schon geholt wurden —
    /// siehe ``serieVorholen(_:)``.
    var vollspeicher: [String: Item] = [:]
    var vorholend: Set<String> = []
    /// Die Folgen der offenen Staffel und der Chip „Staffel laden" darueber.
    var staffelfolgen: [Item] = []
    var staffelladeknopf: Widget?
    // MARK: Stromwacht (siehe `Spieler.stromPruefen`)
    var stromStehtSeit: Date?
    var stromLetzteStelle: Double = -1
    var stromGelesen: UInt64 = 0
    var stromPufferWuchs = Date()
    /// Wann zuletzt gesprungen wurde — die Wacht setzt danach aus.
    var letzterSprung = Date.distantPast
    /// Die Kontozeile unten in der Seitenleiste — sie traegt die
    /// Hervorhebung, solange eine Unterseite offen ist.
    private var profilzeile: Widget?
    /// Den Reiter der offenen Serienseite umschalten — ueber den Stapel,
    /// nicht ueber einen Neubau.
    var reiterZeigen: ((Reiter) -> Void)?
    var kopfzeile: Widget!

    /// Die Kreise unten in der Leiste. Ein ``GtkFixed``, weil sie sich
    /// ueberlappen — GTK kennt keine negativen Raender.
    private var profilkreise: Widget!

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
        // Der Seerr-Zugang steht vor der ersten Ansicht: die Profilseite
        // zeigt daneben „Verbunden" oder „Nicht verbunden".
        seerrLaden()
        g_set_application_name("Swiftly")
        g_set_prgname("swiftly")
        gtk_window_set_title(alsFenster(fenster), "for Jellyfin")
        gtk_window_set_icon_name(alsFenster(fenster), Zeichenwerk.kennung)
        // 1440 x 900 wie `Sources/macOS/SwiftlyApp.swift:59`. Hier standen
        // 1100 x 760 — kein Grund aus Abschnitt F, nur eine nie abgeglichene
        // Zahl. Das Mindestmass darunter stimmt und bleibt.
        //
        // **Das Fenster zu schliessen beendet hier die App, auf dem Mac
        // nicht.** Der Mac bleibt geladen (`applicationShouldTerminate-
        // AfterLastWindowClosed = false`) und holt sich das Fenster mit
        // Befehl-0 zurueck — das ist die Sitte dort, wo eine App im Dock
        // steht. Unter Wayland gibt es kein Dock und kein Gegenstueck dazu;
        // ein Programm ohne Fenster, das weiterlaeuft, waere hier ein
        // Programm, das man nicht mehr los wird. **Bewusst nicht angeglichen**
        // — die Plattform entscheidet, so wie sie auch entscheidet, wo die
        // Fensterampel sitzt.
        gtk_window_set_default_size(alsFenster(fenster), 1440, 900)
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
        if Speicher.bundLesen() == nil, let merk = Speicher.gemerkterServer() {
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
        // **Der Bund, nicht die einzelne Sitzung** — sonst stuende nach einem
        // Neustart nur noch ein Konto im Streifen.
        if let ablage = Speicher.bundLesen() {
            bund = ablage.bund
            sitzungEinsetzen(ablage.bund.aktives, servername: ablage.servername)
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
            // Frist und Takt stehen im Paket (``Quickconnectfrist``) — sie
            // standen hier und in `kontoCodeHolen` zweimal derselbe Wert.
            for _ in 0..<Quickconnectfrist.versuche {
                try? await Task.sleep(nanoseconds: UInt64(Quickconnectfrist.takt) * 1_000_000_000)
                guard (try? await c.quickConnectFreigegeben(vorgang)) == true else { continue }
                guard let sitzung = try? await c.anmeldenMitQuickConnect(vorgang) else { break }
                aufHauptfaden {
                    // Adresse, Name und Kennung stehen jetzt alle in der
                    // Sitzung selbst — `serverURL` wird hier nicht mehr
                    // gebraucht.
                    let servername = gtk_label_get_text(OpaquePointer(self.serverzeile))
                        .map { String(cString: $0) }
                    self.anmeldestandZeigen("")
                    self.sitzungAufnehmen(sitzung, servername: servername)
                }
                return
            }
            aufHauptfaden { self.anmeldestandZeigen(uebersetzt("Der Code ist abgelaufen. Hol dir einen neuen.")) }
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

        zurueckknopf = gtk_button_new_with_label(uebersetzt("Anderer Server"))
        gtk_widget_add_css_class(zurueckknopf, "swiftly-flach")
        gtk_widget_set_margin_top(zurueckknopf, 14)
        gtk_widget_set_halign(zurueckknopf, GTK_ALIGN_CENTER)
        anhaengen(mitte, zurueckknopf)

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
        beiSignal(zurueckknopf, "clicked") { [weak self] in
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
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung,
                                   deviceName: Geraet.name,
                                   clientVersion: Geraet.fassung)
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
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung,
                                   deviceName: Geraet.name,
                                   clientVersion: Geraet.fassung)
            do {
                let sitzung = try await c.authenticate(username: benutzer, password: passwort)
                aufHauptfaden {
                    self.anmeldungFertig()
                    gtk_editable_set_text(OpaquePointer(self.passwortfeld), "")
                    // Sichern macht ``sitzungAufnehmen(_:servername:)`` selbst —
                    // es muss den Bund kennen, bevor etwas auf die Platte geht.
                    self.sitzungAufnehmen(sitzung, servername: servername)
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

    // MARK: - Mehrere Konten auf demselben Server

    /// Die Konten dieses Servers und welches gerade gilt.
    ///
    /// **Der Bund liegt hier, nicht in der Ansicht.** Alle Regeln, die daran
    /// hängen — dasselbe Konto zweimal, welches nach dem Entfernen gilt, eine
    /// alte Einzelsitzung von früher — stehen in ``Kontenbund`` im Paket und
    /// sind dort mit 14 Tests abgedeckt. Hier steht nur, was Linux davon
    /// sichtbar macht.
    var bund: Kontenbund?

    /// Steigt bei jedem Wechsel. Wer beim Neuzeichnen vergleichen muss, ob
    /// seine Daten noch zum angemeldeten Konto gehören, vergleicht diesen Wert.
    ///
    /// **Auf Apple hängt daran ein `onChange`.** Das gibt es hier nicht — die
    /// Oberfläche ist imperativ, also ruft ``aufraeumenNachWechsel()`` direkt
    /// auf, was neu muss. Der Zähler bleibt trotzdem: eine Aufgabe, die vor
    /// dem Wechsel losgeschickt wurde und danach zurückkommt, erkennt an ihm,
    /// dass ihre Antwort zum vorigen Konto gehört.
    var kontowechsel = 0

    /// Nimmt eine frische Sitzung an — nach Anmeldung oder Quick Connect.
    ///
    /// Gibt zurück, ob es ein **Kontowechsel** war, also ob schon jemand
    /// angemeldet war. Wortgleich zu `AppModel.sitzungUebernehmen(_:)`.
    @discardableResult
    func sitzungAufnehmen(_ sitzung: Session, servername: String?) -> Bool {
        // **Ob es ein Wechsel war, sagt das Paket**, nicht diese Seite. Beide
        // Seiten leiteten es vorher aus `bund != nil` her — und die Regel, dass
        // ein anderer Server *kein* Wechsel ist, sondern ein Neuanfang, stand
        // damit zweimal da.
        let (neuer, warAngemeldet) = Kontenbund.aufnehmen(sitzung, in: bund)
        bund = neuer
        bundSichern(servername: servername)
        if warAngemeldet { aufraeumenNachWechsel() }
        sitzungEinsetzen(sitzung, servername: servername)
        return warAngemeldet
    }

    /// Auf ein anderes Konto desselben Servers umschalten.
    ///
    /// **Kein neues Passwort.** Beide Merkmale liegen in `konten.json`; der
    /// Wechsel tauscht nur, welches gilt.
    /// **Die Kennung ist der `kontoschluessel`, nicht die `userID`.** Sobald
    /// zwei Server im Bund liegen, kann dieselbe Benutzerkennung auf beiden
    /// vorkommen; ein Vergleich auf `userID` traefe dann das falsche Konto
    /// oder gar keins. `Kontenbund.konto(_:)` prueft zuerst den vollen
    /// Schluessel und faellt nur zur Sicherheit auf die Benutzerkennung
    /// zurueck — damit bleiben aeltere Aufrufer lesbar.
    func kontoWechseln(zu kennung: String) {
        guard var neu = bund, neu.aktiveKennung != kennung,
              neu.konto(kennung) != nil else { return }
        neu.wechseln(zu: kennung)
        bund = neu
        let name = servername.isEmpty ? nil : servername
        // **Wer im Profil umschaltet, bleibt im Profil** — wie auf dem Mac.
        // Ring und Punkt wandern dann sichtbar zum anderen Kreis, und genau
        // das ist die Rueckmeldung, um die es im Entwurf geht: „verbunden ist,
        // was Akzentring und Punkt traegt, und das aendert sich beim Klicken".
        // Wer stattdessen auf die Startseite geworfen wuerde, saehe die
        // Antwort auf seinen eigenen Klick nie.
        let warImProfil = offeneUnterseite == .profil
        bundSichern(servername: name)
        aufraeumenNachWechsel()
        sitzungEinsetzen(neu.aktives, servername: name)
        // **Erst danach.** Die Seite liest `benutzerID` und `adressen`, und
        // die stellt ``sitzungEinsetzen(_:servername:)``; davor gebaut zeigte
        // sie den Namen des Kontos, von dem man gerade weggegangen ist.
        if warImProfil { unterseiteOeffnen(.profil, schub: .ohne) }
    }

    /// Was nach jedem Kontowechsel neu muss — ausser dem Client selbst.
    ///
    /// **Hier wird nicht abgemeldet.** `abmelden()` schickt ein
    /// `Sessions/Logout` und zieht das Merkmal ein — richtig beim Abmelden,
    /// verheerend beim Umschalten: das Konto, von dem man weggeht, waere
    /// danach unbrauchbar, und der Weg zurueck endet in „Anmeldung
    /// abgelehnt". Der alte Client wird einfach fallen gelassen.
    ///
    /// **Und die Reihen werden nicht geleert.** Auf Apple hat genau das zwei
    /// Runden gekostet: wer erst leert und dann laedt, haengt jede Kachel kurz
    /// aus, und `AsyncImage` bricht dann seinen Abruf ab. Hier ersetzt
    /// ``reihenZeigen(_:)`` ohnehin erst, wenn die neuen Reihen da sind —
    /// diese Funktion fasst den Reihenstapel deshalb gar nicht an.
    private func aufraeumenNachWechsel() {
        kontowechsel += 1
        // **Die Fernsteuerung gehoert dazu, und das sieht man ihr nicht an.**
        // Sie laeuft sonst mit dem Merkmal des vorigen Kontos weiter, und das
        // iPhone saehe die Linux-Sitzung dann unter dem falschen Namen.
        Task.detached { [fernsteuerung] in await fernsteuerung?.beenden() }
        fernsteuerung = nil
        uebernahmelauf?.cancel()
        uebernahmelauf = nil
        uebernahmeangebote = []
        // Detailseiten und geladene Bereiche gehoeren zum vorigen Konto.
        // Ohne das zeigten Filme und Serien nach dem Wechsel dauerhaft die
        // Titel des vorigen Kontos: `geladen` wurde bisher nur beim Abmelden
        // geleert, und ein Bereich laedt genau einmal.
        seitenstapel.removeAll()
        geladen.removeAll()
        offeneUnterseite = nil
        // **Und eine offene Bibliotheksseite.** Sie zeigt eine Sammlung des
        // vorigen Kontos; auf dem Mac setzt `BibliothekView` sie beim
        // Kontowechsel auf `nil` zurueck (`:187-190`). Hier wurde sie nur
        // beim Bereichswechsel geleert, und wer im Konto wechselte, sah die
        // fremde Sammlung stehenbleiben.
        if offeneBibliothek != nil {
            offeneBibliothek = nil
            bibliothekszeilenMalen()
        }
        // **Der Bereich bleibt, der Stapel geht** (G4). Wer aus „Filme" heraus
        // umschaltet, steht danach auf der Wurzel von „Filme", nicht auf der
        // Startseite — der Stapel gehoerte dem vorigen Konto, der Bereich
        // nicht.
        //
        // **Er gilt hier schon als geladen, obwohl nichts geladen ist.**
        // ``zeige(_:)`` wuerde sonst gleich hier ``startseiteLaden()`` rufen —
        // und zwar mit dem **alten** Client, denn der neue steht erst nach
        // `setSession` bereit. Zwei Ladungen liefen dann um die Wette, und wer
        // gewinnt, entschied die Antwortzeit des Servers. Geladen wird gleich
        // in ``sitzungEinsetzen(_:servername:)``, mit dem richtigen Client.
        geladen.insert(bereich)
        zeige(bereich)
        geladen.removeAll()
    }

    // MARK: Weiteres Konto

    /// Meldet ein weiteres Konto mit Name und Passwort an.
    ///
    /// **Die Seite schliesst sich selbst — aber nur, wenn es geklappt hat.**
    /// Bei einem Fehler bleibt sie stehen und zeigt ihn; sie hier zu
    /// schliessen hiesse, die Meldung zu verschlucken.
    /// **Antwortet dort ein Jellyfin?**
    ///
    /// `/System/Info/Public` braucht keine Anmeldung — derselbe Endpunkt, den
    /// die erste Anmeldung nimmt. Erst wenn er antwortet, gibt es ein
    /// Formular; sonst tippt man Name und Passwort in eine Adresse, die es
    /// nicht gibt.
    func serverPruefen(_ eingabe: String) {
        let roh = eingabe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roh.isEmpty, let url = AppModelURLNormalizer.normalize(roh) else {
            serverAufnahmeFehlerZeigen(uebersetzt("Diese Adresse ergibt keinen Server."))
            return
        }
        gtk_widget_set_sensitive(serverAufnahmeKnopf, 0)
        hauptknopfBeschriften(serverAufnahmeKnopf, uebersetzt("Prüfe …"))
        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung,
                                   deviceName: Geraet.name, clientVersion: Geraet.fassung)
            do {
                let auskunft = try await c.publicSystemInfo()
                aufHauptfaden {
                    self.serverAufnahmeURL = url
                    var stuecke: [String] = []
                    if let n = auskunft.serverName, !n.isEmpty { stuecke.append(n) }
                    if let v = auskunft.version, !v.isEmpty { stuecke.append("Jellyfin \(v)") }
                    if stuecke.isEmpty { stuecke.append(url.host() ?? url.absoluteString) }
                    self.serverAufnahmeGeprueft = stuecke.joined(separator: " · ")
                    self.serverAufnahmeFehler = ""
                    self.unterseiteOeffnen(.serverAufnahme, schub: .ohne)
                }
            } catch {
                aufHauptfaden {
                    gtk_widget_set_sensitive(self.serverAufnahmeKnopf, 1)
                    hauptknopfBeschriften(self.serverAufnahmeKnopf, uebersetzt("Weiter"))
                    self.serverAufnahmeFehlerZeigen(lesbarerFehler(error))
                }
            }
        }
    }

    func serverAufnahmeFehlerZeigen(_ text: String) {
        serverAufnahmeFehler = text
        guard serverAufnahmeStand != nil else { return }
        gtk_label_set_text(OpaquePointer(serverAufnahmeStand), text)
        gtk_widget_set_visible(serverAufnahmeStand, text.isEmpty ? 0 : 1)
    }

    /// Anmeldung an einem **anderen** Server als dem verbundenen.
    ///
    /// **`sitzungAufnehmen` traegt das schon.** `Kontenbund.aufnehmen` prueft
    /// seit dem 11.09.2026 nicht mehr, ob die Sitzung zum selben Server
    /// gehoert — ein Bund haelt beliebig viele. Hier ist also nichts
    /// Besonderes zu tun ausser der eigenen Adresse.
    func amNeuenServerAnmelden(benutzer: String, passwort: String) {
        let name = benutzer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = serverAufnahmeURL else { return }
        gtk_widget_set_sensitive(serverAufnahmeKnopf, 0)
        hauptknopfBeschriften(serverAufnahmeKnopf, uebersetzt("Melde an …"))
        serverAufnahmeFehlerZeigen("")
        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung,
                                   deviceName: Geraet.name, clientVersion: Geraet.fassung)
            do {
                let sitzung = try await c.authenticate(username: name, password: passwort)
                let auskunft = try? await c.publicSystemInfo()
                aufHauptfaden {
                    self.serverAufnahmeFehler = ""
                    self.kontoPerCode = false
                    self.sitzungAufnehmen(sitzung, servername: auskunft?.serverName)
                    self.unterseiteOeffnen(.profil, schub: .ohne)
                }
            } catch {
                aufHauptfaden {
                    gtk_widget_set_sensitive(self.serverAufnahmeKnopf, 1)
                    hauptknopfBeschriften(self.serverAufnahmeKnopf, uebersetzt("Anmelden"))
                    self.serverAufnahmeFehlerZeigen(lesbarerFehler(error))
                }
            }
        }
    }

    func kontoAnmelden(benutzer: String, passwort: String) {
        let name = benutzer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = bund?.serverURL else { return }
        gtk_widget_set_sensitive(kontoKnopf, 0)
        hauptknopfBeschriften(kontoKnopf, uebersetzt("Melde an …"))
        gtk_widget_set_visible(kontoStandfeld, 0)

        let servername = self.servername.isEmpty ? nil : self.servername
        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung,
                                   deviceName: Geraet.name,
                                   clientVersion: Geraet.fassung)
            do {
                let sitzung = try await c.authenticate(username: name, password: passwort)
                aufHauptfaden {
                    self.kontoFehler = ""
                    self.kontoPerCode = false
                    self.sitzungAufnehmen(sitzung, servername: servername)
                    // Zurueck aufs Profil — dort steht der Streifen, in dem
                    // das neue Konto jetzt mit Ring und Punkt steht. Das ist
                    // die Antwort auf „Hinzufuegen".
                    self.unterseiteOeffnen(.profil, schub: .ohne)
                }
            } catch {
                aufHauptfaden {
                    gtk_widget_set_sensitive(self.kontoKnopf, 1)
                    hauptknopfBeschriften(self.kontoKnopf, uebersetzt("Hinzufügen"))
                    self.kontoFehlerZeigen(lesbarerFehler(error))
                }
            }
        }
    }

    /// Holt einen Quick-Connect-Code und wartet, bis er freigegeben wird.
    func kontoCodeHolen() {
        guard let url = bund?.serverURL else { return }
        let servername = self.servername.isEmpty ? nil : self.servername
        kontoCodelauf = Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung,
                                   deviceName: Geraet.name,
                                   clientVersion: Geraet.fassung)
            guard let vorgang = try? await c.quickConnectStarten() else {
                aufHauptfaden { self.kontoFehlerZeigen(uebersetzt("Der Server hat keinen Code gegeben.")) }
                return
            }
            aufHauptfaden {
                self.kontoCode = vorgang.code
                gtk_label_set_text(OpaquePointer(self.kontoCodefeld), vorgang.code)
            }
            // Frist und Takt: ``Quickconnectfrist`` im Paket.
            for versuch in 0..<Quickconnectfrist.versuche {
                // **Die Restzeit wird sekundenweise gezeigt**, nicht im
                // Zwei-Sekunden-Takt der Abfrage: eine Uhr, die zweimal
                // dieselbe Zahl zeigt und dann zwei ueberspringt, sieht
                // kaputt aus. Also je Runde zwei Schritte à einer Sekunde.
                for _ in 0..<Quickconnectfrist.takt {
                    let rest = Quickconnectfrist.sekunden
                        - versuch * Quickconnectfrist.takt
                    aufHauptfaden { self.kontoRestZeigen(rest) }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                guard (try? await c.quickConnectFreigegeben(vorgang)) == true else { continue }
                guard let sitzung = try? await c.anmeldenMitQuickConnect(vorgang) else { break }
                aufHauptfaden {
                    self.kontoCode = ""
                    self.kontoFehler = ""
                    self.kontoPerCode = false
                    self.kontoCodelauf = nil
                    self.sitzungAufnehmen(sitzung, servername: servername)
                    self.unterseiteOeffnen(.profil, schub: .ohne)
                }
                return
            }
            aufHauptfaden {
                self.kontoRestZeigen(nil)
                self.kontoFehlerZeigen(uebersetzt("Der Code ist abgelaufen. Hol dir einen neuen."))
            }
        }
    }

    /// „Läuft ab in 4:58" — `nil` blendet die Zeile aus.
    private func kontoRestZeigen(_ sekunden: Int?) {
        guard let feld = kontoRestfeld else { return }
        guard let sekunden, sekunden > 0 else {
            gtk_widget_set_visible(feld, 0)
            return
        }
        let text = String(format: uebersetzt("Läuft ab in %d:%02d"),
                          sekunden / 60, sekunden % 60)
        gtk_label_set_text(OpaquePointer(feld), text)
        gtk_widget_set_visible(feld, 1)
    }

    /// Eine Meldung in die Zeile unter den Feldern — **nicht** dorthin, wo der
    /// Code steht. Die beiden auseinanderzuhalten ist der halbe Grund, warum
    /// diese Seite eine eigene ist.
    private func kontoFehlerZeigen(_ text: String) {
        kontoFehler = text
        guard let feld = kontoStandfeld else { return }
        gtk_label_set_text(OpaquePointer(feld), text)
        gtk_widget_set_visible(feld, text.isEmpty ? 0 : 1)
    }

    private func bundSichern(servername: String?) {
        guard let bund else { return }
        Speicher.bundSchreiben(.init(bund: bund, servername: servername))
    }

    /// Setzt eine Sitzung in Betrieb: Client, Bildadressen, Anzeige, Laden.
    private func sitzungEinsetzen(_ sitzung: Session, servername: String?) {
        let serverURL = sitzung.serverURL
        let token = sitzung.accessToken
        let benutzerID = sitzung.userID
        let benutzername = sitzung.userName
        let c = JellyfinClient(baseURL: serverURL,
                               deviceID: Geraet.kennung,
                               deviceName: Geraet.name)
        adressen = Bildadresse(basis: serverURL, token: token)
        self.benutzerID = benutzerID
        // **Die Downloads gehoeren dem Konto** (H11). Zwei Konten auf einem
        // Server tragen dieselben Kennungen; ohne das Konto kaeme der
        // Fortschritt des einen an den Titel des anderen.
        downloads.beiAenderung = { [weak self] in
            guard let self, self.bereich == .downloads else { return }
            self.downloadseiteFuellen()
        }
        sitzungAnzeigen(benutzername: benutzername, servername: servername)
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "start")

        // **`JellyfinClient` ist ein Akteur.** Die Sitzung einzusetzen geht
        // deshalb nur mit `await`; erst danach darf geladen werden.
        Task.detached { [self] in
            await c.setSession(sitzung)
            aufHauptfaden {
                self.client = c
                self.downloads.anmelden(client: c, konto: benutzerID)
                // **H6/H9: was der Server inzwischen sagt.** Auf Apple laeuft
                // derselbe Abgleich bei jedem Erscheinen der Hauptansicht.
                self.downloads.nachziehen()
                self.geladen = [.start]
                self.startseiteLaden()
                self.bibliothekenLaden()
                // **Und der Bereich, auf dem man steht, falls es nicht die
                // Startseite ist.** Nach einem Kontowechsel bleibt der Bereich
                // stehen (G4) — ohne diese Zeile stuende dort die Liste des
                // vorigen Kontos, denn `geladen` kennt nur `.start`, und
                // niemand fragt nach.
                if self.bereich != .start { self.zeige(self.bereich) }
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
    /// **Nach Bereich, nicht nach Platz in der Liste.** Vorher lag hier ein
    /// Feld parallel zu `Bereich.allCases`; sobald die Leiste in zwei Gruppen
    /// zerfaellt und eine davon nur manchmal da ist, stimmt der Platz nicht
    /// mehr mit der Aufzaehlung ueberein — und dann faerbt sich die falsche
    /// Zeile ein. Derselbe Umbau wie bei den Rasterseiten.
    private var bereichsknoepfe: [Bereich: Widget] = [:]
    /// Die Rubrik „Meins" und ihre Zeilen — sie wird neu gefuellt, wenn der
    /// Downloadschalter umgelegt wird.
    private var meinsliste: Widget!
    private var bibliotheksrubrik: Widget!
    private var bibliotheksliste: Widget!
    /// **Welche Bibliothek gerade als eigene Seite offen ist** — `nil`, wenn
    /// ein Bereich gezeigt wird. Wortgleich `offeneBibliothek` auf dem Mac.
    var offeneBibliothek: Item?
    /// Die Leistenzeilen der Bibliotheken, damit die richtige hervorgehoben
    /// wird und die anderen es nicht bleiben.
    private var bibliotheksknoepfe: [String: Widget] = [:]
    /// Der Titel der Bibliotheksseite. Er wechselt mit jeder Sammlung; die
    /// Bereichsseiten tragen ihren Titel fest.
    private var bibliothekstitel: Widget!
    /// Der Titel der Genre-Seite. Er trägt den **unübersetzten** Namen vom
    /// Server (E7).
    private var gattungstitel: Widget!
    /// Je Rasterseite die Zeile mit dem Servernamen (E15).
    private var serverzeilen: [Bereich: Widget] = [:]
    /// Welches Genre gerade offen ist.
    var offeneGattung: String?
    /// Welche Gattung die Merkliste zeigt (E25).
    /// **Gesichert, nicht nur gemerkt.** Sie war ein reiner Speicherwert und
    /// stand nach jedem Start wieder auf „Filme & Serien"; auf dem Mac liegt
    /// sie in `UserDefaults` (`Merklistenmodell.swift:24-25`).
    var merkgattung: Merkgattung {
        get { Merkgattung(rawValue: wahlen.merkgattung) ?? .alle }
        set { wahlen.merkgattung = newValue.rawValue; wahlen.sichern() }
    }
    private var profilbild: Widget!
    private var profilname: Widget!
    private var profilserver: Widget!
    /// **Die Rasterseiten liegen in Woerterbuechern, nicht in Paaren.**
    ///
    /// Vorher stand ueberall `was == .filme ? filme… : serien…` — an acht
    /// Stellen. Mit einem dritten Bereich (Merkliste) waere daraus ueberall
    /// eine Dreierkette geworden, und jede vergessene Stelle haette still
    /// die falsche Seite gefuellt. Ein Woerterbuch kennt keinen Sonderfall.
    private var rasterFeld: [Bereich: Widget] = [:]
    private var zahlFeld: [Bereich: Widget] = [:]
    private var suchfeld: Widget!
    /// „Zuletzt gesucht" — steht, solange das Feld leer ist.
    private var suchverlaufblock: Widget!
    /// Ob die beiden Bloecke der Suche leer sind — „Nichts gefunden" gilt nur,
    /// wenn **beide** es sind.
    var eigeneTrefferLeer = true
    var seerrTrefferLeer = true
    private var suchhinweis: Widget!
    private var suchverlaufliste: Widget!
    private var suchraster: Widget!
    var suchleer: Widget!
    var geladen: Set<Bereich> = []
    /// Filter und Sortierung, je Bereich getrennt. Auf dem Mac merkt sich
    /// jeder Bereich seinen Stand — wer zwischen Filmen und Serien wechselt,
    /// findet zurück, wo er war.
    private var filter: [Bereich: Bibliotheksfilter] {
        get {
            var d: [Bereich: Bibliotheksfilter] = [:]
            for (k, v) in wahlen.filterJeOrt {
                if let b = Bereich.allCases.first(where: { $0.kennung == k }),
                   let f = Bibliotheksfilter(rawValue: v) { d[b] = f }
            }
            return d
        }
        set { }
    }
    /// **Die Merkliste startet auf „Zuletzt", nicht auf A–Z.** Das ist die
    /// Reihenfolge, in der man eine Merkliste liest — was zuletzt gemerkt
    /// wurde, steht oben. Auf Apple ist es die Vorgabe von
    /// `Merklistenmodell.sortierung`; hier stand sie nirgends, also griff
    /// `?? .name`.
    /// Was gerade gilt — gelesen aus ``Wahlen``, geschrieben ueber
    /// ``sortierungSetzen(_:_:)``. Die Merkliste startet auf „Zuletzt": das
    /// ist die Reihenfolge, in der man eine Merkliste liest.
    private var sortierung: [Bereich: Sortierung] {
        get {
            var d: [Bereich: Sortierung] = [.merkliste: .neueste]
            for (k, v) in wahlen.sortierungJeOrt {
                if let b = Bereich.allCases.first(where: { $0.kennung == k }),
                   let s = Sortierung(rawValue: v) { d[b] = s }
            }
            return d
        }
        set { }
    }

    /// **Unter welchem Namen Filter und Sortierung eines Ortes liegen.**
    ///
    /// Nicht `Bereich.kennung`: die ist fuer `.bibliothek` die Konstante
    /// „bibliothek", und damit teilten sich **alle** Sammlungen einen
    /// einzigen Stand. Der Mac schluesselt ueber die Kennung der Bibliothek
    /// (`Bibliotheksseite.swift:33-37`, `merkname: bibliothek.id`) und sagt
    /// dazu: „zwei Filmbibliotheken sind zwei Orte". Dasselbe fuer ein Genre.
    private func ortschluessel(_ was: Bereich) -> String {
        switch was {
        case .bibliothek: return "bibliothek:" + (offeneBibliothek?.id ?? "")
        case .gattung:    return "gattung:" + (offeneGattung ?? "")
        default:          return was.kennung
        }
    }

    /// Was an diesem Ort gilt. **Die Merkliste startet auf „Zuletzt"** — das
    /// ist die Reihenfolge, in der man eine Merkliste liest.
    func sortierungVon(_ was: Bereich) -> Sortierung {
        if let roh = wahlen.sortierungJeOrt[ortschluessel(was)],
           let s = Sortierung(rawValue: roh) { return s }
        return was == .merkliste ? .neueste : .name
    }

    func filterVon(_ was: Bereich) -> Bibliotheksfilter {
        if let roh = wahlen.filterJeOrt[ortschluessel(was)],
           let f = Bibliotheksfilter(rawValue: roh) { return f }
        return .alle
    }

    private func sortierungSetzen(_ was: Bereich, _ neu: Sortierung) {
        wahlen.sortierungJeOrt[ortschluessel(was)] = neu.rawValue
        wahlen.sichern()
    }

    private func filterSetzen(_ was: Bereich, _ neu: Bibliotheksfilter) {
        wahlen.filterJeOrt[ortschluessel(was)] = neu.rawValue
        wahlen.sichern()
    }
    private var chipzeilen: [Bereich: Widget] = [:]
    /// Der Ersatzinhalt einer Rasterseite, die nichts hergibt — nur dort, wo
    /// der Mac einen hat.
    private var leerFeld: [Bereich: Widget] = [:]

    /// Zeichen, Ueberschrift und Erklaerung des Leerzustands, wortgleich vom
    /// Mac. `nil` heisst: dort steht keiner.
    private func leertext(_ was: Bereich) -> (String, String, String?)? {
        switch was {
        // `MerklisteView.swift:117-125`
        case .merkliste:
            return ("bookmark-new-symbolic", uebersetzt("Noch nichts gemerkt"),
                    uebersetzt("Auf jeder Film- und Serienseite steht „Merkliste“ in der Knopfreihe. Was du dort antippst, sammelt sich hier."))
        // `GenreView.swift:56-60`
        case .gattung:
            return ("tag-symbolic", uebersetzt("Nichts in diesem Genre"),
                    uebersetzt("Auf deinem Server steht gerade kein Film und keine Serie darin."))
        default: return nil
        }
    }
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
    /// Die Staffel**nummer**, über die man kam — zweiter Weg neben der
    /// Kennung. Am Gerät gemessen liefert der Server an einer Folge nicht
    /// immer eine `SeasonId`; dann greift der Kennungsvergleich ins Leere
    /// und nur die Nummer trägt noch (A10).
    var startStaffelNummer: Int?
    /// Die Rolle, über die man auf eine Personenseite kam, und der Titel, in
    /// dem sie gespielt wurde.
    ///
    /// **Beiwerk neben dem Stapel, wie `startStaffel`.** Auf Apple trägt
    /// `PersonRoute` beides mit; hier hält der Stapel `Item`, und eine Rolle
    /// steht in keinem Item — sie gehört zur *Verbindung* zwischen Titel und
    /// Person, nicht zur Person. Den Stapel dafür auf eine Aufzählung von
    /// Zielen umzubauen wäre ein Umbau an jeder Seite, für zwei Zeichenketten.
    /// Stand der Serveraufnahme — Adresse, geprüfter Name, Fehler.
    var serverAufnahmeAdresse = ""
    var serverAufnahmeGeprueft: String?
    var serverAufnahmeFehler = ""
    var serverAufnahmeVorgegeben = false
    var serverAufnahmeStand: Widget!
    var serverAufnahmeKnopf: Widget!
    /// Die geprüfte Adresse, an der angemeldet wird.
    var serverAufnahmeURL: URL?

    var personRolle: String?
    var personHerkunft: String?
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

    /// **H1.** Kurzform fuer `wahlen.downloadsAn` — die Leiste und die
    /// Detailseite fragen oft danach.
    var downloadsAn: Bool { wahlen.downloadsAn }

    /// Was auf dieser Maschine liegt. Die Regeln stehen im Paket, der
    /// Ladevorgang in `Downloadverwaltung`; hier haengt nur die Oberflaeche
    /// daran.
    let downloads = Downloadverwaltung()

    // MARK: Downloadseite — Widgets und Zustand
    var downloadliste: Widget!
    var downloadbelegung: Widget!
    var downloadentfernen: Widget!
    var downloadbearbeitenknopf: Widget!
    var downloadleer: Widget!
    var downloadbearbeiten = false
    var downloadgewaehlt: Set<String> = []
    /// Welche Serien in der Downloadliste aufgeklappt sind (H12).
    var downloadOffeneSerien: Set<String> = []

    // MARK: Seerr-Titelseite
    var seerrBlock: Widget!
    var seerrAngaben: Widget!
    var seerrHandlung: Widget!
    var seerrKnopfreihe: Widget!
    /// Welche Staffeln angefragt werden sollen. Leer heisst: noch keine
    /// gewaehlt — und dann fragt der Knopf auch keine an.
    var seerrGewaehlteStaffeln: Set<Int> = []
    /// **Der erste Druck fragt nach, der zweite schickt.** Nur bei einem
    /// Film — bei einer Serie ist die Staffelauswahl die zweite Stufe.
    /// Wird beim Oeffnen einer Seerr-Seite zurueckgesetzt.
    var seerrBestaetigt = false
    /// Ob die Staffelliste einer Seerr-Serie aufgeklappt ist — der erste
    /// Druck auf den Hauptknopf oeffnet sie, der zweite fragt an.
    var seerrStaffelnOffen = false
    var seerrStaffelaufklapp: Widget?
    /// Fortschrittsbalken und Standzeilen je Posten — damit ein Fortschritt
    /// die Liste nicht neu bauen muss.
    var downloadbalken: [String: Widget] = [:]
    var downloadstandzeilen: [String: Widget] = [:]
    /// H10: die Nachfrage vor dem Abschalten, in den Einstellungen.
    var downloadabschaltfrage: Widget!
    var benutzername = ""
    /// Der Name des Servers. **Er steht auch im Kopf jeder Rasterseite**
    /// (E15) — deshalb malen die Seiten nach, sobald er sich ändert.
    var servername = "" { didSet { if servername != oldValue { serverzeilenMalen() } } }
    var serverfassung = ""
    /// Was im Raster schon steht, und wie viel der Server insgesamt hat —
    /// für das Nachladen beim Blättern.
    var rasterItems: [Bereich: [Item]] = [:]
    var rasterGesamt: [Bereich: Int] = [:]
    var rasterLaedt: Set<Bereich> = []
    var laderFeld: [Bereich: Widget] = [:]
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
    /// **Läuft gerade ein Folgenwechsel?** Siehe ``naechsteFolge()`` — ohne
    /// diesen Riegel lief er mehrfach an, weil `Folgenende.weiterschalten`
    /// jeden Takt wahr bleibt, während der Wechsel zwei Netzabrufe braucht.
    var wechselt = false
    /// Ob der Nutzer auf der offenen Detailseite schon etwas gewählt hat.
    /// Die zuletzt aufgeklappte Tafel des Mehr-Knopfs. Sie wird beim nächsten
    /// Klick gelöst — sonst hängen sie sich am Knopf auf.
    var offeneTafel: Widget?

    /// **Eine Tafel oeffnen und sie richtig merken.**
    ///
    /// Die vorige kommt weg — sonst hinge nach dem dritten Klick die dritte
    /// Tafel am Knopf und die beiden davor daneben. Und die neue vergisst
    /// sich selbst, sobald GTK sie abraeumt: `tafelAn` haengt sie beim
    /// Zerstoeren des Ankers ab, und ein Feld, das dann noch auf sie zeigt,
    /// ist ein Zeiger auf freigegebenen Speicher. Der naechste Klick auf
    /// „Mehr" war damit ein Absturz — im Kern nachgelesen, nicht vermutet.
    ///
    /// Dieselbe Klasse Fehler wie bei den Zeichenflaechen, die sich selbst
    /// halten muessen: wer ein GTK-Objekt in einem Swift-Feld merkt, muss
    /// auf sein Ende hoeren.
    func tafelOeffnen(an knopf: Widget!, stil: String = "swiftly-mehr") -> Widget! {
        tafelSchliessen()
        let tafel = tafelAn(knopf, stil: stil)
        offeneTafel = tafel
        beiSignal(tafel, "destroy") { [weak self] in self?.offeneTafel = nil }
        return tafel
    }

    func tafelSchliessen() {
        guard let alt = offeneTafel else { return }
        offeneTafel = nil
        gtk_widget_unparent(alt)
    }
    var detailBeruehrt = false
    /// Was zuletzt bei „Verbindung prüfen" herauskam.
    var pruefergebnis = ""
    /// „Läuft ab in 4:58" unter dem Quick-Connect-Code.
    var kontoRestfeld: Widget!
    /// **Staffeln und Folgen, einmal geholt.**
    ///
    /// Der Mac hat dafür `Seriencache`: wer eine Serienseite verlässt und
    /// zurückkommt, sieht sie sofort stehen. Auf Linux wurde jedes Mal neu
    /// geholt, mit „Lade …" davor — bei einer Serie, die man mehrmals am
    /// Abend öffnet, ist das jedes Mal dieselbe Wartezeit.
    var staffelspeicher: [String: [Item]] = [:]
    var folgenspeicher: [String: [Item]] = [:]

    /// **Was hier liegt, traegt auch den Sehstand.**
    ///
    /// Die gemerkten Folgen tragen `userData` — also Haken und Fortschritt.
    /// Wer eine Folge abhakt, aendert den Stand beim Server; was hier liegt,
    /// weiss nichts davon, und beim naechsten Oeffnen der Staffel steht sie
    /// wieder offen da.
    ///
    /// Am 12.09.2026 auf dem iPhone gemeldet und dort gleich behoben
    /// (`Sources/Shared/AppModel.swift`): eine ganze Staffel abgehakt,
    /// zurueck, wieder hinein — alles wieder ungesehen. Derselbe Speicher,
    /// dieselbe Falle, nur in GTK.
    ///
    /// **Wegwerfen statt nachtragen.** Den Haken im gemerkten `Item` zu
    /// aendern hiesse, `Item` und `UserItemData` neu zu bauen; der Speicher
    /// ist dafuer da, dass der Rueckweg nicht leer ist, nicht dafuer, die
    /// Wahrheit ueber den Sehstand zu halten.
    func sehstandVergessen(_ item: Item) {
        let serie = item.seriesId ?? item.id
        for staffel in staffelspeicher[serie] ?? [] { folgenspeicher[staffel.id] = nil }
        staffelspeicher[serie] = nil
        // Die Staffel selbst, und die Staffel, in der eine Folge steht —
        // beide koennen gemerkt sein, ohne dass die Serie es ist.
        folgenspeicher[item.id] = nil
        if let staffel = item.seasonId { folgenspeicher[staffel] = nil }
    }

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
    /// Zaehlt die Spielerseiten. Siehe ``spielerOeffnen(_:ab:)``.
    var spielerZaehler = 0
    var spielerAbspielzeichen: Abspielzeichen?
    var spielerWeiter: Widget!
    var spielerSpurknopf: Widget!
    /// Hält das gemalte Reglerzeichen des Wiedergabe-Chips am Leben, solange
    /// die Spielerseite steht.
    var spielerReglerzeichen: Reglerzeichen?
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
    /// Welcher Bereich im Wiedergabemenue gerade links gewaehlt ist.
    var spurbereich: Spurbereich = .ton
    /// Das Technikschild ueber dem Film — `nil`, wenn es aus ist.
    var technikschild: Widget!
    /// Der letzte Stand der Zaehler; die naechste Messung rechnet daraus.
    var technikzaehler: Zaehlwerk?
    /// Seerr — Zugang und Client, `nil` solange nichts eingerichtet ist.
    var seerrzugang: Seerrzugang?
    var seerrclient: SeerrClient?
    /// Ob die gespeicherte Seerr-Sitzung noch traegt. `nil` heisst „noch
    /// nicht nachgesehen"; zurueckgesetzt beim Trennen und beim Verbinden.
    var seerrGilt: Bool?
    /// Die Seerr-Treffer der Suche — Ueberschrift und Raster darunter.
    var seerrUeberschrift: Widget!
    /// Die Zeile aus Überschrift und Zählmarke — sie wird als Ganzes
    /// ein- und ausgeblendet, nicht nur die Überschrift.
    var seerrKopfzeile: Widget!
    /// Wie viele Treffer Seerr hat (E27).
    var seerrZahl: Widget!
    var seerrRaster: Widget!
    /// Die Rueckfrage vor einer Anfrage — sie steht dort, wo geklickt wurde.
    var seerrRueckfrage: Widget!
    var schlafminuten: Int?
    var schlaftakt = 0

    // MARK: Bibliotheken (D9)
    /// Was der Server an Bibliotheken hat. **Ab zwei derselben Gattung** wird
    /// zwischen ihnen gewählt; bei einer erscheint kein Umschalter.
    var sichten: [Item] = []
    var gewaehlteBibliothek: [Bereich: String] {
        get {
            var d: [Bereich: String] = [:]
            for (k, v) in wahlen.bibliothekJeGattung {
                if let b = Bereich.allCases.first(where: { $0.kennung == k }) { d[b] = v }
            }
            return d
        }
        set {
            for (b, v) in newValue { wahlen.bibliothekJeGattung[b.kennung] = v }
            wahlen.sichern()
        }
    }
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
        gtk_stack_add_named(OpaquePointer(inhalt), rasterseiteBauen(.merkliste), "merkliste")
        gtk_stack_add_named(OpaquePointer(inhalt), rasterseiteBauen(.bibliothek), "bibliothek")
        gtk_stack_add_named(OpaquePointer(inhalt), rasterseiteBauen(.gattung), "gattung")
        gtk_stack_add_named(OpaquePointer(inhalt), downloadseiteBauen(), "downloads")
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
                letzterSprung = Date()
                spielerZurueckZeichen?.stupsen()
                sprungZeigen(true)
                steuerungZeigen()
                return true
            case 0xFF53:                                   // Pfeil rechts
                abspieler.springen(Double(wahlen.vorSekunden))
                sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
                letzterSprung = Date()
                spielerVorZeichen?.stupsen()
                sprungZeigen(false)
                steuerungZeigen()
                return true
            case 0xFFC8:                                   // F11
                vollbildUmschalten()
                return true
            case 0xFF1B:                                   // Escape
                // **Erst die Tafel, dann das Vollbild, dann der Player.**
                // Der Mac prueft die offene Spurwahl vor allem anderen
                // (`PlayerScreen.fluchttaste()`, `:659`); hier uebersprang
                // Escape sie und schloss gleich den ganzen Player.
                if spurtafel != nil {
                    spurwahlSchliessen()
                } else if gtk_window_is_fullscreen(alsFenster(fenster)) != 0 {
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
        for fall in Bereich.obenGruppe { anhaengen(bereiche, bereichszeile(fall)) }
        anhaengen(leiste, bereiche)

        // **Darunter, was mir gehoert.** Die Begruendung steht bei
        // `Bereich.meinsGruppe`; die Masse sind die der Bibliotheksrubrik,
        // weil es dieselbe Sorte Zwischenueberschrift ist.
        let meinsrubrik = rubrik(uebersetzt("Meins"))
        gtk_widget_set_margin_top(meinsrubrik, 26)
        gtk_widget_set_margin_bottom(meinsrubrik, 8)
        gtk_widget_set_margin_start(meinsrubrik, 12)
        gtk_widget_set_margin_end(meinsrubrik, 12)
        anhaengen(leiste, meinsrubrik)

        meinsliste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_margin_start(meinsliste, 12)
        gtk_widget_set_margin_end(meinsliste, 12)
        anhaengen(leiste, meinsliste)
        meinsFuellen()

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

    /// Eine Zeile in der Leiste, gemerkt unter ihrem Bereich.
    private func bereichszeile(_ fall: Bereich) -> Widget! {
        let zeile = seitenleistenzeile(symbol: fall.symbol,
                                       text: fall.beschriftung,
                                       aktiv: fall == bereich)
        // **Das Kuerzel steht am Kurzhinweis.**
        //
        // Auf dem Mac stehen alle fuenf sichtbar in der Menueleiste unter
        // „Gehe zu" (`SwiftlyApp.swift:102-110`). Die gibt es hier nicht —
        // ein Wayland-Fenster hat keine —, und die Kuerzel selbst
        // funktionierten, waren aber nirgends abzulesen. Ein Kurzhinweis ist
        // der Ort, an dem eine Oberflaeche ohne Menue so etwas sagt.
        if let kuerzel = fall.kuerzel {
            gtk_widget_set_tooltip_text(zeile, "\(fall.beschriftung)   \(kuerzel)")
        }
        beiSignal(zeile, "clicked") { [weak self] in self?.zeige(fall) }
        bereichsknoepfe[fall] = zeile
        return zeile
    }

    /// **Die Rubrik „Meins" wird neu gebaut, wenn der Schalter umgeht.**
    /// H1: ohne Downloads gibt es die Zeile nicht — und wer sie ausschaltet,
    /// waehrend er darauf steht, soll nicht auf einer Seite stehenbleiben,
    /// die es nicht mehr gibt.
    func meinsFuellen() {
        guard meinsliste != nil else { return }
        leeren(meinsliste)
        for fall in Bereich.meinsGruppe(downloads: downloadsAn) {
            anhaengen(meinsliste, bereichszeile(fall))
        }
        if !downloadsAn {
            bereichsknoepfe[.downloads] = nil
            if bereich == .downloads { zeige(.start) }
        }
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
    /// nächsten Start erscheint, ist keins.
    ///
    /// **Fünf Sekunden, nicht zehn.** Hier standen zehn, mit genau der
    /// Begründung, die auf Apple am 10.09.2026 verworfen wurde: „der Server
    /// meldet den Fortschritt ohnehin in dem Takt". Das stimmt für die
    /// Stelle — nur wird hier nicht nach einem neuen Sekundenstand gesucht,
    /// sondern nach einer Sitzung, die es vorher **gar nicht gab**, und die
    /// meldet sich sofort. Die ganze Wartezeit entstand allein an dieser
    /// Zahl (`Sources/Shared/Uebernahmemodell.swift:46-60`).
    func uebernahmetaktStarten() {
        uebernahmelauf?.cancel()
        uebernahmelauf = Task.detached { [self] in
            while !Task.isCancelled {
                await self.uebernahmeFragen()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func uebernahmeFragen() async {
        guard let client, !benutzerID.isEmpty else { return }
        // **Still nach aussen, laut im Protokoll.** Gefragt wird im Takt;
        // eine Meldung auf der Startseite waere Laerm. Der Unterschied
        // zwischen „nichts laeuft" und „die Frage kam nicht an" muss aber
        // irgendwo stehen — genau daran ist die Uebernahme am 10.09.2026
        // stundenlang vorbeigesucht worden, weil `fremdsitzungen()` jeden
        // Fehlschlag als leere Liste zurueckgab.
        let sitzungen: [Fremdsitzung]
        do {
            sitzungen = try await client.fremdsitzungen()
        } catch {
            Spur.sag("[Uebernahme] Abfrage fehlgeschlagen: \(error)")
            return
        }
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
        // **Sie traegt die Hervorhebung, solange eine Unterseite offen ist.**
        // Auf dem Mac bekommt `Profilzeile` dafuer `aktiv: imKonto`
        // (`HauptView.swift:831`) und faerbt Namen und Flaeche im Akzent.
        // Hier nahm `bereichszeilenMalen` allen Bereichszeilen die
        // Hervorhebung, sobald eine Unterseite offen war, gab sie aber
        // nirgends weiter: dann leuchtete gar nichts mehr.
        profilzeile = knopf
        raender(knopf, 12)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)

        // **Die Zone traegt bei mehreren Konten mehrere Kreise** und wird
        // deshalb bei jeder Anmeldung neu gefuellt, statt ein festes Bild zu
        // halten. ``profilkreiseAuffrischen()`` baut sie.
        profilkreise = gtk_fixed_new()
        gtk_widget_set_valign(profilkreise, GTK_ALIGN_CENTER)
        anhaengen(reihe, profilkreise)

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
    /// **`blende` ist der Bereichswechsel**, `tiefer`/`zurueck` das Blaettern
    /// in Titeln, `ohne` der Neubau an Ort und Stelle.
    ///
    /// Sie ist dazugekommen, weil derselbe Klick zwei Verhalten hatte: wer
    /// auf einen Bereich ohne gemerkte Detailseite ging, sah die Kreuzblende
    /// des Stapels; wer auf einen mit gemerkter Seite ging, bekam
    /// `schieben(.ohne)` — also gar nichts. Filme und Serien schalteten
    /// deshalb hart um und die Merkliste blendete ein.
    enum Schub { case tiefer, zurueck, ohne, blende }

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

        // **„Fade Through": erst hinaus, dann herein** — und die beiden
        // ueberlappen. Hier stand eine gleichzeitige Kreuzblende mit **einer**
        // Dauer; damit steht die Seite in der Mitte des Wechsels auf halber
        // Deckung, und beide Bilder sind gleichzeitig halb zu sehen. Der Mac
        // trennt die Dauern (`Sources/macOS/Stil.swift:208-210`): 0,20 s
        // hinaus mit `easeInOut`, 0,26 s herein mit `easeOut` und 0,04 s
        // Vorlauf. Zusammen 0,30 s, und es ist nie nichts zu sehen.
        if richtung == .blende {
            gtk_fixed_move(fest, ziel, 0, 0)
            gtk_widget_insert_before(ziel, buehne, nil)
            gtk_widget_set_opacity(ziel, 0)
            let hinaus = Stil.zeitBlendeHinaus
            let vorlauf = Stil.zeitBlendeVorlauf
            let herein = Stil.zeitBlendeHerein
            let gesamt = max(hinaus, vorlauf + herein)
            laufen(auf: buehne, dauer: gesamt) { e in
                let t = e * gesamt
                // Das Alte: `easeInOut` ueber `hinaus`.
                let a = min(max(t / hinaus, 0), 1)
                gtk_widget_set_opacity(alt, 1 - (a < 0.5 ? 2 * a * a
                                                         : 1 - pow(-2 * a + 2, 2) / 2))
                // Das Neue: `easeOut` ueber `herein`, nach dem Vorlauf.
                let b = min(max((t - vorlauf) / herein, 0), 1)
                gtk_widget_set_opacity(ziel, 1 - pow(1 - b, 3))
            } fertig: {
                gtk_widget_set_opacity(ziel, 1)
                gtk_widget_set_opacity(alt, 1)
                gtk_widget_set_visible(alt, 0)
            }
            return
        }

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
    ///
    /// **Ein Klick auf den offenen Bereich fuehrt auf dessen Wurzel.**
    /// Vorher passierte nichts: `zeige(.start)` setzte `bereich` auf den Wert,
    /// den es schon hatte, sah oben auf dem Stapel eine Detailseite und zeigte
    /// genau die wieder. Wer aus einem Titel heraus auf „Start" klickte, blieb
    /// im Titel — und hatte keinen Weg zurueck ausser dem Pfeil. Auf dem Mac
    /// ist derselbe Fall in `bereichWaehlen` behoben.
    ///
    /// Ein Klick auf einen **anderen** Bereich laesst dessen Stapel stehen:
    /// wer zwischen Filmen und Serien wechselt, findet zurueck, wo er war.
    func zeige(_ neu: Bereich) {
        let schonHier = bereich == neu && offeneUnterseite == nil
        // **Und er schliesst eine offene Unterseite.** Profil, Einstellungen
        // und Wiedergabe liegen ueber dem Bereich, nicht daneben.
        let ausUnterseite = offeneUnterseite != nil
        offeneUnterseite = nil
        if schonHier { seitenstapel[neu] = [] }

        // **Ein Bereich schliesst die offene Bibliothek.** Sonst bliebe ihre
        // Zeile hervorgehoben, waehrend rechts etwas anderes steht — auf dem
        // Mac macht das `bibliothekSchliessen()` an derselben Stelle.
        if neu != .bibliothek, offeneBibliothek != nil {
            offeneBibliothek = nil
            bibliothekszeilenMalen()
        }
        _ = ausUnterseite
        bereich = neu
        bereichszeilenMalen()
        // **Der Stapel entscheidet, was zu sehen ist.** Liegt auf diesem
        // Bereich eine Detailseite, kommt sie zurück — nicht die Liste.
        // **Ein Bereichswechsel blendet — beide Wege.** Vorher blendete nur
        // der eine, weil der andere ueber `schieben(.ohne)` lief.
        if let oben = seitenstapel[neu]?.last {
            detailZeigen(oben, schub: .blende)
        } else {
            bereichZeigen(neu.kennung, schub: .blende)
        }
        // **Wer auf „Suche" geht, will tippen.** Der Mac setzt den Fokus beim
        // Erscheinen der Seite; hier ging es nur über Strg+F.
        if neu == .suche { gtk_widget_grab_focus(suchfeld); suchverlaufZeigen() }
        // **Jeder Bereich lädt einmal.** Auf dem Mac bleiben die Stände der
        // Bereiche liegen; wer zwischen Filmen und Serien wechselt, wartet
        // nur beim ersten Mal.
        guard !geladen.contains(neu) else { return }
        geladen.insert(neu)
        switch neu {
        case .start:  startseiteLaden()
        case .filme:  rasterLaden(.filme)
        case .serien: rasterLaden(.serien)
        case .merkliste: rasterLaden(.merkliste)
        // Die Downloadliste steht auf der Platte; sie wird nicht geholt,
        // sondern gezeigt.
        case .downloads: downloadseiteFuellen()
        case .bibliothek: rasterLaden(.bibliothek)
        case .gattung: rasterLaden(.gattung)
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

    /// **Die Haarlinie, die beim Scrollen einblendet** (E15).
    ///
    /// Sie fehlte auf den Rasterseiten als einzigen — die Serienseite hat sie
    /// seit langem (`Serienseite.swift:61`). Ohne sie laeuft der Inhalt beim
    /// Blaettern ohne Kante unter dem Kopf durch, und man sieht nicht, dass
    /// oben noch etwas steht.
    ///
    /// Sie liegt als Ueberzug **ueber** dem Scroller, nicht darin: im Inhalt
    /// wanderte sie mit.
    private func mitKopflinie(_ scroller: Widget!) -> Widget! {
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), scroller)

        let linie: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(linie, "swiftly-trennlinie")
        gtk_widget_set_size_request(linie, -1, 1)
        gtk_widget_set_valign(linie, GTK_ALIGN_START)
        gtk_widget_set_opacity(linie, 0)
        gtk_widget_set_can_target(linie, 0)
        gtk_overlay_add_overlay(OpaquePointer(ueber), linie)

        guard let anpassung = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return ueber }
        // Ueber die ersten 24 Punkt einblenden — dieselbe kurze Strecke wie
        // beim Detailkopf, damit es nicht als Bewegung auffaellt.
        beiSignalRoh(UnsafeMutableRawPointer(anpassung), "value-changed") {
            let wert = gtk_adjustment_get_value(anpassung)
            gtk_widget_set_opacity(linie, min(max(wert / 24, 0), 1))
        }
        return ueber
    }

    /// Eine Seitenüberschrift mit der Zahl rechts — „Filme … 7".
    /// - Parameters:
    ///   - mitServer: Ob die Serverzeile unter dem Titel steht. **Nur die
    ///     Bibliotheksseiten** — `BibliothekView.swift:61-80` hat sie, die
    ///     Merkliste (`MerklisteView.swift:42-49`) und die Genreseite
    ///     (`GenreView.swift:29`, ein blanker `Unterseitenkopf`) nicht.
    ///   - mitZahl: Ob rechts die Zaehlmarke steht. Die Genreseite hat keine.
    private func seitenkopf(_ titel: String, zahl: inout Widget!,
                            titelfeld: inout Widget!,
                            serverfeld: inout Widget!,
                            zurueck: (() -> Void)? = nil,
                            mitServer: Bool = true,
                            mitZahl: Bool = true) -> Widget! {
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        if let zurueck {
            let pfeil: Widget! = gtk_button_new()
            gtk_widget_add_css_class(pfeil, "swiftly-zurueck")
            gtk_button_set_child(alsKnopf(pfeil),
                                 gtk_image_new_from_icon_name("go-previous-symbolic"))
            gtk_widget_set_valign(pfeil, GTK_ALIGN_CENTER)
            beiSignal(pfeil, "clicked", zurueck)
            anhaengen(reihe, pfeil)
        }
        let spalte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 3)
        gtk_widget_set_hexpand(spalte, 1)
        let t = beschriftung(titel, stil: "swiftly-titel-gross")
        titelfeld = t
        gtk_label_set_xalign(OpaquePointer(t), 0)
        anhaengen(spalte, t)

        // **Wo bin ich hier eigentlich?** (E15) Der Servername stand auf
        // keiner Seite; bei mehreren Konten mit gleich benannten Bibliotheken
        // ist er der einzige Unterschied. Er steht nur da, wenn es einen gibt
        // — eine leere zweite Zeile waere eine Luecke ohne Aussage.
        let sv = beschriftung(servername, stil: "swiftly-zaehlmarke")
        gtk_label_set_xalign(OpaquePointer(sv), 0)
        gtk_label_set_ellipsize(OpaquePointer(sv), PANGO_ELLIPSIZE_END)
        gtk_widget_set_visible(sv, (mitServer && !servername.isEmpty) ? 1 : 0)
        serverfeld = mitServer ? sv : nil
        anhaengen(spalte, sv)
        anhaengen(reihe, spalte)

        // **Erst ab eins.** Der Mac zeigt die Zahl nur bei `gesamt > 0`
        // (`BibliothekView.swift:80`, `MerklisteView.swift:48`); hier stand
        // bei leerem Ergebnis eine „0" neben der Ueberschrift.
        zahl = beschriftung("", stil: "swiftly-zaehlmarke")
        gtk_widget_set_valign(zahl, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(zahl, 0)
        if mitZahl { anhaengen(reihe, zahl) }
        return reihe
    }

    /// **Die Startseite bekommt seitlich keinen Rand.**
    ///
    /// Der Grund war der Rand hier — er schneidet die waagerechte
    /// Blätterfläche mit ab.
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
        // Der obere Abstand steckt im Stilblatt als `padding`, nicht hier als
        // `margin`: der Farbschein ist der Anstrich dieses Kastens und begänne
        // sonst erst unterhalb des Randes.
        gtk_widget_add_css_class(reihenstapel, "swiftly-startschein")
        // **Ueber die volle Breite.** Ohne das behaelt der Stapel nach einem
        // Zurueck die Breite, die er beim Hereinfahren hatte — rechts blieb
        // ein schwarzer Streifen stehen, und der Farbschein endete mitten auf
        // der Seite.
        gtk_widget_set_hexpand(reihenstapel, 1)
        gtk_widget_set_halign(reihenstapel, GTK_ALIGN_FILL)
        gtk_widget_set_margin_bottom(reihenstapel, Int32(Stil.randAbstand))
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihenstapel)
        return scroller
    }

    private func rasterseiteBauen(_ was: Bereich) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 20)
        var zahl: Widget!
        var titel: Widget!
        var serverzeile: Widget!
        // **Eine Genreseite ist keine Wurzel** und traegt deshalb einen
        // Zurueckpfeil im Inhalt, wie jede Unterseite
        // (`Sources/macOS/GenreView.swift:29`). Filme, Serien, Merkliste und
        // Downloads stehen in der Leiste und brauchen keinen; die Bibliothek
        // steht dort ebenfalls.
        anhaengen(block, seitenkopf(was.beschriftung, zahl: &zahl, titelfeld: &titel,
                                    serverfeld: &serverzeile,
                                    zurueck: was == .gattung ? { [weak self] in
                                        self?.zeige(.start)
                                    } : nil,
                                    mitServer: was != .gattung && was != .merkliste,
                                    mitZahl: was != .gattung))
        // Nur diese eine Seite wechselt ihren Titel.
        if was == .bibliothek { bibliothekstitel = titel }
        if was == .gattung { gattungstitel = titel }
        // `nil`, wo die Seite keine traegt — sonst faerbte
        // `serverzeilenMalen` sie doch wieder ein.
        serverzeilen[was] = serverzeile

        let zeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        chipzeilen[was] = zeile
        anhaengen(block, zeile)
        chipsFuellen(was)

        let raster = rasterBauen()
        anhaengen(block, raster)

        // **Leerzustaende, wie der Mac sie hat.** Genre und Merkliste zeigen
        // dort einen (`GenreView.swift:56`, `MerklisteView.swift:117`); Filme,
        // Serien und Bibliothek nicht — dort sagt die Zaehlmarke genug.
        if let (zeichen, kopf, text) = leertext(was) {
            let leer = leerzustand(zeichen, kopf, text)
            gtk_widget_set_visible(leer, 0)
            gtk_widget_set_margin_top(leer, 60)
            anhaengen(block, leer)
            leerFeld[was] = leer
        }
        // **Kein „Lade …" als Fliesstext** (E17). Das Register laesst Text nur
        // an Knoepfen zu; auf einer Liste steht ein Platzhalter in der Form
        // dessen, was kommt. Auf der Serienseite und der Startseite steht das
        // schon so — hier stand die dritte Form, die es nirgends geben soll.
        let lader = rasterPlatzhalter(anzahl: 6, rand: 0)
        gtk_widget_set_halign(lader, GTK_ALIGN_START)
        gtk_widget_set_margin_top(lader, 8)
        gtk_widget_set_visible(lader, 0)
        anhaengen(block, lader)
        rasterFeld[was] = raster
        zahlFeld[was] = zahl
        laderFeld[was] = lader

        let rahmen = seitenrahmen(block)
        // **Am unteren Rand wird nachgeladen** (`edge-reached` — das Signal
        // bringt die Kante mit, also wieder ein eigener Rückruf, Falle 2).
        // **Eine Genreseite laedt einmal.** Der Mac holt dort genau 200 und
        // blaettert nicht nach (`GenreView.swift:69-72`; `titel(gattung:)`
        // im Paket kennt kein `startIndex`). Hier hing dieselbe
        // Nachladeschleife dran wie an einer Bibliothek.
        if was != .gattung {
            randMelden(rahmen) { [weak self] in self?.rasterNachladen(was) }
        }
        return mitKopflinie(rahmen)
    }

    /// **Filter links, Sortierung rechts** — die Anordnung des Macs.
    ///
    /// Beide Listen kommen aus `JellyfinKit.Bibliotheksfilter` und
    /// `Sortierung`. Dort steht auch, was sie beim Server bedeuten, und dass
    /// „Ungesehen" bewusst den eigenen Schalter braucht statt Jellyfins
    /// `Filters=IsUnplayed` — das arbeitet bei Serien auf Folgenebene.
    /// Die Bibliotheken einer Gattung.
    func bibliotheken(fuer was: Bereich) -> [Item] {
        // **Die Merkliste hat keine.** Sie geht ueber alle Bibliotheken und
        // siebt beim Server auf `IsFavorite`; eine Bibliothekswahl waere dort
        // eine Einschraenkung, die es auf dem Mac auch nicht gibt.
        switch was {
        case .filme:  return sichten.filter { $0.collectionType == "movies" }
        case .serien: return sichten.filter { $0.collectionType == "tvshows" }
        default:      return []
        }
    }

    func chipsFuellen(_ was: Bereich) {
        guard let zeile = chipzeilen[was] else { return }
        leeren(zeile)
        // **Eine Genreseite hat keine Chips.** Der Mac zeigt dort weder
        // Filter noch Sortierung (`Sources/macOS/GenreView.swift`): die
        // Reihenfolge steht fest auf „zuletzt hinzugefuegt", weil man ein
        // Genre antippt, um zu sehen, was neu ist. Hier hingen beide Reihen
        // dran — der Sortierchip leuchtete auf und tat nichts, weil
        // `rasterLaden` fuer Genres ohnehin `DateCreated` erzwingt, und der
        // Filterchip tat etwas, das es beim Vorbild gar nicht gibt.
        if was == .gattung {
            gtk_widget_set_visible(zeile, 0)
            return
        }
        gtk_widget_set_visible(zeile, 1)
        let jetztFilter = filterVon(was)
        let jetztSort = sortierungVon(was)

        // **Die Bibliothekswahl steht hier nicht mehr.**
        //
        // Sie stand als Chips vorn: bei mehreren Sammlungen einer Gattung
        // konnte man umschalten. Der Mac hat das verworfen, und zwar mit
        // Begruendung (`BibliothekView.swift:84`): seit die uebrigen
        // Bibliotheken links in der Leiste stehen und sich als eigene Wurzel
        // oeffnen, ist es ein zweiter Weg zur selben Sache — **und einer, der
        // die Ueberschrift nicht mitnimmt.** Genau das war hier auch der Fall:
        // `rasterseiteBauen` haelt den Titel nur fuer `.bibliothek` und
        // `.gattung` fest, also blieb ueber „Filmabend" die Ueberschrift
        // „Filme" stehen.
        //
        // Welche Sammlung ein Bereich zeigt, entscheidet damit allein die
        // gemerkte Wahl — und die Leiste zeigt daneben, was es sonst noch gibt.

        // **Die Merkliste waehlt die Gattung, nicht den Zustand** (E25).
        // Der Server siebt dort schon auf `IsFavorite`; ein Zustandsfilter
        // daneben stuende da und taete nichts. Stattdessen die Gattungspille
        // — sie fehlte auf Linux ganz, und damit gab es keinen Weg, Filme und
        // Serien zu trennen.
        if was == .merkliste {
            for fall in Merkgattung.allCases {
                let c = chip(fall.beschriftung, aktiv: fall == merkgattung)
                beiSignal(c, "clicked") { [weak self] in
                    guard let self, fall != self.merkgattung else { return }
                    self.merkgattung = fall
                    self.chipsFuellen(was)
                    self.rasterLaden(was)
                }
                anhaengen(zeile, c)
            }
        }
        for fall in was == .merkliste ? [] : Bibliotheksfilter.allCases {
            let c = chip(fall.beschriftung, aktiv: fall == jetztFilter)
            beiSignal(c, "clicked") { [weak self] in
                guard let self else { return }
                self.filterSetzen(was, fall)
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
                self.sortierungSetzen(was, fall)
                self.chipsFuellen(was)
                self.rasterLaden(was)
            }
            anhaengen(zeile, c)
        }
    }

    private func sucheBauen() -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 20)
        var unbenutzt: Widget!
        var unbenutztertitel: Widget!
        var unbenutzteserverzeile: Widget!
        anhaengen(block, seitenkopf(uebersetzt("Suche"), zahl: &unbenutzt,
                                    titelfeld: &unbenutztertitel,
                                    serverfeld: &unbenutzteserverzeile))

        // **„Titel, Serie, Person", nicht „Suchen".** Der Platzhalter sagt
        // auf dem Mac, **wonach** man suchen kann (`SucheView.swift:100`);
        // „Suchen" wiederholt nur die Überschrift darüber.
        suchfeld = eingabezeile(symbol: "system-search-symbolic",
                                platzhalter: uebersetzt("Titel, Serie, Person"))
        // **420 breit, nicht über die ganze Seite** — `SucheView.swift:102`
        // deckelt mit `frame(maxWidth: 420)`. Ein Feld über 1200 Punkt sieht
        // aus, als erwarte es einen Satz.
        gtk_widget_set_size_request(suchfeld, 420, Int32(Stil.feldHoehe))
        gtk_widget_set_halign(suchfeld, GTK_ALIGN_START)
        gtk_widget_set_hexpand(suchfeld, 0)
        anhaengen(block, suchfeld)

        // **„Zuletzt gesucht" — dieselbe Liste wie auf iPhone, Fernseher und
        // Mac.** Die Logik liegt als ``Suchverlauf`` im Paket und war hier nie
        // angeschlossen: bei leerem Feld stand auf Linux gar nichts.
        let (verlaufAussen, verlaufRaum) = zeilengruppe()
        suchverlaufblock = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        let verlaufkopf = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        gtk_widget_set_margin_top(verlaufkopf, 26)
        gtk_widget_set_margin_bottom(verlaufkopf, 8)
        let verlauftitel = rubrik(uebersetzt("Zuletzt gesucht"))
        gtk_widget_set_hexpand(verlauftitel, 1)
        anhaengen(verlaufkopf, verlauftitel)
        let verlaufWeg: Widget! = gtk_button_new()
        gtk_widget_add_css_class(verlaufWeg, "swiftly-blank")
        gtk_button_set_child(alsKnopf(verlaufWeg),
                             beschriftung(uebersetzt("Löschen"), stil: "swiftly-zaehlmarke"))
        beiSignal(verlaufWeg, "clicked") { [weak self] in
            self?.wahlen.suchverlauf = ""
            self?.wahlen.sichern()
            self?.suchverlaufZeigen()
        }
        anhaengen(verlaufkopf, verlaufWeg)
        anhaengen(suchverlaufblock, verlaufkopf)
        anhaengen(suchverlaufblock, verlaufAussen)
        suchverlaufliste = verlaufRaum
        // 700 breit und links — `SucheView.swift:83`
        // (`frame(maxWidth: Stil.lesebreite, alignment: .leading)`). Ohne den
        // Deckel lief die Karte über die ganze Fensterbreite, und eine
        // Wortliste von zwölfhundert Punkt Breite liest sich nicht.
        gtk_widget_set_size_request(suchverlaufblock, Int32(Stil.lesebreite), -1)
        gtk_widget_set_halign(suchverlaufblock, GTK_ALIGN_START)
        anhaengen(block, suchverlaufblock)

        // **Solange nichts dasteht, sagt die Seite, wonach man suchen kann.**
        // Auf dem Mac steht das statt der Verlaufsliste, wenn es keinen
        // Verlauf gibt (`SucheView.swift:109`); auf Linux blieb die Seite
        // unter dem Feld einfach leer.
        suchhinweis = leerzustand("system-search-symbolic",
                                  uebersetzt("Filme, Serien und Folgen durchsuchen"), nil)
        gtk_widget_set_visible(suchhinweis, 0)
        anhaengen(block, suchhinweis)

        suchraster = rasterBauen()
        anhaengen(block, suchraster)
        // **Leer ist eine Auskunft.** Ohne sie steht die Seite still da, und
        // man weiss nicht, ob gesucht wurde oder nichts da ist.
        suchleer = leerzustand("mail-inbox-symbolic", uebersetzt("Nichts gefunden"), nil)
        gtk_widget_set_visible(suchleer, 0)
        anhaengen(block, suchleer)

        // **Was der Server nicht hat, steht darunter — nicht dazwischen.**
        //
        // Woertlich die Anordnung der Apple-Fassung: erst die eigene
        // Bibliothek, dann eine eigene Ueberschrift und darunter, was Seerr
        // kennt. Vermischt waere nicht zu sehen, was man ansehen kann und was
        // man erst anfordern muss.
        // **Beide Blöcke der Suche tragen rechts die Zählmarke** (E27). Hier
        // stand nur die Überschrift; wie viele Treffer Seerr hat, sagte nichts.
        let seerrzeile = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        gtk_widget_set_margin_top(seerrzeile, 12)
        gtk_widget_set_visible(seerrzeile, 0)
        // **Eine Rubrik, keine Reihenueberschrift.** Auf dem Mac steht dort
        // 13 halbfett in Versalien mit 0,5 Sperrung, in `schriftSehrLeise`
        // (`SucheView.swift:143`) — hier stand `swiftly-reihe`, also 20 Punkt
        // wie ueber einer Startseitenreihe. Das machte den Seerr-Block
        // gewichtiger als die eigenen Treffer darueber, die gar keine
        // Ueberschrift haben.
        seerrUeberschrift = rubrik(uebersetzt("Kann angefragt werden"))
        gtk_label_set_xalign(OpaquePointer(seerrUeberschrift), 0)
        gtk_widget_set_hexpand(seerrUeberschrift, 1)
        anhaengen(seerrzeile, seerrUeberschrift)
        seerrZahl = beschriftung("", stil: "swiftly-zaehlmarke")
        gtk_widget_set_valign(seerrZahl, GTK_ALIGN_CENTER)
        anhaengen(seerrzeile, seerrZahl)
        seerrKopfzeile = seerrzeile
        anhaengen(block, seerrzeile)

        seerrRueckfrage = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_set_visible(seerrRueckfrage, 0)
        gtk_widget_set_margin_top(seerrRueckfrage, 4)
        anhaengen(block, seerrRueckfrage)

        seerrRaster = rasterBauen()
        gtk_widget_set_visible(seerrRaster, 0)
        anhaengen(block, seerrRaster)
        // Die Eingabetaste sucht sofort — und wird dabei selbst zur juengsten
        // Suche, sonst verwirft sie der Takt der noch laufenden Wartezeit.
        beiSignal(suchfeld, "activate") { [weak self] in
            guard let self else { return }
            self.suchtakt += 1
            // **Nur hier wird gemerkt.** Siehe ``suchen(_:merken:)``.
            self.suchen(self.suchtakt, merken: true)
        }
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
        guard let lader = laderFeld[was] else { return }
        gtk_widget_set_visible(lader, an ? 1 : 0)
    }

    /// **Leer ist eine Auskunft, kein leerer Kasten.** Symbol, Satz,
    /// Erklärzeile — die Form vom Mac (`Leerzustand`).
    func leerzustand(_ symbol: String, _ titel: String, _ text: String?) -> Widget! {
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
        // **Ohne Unterzeile keine leere Zeile.** „Nichts gefunden" auf dem
        // Mac steht allein da; ein leeres Feld darunter waere ein Loch.
        if let text {
            let u = beschriftung(text, stil: "swiftly-zweitzeile", umbruch: true)
            gtk_widget_add_css_class(u, "swiftly-leise")
            gtk_label_set_justify(OpaquePointer(u), GTK_JUSTIFY_CENTER)
            gtk_widget_set_halign(u, GTK_ALIGN_CENTER)
            anhaengen(block, u)
        }
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

    /// - Parameter auskunft: Ob die Zweitzeile die reiche Trefferauskunft
    ///   traegt („Serie · 3 Staffeln", „Breaking Bad · S1 E4 · 52 Min.")
    ///   statt der blossen Jahreszahl. **Nur die Suche.** Der Mac setzt sie
    ///   dort (`SucheView.swift:117`) und in der Bibliothek nicht
    ///   (`BibliothekView.swift:136`).
    func rasterFuellen(_ raster: Widget!, _ items: [Item], auskunft: Bool = false) {
        // **Dieselbe Bauart, die die App schon einmal aufgehängt hat.** Die
        // Schleife hing am Vorhandensein eines Kindes statt am Fortschritt:
        // schlägt `gtk_flow_box_remove` fehl — der Zeiger wird dafür blind
        // gecastet —, liefert `get_child_at_index` dasselbe Kind wieder, und
        // es geht ewig weiter. In ``leeren(_:)`` war genau das der Grund für
        // einen vollen Kern und ein Protokoll mit 58 MB je Sekunde.
        while let kind = gtk_flow_box_get_child_at_index(OpaquePointer(raster), 0) {
            gtk_flow_box_remove(OpaquePointer(raster),
                                unsafeBitCast(kind, to: Widget.self))
            guard gtk_flow_box_get_child_at_index(OpaquePointer(raster), 0) != kind
            else { break }
        }
        for item in items {
            gtk_flow_box_insert(OpaquePointer(raster),
                                rasterkachel(item, auskunft: auskunft), -1)
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
        // **Mit Plakat.** Der Mac legt es als `MPMediaItemPropertyArtwork` in
        // die Wiedergabezentrale (`Sources/Shared/Wiedergabezentrale.swift:210`);
        // MPRIS kennt dafuer `mpris:artUrl`, und die Kachel in der
        // Systemleiste stand hier ohne Bild da. **Die Adresse, nicht die
        // Bytes** — jede Umgebung holt das Bild selbst, und die Adresse hat
        // kein Zugangsmerkmal (G3, `Bildschluessel`).
        let plakat = adressen.flatMap {
            Bildwahl.hochkant(titel, adressen: $0, maxHoehe: 600)
        }
        medienleiste?.standMelden(laeuft: spielstand.laeuft,
                                  titel: titel.name,
                                  untertitel: titel.kontextzeile ?? titel.seriesName ?? "",
                                  dauer: spielstand.dauer,
                                  stelle: spielstand.position,
                                  bild: plakat?.absoluteString ?? "")
        // „Weiter" ist nur aktiv, wenn es eine naechste Folge gibt.
        medienleiste?.naechsteMelden(titel.type == "Episode")
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

    /// Meldet das **aktive** Konto ab.
    ///
    /// **Bleibt eines übrig, schaltet die App darauf um**, statt zur
    /// Serveranmeldung zurückzufallen — alle Konten auf einmal zu entfernen
    /// wäre eine zweite Bedeutung für denselben Knopf. Welches danach gilt,
    /// entscheidet ``Kontenbund/entfernt(_:)`` im Paket.
    func abmelden() {
        if let alter = bund, let rest = alter.entfernt(alter.aktiveKennung) {
            bund = rest
            let name = servername.isEmpty ? nil : servername
            let warImProfil = offeneUnterseite == .profil
            bundSichern(servername: name)
            aufraeumenNachWechsel()
            sitzungEinsetzen(rest.aktives, servername: name)
            // Auch hier im Profil bleiben: dass ein Konto aus dem Streifen
            // verschwunden ist, ist die Antwort auf den Knopf.
            if warImProfil { unterseiteOeffnen(.profil, schub: .ohne) }
            return
        }
        bund = nil
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
        profilkreiseAuffrischen()
    }

    /// Die Kreise unten in der Leiste — der aktive vorn, die anderen dahinter.
    ///
    /// **Warum sie hier stehen und nicht nur im Profil.** Der Streifen im
    /// Profil beantwortet die Frage „mit welchem Konto bin ich hier?" erst,
    /// nachdem man ihn geoeffnet hat. Zwei Kreise unten in der Leiste sagen
    /// es beilaeufig — und genau so steht es im abgenommenen Entwurf.
    ///
    /// **Hoechstens drei.** Der Platz ist eine Zeile in einer 220 breiten
    /// Leiste; wer sechs Konten haette, saehe sonst nur noch Kreise und
    /// keinen Namen mehr.
    private func profilkreiseAuffrischen() {
        guard let profilkreise else { return }
        leeren(profilkreise)

        // **26, nicht 30.** Die Zeile war auf 26 gebaut — mit 30 stand das
        // Bild groesser da als sein Platz, und GTK schnitt es unten und links
        // an: „der Kreis ist kein richtiger Kreis". Die Groesse aus dem
        // Entwurf (96/72) gilt fuer den Streifen im Profil, nicht fuer die
        // Fusszeile; hier zaehlt, dass die Zeile ihre Hoehe behaelt.
        let kante = 26, versatz = 17, hoechstens = 3
        // **Der Ring braucht seinen eigenen Platz.** Er liegt als Schatten
        // *ausserhalb* des Kreises; ohne Zuschlag schnitt die Zone ihn unten
        // ab Zwei Punkte ringsum, das ist die staerkste der beiden
        // Ringstaerken (1,5 aktiv, 2 daneben), aufgerundet.
        let ring = 2
        // Der aktive vorn, danach die anderen in ihrer Reihenfolge.
        var reihenfolge: [Session] = []
        if let bund {
            reihenfolge = [bund.aktives] + bund.konten.filter { $0.userID != bund.aktiveKennung }
        } else if !benutzerID.isEmpty {
            reihenfolge = []
        }
        let sichtbar = Array(reihenfolge.prefix(hoechstens))
        let breite = (sichtbar.isEmpty ? kante : kante + versatz * (sichtbar.count - 1))
        gtk_widget_set_size_request(profilkreise,
                                    Int32(breite + 2 * ring), Int32(kante + 2 * ring))

        guard !sichtbar.isEmpty else {
            // Kein Bund: das eine Bild wie bisher.
            let teile = profilzeichen(name: benutzername.isEmpty ? "?" : benutzername,
                                      kante: kante, stil: "swiftly-profilbild",
                                      schriftstil: "swiftly-zeichen26")
            profilbild = teile.bild
            gtk_fixed_put(alsFest(profilkreise), teile.huelle, Double(ring), Double(ring))
            profilbildLaden(teile,
                            url: benutzerID.isEmpty ? nil
                                                    : adressen?.benutzer(benutzerID, kante: 60),
                            schluessel: "leiste-\(benutzerID)")
            return
        }

        // **Von hinten nach vorn.** In einem ``GtkFixed`` liegt obenauf, was
        // zuletzt dazukommt; der aktive Kreis muss die anderen ueberdecken,
        // damit sein Akzentring nicht angeschnitten wird.
        for (i, konto) in sichtbar.enumerated().reversed() {
            // Ein einzelnes Konto sieht aus wie eh und je — ohne Ring. Der
            // Ring beantwortet die Frage „welches von mehreren"; bei einem
            // gibt es die Frage nicht.
            let stil = sichtbar.count == 1 ? "swiftly-profilbild"
                     : (i == 0 ? "swiftly-profilbild-aktiv" : "swiftly-profilbild-daneben")
            let teile = profilzeichen(name: konto.userName, kante: kante, stil: stil,
                                      schriftstil: "swiftly-zeichen26")
            if i == 0 { profilbild = teile.bild } else { gtk_widget_set_opacity(teile.huelle, 0.55) }
            gtk_fixed_put(alsFest(profilkreise), teile.huelle,
                          Double(ring + i * versatz), Double(ring))
            profilbildLaden(teile, url: adressen?.benutzer(konto.userID, kante: 60),
                            schluessel: "leiste-\(konto.userID)")
        }
    }

    private func bibliothekenLaden() {
        guard let client else { return }
        let stand = kontowechsel
        Task.detached { [self] in
            let sichten = (try? await client.userViews()) ?? []
            aufHauptfaden {
                // Dieselbe Eintrittskarte wie bei der Startseite: die
                // Bibliotheken des vorigen Kontos gehoeren nicht in die Leiste
                // des neuen.
                guard self.kontowechsel == stand else { return }
                self.bibliothekenZeigen(sichten)
            }
        }
    }

    /// **Die Rubrik zeigt die *uebrigen* Bibliotheken.**
    ///
    /// Oben stehen Filme und Serien; die beiden Sammlungen, die genau diese
    /// Bereiche zeigen, gehoeren nicht noch einmal hierher. Bleibt nichts
    /// uebrig, faellt die Rubrik ganz weg — dann *sind* Filme und Serien die
    /// Bibliotheken, und sie stehen schon oben.
    ///
    /// Hier stand bisher jede Sammlung, auch die beiden. Auf einem Server mit
    /// genau einer Filmbibliothek und einer Serienbibliothek — dem Normalfall —
    /// stand damit alles doppelt da. Die Regel steht seit jeher in
    /// `HauptView.sammlungen` auf dem Mac.
    private var uebrigeSammlungen: [Item] {
        let schonOben = Set([
            gewaehlteBibliothek[.filme] ?? bibliotheken(fuer: .filme).first?.id,
            gewaehlteBibliothek[.serien] ?? bibliotheken(fuer: .serien).first?.id,
        ].compactMap { $0 })
        return sichten
            .filter { $0.collectionType == "movies" || $0.collectionType == "tvshows" }
            .filter { !schonOben.contains($0.id) }
    }

    private func bibliothekenZeigen(_ sichten: [Item]) {
        self.sichten = sichten
        leeren(bibliotheksliste)
        bibliotheksknoepfe = [:]
        let uebrige = uebrigeSammlungen
        gtk_widget_set_visible(bibliotheksrubrik, uebrige.isEmpty ? 0 : 1)
        for sicht in uebrige {
            // Der Sammlungstyp bestimmt das Zeichen, wie auf dem Mac.
            let symbol: String
            switch sicht.collectionType {
            case "movies":  symbol = "video-x-generic-symbolic"
            case "tvshows": symbol = "tv-symbolic"
            case "music":   symbol = "folder-music-symbolic"
            default:        symbol = "folder-symbolic"
            }
            let zeile = seitenleistenzeile(symbol: symbol, text: sicht.name,
                                           aktiv: offeneBibliothek?.id == sicht.id)
            // **Eine eigene Seite, kein Umschalter** — woertlich die
            // Entscheidung des Macs. Vorher fuehrte das hier in den
            // Filme-Bereich und waehlte sich dort aus; ueber „Filmabend"
            // stand dann die Ueberschrift „Filme". Und eine Sammlung, die
            // weder `movies` noch `tvshows` ist, tat gar nichts, weil es
            // fuer sie keinen Bereich gab.
            beiSignal(zeile, "clicked") { [weak self] in
                self?.bibliothekOeffnen(sicht)
            }
            bibliotheksknoepfe[sicht.id] = zeile
            anhaengen(bibliotheksliste, zeile)
        }
    }

    /// **Eine Bibliothek als eigene Seite oeffnen.**
    ///
    /// Sie bekommt ihren eigenen Titel, ihren eigenen Filter und ihre eigene
    /// Sortierung — nichts davon greift in den Filme- oder Serienbereich
    /// hinein. Genau das war der Fehler: die Sammlung schaltete den Bereich
    /// um, und ueber „Filmabend" stand „Filme".
    func bibliothekOeffnen(_ sicht: Item) {
        offeneBibliothek = sicht
        bibliothekszeilenMalen()
        if bibliothekstitel != nil {
            gtk_label_set_text(OpaquePointer(bibliothekstitel), sicht.name)
        }
        // **Neu laden, nicht das Alte zeigen.** `geladen` merkt sich je
        // Bereich, dass schon einmal geholt wurde; ohne diese Zeile stuenden
        // unter der zweiten Sammlung die Titel der ersten. Genau die
        // Beschwerde: „die falschen werden angezeigt".
        geladen.remove(.bibliothek)
        seitenstapel[.bibliothek] = []
        // **Nicht zuruecksetzen.** Hier standen zwei Zeilen, die Filter und
        // Sortierung bei jedem Oeffnen auf die Vorgabe zwangen — damit war
        // der gemerkte Stand nie zu sehen. Seit der Schluessel die Kennung
        // der Sammlung traegt, ist auch nichts mehr zu bereinigen: jede
        // Sammlung hat ihren eigenen. Der Mac laesst ihn ebenso stehen und
        // begruendet das mit einem Nutzerzitat („ich sortiere nach zuletzt …
        // komme wieder, bin ich zurueck beim Standard").
        chipsFuellen(.bibliothek)
        zeige(.bibliothek)
    }

    /// **Ein Genre als eigene Seite** — dasselbe Raster wie Bibliothek,
    /// Merkliste und Suche, mit dem Genrenamen als Titel.
    ///
    /// Sortiert nach „zuletzt hinzugefügt": wer ein Genre antippt, sucht
    /// meist, was neu ist. Die Regel steht als `titel(gattung:)` im Paket.
    func gattungOeffnen(_ name: String) {
        offeneGattung = name
        if gattungstitel != nil {
            gtk_label_set_text(OpaquePointer(gattungstitel), name)
        }
        geladen.remove(.gattung)
        seitenstapel[.gattung] = []
        zeige(.gattung)
    }

    /// **Welche Leistenzeile hervorgehoben ist.**
    ///
    /// Nicht nur „welcher Bereich" — auch, ob ueberhaupt einer dran ist. Steht
    /// eine Unterseite offen (Profil, Einstellungen, Wiedergabe) oder eine
    /// Bibliothek, gehoert die Hervorhebung keiner Bereichszeile: sonst
    /// leuchtet „Start", waehrend rechts das Profil steht. Auf dem Mac steht
    /// dieselbe Bedingung an der Zeile selbst
    /// (`bereich == fall && !bibliothekOffen && !imKonto`).
    /// Traegt den Servernamen in alle Seitenkoepfe nach (E15) — er kommt
    /// erst mit `publicSystemInfo`, die Seiten stehen da schon.
    func serverzeilenMalen() {
        for (_, zeile) in serverzeilen {
            gtk_label_set_text(OpaquePointer(zeile), servername)
            gtk_widget_set_visible(zeile, servername.isEmpty ? 0 : 1)
        }
    }

    func bereichszeilenMalen() {
        let keiner = offeneUnterseite != nil || offeneBibliothek != nil
        for (fall, knopf) in bereichsknoepfe {
            if !keiner, fall == bereich { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(knopf, "swiftly-aktiv") }
        }
        if let profilzeile {
            if offeneUnterseite != nil { gtk_widget_add_css_class(profilzeile, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(profilzeile, "swiftly-aktiv") }
        }
    }

    private func bibliothekszeilenMalen() {
        for (kennung, knopf) in bibliotheksknoepfe {
            if kennung == offeneBibliothek?.id {
                gtk_widget_add_css_class(knopf, "swiftly-aktiv")
            } else {
                gtk_widget_remove_css_class(knopf, "swiftly-aktiv")
            }
        }
    }

    func startseiteLaden() {
        guard let client else { return }
        zuletztGeladen = Date()
        // **H8: was der Server noch nicht weiss, geht jetzt raus.** Nicht in
        // einem eigenen Takt — hier ist der Server nachweislich da, weil
        // gleich darunter Reihen von ihm geholt werden. Dieselbe Stelle wie
        // auf dem Mac, nur dass die dort an der Verbindungspruefung haengt.
        let konto = benutzerID
        Task.detached { await Nachmeldezettel.abschicken(client, konto: konto) }
        // **Wessen Antwort ist das gleich?** Der Wechsel laesst den alten
        // Client fallen, aber eine Abfrage, die schon unterwegs ist, kommt
        // trotzdem zurueck — und wuerde die Reihen des neuen Kontos mit denen
        // des alten ueberschreiben. Der Zaehler ist die Eintrittskarte: passt
        // er beim Auflegen nicht mehr, gehoert die Antwort zu niemandem.
        let stand = kontowechsel
        // **„Lade …" nur beim ersten Mal.** Beim Nachladen (D8, und beim
        // Schliessen des Players) steht schon alles da; es wegzuwerfen und
        // durch ein Wort zu ersetzen, sah aus, als sei die App neu gestartet
        // — dabei ändert sich meist nur ein Fortschrittsbalken. Ersetzt wird
        // erst, wenn die neuen Reihen da sind.
        if gtk_widget_get_first_child(reihenstapel) == nil {
            // **Kein Ladering, kein „Lade …"** (E17): die Reihen stehen in
            // ihrer Form da und lösen sich auf, wenn die Daten kommen.
            anhaengen(reihenstapel, reihenPlatzhalter(rand: Stil.randAbstand))
        }

        // Die Wahl vor dem Faden ablesen — `wahlen` gehört dem Hauptfaden.
        let getrennt = wahlen.neuzugaengeGetrennt
        let reihenfolge = wahlen.startReihen
        let ausgeblendet = wahlen.startAus
        let gattungen = wahlen.startGenres
        let alsChips = wahlen.genreChips
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
            // **Getrennt heisst getrennt gefragt, nicht nachtraeglich
            // gesiebt.** Bis zum 13.09.2026 holte Linux die gemischte Reihe
            // und filterte sie danach nach `type`. Damit zeigte "Zuletzt
            // hinzugefuegte Filme" nur, was zufaellig in den obersten zwanzig
            // der Mischung lag — bei einem Server, auf dem gerade eine Serie
            // nach der anderen ankommt, war die Filmreihe leer, obwohl Filme
            // dazugekommen waren. Der Mac fragt je Bibliothek einzeln
            // (`Startseitenmodell.swift:73-79`); hier jetzt auch.
            let filmBib = gewaehlteBibliothek[.filme] ?? bibliotheken(fuer: .filme).first?.id
            let serienBib = gewaehlteBibliothek[.serien] ?? bibliotheken(fuer: .serien).first?.id
            async let neu = getrennt ? nil : await client.zuletztHinzugefuegt()
            async let neuFilme = getrennt
                ? await client.zuletztHinzugefuegt(in: filmBib) : nil
            async let neuSerien = getrennt
                ? await client.zuletztHinzugefuegt(in: serienBib) : nil

            // **Jede Reihe hat ihre eigene Kachelform, und das ist keine
            // Geschmacksfrage.** A2 im Register: „Nächste Folge öffnet die
            // Übersicht, sie startet nicht. Nur ‚Weiterschauen' springt
            // direkt in die Wiedergabe." Waagerecht ist deshalb allein
            // „Weiterschauen" — auf iPhone, Fernseher und Mac genauso.
            let neuzugaenge = await neu ?? []
            let filme = await neuFilme ?? []
            let serien = await neuSerien ?? []
            // **Neue Filme und neue Serien getrennt, wenn gewünscht.** Eine
            // gemischte Reihe ist die Vorgabe; wer viel neu bekommt, will sie
            // auseinander. Die Zeile fehlte auf Linux ganz.
            // **Die feste Reihenfolge kam aus dem Code, jetzt aus den
            // Einstellungen.** Welche Reihen, in welcher Folge, und welche
            // ausgeblendet sind — `Startreihenfolge` im Paket rechnet es aus,
            // damit dieselbe Ablage auf jeder Plattform dasselbe ergibt.
            // **Jede Reihe geht entdoppelt hinein** (`Listenregeln`). Der
            // Server liefert denselben Titel gelegentlich zweimal; auf Apple
            // beschwert sich `ForEach` ueber die doppelte Kennung, auf GTK
            // stuende die Kachel schlicht zweimal in der Reihe.
            let inhalt: [Startreihe: (Reihenart, [Item])] = [
                .weiterschauen: (.weiterschauen, Listenregeln.ohneDoppelte(await weiter ?? [])),
                .naechsteFolge: (.naechste, Listenregeln.ohneDoppelte(await naechste ?? [])),
                .neuzugaenge:   (.neu, Listenregeln.ohneDoppelte(neuzugaenge)),
                .neueFilme:     (.neu, Listenregeln.ohneDoppelte(filme)),
                .neueSerien:    (.neu, Listenregeln.ohneDoppelte(serien)),
            ]
            var gesammelt: [(String, Reihenart, [Item])] = Startreihenfolge
                .sichtbar(abgelegt: reihenfolge, aus: Set(ausgeblendet), getrennt: getrennt)
                .compactMap { r in
                    guard let (art, items) = inhalt[r], !items.isEmpty else { return nil }
                    return (uebersetzt(r.reihentitel), art, items)
                }

            // **Die Genres als eigene Reihen, nach den festen** — nur wenn
            // sie nicht als Chips oben stehen. Ihre Namen kommen vom Server
            // und laufen deshalb **nie** durch die Übersetzung (E7).
            if !alsChips {
                for name in gattungen {
                    guard let treffer = await client.titel(gattung: name), !treffer.isEmpty
                    else { continue }
                    gesammelt.append((name, .neu, Listenregeln.ohneDoppelte(treffer)))
                }
            }
            // Ab hier unveraenderlich — sonst faengt der Sprung auf den
            // Hauptfaden eine `var` ein, und Swift 6 laesst das nicht zu.
            let reihen = gesammelt

            aufHauptfaden {
                guard self.kontowechsel == stand else { return }
                self.gattungschipsZeigen(alsChips ? gattungen : [])
                self.reihenZeigen(reihen)
            }
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
        let schon = (rasterItems[was] ?? []).count
        guard schon > 0,
              Listenregeln.nochMehrDa(geladen: schon, gesamt: rasterGesamt[was] ?? 0)
        else { return }
        rasterLaden(was, ab: schon)
    }

    private func rasterLaden(_ was: Bereich, ab: Int = 0) {
        guard let client else { return }
        rasterLaedt.insert(was)
        if ab == 0 {
            rasterItems[was] = []
            rasterLaderZeigen(was, true)
        }
        // **Die Merkliste ist keine Bibliothek, sondern ein Filter.** Sie
        // fragt beide Gattungen ab und laesst den Server auf `IsFavorite`
        // sieben — woertlich `AppModel.gemerkte(art:sortierung:ab:)` vom Mac.
        let gattungen: [String]
        switch was {
        case .filme:  gattungen = ["Movie"]
        case .serien: gattungen = ["Series"]
        // Was die Pille sagt (E25) — vorher stand hier fest Film und Serie,
        // und die Trennung war serverseitig gar nicht moeglich.
        case .merkliste: gattungen = merkgattung.typen
        // **Die Sammlung sagt selbst, was in ihr liegt** — und die Zuordnung
        // steht als `Bibliotheksgattung` im Paket, nicht hier.
        //
        // Hier stand eine eigene Fassung, die nur `movies` und `tvshows`
        // kannte und sonst auf `["Movie", "Series"]` fiel. Auf einer Musik-,
        // Buch- oder Heimvideobibliothek hiess das: der Server bekommt eine
        // Einschraenkung auf Gattungen, die dort gar nicht liegen, und die
        // Seite bleibt **leer**. Die Paketfassung antwortet in dem Fall mit
        // einer leeren Liste — nicht einschraenken statt falsch einschraenken,
        // lieber ein Ordner zu viel als eine leere Seite.
        case .bibliothek:
            gattungen = Bibliotheksgattung.typen(zu: offeneBibliothek?.collectionType)
        default:      gattungen = ["Movie", "Series"]
        }
        let f = filterVon(was)
        let sort = sortierungVon(was)
        // Die Merkliste hat keine Bibliothek — sie geht ueber alles.
        let eltern: String?
        switch was {
        case .merkliste, .gattung: eltern = nil
        case .bibliothek: eltern = offeneBibliothek?.id
        // **Und die gemerkte Sammlung muss es noch geben.** `?? .first`
        // greift nur, wenn gar keine gemerkt ist — nicht, wenn die gemerkte
        // vom Server verschwunden ist. Dann fragte die Seite eine Kennung ab,
        // die es nicht mehr gibt, und blieb leer. Der Mac prueft an
        // derselben Stelle (`AppModel.gewaehlteBibliothek(art:)`, `:142-149`).
        default:
            let da = bibliotheken(fuer: was)
            eltern = da.first { $0.id == gewaehlteBibliothek[was] }?.id ?? da.first?.id
        }
        let stand = kontowechsel
        // **Ein Genre geht ueber alle Bibliotheken**, wie die Merkliste — es
        // ist kein Ort, sondern eine Eigenschaft. Und es sortiert nach
        // „zuletzt hinzugefuegt", nicht nach dem gewaehlten Feld: wer ein
        // Genre antippt, sucht meist, was neu ist.
        let genre = was == .gattung ? offeneGattung : nil
        let rekursiv = was == .bibliothek
            ? Bibliotheksgattung.rekursiv(zu: offeneBibliothek?.collectionType)
            : true
        Task.detached { [self] in
            let antwort = try? await client.items(parentID: eltern,
                                                  // 200 auf einen Schlag fuer
                                                  // ein Genre, sonst 100 je
                                                  // Seite — `GenreView.swift:70`.
                                                  limit: genre != nil ? 200 : 100,
                                                  startIndex: ab,
                                                  sortBy: genre != nil ? "DateCreated" : sort.feld,
                                                  sortOrder: genre != nil ? "Descending"
                                                                          : sort.richtung,
                                                  filters: was == .merkliste
                                                      ? ["IsFavorite"] : f.jellyfinFilter,
                                                  istGesehen: was == .merkliste
                                                      ? nil : f.istGesehen,
                                                  // **Nicht fest `true`.**
                                                  // `Bibliotheksgattung.rekursiv`
                                                  // sagt `false`, sobald eine
                                                  // Sammlung keine bekannten
                                                  // Gattungen hat — dann ist
                                                  // rekursiv zu suchen falsch,
                                                  // weil gar nichts
                                                  // einzuschraenken ist. So
                                                  // steht es auf dem Mac
                                                  // (`AppModel.swift:1022`).
                                                  recursive: rekursiv,
                                                  includeItemTypes: gattungen,
                                                  gattungen: genre.map { [$0] } ?? [])
            let items = antwort?.items ?? []
            let gesamt = antwort?.totalRecordCount ?? items.count
            aufHauptfaden {
                // Auch hier: eine Antwort des vorigen Kontos wird
                // weggeworfen, statt an seine Titel angehaengt zu werden.
                guard self.kontowechsel == stand else { return }
                self.rasterLaedt.remove(was)
                self.rasterLaderZeigen(was, false)
                guard let raster = self.rasterFeld[was], let zahl = self.zahlFeld[was]
                else { return }
                // **Entdoppelt anhaengen** (`Listenregeln.anhaengen`). Der
                // Server kann zwischen zwei Seiten etwas hinzufuegen; dann
                // rutscht ein Titel eine Stelle nach hinten und kaeme in der
                // naechsten Seite ein zweites Mal. Auf Apple beschwert sich
                // `ForEach` darueber, auf GTK stuende die Kachel einfach
                // zweimal im Raster. Hier stand ein blankes `+=`.
                self.rasterItems[was] = Listenregeln.anhaengen(
                    items, an: self.rasterItems[was] ?? [])
                self.rasterGesamt[was] = gesamt
                self.rasterFuellen(raster, self.rasterItems[was] ?? [])
                gtk_label_set_text(OpaquePointer(zahl), String(gesamt))
                gtk_widget_set_visible(zahl, gesamt > 0 ? 1 : 0)
                // Der Ersatzinhalt erscheint erst, wenn die Antwort da ist —
                // vorher steht der Platzhalter.
                if let leer = self.leerFeld[was] {
                    gtk_widget_set_visible(leer, gesamt == 0 ? 1 : 0)
                }
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
        guard Anzeigeregeln.suchbegriffTaugt(begriff) else {
            rasterFuellen(suchraster, [])
            gtk_widget_set_visible(suchleer, 0)
            seerrRueckfrageWeg()
            seerrTrefferZeigen([])
            // Feld leer heisst: „Zuletzt gesucht" kommt zurueck.
            suchverlaufZeigen()
            return
        }
        Task.detached { [self] in
            // 300 ms — `Sources/macOS/SucheView.swift:188`. Hier standen 280,
            // und der Kommentar darueber nannte sie sogar als Mac-Wert.
            try? await Task.sleep(nanoseconds: 300_000_000)
            aufHauptfaden {
                guard self.suchtakt == meins else { return }
                self.suchen(meins)
            }
        }
    }

    /// **Der eigene Server zuerst, Seerr danach — in zwei Schritten.**
    ///
    /// Beides in einem Zug abzuwarten hiesse, die eigene Bibliothek so lange
    /// leer zu lassen, wie ein fremder Dienst braucht. Seerr steht auf einem
    /// anderen Rechner und kann Sekunden brauchen oder gar nicht antworten;
    /// die eigenen Treffer sind in Millisekunden da und werden sofort
    /// gezeigt. Die Zeile darunter kommt nach, wenn sie kommt.
    ///
    /// **Der Takt wird auch nach dem Warten geprueft**, nicht nur davor. Beim
    /// eigenen Server war das lange folgenlos, weil er schneller antwortet,
    /// als jemand tippt. Seerr ist es nicht: ohne die Pruefung malt die
    /// Antwort auf „Herr" die Treffer unter „Herr der Ringe".
    /// Baut „Zuletzt gesucht" neu und blendet den Block aus, wenn er leer ist
    /// oder gerade gesucht wird.
    func suchverlaufZeigen() {
        guard suchverlaufliste != nil else { return }
        let worte = Suchverlauf.liste(wahlen.suchverlauf)
        let feldLeer = text(suchfeld).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        gtk_widget_set_visible(suchverlaufblock, (feldLeer && !worte.isEmpty) ? 1 : 0)
        if suchhinweis != nil {
            gtk_widget_set_visible(suchhinweis, (feldLeer && worte.isEmpty) ? 1 : 0)
        }
        leeren(suchverlaufliste)
        for (stelle, wort) in worte.enumerated() {
            if stelle > 0 {
                let strich: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
                gtk_widget_add_css_class(strich, "swiftly-trennlinie")
                gtk_widget_set_size_request(strich, -1, 1)
                gtk_widget_set_margin_start(strich, 48)
                anhaengen(suchverlaufliste, strich)
            }
            let zeile = wertezeile(symbol: "document-open-recent-symbolic", titel: wort) {
                [weak self] in
                guard let self else { return }
                gtk_editable_set_text(OpaquePointer(self.suchfeld), wort)
                self.suchtakt += 1
                self.suchen(self.suchtakt)
            }
            anhaengen(suchverlaufliste, zeile)
        }
    }

    /// - Parameter merken: Ob der Begriff in „Zuletzt gesucht" landet.
    ///
    ///   **Nur beim Abschicken, nicht beim Tippen.** Der Aufruf stand
    ///   unbedingt hier drin, und diese Funktion haengt auch am Taktgeber
    ///   nach jeder Tippause: wer „Ga", „Gam", „Game" eingibt, hatte danach
    ///   drei Eintraege im Verlauf. Auf dem Mac haengt `merken` allein am
    ///   `abschluss` des Feldes (`SucheView.swift:101`) — genau derselbe
    ///   Fehler ist dort schon einmal behoben worden.
    private func suchen(_ meins: Int, merken: Bool = false) {
        guard let client else { return }
        let begriff = text(suchfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        // **Die Schwelle kommt aus dem Paket** (A7): `Anzeigeregeln`
        // verlangt zwei Zeichen, getrimmt. Hier stand `!begriff.isEmpty` —
        // ein einzelner Buchstabe loeste damit eine Serveranfrage aus, auf
        // dem Mac nicht. Der Taktgeber prueft es zwar auch, aber Enter und
        // ein Klick auf einen Verlaufseintrag laufen an ihm vorbei.
        guard Anzeigeregeln.suchbegriffTaugt(begriff) else {
            rasterFuellen(suchraster, [])
            suchverlaufZeigen()
            return
        }
        if merken {
            wahlen.suchverlauf = Suchverlauf.merken(begriff, in: wahlen.suchverlauf)
            wahlen.sichern()
        }
        suchverlaufZeigen()
        let seerr = seerrclient
        Task.detached { [self] in
            let treffer = Listenregeln.ohneDoppelte((try? await client.suche(begriff)) ?? [])
            aufHauptfaden {
                guard self.suchtakt == meins else { return }
                self.rasterFuellen(self.suchraster, treffer, auskunft: true)
                // **Beide leer, nicht nur die Bibliothek.** Stuende hier nur
                // `treffer.isEmpty`, gewaenne dieser Zweig, sobald der eigene
                // Server nichts hat — und „Nichts gefunden" stuende ueber den
                // Seerr-Treffern, also genau ueber dem Fall, fuer den die
                // ganze Anbindung gebaut ist. Der Seerr-Teil antwortet
                // spaeter und blendet dann nach.
                self.eigeneTrefferLeer = treffer.isEmpty
                gtk_widget_set_visible(self.suchleer,
                                       treffer.isEmpty && self.seerrTrefferLeer ? 1 : 0)
                self.seerrRueckfrageWeg()
                self.seerrTrefferZeigen([])
            }
            guard let seerr else { return }
            let fremde = await seerr.suchen(begriff)
            aufHauptfaden {
                guard self.suchtakt == meins else { return }
                self.seerrTrefferZeigen(fremde)
                // Gefunden ist gefunden, auch wenn es woanders liegt.
                if !fremde.isEmpty { gtk_widget_set_visible(self.suchleer, 0) }
            }
        }
    }

    /// **Genres als Chips, ganz oben** — ein Einstieg, kein Inhalt: ein Klick
    /// öffnet das Genre.
    ///
    /// **Eckig, nicht rund.** Ecke wie ein Knopf; rund ist, was ein Bild ist
    /// (E26). Die Namen kommen vom Server und laufen deshalb nie durch die
    /// Übersetzung (E7).
    private func gattungschipsZeigen(_ namen: [String]) {
        gattungschips = namen
    }

    private func gattungschipzeile() -> Widget! {
        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
        gtk_widget_set_margin_start(reihe, Int32(Stil.randAbstand))
        gtk_widget_set_margin_end(reihe, Int32(Stil.randAbstand))
        for name in gattungschips {
            let chip: Widget! = gtk_button_new_with_label(name)
            gtk_widget_add_css_class(chip, "swiftly-gattungschip")
            beiSignal(chip, "clicked") { [weak self] in self?.gattungOeffnen(name) }
            anhaengen(reihe, chip)
        }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)
        // 34 hoch und 120 je Stueck — `Blätterreihe(breiteJeStueck: 120,
        // bildHoehe: 34)` auf dem Mac (`HomeView.swift:248-264`).
        return blaetterflaeche(scroller, bildHoehe: 34, stueck: 120)
    }

    private func reihenZeigen(_ reihen: [(String, Reihenart, [Item])]) {
        letzteStartreihe = reihen.first?.2 ?? []
        leeren(reihenstapel)
        if !gattungschips.isEmpty { anhaengen(reihenstapel, gattungschipzeile()) }
        guard !reihen.isEmpty else {
            // Symbol, Satz, Erklärzeile — dieselbe Form wie auf dem Mac
            // (`Leerzustand`), statt einer einzelnen Textzeile.
            anhaengen(reihenstapel,
                      leerzustand("mail-inbox-symbolic", uebersetzt("Hier ist noch nichts"),
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
        return reiheBauen(titel: titel,
                          bildHoehe: quer ? Stil.querHoehe : Stil.kachelHoehe,
                          stueck: (quer ? Stil.querBreite : Stil.kachelBreite)
                                  + Stil.kachelAbstand,
                          rand: rand,
                          kacheln: items.map { kachelBauen($0, art: art) })
    }

    /// **Dieselbe Reihe, nur nicht aus `Item`.**
    ///
    /// Ueberschrift, waagerechtes Blaettern, die beiden Pfeile beim
    /// Schweben, das sanfte Springen um drei Kacheln — das haengt an nichts,
    /// was ein Serverobjekt waere. Herausgezogen, als die Seerr-Seite
    /// Besetzung und Aehnliches zeigen sollte: eine zweite Fassung davon
    /// waere die kopierte Funktion, gegen die die Regel steht, und sie waere
    /// prompt auseinandergelaufen.
    func reiheBauen(titel: String, bildHoehe: Int, stueck: Int,
                    rand: Int = Stil.randAbstand, kacheln: [Widget?]) -> Widget! {
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
        for k in kacheln { anhaengen(reihe, k) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)

        let ueber = blaetterflaeche(scroller, bildHoehe: bildHoehe, stueck: stueck)

        anhaengen(block, ueber)
        return block
    }

    /// **Die Blätterpfeile über einer waagerechten Fläche.**
    ///
    /// Sie standen fest in ``reiheBauen(titel:bildHoehe:stueck:rand:kacheln:)``
    /// und damit **nur** dort — die Genrechips oben auf der Startseite waren
    /// ein nackter Scroller ohne Pfeile, als einzige waagerechte Reihe der
    /// App. Auf dem Mac baut `Blätterreihe` beide (`HomeView.swift:248`).
    private func blaetterflaeche(_ scroller: Widget!, bildHoehe: Int,
                                 stueck: Int) -> Widget! {
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
        return ueber
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
            bildLaden(bild, url: adresse, schluessel: Bildschluessel.fuer(adresse))
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
        // **Die Plakette gehört auf jede hochkante Kachel** (E16) — Haken,
        // offene Folgen oder Staffelzahl. Auf der Querkachel nicht: dort steht
        // der Balken, und beides zusammen wäre zweimal dieselbe Auskunft.
        if !quer { kachelmarkeLegen(kaefig, item: item) }
        // **Nur „Weiterschauen" springt direkt in die Wiedergabe** (A1).
        // „Nächste Folge" und „Zuletzt hinzugefügt" öffnen die Übersicht
        // (A2, A3) — was man nicht angefangen hat, will man erst ansehen.
        return kachelhuelle(bild: kaefig, breite: breite, oben: oben, unten: unten,
                            uebersicht: quer ? { [weak self] in self?.oeffne(item) } : nil,
                            vorholen: { [weak self] in self?.serieVorholen(item) }) {
            [weak self] in
            guard let self else { return }
            if quer { self.starte(item) } else { self.oeffne(item) }
        }
    }

    /// **Die Serie zu einer Folge schon holen, bevor jemand klickt.**
    ///
    /// Auf dem Schreibtisch liegt der Zeiger immer erst auf der Kachel; der
    /// Mac nutzt das (`Serienspeicher.vorholen`, Begruendung in
    /// `Sources/Shared/Serienspeicher.swift:100-124`). Auf Linux fehlte es,
    /// und ein Klick auf eine Weiterschauen-Kachel stand bis zu zwei
    /// nacheinander laufende Abrufe lang still.
    ///
    /// **Hoechstens einer je Serie, und nur einmal.** `serienspeicher` haelt,
    /// was schon da ist; `serienlauf` verhindert, dass ein zweites Ueberfahren
    /// denselben Abruf noch einmal startet.
    private func serieVorholen(_ item: Item) {
        guard item.type == "Episode", let serie = item.seriesId, let client else { return }
        guard vollspeicher[serie] == nil, !vorholend.contains(serie) else { return }
        vorholend.insert(serie)
        Task.detached { [self] in
            let geholt = try? await client.item(id: serie)
            aufHauptfaden {
                self.vorholend.remove(serie)
                if let geholt { self.vollspeicher[serie] = geholt }
            }
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
    private func rasterkachel(_ item: Item, auskunft: Bool = false) -> Widget! {
        let (kaefig, bild) = gerahmtesBild(breite: Stil.kachelBreite,
                                           hoehe: Stil.kachelHoehe,
                                           stil: "swiftly-plakat")
        if let adresse = adressen.flatMap({ Bildwahl.hochkant(item, adressen: $0,
                                                              maxHoehe: Stil.kachelHoehe * 2) }) {
            bildLaden(bild, url: adresse, schluessel: Bildschluessel.fuer(adresse))
        } else {
            zeichenLegen(kaefig, serie: item.seriesId != nil || item.type == "Series")
        }
        // **Die Plakette fehlte hier ganz** (E16): im Suchraster und in jedem
        // Bibliotheksraster stand keine Auskunft, ob ein Titel gesehen ist
        // oder wie viele Folgen offen sind.
        kachelmarkeLegen(kaefig, item: item)
        // Jeder Suchtreffer und jede Kachel im Raster führt auf die Seite,
        // keiner startet (A7b).
        let kachel = kachelhuelle(bild: kaefig, breite: Stil.kachelBreite,
                                  oben: item.name,
                                  unten: auskunft ? item.trefferauskunft
                                                  : item.productionYear.map(String.init)) {
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
    /// Mac Eine Kachel: Bild, Titel, Zweitzeile — und der Rechtsklickweg zur
    /// Übersicht (A6).
    ///
    /// **Wozu er da ist:** „Weiterschauen" springt sofort in die Wiedergabe
    /// (A1). Wer *erst nachsehen* will, worum es geht, hat sonst keinen Weg
    /// zur Seite. Auf dem Mac steht dafür `.contextMenu` (`Macbausteine`), auf
    /// dem Telefon das lange Drücken; hier die rechte Taste.
    ///
    /// `uebersicht` ist `nil`, wo die Kachel ohnehin schon dorthin führt — ein
    /// Menü mit dem einen Eintrag, den der Klick auch tut, ist keiner.
    /// - Parameter vorholen: Was geschieht, sobald der Zeiger die Kachel
    ///   erreicht — siehe unten.
    func kachelhuelle(bild: Widget!, breite: Int, oben: String, unten: String?,
                      uebersicht: (() -> Void)? = nil,
                      vorholen: (() -> Void)? = nil,
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
        if let vorholen {
            // **Vorholen beim Ueberfahren.** Auf dem Schreibtisch liegt der
            // Zeiger immer erst auf der Kachel, bevor geklickt wird — der Mac
            // nutzt das (`Macbausteine.swift:237-241`, Begruendung in
            // `Serienspeicher.swift:100-124`) und holt die Serie zur Folge
            // schon vor. Hier fehlte es ganz: ein Klick auf eine
            // Weiterschauen-Kachel blieb bis zu zwei nacheinander laufende
            // Abrufe lang ohne jede Reaktion.
            beiZeiger(knopf, herein: vorholen, hinaus: {})
        }

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
    /// **Die Fassung, mit der sich diese App beim Server meldet.**
    ///
    /// Auf den Apple-Fassungen liest `JellyfinKit.Fassungsnummer` sie aus dem
    /// Buendel. Hier gibt es keins — Foundation liefert dann „unbekannt", und
    /// das stuende in Jellyfins Geraeteliste und in jedem Fehlerbericht, den
    /// jemand von dort abschreibt.
    ///
    /// **Nicht neu getippt, sondern aus ``Fassung``.** Ich hatte die Zahl
    /// hier ein zweites Mal hingeschrieben und es beim Bauen gemerkt — es
    /// gibt sie laengst, mit demselben Kommentar darueber, dass sie an genau
    /// zwei Orten stehen darf. Ein dritter waere der Anfang des
    /// Auseinanderlaufens gewesen, und zwar an der Stelle, die das gerade
    /// verhindern sollte.
    static var fassung: String { "\(Fassung.nummer) (\(Fassung.bau))" }

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
