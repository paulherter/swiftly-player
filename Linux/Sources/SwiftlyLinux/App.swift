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
final class App {

    // Fenster und die zwei Seiten darin.
    private var fenster: Widget!
    private var seiten: Widget!          // GtkStack
    private var anmeldeseite: Widget!
    private var startseite: Widget!

    // Anmeldung
    private var serverfeld: Widget!
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
        fenster = adw_application_window_new(anwendung)
        gtk_window_set_title(alsFenster(fenster), "Swiftly")
        gtk_window_set_default_size(alsFenster(fenster), 1100, 760)

        seiten = gtk_stack_new()
        gtk_stack_set_transition_type(OpaquePointer(seiten), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_widget_set_vexpand(seiten, 1)

        anmeldeseite = anmeldungBauen()
        startseite = startseiteBauen()
        gtk_stack_add_named(OpaquePointer(seiten), anmeldeseite, "anmeldung")
        gtk_stack_add_named(OpaquePointer(seiten), startseite, "start")

        let inhalt = stapel(GTK_ORIENTATION_VERTICAL)
        kopfzeile = adw_header_bar_new()
        anhaengen(inhalt, kopfzeile)
        anhaengen(inhalt, seiten)
        adw_application_window_set_content(
            unsafeBitCast(fenster, to: UnsafeMutablePointer<AdwApplicationWindow>.self), inhalt)

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
        let mitte = stapel(GTK_ORIENTATION_VERTICAL, abstand: 12)
        raender(mitte, 40)
        gtk_widget_set_valign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(mitte, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(mitte, 380, -1)

        anhaengen(mitte, beschriftung("Swiftly", stil: "title-1"))
        anhaengen(mitte, beschriftung("Wo steht dein Jellyfin?", stil: "dim-label"))

        serverfeld = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(serverfeld), "tv.beispiel.de")
        gtk_widget_set_margin_top(serverfeld, 10)
        anhaengen(mitte, serverfeld)

        benutzerfeld = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(benutzerfeld), "Benutzername")
        anhaengen(mitte, benutzerfeld)

        passwortfeld = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(passwortfeld), "Passwort")
        gtk_entry_set_visibility(alsFeld(passwortfeld), 0)
        anhaengen(mitte, passwortfeld)

        anmeldeknopf = gtk_button_new_with_label("Anmelden")
        gtk_widget_add_css_class(anmeldeknopf, "suggested-action")
        gtk_widget_add_css_class(anmeldeknopf, "pill")
        gtk_widget_set_margin_top(anmeldeknopf, 8)
        anhaengen(mitte, anmeldeknopf)

        anmeldestand = beschriftung("", stil: "dim-label", umbruch: true)
        gtk_widget_set_margin_top(anmeldestand, 6)
        anhaengen(mitte, anmeldestand)

        beiSignal(anmeldeknopf, "clicked") { [weak self] in self?.anmelden() }
        for feld in [serverfeld, benutzerfeld, passwortfeld] {
            beiSignal(feld, "activate") { [weak self] in self?.anmelden() }
        }
        return mitte
    }

    private func text(_ feld: Widget!) -> String {
        gtk_editable_get_text(OpaquePointer(feld)).map { String(cString: $0) } ?? ""
    }

    private func anmeldestandZeigen(_ s: String) {
        gtk_label_set_text(OpaquePointer(anmeldestand), s)
    }

    private func anmelden() {
        guard !meldetGerade else { return }

        let eingabe = text(serverfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        let benutzer = text(benutzerfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        let passwort = text(passwortfeld)

        guard !eingabe.isEmpty else { anmeldestandZeigen("Trag erst eine Adresse ein."); return }
        guard !benutzer.isEmpty else { anmeldestandZeigen("Und einen Benutzernamen."); return }

        // Dieselbe Regel wie auf allen Apple-Plattformen: ohne Schema bekommt
        // eine Adresse `https` vorgesetzt, außer sie sieht nach Heimnetz aus.
        guard let url = AppModelURLNormalizer.normalize(eingabe) else {
            anmeldestandZeigen("Mit dieser Adresse kann ich nichts anfangen.")
            return
        }

        meldetGerade = true
        gtk_widget_set_sensitive(anmeldeknopf, 0)
        gtk_button_set_label(alsKnopf(anmeldeknopf), "Melde an …")
        anmeldestandZeigen("Frage \(url.absoluteString) …")

        Task.detached { [weak self] in
            let neuerClient = JellyfinClient(baseURL: url,
                                             deviceID: Geraet.kennung,
                                             deviceName: Geraet.name)
            do {
                let info = try? await neuerClient.publicSystemInfo()
                let sitzung = try await neuerClient.authenticate(username: benutzer,
                                                                 password: passwort)
                Speicher.schreiben(.init(serverURL: url,
                                         token: sitzung.accessToken,
                                         benutzerID: sitzung.userID,
                                         benutzername: benutzer,
                                         servername: info?.serverName))
                aufHauptfaden {
                    self?.anmeldungFertig()
                    self?.sitzungUebernehmen(serverURL: url,
                                             token: sitzung.accessToken,
                                             benutzerID: sitzung.userID,
                                             benutzername: benutzer,
                                             servername: info?.serverName)
                }
            } catch {
                aufHauptfaden {
                    self?.anmeldungFertig()
                    self?.anmeldestandZeigen("Ging nicht: \(error.localizedDescription)")
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
        c.setSession(Session(accessToken: token, userID: benutzerID))
        client = c
        adressen = Bildadresse(basis: serverURL, token: token)

        gtk_label_set_text(OpaquePointer(titelzeile),
                           servername.map { "Swiftly · \($0)" } ?? "Swiftly")
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "start")
        startseiteLaden()
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
        adw_header_bar_set_title_widget(OpaquePointer(kopfzeile), titelzeile)
        adw_header_bar_pack_end(OpaquePointer(kopfzeile), abmeldeknopf)
    }

    private func abmelden() {
        Speicher.loeschen()
        client = nil
        adressen = nil
        leeren(reihenstapel)
        gtk_editable_set_text(OpaquePointer(passwortfeld), "")
        anmeldestandZeigen("Abgemeldet.")
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "anmeldung")
    }

    private func startseiteLaden() {
        guard let client else { return }
        leeren(reihenstapel)
        anhaengen(reihenstapel, beschriftung("Lade …", stil: "dim-label"))

        Task.detached { [weak self] in
            async let weiter = try? await client.resumeItems(limit: 20)
            async let naechste = try? await client.nextUp(limit: 20)
            async let neu = try? await client.latest(limit: 20)

            let reihen: [(String, [Item])] = [
                ("Weiterschauen", await weiter ?? []),
                ("Nächste Folge", await naechste ?? []),
                ("Zuletzt hinzugefügt", await neu ?? [])
            ].filter { !$0.1.isEmpty }

            aufHauptfaden { self?.reihenZeigen(reihen) }
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
        gtk_widget_set_size_request(kachel, 140, -1)

        let bild = gtk_picture_new()
        gtk_widget_set_size_request(bild, 140, 200)
        gtk_picture_set_content_fit(OpaquePointer(bild), GTK_CONTENT_FIT_COVER)
        gtk_widget_add_css_class(bild, "card")
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
