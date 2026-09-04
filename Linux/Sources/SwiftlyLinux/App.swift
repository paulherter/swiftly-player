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
    private var bereich: Bereich = .start
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

        let frage = beschriftung("Wo steht dein Jellyfin-Server?",
                                 stil: "swiftly-koerper")
        gtk_widget_add_css_class(frage, "dim-label")
        gtk_widget_set_margin_top(frage, 40)
        anhaengen(mitte, frage)

        // Die Weltkugel im Feld — auf dem Mac steht dort `Image("globe")`.
        serverfeld = eingabezeile(symbol: "globe-symbolic", platzhalter: "tv.beispiel.de")
        gtk_widget_set_margin_top(serverfeld, 24)
        anhaengen(mitte, serverfeld)

        serverstand = meldezeile()
        anhaengen(mitte, serverstand)

        verbindeknopf = hauptknopf("Verbinden")
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

        benutzerfeld = eingabezeile(symbol: "avatar-default-symbolic",
                                    platzhalter: "Benutzername")
        gtk_widget_set_margin_top(benutzerfeld, 28)
        anhaengen(mitte, benutzerfeld)

        passwortfeld = eingabezeile(symbol: "channel-secure-symbolic",
                                    platzhalter: "Passwort", geheim: true)
        gtk_widget_set_margin_top(passwortfeld, 10)
        anhaengen(mitte, passwortfeld)

        anmeldestand = meldezeile()
        anhaengen(mitte, anmeldestand)

        anmeldeknopf = hauptknopf("Anmelden")
        gtk_widget_set_margin_top(anmeldeknopf, 24)
        gtk_widget_set_sensitive(anmeldeknopf, 0)
        anhaengen(mitte, anmeldeknopf)

        // Der Mac kommt über die Fensterampel zurueck; hier braucht es einen
        // Weg im Bild, sonst sitzt man auf dem falschen Server fest.
        let zurueck: Widget! = gtk_button_new_with_label("Anderer Server")
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

    private func text(_ feld: Widget!) -> String {
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
            }
        }
    }

    // MARK: - Das Fenster nach der Anmeldung

    private var titelzeile: Widget!
    private var inhalt: Widget!            // GtkStack: start / filme / serien / suche
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
    private var filmezahl: Widget!
    private var serienzahl: Widget!
    private var geladen: Set<Bereich> = []
    private var benutzerID = ""

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

        anhaengen(quer, inhalt)

        titelzeile = beschriftung("", stil: "swiftly-zweitzeile")
        return quer
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

        bibliotheksrubrik = rubrik("Bibliotheken")
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
        anhaengen(leiste, trennlinie())
        anhaengen(leiste, profilzeileBauen())
        return leiste
    }

    /// Wer angemeldet ist, und wo. Unten in der Leiste — 40 hoch, Bild 26,
    /// Name 14 halbfett, Server 11 sehr leise.
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
        // Bis es eine Profilseite gibt, führt der Knopf hinaus. Auf dem Mac
        // liegt „Abmelden" eine Ebene tiefer, hinter dem Profil.
        beiSignal(knopf, "clicked") { [weak self] in self?.abmelden() }
        return knopf
    }

    /// Schaltet den Bereich um und färbt die Zeilen nach.
    private func zeige(_ neu: Bereich) {
        bereich = neu
        for (i, fall) in Bereich.allCases.enumerated() {
            guard let knopf = bereichsknoepfe[i] else { continue }
            if fall == neu { gtk_widget_add_css_class(knopf, "swiftly-aktiv") }
            else { gtk_widget_remove_css_class(knopf, "swiftly-aktiv") }
        }
        gtk_stack_set_visible_child_name(OpaquePointer(inhalt), neu.kennung)
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
        let scroller = gtk_scrolled_window_new()
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
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

    private func startbereichBauen() -> Widget! {
        reihenstapel = stapel(GTK_ORIENTATION_VERTICAL, abstand: Int32(Stil.reihenAbstand))
        return seitenrahmen(reihenstapel)
    }

    private func rasterseiteBauen(_ was: Bereich) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 20)
        var zahl: Widget!
        anhaengen(block, seitenkopf(was.beschriftung, zahl: &zahl))
        let raster = rasterBauen()
        anhaengen(block, raster)
        if was == .filme { filmeraster = raster; filmezahl = zahl }
        else { serienraster = raster; serienzahl = zahl }
        return seitenrahmen(block)
    }

    private func sucheBauen() -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 20)
        var unbenutzt: Widget!
        anhaengen(block, seitenkopf("Suche", zahl: &unbenutzt))

        suchfeld = eingabezeile(symbol: "system-search-symbolic", platzhalter: "Suchen")
        // Auf der Suchseite geht das Feld über die Inhaltsbreite, nicht über
        // die 360 des Anmeldeblocks.
        gtk_widget_set_size_request(suchfeld, -1, Int32(Stil.feldHoehe))
        gtk_widget_set_halign(suchfeld, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(suchfeld, 1)
        anhaengen(block, suchfeld)

        suchraster = rasterBauen()
        anhaengen(block, suchraster)
        beiSignal(suchfeld, "activate") { [weak self] in self?.suchen() }
        return seitenrahmen(block)
    }

    /// Ein umbrechendes Raster. GTKs `GtkFlowBox` kann genau das, was auf dem
    /// Mac ein `LazyVGrid` mit fester Spaltenbreite tut.
    private func rasterBauen() -> Widget! {
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

    private func rasterFuellen(_ raster: Widget!, _ items: [Item]) {
        while let kind = gtk_flow_box_get_child_at_index(OpaquePointer(raster), 0) {
            gtk_flow_box_remove(OpaquePointer(raster),
                                unsafeBitCast(kind, to: Widget.self))
        }
        for item in items {
            gtk_flow_box_insert(OpaquePointer(raster), rasterkachel(item), -1)
        }
    }

    // MARK: Laden

    private func abmelden() {
        Speicher.loeschen()
        client = nil
        adressen = nil
        geladen.removeAll()
        leeren(reihenstapel)
        gtk_editable_set_text(OpaquePointer(passwortfeld), "")
        anmeldestandZeigen("")
        serverstandZeigen("")
        kopfzeileZeigen(false)
        gtk_stack_set_visible_child_name(OpaquePointer(anmeldeschritte), "server")
        gtk_stack_set_visible_child_name(OpaquePointer(seiten), "anmeldung")
    }

    /// Name, Server und Bild unten in der Leiste, dazu die Bibliotheken.
    private func sitzungAnzeigen(benutzername: String, servername: String?) {
        gtk_label_set_text(OpaquePointer(profilname), benutzername)
        gtk_label_set_text(OpaquePointer(profilserver), servername ?? "")
        if let adressen, !benutzerID.isEmpty,
           let url = adressen.benutzer(benutzerID, kante: 60) {
            bildLaden(profilbild, url: url, schluessel: "benutzer-\(benutzerID)")
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
            anhaengen(bibliotheksliste,
                      seitenleistenzeile(symbol: symbol, text: sicht.name, aktiv: false))
        }
    }

    private func startseiteLaden() {
        guard let client else { return }
        leeren(reihenstapel)
        anhaengen(reihenstapel, beschriftung("Lade …", stil: "swiftly-koerper"))

        Task.detached { [self] in
            async let weiter = try? await client.resumeItems(limit: 20)
            async let naechste = try? await client.nextUp(limit: 20)
            async let neu = try? await client.latest(limit: 20)

            // **Jede Reihe hat ihre eigene Kachelform, und das ist keine
            // Geschmacksfrage.** A2 im Register: „Nächste Folge öffnet die
            // Übersicht, sie startet nicht. Nur ‚Weiterschauen' springt
            // direkt in die Wiedergabe." Waagerecht ist deshalb allein
            // „Weiterschauen" — auf iPhone, Fernseher und Mac genauso.
            let reihen: [(String, Reihenart, [Item])] = [
                ("Weiterschauen", .weiterschauen, await weiter ?? []),
                ("Nächste Folge", .naechste, await naechste ?? []),
                ("Zuletzt hinzugefügt", .neu, await neu ?? [])
            ].filter { !$0.2.isEmpty }

            aufHauptfaden { self.reihenZeigen(reihen) }
        }
    }

    /// Filme und Serien. **Mit Gattung und rekursiv**, aus demselben Grund,
    /// der in `JellyfinClient.items` steht: sonst kommen bei einer
    /// Serienbibliothek die virtuellen Ordner statt der Serien.
    private func rasterLaden(_ was: Bereich) {
        guard let client else { return }
        let gattung = was == .filme ? "Movie" : "Series"
        Task.detached { [self] in
            let antwort = try? await client.items(limit: 500,
                                                  recursive: true,
                                                  includeItemTypes: [gattung])
            let items = antwort?.items ?? []
            let gesamt = antwort?.totalRecordCount ?? items.count
            aufHauptfaden {
                let raster = was == .filme ? self.filmeraster : self.serienraster
                let zahl = was == .filme ? self.filmezahl : self.serienzahl
                self.rasterFuellen(raster, items)
                gtk_label_set_text(OpaquePointer(zahl), String(gesamt))
            }
        }
    }

    private func suchen() {
        guard let client else { return }
        let begriff = text(suchfeld).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !begriff.isEmpty else { rasterFuellen(suchraster, []); return }
        Task.detached { [self] in
            let treffer = (try? await client.suche(begriff)) ?? []
            aufHauptfaden { self.rasterFuellen(self.suchraster, treffer) }
        }
    }

    private func reihenZeigen(_ reihen: [(String, Reihenart, [Item])]) {
        leeren(reihenstapel)
        guard !reihen.isEmpty else {
            anhaengen(reihenstapel,
                      beschriftung("Nichts gefunden. Steht auf dem Server etwas?",
                                   stil: "swiftly-koerper", umbruch: true))
            return
        }
        for (titel, art, titelListe) in reihen {
            anhaengen(reihenstapel, reiheBauen(titel: titel, art: art, items: titelListe))
        }
    }

    /// Eine waagerecht scrollende Reihe mit Postern. Überschrift 20 halbfett,
    /// darunter 10 Luft — `Stil.reihe`.
    private func reiheBauen(titel: String, art: Reihenart, items: [Item]) -> Widget! {
        let block = stapel(GTK_ORIENTATION_VERTICAL, abstand: 10)

        let ueberschrift = beschriftung(titel, stil: "swiftly-reihe")
        gtk_label_set_xalign(OpaquePointer(ueberschrift), 0)
        gtk_widget_set_halign(ueberschrift, GTK_ALIGN_START)
        anhaengen(block, ueberschrift)

        let scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(OpaquePointer(scroller),
                                       GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)

        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: Int32(Stil.kachelAbstand))
        for item in items { anhaengen(reihe, kachelBauen(item, art: art)) }
        gtk_scrolled_window_set_child(OpaquePointer(scroller), reihe)
        anhaengen(block, scroller)
        return block
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

        let kachel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        gtk_widget_set_size_request(kachel, Int32(breite), -1)
        gtk_widget_set_valign(kachel, GTK_ALIGN_START)

        let (kaefig, bild) = gerahmtesBild(breite: breite, hoehe: hoehe,
                                           stil: "swiftly-plakat")
        if let adressen {
            // **Welches Bild, entscheidet `Bildwahl` im Paket.** Bei einer
            // Folge hochkant das Plakat der Serie, quer der Hintergrund der
            // Serie mit vier Rückfällen dahinter. Die Begründung zu jeder
            // Stufe steht dort, mit Tests.
            let adresse = quer
                ? Bildwahl.quer(item, adressen: adressen, breite: breite * 2)?.url
                : Bildwahl.hochkant(item, adressen: adressen, maxHoehe: hoehe * 2)
            if let adresse {
                bildLaden(bild, url: adresse, schluessel: "\(item.id)-\(quer ? "quer" : "hoch")")
            }
        }

        // Der Fortschrittsbalken liegt **auf** dem Bild, unten, wie auf dem
        // Mac. Nur bei „Weiterschauen" — sonst steht er unter Titeln, die
        // noch gar nicht angefangen wurden.
        if quer, let anteil = item.gesehenerAnteil {
            anhaengen(kachel, mitBalken(kaefig, breite: breite, anteil: anteil))
        } else {
            anhaengen(kachel, kaefig)
        }

        let (oben, unten): (String, String?) = switch art {
        case .weiterschauen: (item.seriesName ?? item.name, item.kontextzeile)
        case .naechste:      (item.seriesName ?? item.name, item.folgenkuerzel)
        case .neu:           (item.name, item.neuzugangszeile)
        }

        anhaengen(kachel, kacheltitel(oben, stil: "swiftly-kacheltitel"))
        if let unten, !unten.isEmpty {
            let zweite = kacheltitel(unten, stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(zweite, "dim-label")
            anhaengen(kachel, zweite)
        }
        return kachel
    }

    /// Eine Kachel im Raster — Plakat, Name, Jahr.
    private func rasterkachel(_ item: Item) -> Widget! {
        let kachel = stapel(GTK_ORIENTATION_VERTICAL, abstand: 8)
        gtk_widget_set_size_request(kachel, Int32(Stil.kachelBreite), -1)
        gtk_widget_set_valign(kachel, GTK_ALIGN_START)

        let (kaefig, bild) = gerahmtesBild(breite: Stil.kachelBreite,
                                           hoehe: Stil.kachelHoehe,
                                           stil: "swiftly-plakat")
        anhaengen(kachel, kaefig)
        if let adressen,
           let adresse = Bildwahl.hochkant(item, adressen: adressen,
                                           maxHoehe: Stil.kachelHoehe * 2) {
            bildLaden(bild, url: adresse, schluessel: "\(item.id)-hoch")
        }

        anhaengen(kachel, kacheltitel(item.name, stil: "swiftly-kacheltitel"))
        if let jahr = item.productionYear {
            let zweite = kacheltitel(String(jahr), stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(zweite, "dim-label")
            anhaengen(kachel, zweite)
        }
        return kachel
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

    /// Legt den Fortschrittsbalken unten auf ein Bild.
    ///
    /// Zwei Lagen: eine dunkle Spur über die ganze Breite und darauf der
    /// Akzent, so breit wie der gesehene Anteil. GTK kennt keinen Anteil als
    /// Breitenangabe — die Kachel hat aber eine feste Breite, also lässt er
    /// sich ausrechnen.
    private func mitBalken(_ kaefig: Widget!, breite: Int, anteil: Double) -> Widget! {
        let ueber: Widget! = gtk_overlay_new()
        gtk_overlay_set_child(OpaquePointer(ueber), kaefig)

        let spur: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(spur, "swiftly-balkenspur")
        gtk_widget_set_size_request(spur, -1, 4)
        gtk_widget_set_valign(spur, GTK_ALIGN_END)
        gtk_widget_set_halign(spur, GTK_ALIGN_FILL)
        gtk_overlay_add_overlay(OpaquePointer(ueber), spur)

        let balken: Widget! = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(balken, "swiftly-balken")
        gtk_widget_set_size_request(balken, Int32(Double(breite) * min(max(anteil, 0), 1)), 4)
        gtk_widget_set_valign(balken, GTK_ALIGN_END)
        gtk_widget_set_halign(balken, GTK_ALIGN_START)
        gtk_overlay_add_overlay(OpaquePointer(ueber), balken)
        return ueber
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
