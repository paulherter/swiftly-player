import CGtk
import Foundation
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
    private var fenster: Widget!
    private var seiten: Widget!          // GtkStack
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
    private var anmeldeknopf: Widget!
    private var anmeldestand: Widget!
    private var meldetGerade = false

    // Startseite
    private var reihenstapel: Widget!
    private var kopfzeile: Widget!

    private var client: JellyfinClient?
    private var adressen: Bildadresse?

    // MARK: - Aufbau

    func aufbauen(anwendung: UnsafeMutablePointer<GtkApplication>!) {
        fenster = gtk_application_window_new(anwendung)
        gtk_window_set_title(alsFenster(fenster), "Swiftly")
        gtk_window_set_default_size(alsFenster(fenster), 1100, 760)

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
        gtk_window_set_child(alsFenster(fenster), inhalt)

        gtk_window_present(alsFenster(fenster))

        // Gemerkte Sitzung: gleich weiter zur Startseite, ohne Nachfragen.
        if let abgelegt = Speicher.lesen() {
            sitzungUebernehmen(serverURL: abgelegt.serverURL,
                               token: abgelegt.token,
                               benutzerID: abgelegt.benutzerID,
                               benutzername: abgelegt.benutzername,
                               servername: abgelegt.servername)
        }
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
    private func serverSchrittBauen() -> Widget! {
        let mitte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 12)
        raender(mitte, 40)
        gtk_widget_set_valign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(mitte, 380, -1)

        anhaengen(mitte, Stil.wortmarke(hoehe: 46))
        anhaengen(mitte, beschriftung("Wo steht dein Jellyfin?", stil: "dim-label"))

        serverfeld = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(serverfeld), "tv.beispiel.de")
        gtk_widget_set_margin_top(serverfeld, 10)
        anhaengen(mitte, serverfeld)

        let hinweis = beschriftung("Kein https:// nötig — das ergänzen wir.", stil: "caption")
        gtk_widget_add_css_class(hinweis, "dim-label")
        anhaengen(mitte, hinweis)

        verbindeknopf = gtk_button_new_with_label("Verbinden")
        gtk_widget_add_css_class(verbindeknopf, "swiftly-haupt")
        gtk_widget_set_margin_top(verbindeknopf, 8)
        anhaengen(mitte, verbindeknopf)

        serverstand = beschriftung("", stil: "dim-label", umbruch: true)
        anhaengen(mitte, serverstand)

        beiSignal(verbindeknopf, "clicked") { [weak self] in self?.verbinden() }
        beiSignal(serverfeld, "activate") { [weak self] in self?.verbinden() }
        return mitte
    }

    /// Schritt zwei: welches Konto?
    private func kontoSchrittBauen() -> Widget! {
        let mitte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 12)
        raender(mitte, 40)
        gtk_widget_set_valign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(mitte, 380, -1)

        serverzeile = beschriftung("", stil: "title-2", umbruch: true)
        anhaengen(mitte, serverzeile)
        fassungszeile = beschriftung("", stil: "dim-label")
        anhaengen(mitte, fassungszeile)

        benutzerfeld = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(benutzerfeld), "Benutzername")
        gtk_widget_set_margin_top(benutzerfeld, 14)
        anhaengen(mitte, benutzerfeld)

        passwortfeld = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(passwortfeld), "Passwort")
        gtk_entry_set_visibility(alsFeld(passwortfeld), 0)
        anhaengen(mitte, passwortfeld)

        anmeldeknopf = gtk_button_new_with_label("Anmelden")
        gtk_widget_add_css_class(anmeldeknopf, "swiftly-haupt")
        gtk_widget_set_margin_top(anmeldeknopf, 8)
        anhaengen(mitte, anmeldeknopf)

        anmeldestand = beschriftung("", stil: "dim-label", umbruch: true)
        anhaengen(mitte, anmeldestand)

        let zurueck = gtk_button_new_with_label("Anderer Server")
        gtk_widget_add_css_class(zurueck, "flat")
        gtk_widget_set_margin_top(zurueck, 6)
        anhaengen(mitte, zurueck)

        beiSignal(anmeldeknopf, "clicked") { [weak self] in self?.anmelden() }
        beiSignal(passwortfeld, "activate") { [weak self] in self?.anmelden() }
        beiSignal(benutzerfeld, "activate") { [weak self] in self?.anmelden() }
        beiSignal(zurueck, "clicked") { [weak self] in
            guard let self else { return }
            gtk_stack_set_visible_child_name(OpaquePointer(self.anmeldeschritte), "server")
        }
        return mitte
    }

    private func text(_ feld: Widget!) -> String {
        gtk_editable_get_text(OpaquePointer(feld)).map { String(cString: $0) } ?? ""
    }

    private func serverstandZeigen(_ s: String) {
        gtk_label_set_text(OpaquePointer(serverstand), s)
    }

    private func anmeldestandZeigen(_ s: String) {
        gtk_label_set_text(OpaquePointer(anmeldestand), s)
    }

    // MARK: Schritt eins — verbinden

    private func verbinden() {
        guard !meldetGerade else { return }
        let eingabe = text(serverfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eingabe.isEmpty else { serverstandZeigen("Trag erst eine Adresse ein."); return }

        // Dieselbe Regel wie überall: ohne Schema bekommt eine Adresse
        // `https` vorgesetzt, außer sie sieht nach Heimnetz aus.
        guard let url = AppModelURLNormalizer.normalize(eingabe) else {
            serverstandZeigen("Mit dieser Adresse kann ich nichts anfangen.")
            return
        }

        meldetGerade = true
        gtk_widget_set_sensitive(verbindeknopf, 0)
        gtk_button_set_label(alsKnopf(verbindeknopf), "Verbinde …")
        serverstandZeigen("Frage \(url.absoluteString) …")

        Task.detached { [self] in
            let c = JellyfinClient(baseURL: url, deviceID: Geraet.kennung, deviceName: Geraet.name)
            do {
                let info = try await c.publicSystemInfo()
                let name = info.serverName ?? url.host() ?? "Server"
                let fassung = info.version ?? "?"
                aufHauptfaden {
                    self.verbindenFertig()
                    self.serverURL = url
                    gtk_label_set_text(OpaquePointer(self.serverzeile), name)
                    gtk_label_set_text(OpaquePointer(self.fassungszeile), "Jellyfin \(fassung)")
                    self.serverstandZeigen("")
                    gtk_stack_set_visible_child_name(OpaquePointer(self.anmeldeschritte), "konto")
                    gtk_widget_grab_focus(self.benutzerfeld)
                }
            } catch {
                aufHauptfaden {
                    self.verbindenFertig()
                    self.serverstandZeigen("Ging nicht: \(error.localizedDescription)")
                }
            }
        }
    }

    private func verbindenFertig() {
        meldetGerade = false
        gtk_widget_set_sensitive(verbindeknopf, 1)
        gtk_button_set_label(alsKnopf(verbindeknopf), "Verbinden")
    }

    // MARK: Schritt zwei — anmelden

    private func anmelden() {
        guard !meldetGerade, let url = serverURL else { return }
        let benutzer = text(benutzerfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        let passwort = text(passwortfeld)
        guard !benutzer.isEmpty else { anmeldestandZeigen("Trag einen Benutzernamen ein."); return }

        meldetGerade = true
        gtk_widget_set_sensitive(anmeldeknopf, 0)
        gtk_button_set_label(alsKnopf(anmeldeknopf), "Melde an …")
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
                    self.anmeldestandZeigen("Ging nicht: \(error.localizedDescription)")
                }
            }
        }
    }

    private func anmeldungFertig() {
        meldetGerade = false
        gtk_widget_set_sensitive(anmeldeknopf, 1)
        gtk_button_set_label(alsKnopf(anmeldeknopf), "Anmelden")
    }

    private func sitzungUebernehmen(serverURL: URL, token: String, benutzerID: String,
                                    benutzername: String, servername: String?) {
        let c = JellyfinClient(baseURL: serverURL,
                               deviceID: Geraet.kennung,
                               deviceName: Geraet.name)
        adressen = Bildadresse(basis: serverURL, token: token)
        gtk_label_set_text(OpaquePointer(titelzeile),
                           servername.map { "Swiftly · \($0)" } ?? "Swiftly")
        kopfzeileZeigen(true)
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "start")

        // **`JellyfinClient` ist ein Akteur.** Die Sitzung einzusetzen geht
        // deshalb nur mit `await`; erst danach darf geladen werden.
        let sitzung = Session(accessToken: token, userID: benutzerID,
                              userName: benutzername, serverURL: serverURL)
        Task.detached { [self] in
            await c.setSession(sitzung)
            aufHauptfaden {
                self.client = c
                self.startseiteLaden()
            }
        }
    }

    // MARK: - Startseite

    private var titelzeile: Widget!
    private var abmeldeknopf: Widget!

    private func startseiteBauen() -> Widget! {
        let scroller = gtk_scrolled_window_new()
        gtk_widget_set_vexpand(scroller, 1)

        reihenstapel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 26)
        raender(reihenstapel, 24)
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihenstapel)

        titelzeile = beschriftung("Swiftly", stil: "title-4")
        abmeldeknopf = gtk_button_new_with_label("Abmelden")
        gtk_widget_add_css_class(abmeldeknopf, "flat")
        beiSignal(abmeldeknopf, "clicked") { [weak self] in self?.abmelden() }
        return scroller
    }

    private func kopfzeileFuellen() {
        gtk_header_bar_set_title_widget(OpaquePointer(kopfzeile), titelzeile)
        gtk_header_bar_pack_end(OpaquePointer(kopfzeile), abmeldeknopf)
        kopfzeileZeigen(false)
    }

    /// **Die Kopfzeile gehört zur Sitzung, nicht zum Fenster.**
    ///
    /// Servername und „Abmelden" haben auf dem Anmeldebildschirm nichts zu
    /// suchen — sie standen dort, weil beide einmal aufgebaut werden und
    /// niemand sie wieder ausgeblendet hat. Auf dem Anmeldeweg bleibt der
    /// Kopf leer.
    private func kopfzeileZeigen(_ sichtbar: Bool) {
        gtk_widget_set_visible(titelzeile, sichtbar ? 1 : 0)
        gtk_widget_set_visible(abmeldeknopf, sichtbar ? 1 : 0)
    }

    private func abmelden() {
        Speicher.loeschen()
        client = nil
        adressen = nil
        leeren(reihenstapel)
        gtk_editable_set_text(OpaquePointer(passwortfeld), "")
        anmeldestandZeigen("")
        serverstandZeigen("Abgemeldet.")
        kopfzeileZeigen(false)
        gtk_stack_set_visible_child_name(OpaquePointer(anmeldeschritte), "server")
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "anmeldung")
    }

    private func startseiteLaden() {
        guard let client else { return }
        leeren(reihenstapel)
        anhaengen(reihenstapel, beschriftung("Lade …", stil: "dim-label"))

        Task.detached { [self] in
            async let weiter = try? await client.resumeItems(limit: 20)
            async let naechste = try? await client.nextUp(limit: 20)
            async let neu = try? await client.latest(limit: 20)

            let reihen: [(String, [Item])] = [
                ("Weiterschauen", await weiter ?? []),
                ("Nächste Folge", await naechste ?? []),
                ("Zuletzt hinzugefügt", await neu ?? [])
            ].filter { !$0.1.isEmpty }

            aufHauptfaden { self.reihenZeigen(reihen) }
        }
    }

    private func reihenZeigen(_ reihen: [(String, [Item])]) {
        leeren(reihenstapel)
        guard !reihen.isEmpty else {
            anhaengen(reihenstapel,
                      beschriftung("Nichts gefunden. Steht auf dem Server etwas?",
                                   stil: "dim-label", umbruch: true))
            return
        }
        for (titel, titelListe) in reihen {
            anhaengen(reihenstapel, reiheBauen(titel: titel, items: titelListe))
        }
    }

    /// Eine waagerecht scrollende Reihe mit Postern.
    private func reiheBauen(titel: String, items: [Item]) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)

        let ueberschrift = beschriftung(titel, stil: "title-2")
        gtk_widget_set_halign(ueberschrift, GTK_ALIGN_START)
        anhaengen(block, ueberschrift)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_widget_set_size_request(scroller, -1, 260)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        for item in items { anhaengen(reihe, kachelBauen(item)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)
        anhaengen(block, scroller)
        return block
    }

    private func kachelBauen(_ item: Item) -> Widget! {
        let kachel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 6)
        gtk_widget_set_size_request(kachel, Int32(Stil.kachelBreiteBreit), -1)

        let bild = gtk_picture_new()
        gtk_widget_set_size_request(bild, Int32(Stil.kachelBreiteBreit),
                                   Int32(Stil.kachelHoehe(Stil.kachelBreiteBreit)))
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
        gtk_widget_add_css_class(bild, "swiftly-plakat")
        gtk_widget_set_overflow(bild, GTK_OVERFLOW_HIDDEN)
        anhaengen(kachel, bild)

        if let adressen { posterLaden(bild, item: item, adressen: adressen, kante: 300) }

        let name = beschriftung(item.name, stil: "caption-heading")
        gtk_label_set_ellipsize(OpaquePointer(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_halign(name, GTK_ALIGN_START)
        anhaengen(kachel, name)

        // Bei Folgen die Serie darunter, bei Filmen das Jahr.
        let zweite = item.seriesName ?? item.productionYear.map(String.init) ?? ""
        if !zweite.isEmpty {
            let unten = beschriftung(zweite, stil: "caption")
            gtk_widget_add_css_class(unten, "dim-label")
            gtk_label_set_ellipsize(OpaquePointer(unten), PANGO_ELLIPSIZE_END)
            gtk_widget_set_halign(unten, GTK_ALIGN_START)
            anhaengen(kachel, unten)
        }
        return kachel
    }

    func kopfzeileEinrichten() { kopfzeileFuellen() }
}

/// Wie sich diese App beim Server vorstellt.
///
/// Die Kennung muss über Neustarts gleich bleiben — Jellyfin führt darüber
/// die Geräteliste und die Übernahme der Wiedergabe von einem anderen Gerät.
enum Geraet {
    static let name: String = {
        let rechner = ProcessInfo.processInfo.hostName
        return "Swiftly auf \(rechner)"
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
