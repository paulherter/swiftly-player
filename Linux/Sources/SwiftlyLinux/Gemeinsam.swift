import CGtk
import Foundation
import JellyfinKit

// MARK: - Gemeinsam schauen

/// **Gemeinsam schauen, auf Linux und Windows.**
///
/// Der Ablauf steht im Paket (``SyncPlaySitzung``), derselbe wie auf iPhone,
/// Mac, Fernseher und Android: Gruppe anlegen, beitreten, verlassen, die Uhr,
/// die Warteschlange, Befehle zum Zeitpunkt, Puffern und „bereit". Hier liegt
/// nur, was an dieser Oberfläche hängt — der Spiegel der ``SyncPlayLage``,
/// die Tafeln, das Laden eines Titels in den Player und die Zeichen zu den
/// Hinweisen. Vorlage ist iOS (`Sources/Shared/Gemeinsammodell.swift`,
/// `Sources/iOS/Gemeinsamansichten.swift`), in der Form des Schreibtischs:
/// Tafeln am Knopf statt Blätter (VERHALTEN.md F, Zeigerbedienung).
///
/// **Alles hier gehört dem GTK-Faden**, wie der Rest der App (siehe
/// `Discordstand.swift`). Nur die Sitzung selbst ist ein Akteur; was sie
/// von der App wissen will, holt sie über ``aufHauptfadenHolen(_:)``.
final class Gemeinsamstand: @unchecked Sendable {
    /// Der letzte Stand aus dem Paket.
    var lage = SyncPlayLage()
    /// Einer für die Laufzeit der App; er fragt bei jedem Schritt nach dem
    /// Client, der gerade gilt.
    var sitzung: SyncPlaySitzung?
    var zuhoeren: Task<Void, Never>?
    /// Recht holen und im Takt der Übernahme nach Gruppen fragen.
    var takt: Task<Void, Never>?
    /// Anschliessen, Abtrennen und Beenden in der Reihenfolge, in der sie
    /// hier geschahen — zwei lose Aufträge könnten sich überholen.
    var kette: Task<Void, Never>?
    /// Der offene Player gehört zur Gruppe (iOS: `gemeinsamAn`).
    var an = false
    /// Der Titel, den die Gruppe zuletzt gesetzt hat. Bis der Player auf ihm
    /// steht, gilt er als nicht bereit.
    var erwartet: String?
    var spieler: Gemeinsamspieler?
    /// Solange die Zeitleiste gezogen wird: das Ziel. Die Bitte geht erst
    /// beim Loslassen — sonst eine je Mausbewegung.
    var reglerZiel: Double?

    /// Die Tafel „Gemeinsam schauen" oder „Beitreten", solange sie offen ist.
    var tafel: Widget?
    var tafelKnopf: Widget?

    /// Der Hinweis oben im Player.
    var ereignisHuelle: Widget?
    var ereignisBild: Widget?
    var ereignisText: Widget?
    var ereignisID: UUID?
    /// Was die Metazeile im Player zuletzt zeigte — neu gebaut wird nur,
    /// wenn sich daran etwas ändert.
    var metastand = ""

    /// „Filmabend verlassen · Wieder beitreten".
    var streifen: Widget?
    var streifenText: Widget?

    /// Fehler der Gruppe, über allem — auch über dem Player.
    var hinweis: Widget?
    var hinweistakt = 0
}

/// **Was der Player für die Gruppe hergibt** (iOS: `Gemeinsamspieler`).
///
/// Die Sitzung liest immer den **jetzigen** Stand; jeder Griff geht dafür
/// auf den GTK-Faden und liest dort, was gerade gilt.
final class Gemeinsamspieler: SyncPlaySpieler, @unchecked Sendable {
    let app: App
    init(app: App) { self.app = app }

    func titel() async -> String {
        await aufHauptfadenHolen { [app] in app.laufenderTitel?.id ?? "" }
    }

    /// Steht das Bild, und wird gerade kein Titel gewechselt? Solange die
    /// Gruppe einen anderen Titel gesetzt hat, als der Player zeigt, nicht —
    /// sonst ginge „bereit" für den alten hinaus, bevor der neue lädt.
    func bereit() async -> Bool {
        await aufHauptfadenHolen { [app] in
            guard let titel = app.laufenderTitel, app.laufenderPlan != nil else { return false }
            if let erwartet = app.gemeinsam.erwartet, erwartet != titel.id { return false }
            return app.spielstand.erstesBildDa && app.spielerLadeschirm == nil
                && !app.folgenwechsel.laeuft
        }
    }

    func stelle() async -> Double {
        await aufHauptfadenHolen { [app] in app.abspieler.position }
    }

    func weiter() async {
        await aufHauptfadenHolen { [app] in app.gemeinsamLaufzustand(true) }
    }

    func anhalten() async {
        await aufHauptfadenHolen { [app] in app.gemeinsamLaufzustand(false) }
    }

    /// Springt und zieht Zeitleiste und Knopf gleich nach.
    func springen(_ ziel: Double) async {
        await aufHauptfadenHolen { [app] in app.springeDirekt(auf: ziel) }
    }
}

/// `aufHauptfaden` mit Antwort — für die Sitzung, die als Akteur abseits
/// läuft und einen Wert der Oberfläche braucht. Nie vom GTK-Faden aus rufen.
func aufHauptfadenHolen<T: Sendable>(_ block: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (fertig: CheckedContinuation<T, Never>) in
        aufHauptfaden { fertig.resume(returning: block()) }
    }
}

extension App {

    // MARK: Die Sitzung

    var gemeinsamSitzung: SyncPlaySitzung {
        if let s = gemeinsam.sitzung { return s }
        let s = SyncPlaySitzung(
            client: { [self] in await aufHauptfadenHolen { self.client } },
            ich: { [self] in
                await aufHauptfadenHolen { self.benutzername.isEmpty ? nil : self.benutzername }
            },
            titelLaden: { [self] titel, ab in await self.gemeinsamTitelLaden(titel, ab: ab) })
        gemeinsam.sitzung = s
        gemeinsam.zuhoeren = Task.detached { [self] in
            for await m in s.mitteilungen {
                aufHauptfaden { self.gemeinsamMitteilung(m) }
            }
        }
        return s
    }

    /// Die Gruppe läuft in diesem Player (iOS: `inGruppe`).
    var inGruppe: Bool { gemeinsam.an && gemeinsam.lage.gruppe != nil }

    /// Gruppen auf dem Server, die das Abzeichen anbietet — keine, solange
    /// man selbst in einer ist oder nicht beitreten darf.
    var gemeinsamAngebote: [SyncPlayGruppe] {
        gemeinsam.lage.gruppe == nil && gemeinsam.lage.darfBeitreten ? gemeinsam.lage.angebote : []
    }

    /// Nach dem Anmelden, neben der Übernahme: das Recht einmal, die Gruppen
    /// im selben Takt — und nicht, solange hier der Player läuft.
    func gemeinsamStarten() {
        let sitzung = gemeinsamSitzung
        gemeinsam.takt?.cancel()
        // **Erst das Beenden des vorigen Kontos, dann das Recht des neuen** —
        // sonst löschte ein spätes `beenden()` das eben geholte Recht.
        let vorher = gemeinsam.kette
        gemeinsam.takt = Task.detached { [self] in
            await vorher?.value
            await sitzung.rechtHolen()
            while !Task.isCancelled {
                let spielt = await aufHauptfadenHolen { self.laufenderTitel != nil }
                if !spielt { await sitzung.angeboteFragen() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Beim Abmelden und Kontowechsel: raus aus der Gruppe, alles vergessen.
    func gemeinsamBeenden() {
        gemeinsam.takt?.cancel()
        gemeinsam.takt = nil
        gemeinsam.an = false
        gemeinsam.erwartet = nil
        // Mit dem Client des alten Kontos verlassen — gleich danach setzt
        // der Aufrufer den neuen, und das `Leave` ginge in dessen Namen.
        let alt = client
        gemeinsamKette { await $0.beenden(alterClient: alt) }
    }

    private func gemeinsamKette(_ schritt: @escaping @Sendable (SyncPlaySitzung) async -> Void) {
        let sitzung = gemeinsamSitzung
        let vorher = gemeinsam.kette
        gemeinsam.kette = Task.detached {
            await vorher?.value
            await schritt(sitzung)
        }
    }

    // MARK: Was aus dem Paket kommt

    private func gemeinsamMitteilung(_ m: SyncPlayMitteilung) {
        switch m {
        case let .lage(neu):
            gemeinsam.lage = neu
            // Die Gruppe ist weg, der Player läuft allein weiter — dann
            // gelten wieder die eigenen Knöpfe.
            if neu.gruppe == nil { gemeinsam.reglerZiel = nil }
            uebernahmeZeigen()
            gemeinsamEreignisZeigen()
            gemeinsamMetazeileNachfuehren()
            gemeinsamStreifenZeigen()
        case let .fehler(f):
            Protokoll.schreib("[Gemeinsam] Meldung: \(f.text)")
            fflush(nil)
            gemeinsamHinweis(f.text)
            // Die Tafel bleibt offen; ihr Knopf geht wieder.
            if let knopf = gemeinsam.tafelKnopf, let t = gemeinsam.tafel, t == offeneTafel {
                gtk_widget_set_sensitive(knopf, 1)
            }
        }
    }

    /// **Die Gruppe setzt einen Titel**: im offenen Player wechseln, sonst
    /// den Player öffnen. Derselbe Titel im offenen Player kommt hier nicht
    /// an — dahin springt die Sitzung selbst. `false`, wenn Titel oder Plan
    /// nicht zu holen sind.
    func gemeinsamTitelLaden(_ titelID: String, ab: Double) async -> Bool {
        let (client, grenze) = await aufHauptfadenHolen { (self.client, self.wahlen.profilBitrate) }
        guard let client else { return false }
        // Eigene Aufgaben statt `async let` (siehe ``nebenher(_:)``).
        let titelAbruf = nebenher { try? await client.item(id: titelID) }
        let planAbruf = nebenher {
            try? await client.playbackPlan(for: titelID, profile: .vlc(maxBitrate: grenze))
        }
        let titelGeholt = await titelAbruf.value
        let planGeholt = await planAbruf.value
        guard let titel = titelGeholt, let plan = planGeholt else { return false }
        await aufHauptfadenHolen {
            if self.gemeinsam.an, self.laufenderTitel != nil {
                // Im offenen Player wechseln, derselbe Weg wie eine Folge
                // aus der Folgenebene (iOS: `titelWechseln` → `zurNaechstenFolge`).
                self.wechsleZu(titel, ab: ab)
            } else {
                self.spielerOeffnen(titel, ab: ab, vorgeplant: plan, gruppe: true)
            }
            // **Erst danach**: `spielerOeffnen` schliesst einen alten Player
            // und vergisst dabei, was die Gruppe erwartet.
            self.gemeinsam.erwartet = titel.id
        }
        return true
    }

    // MARK: Aus dem Player

    /// Der Player ist offen und gehört zur Gruppe.
    func gemeinsamAnschliessen() {
        let s = gemeinsam.spieler ?? Gemeinsamspieler(app: self)
        gemeinsam.spieler = s
        gemeinsam.an = true
        gemeinsam.metastand = ""
        gemeinsamKette { await $0.anschliessen(s) }
    }

    /// Der Player geht zu. **Das ist das Verlassen** (Entwurf A).
    func gemeinsamAbtrennen() {
        gemeinsam.an = false
        gemeinsam.erwartet = nil
        gemeinsam.reglerZiel = nil
        gemeinsamKette { await $0.abtrennen() }
    }

    /// Anhalten und Weiter gehen als Bitte an den Server. Der Knopf springt
    /// erst um, wenn der Befehl zurückkommt — dann bei allen gleichzeitig.
    func gemeinsamBitteUmschalten(laeuftGerade: Bool) {
        let sitzung = gemeinsamSitzung
        Task.detached { await sitzung.bitteUmschalten(laeuftGerade: laeuftGerade) }
        steuerungZeigen()
    }

    func gemeinsamBitteSpringen(auf sekunden: Double) {
        let sitzung = gemeinsamSitzung
        Task.detached { await sitzung.bitteSpringen(auf: max(0, sekunden)) }
    }

    /// Folgenwahl im Player, in der Gruppe: für alle.
    func gemeinsamBitteTitel(_ titelID: String) {
        let sitzung = gemeinsamSitzung
        Task.detached { await sitzung.bitteTitel(titelID) }
    }

    /// Einmal je Takt des Players: Puffern melden.
    func gemeinsamTakt() {
        let sitzung = gemeinsamSitzung
        Task.detached { await sitzung.spielertakt() }
    }

    /// Ein Befehl der Gruppe hält an oder lässt laufen — Knopf und Kachel
    /// der Arbeitsumgebung ziehen mit.
    func gemeinsamLaufzustand(_ laeuft: Bool) {
        guard laufenderTitel != nil else { return }
        if laeuft { abspieler.abspielen() } else { abspieler.anhalten() }
        spielstand.laeuft = laeuft
        spielerAbspielzeichen?.setzen(laeuft)
        medienstandMelden()
    }

    // MARK: Anlegen

    /// „Gemeinsam schauen" für diesen Titel — eine Tafel an dem Knopf, der
    /// sie geöffnet hat (iOS: das Blatt in `Gemeinsamblaetter.anlegen`).
    func gemeinsamAnlegenZeigen(_ titel: Item, an knopf: Widget!) {
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(liste, 300, -1)
        gtk_widget_set_margin_start(liste, 12)
        gtk_widget_set_margin_end(liste, 12)
        gtk_widget_set_margin_top(liste, 8)
        gtk_widget_set_margin_bottom(liste, 8)

        let kopf = beschriftung(uebersetzt("Gemeinsam schauen"), stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(kopf), 0)
        anhaengen(liste, kopf)
        // Titel und Folge vom Server — wörtlich.
        let zeile = beschriftung(Self.gemeinsamTitelzeile(titel), stil: "swiftly-zweitzeile")
        gtk_widget_add_css_class(zeile, "dim-label")
        gtk_label_set_xalign(OpaquePointer(zeile), 0)
        gtk_label_set_ellipsize(OpaquePointer(zeile), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(zeile), 1)
        gtk_widget_set_margin_top(zeile, 2)
        gtk_widget_set_margin_bottom(zeile, 14)
        anhaengen(liste, zeile)

        let feldname = beschriftung(uebersetzt("Name der Gruppe"), stil: "swiftly-uebernahmezeile")
        gtk_label_set_xalign(OpaquePointer(feldname), 0)
        gtk_widget_set_margin_bottom(feldname, 6)
        anhaengen(liste, feldname)
        let feld: Widget! = gtk_entry_new()
        gtk_entry_set_placeholder_text(alsFeld(feld), uebersetzt("Filmabend"))
        gtk_editable_set_text(OpaquePointer(feld), uebersetzt("Filmabend"))
        gtk_widget_set_size_request(feld, -1, Int32(Stil.feldHoehe))
        gtk_widget_set_hexpand(feld, 1)
        beschriften(feld, uebersetzt("Name der Gruppe"))
        anhaengen(liste, feld)

        let hinweis = beschriftung(
            uebersetzt("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(hinweis, "dim-label")
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_label_set_max_width_chars(OpaquePointer(hinweis), 1)
        gtk_widget_set_margin_top(hinweis, 14)
        gtk_widget_set_margin_bottom(hinweis, 18)
        anhaengen(liste, hinweis)

        let haupt = hauptknopf(uebersetzt("Gruppe öffnen"), symbol: "system-users-symbolic")
        gtk_widget_set_size_request(haupt, -1, Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_halign(haupt, GTK_ALIGN_FILL)
        anhaengen(liste, haupt)

        let tafel = tafelOeffnen(an: knopf)
        gtk_popover_set_child(alsTafel(tafel), Skalierung.gehuellt(liste))
        gemeinsam.tafel = tafel
        gemeinsam.tafelKnopf = haupt
        let feldKiste = Zeigerkiste(feld)
        beiSignal(haupt, "clicked") { [weak self] in
            guard let self else { return }
            let name = String(cString: gtk_editable_get_text(OpaquePointer(feldKiste.widget)))
            gtk_widget_set_sensitive(self.gemeinsam.tafelKnopf, 0)
            let sitzung = self.gemeinsamSitzung
            Protokoll.schreib("[Gemeinsam] Gruppe anlegen fuer \(titel.id)")
            fflush(nil)
            Task.detached { [self] in
                await sitzung.anlegen(name: name, titel: titel.id, angenommen: {
                    await aufHauptfadenHolen { self.gemeinsamTafelZu() }
                })
            }
        }
        gtk_popover_popup(alsTafel(tafel))
        gtk_widget_grab_focus(feld)
    }

    // MARK: Beitreten und Auswahl

    /// Die Tafel zum Beitreten, am Abzeichen (iOS: `Gemeinsamblaetter.beitreten`).
    func gemeinsamBeitretenZeigen(_ g: SyncPlayGruppe, an knopf: Widget!) {
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_size_request(liste, 300, -1)
        gtk_widget_set_margin_start(liste, 12)
        gtk_widget_set_margin_end(liste, 12)
        gtk_widget_set_margin_top(liste, 8)
        gtk_widget_set_margin_bottom(liste, 8)

        // Name und Teilnehmer kommen vom Server — wörtlich.
        let kopf = beschriftung(g.name, stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(kopf), 0)
        gtk_label_set_ellipsize(OpaquePointer(kopf), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(kopf), 1)
        anhaengen(liste, kopf)
        let wer = beschriftung(gemeinsamWer(g), stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(wer, "dim-label")
        gtk_label_set_xalign(OpaquePointer(wer), 0)
        gtk_label_set_max_width_chars(OpaquePointer(wer), 1)
        gtk_widget_set_margin_top(wer, 2)
        anhaengen(liste, wer)
        if let zustand = Self.gemeinsamZustandText(g.zustand) {
            let z = beschriftung(zustand, stil: "swiftly-uebernahmezeile")
            gtk_widget_add_css_class(z, "swiftly-akzentschrift")
            gtk_label_set_xalign(OpaquePointer(z), 0)
            gtk_widget_set_margin_top(z, 6)
            anhaengen(liste, z)
        }
        let regel = beschriftung(uebersetzt("Pause und Springen gelten für alle."),
                                 stil: "swiftly-uebernahmezeile", umbruch: true)
        gtk_label_set_xalign(OpaquePointer(regel), 0)
        gtk_label_set_max_width_chars(OpaquePointer(regel), 1)
        gtk_widget_set_margin_top(regel, 10)
        gtk_widget_set_margin_bottom(regel, 18)
        anhaengen(liste, regel)

        let haupt = hauptknopf(uebersetzt("Beitreten"), symbol: "system-users-symbolic")
        gtk_widget_set_size_request(haupt, -1, Int32(Stil.hauptknopfHoehe))
        gtk_widget_set_halign(haupt, GTK_ALIGN_FILL)
        anhaengen(liste, haupt)

        let tafel = tafelOeffnen(an: knopf)
        gtk_popover_set_child(alsTafel(tafel), Skalierung.gehuellt(liste))
        gemeinsam.tafel = tafel
        gemeinsam.tafelKnopf = haupt
        beiSignal(haupt, "clicked") { [weak self] in
            guard let self else { return }
            gtk_widget_set_sensitive(self.gemeinsam.tafelKnopf, 0)
            self.gemeinsamBeitreten(g)
        }
        gtk_popover_popup(alsTafel(tafel))
    }

    private func gemeinsamBeitreten(_ g: SyncPlayGruppe) {
        let sitzung = gemeinsamSitzung
        Protokoll.schreib("[Gemeinsam] beitreten \(g.id)")
        fflush(nil)
        Task.detached { [self] in
            await sitzung.beitreten(g, angenommen: {
                await aufHauptfadenHolen { self.gemeinsamTafelZu() }
            })
        }
    }

    /// **Läuft woanders etwas und gibt es eine Gruppe**, fragt eine Tafel,
    /// was gemeint ist (iOS: `Gemeinsamblaetter.auswahl`): Geräte mit „Hier
    /// weiterschauen", Gruppen mit „Beitreten".
    func gemeinsamAuswahlZeigen(geraete: [Fremdsitzung], gruppen: [SyncPlayGruppe],
                                an knopf: Widget!) {
        let liste = stapel(GTK_ORIENTATION_VERTICAL, abstand: 2)
        gtk_widget_set_size_request(liste, 320, -1)
        let kopf = beschriftung(uebersetzt("Läuft gerade"), stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(kopf), 0)
        gtk_widget_set_margin_start(kopf, 12)
        gtk_widget_set_margin_top(kopf, 6)
        gtk_widget_set_margin_bottom(kopf, 4)
        anhaengen(liste, kopf)

        let tafel = tafelOeffnen(an: knopf)
        gtk_popover_set_child(alsTafel(tafel), Skalierung.gehuellt(liste))
        gemeinsam.tafel = tafel
        gemeinsam.tafelKnopf = nil
        for s in geraete {
            anhaengen(liste, gemeinsamAngebotszeile(
                symbol: geraetezeichen(s.geraeteart),
                titel: s.geraetename ?? uebersetzt("Gerät"), unter: s.titelzeile,
                handlung: uebersetzt("Hier weiterschauen")) { [weak self] in
                gtk_popover_popdown(alsTafel(tafel))
                self?.uebernehmen(s)
            })
        }
        for g in gruppen {
            anhaengen(liste, gemeinsamAngebotszeile(
                symbol: "system-users-symbolic", titel: g.name, unter: gemeinsamWer(g),
                handlung: uebersetzt("Beitreten")) { [weak self] in
                self?.gemeinsamBeitreten(g)
            })
        }
        Protokoll.schreib("[Gemeinsam] Auswahl mit \(geraete.count) Geraeten, \(gruppen.count) Gruppen")
        fflush(nil)
        gtk_popover_popup(alsTafel(tafel))
    }

    /// Zeichen, Name mit Zeile darunter, rechts die Handlung im Akzent —
    /// 58 hoch wie die Zeile im Blatt auf dem iPhone.
    private func gemeinsamAngebotszeile(symbol: String, titel: String, unter: String,
                                        handlung: String,
                                        tun: @escaping () -> Void) -> Widget! {
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-handlung")
        gtk_widget_add_css_class(knopf, "swiftly-angebotszeile")
        let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 14)
        let bild: Widget! = gtk_image_new_from_icon_name(symbol)
        gtk_image_set_pixel_size(OpaquePointer(bild), 16)
        gtk_widget_add_css_class(bild, "swiftly-akzentzeichen")
        gtk_widget_set_size_request(bild, 26, -1)
        anhaengen(reihe, bild)
        let text = stapel(GTK_ORIENTATION_VERTICAL, abstand: 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(text, 1)
        let oben = beschriftung(titel, stil: "swiftly-kacheltitel")
        gtk_label_set_xalign(OpaquePointer(oben), 0)
        gtk_label_set_ellipsize(OpaquePointer(oben), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(oben), 1)
        anhaengen(text, oben)
        let untenZeile = beschriftung(unter, stil: "swiftly-uebernahmezeile")
        gtk_label_set_xalign(OpaquePointer(untenZeile), 0)
        gtk_label_set_ellipsize(OpaquePointer(untenZeile), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(OpaquePointer(untenZeile), 1)
        anhaengen(text, untenZeile)
        anhaengen(reihe, text)
        let tat = beschriftung(handlung, stil: "swiftly-kacheltitel")
        gtk_widget_add_css_class(tat, "swiftly-akzentschrift")
        anhaengen(reihe, tat)
        gtk_button_set_child(alsKnopf(knopf), reihe)
        beschriften(knopf, "\(titel), \(unter), \(handlung)")
        beiSignal(knopf, "clicked", tun)
        return knopf
    }

    /// Die Tafel zu, weil der Server ja gesagt hat — nur, wenn es noch
    /// unsere ist.
    private func gemeinsamTafelZu() {
        if let t = gemeinsam.tafel, t == offeneTafel { gtk_popover_popdown(alsTafel(t)) }
        gemeinsam.tafel = nil
        gemeinsam.tafelKnopf = nil
    }

    // MARK: Im Player

    /// Kurz oben im Bild: wer kam, wer ging, warum der Film steht (iOS:
    /// `Gruppenereignis`). Nimmt keine Klicks.
    func gemeinsamEreignisBauen() -> Widget! {
        let huelle = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 10)
        gtk_widget_add_css_class(huelle, "swiftly-gruppenereignis")
        gtk_widget_set_halign(huelle, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(huelle, GTK_ALIGN_START)
        gtk_widget_set_margin_top(huelle, Playermass.oben + Playermass.knopf + 8)
        gtk_widget_set_can_target(huelle, 0)
        gtk_widget_set_opacity(huelle, 0)
        let bild: Widget! = gtk_image_new_from_icon_name("system-users-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(bild), 15)
        gtk_widget_add_css_class(bild, "swiftly-akzentzeichen")
        anhaengen(huelle, bild)
        let text = beschriftung("", stil: "swiftly-koerper")
        anhaengen(huelle, text)
        gemeinsam.ereignisHuelle = huelle
        gemeinsam.ereignisBild = bild
        gemeinsam.ereignisText = text
        gemeinsam.ereignisID = nil
        beiSignal(huelle, "destroy") { [weak self] in
            guard let self else { return }
            // Nur vergessen, wenn es noch dieser Hinweis ist — die neue
            // Spielerseite steht schon, wenn die alte abgeräumt wird.
            if self.gemeinsam.ereignisHuelle == huelle {
                self.gemeinsam.ereignisHuelle = nil
                self.gemeinsam.ereignisBild = nil
                self.gemeinsam.ereignisText = nil
            }
        }
        return huelle
    }

    private func gemeinsamEreignisZeigen() {
        guard let huelle = gemeinsam.ereignisHuelle else { return }
        guard inGruppe, let e = gemeinsam.lage.ereignis else {
            if gemeinsam.ereignisID != nil {
                gemeinsam.ereignisID = nil
                blenden(huelle, auf: 0, dauer: 0.2, kennlinie: .easeInOut)
            }
            return
        }
        guard e.id != gemeinsam.ereignisID else { return }
        gemeinsam.ereignisID = e.id
        gtk_image_set_from_icon_name(OpaquePointer(gemeinsam.ereignisBild), Self.gemeinsamZeichen(e.art))
        gtk_label_set_text(OpaquePointer(gemeinsam.ereignisText), e.text)
        beschriften(huelle, e.text)
        blenden(huelle, auf: 1, dauer: 0.2, kennlinie: .easeOut)
    }

    /// Das Zeichen je Hinweis — die Wahl trifft die Plattform, der Text
    /// kommt aus dem Paket. Namen gegen breeze-dark geprüft.
    static func gemeinsamZeichen(_ art: SyncPlayEreignis.Art) -> String {
        switch art {
        case .dabei, .gegangen: "system-users-symbolic"
        case .wartetAufAlle: "content-loading-symbolic"
        case .angehalten: "media-playback-pause-symbolic"
        case .gehtWeiter: "media-playback-start-symbolic"
        case .gesprungen: "media-seek-forward-symbolic"
        case .keinZugriff, .nichtAbspielbar: "dialog-warning-symbolic"
        }
    }

    /// „Filmabend · mit Paul und Tom" — wo sonst Staffel und Folge stehen
    /// (iOS: `Gruppenzeile`). Der Name trägt den Akzent: in einer Gruppe zu
    /// sein ist ein Zustand.
    func gemeinsamGruppenzeile(_ zeile: Widget!) -> Bool {
        guard inGruppe, let g = gemeinsam.lage.gruppe else { return false }
        let bild: Widget! = gtk_image_new_from_icon_name("system-users-symbolic")
        gtk_image_set_pixel_size(OpaquePointer(bild), Int32(Stil.zweitzeile + 1))
        gtk_widget_add_css_class(bild, "swiftly-akzentzeichen")
        anhaengen(zeile, bild)
        // Name und Teilnehmer vom Server — wörtlich.
        let name = beschriftung(g.name, stil: "swiftly-spielerzeile")
        gtk_widget_add_css_class(name, "swiftly-gruppenname")
        anhaengen(zeile, name)
        let wer = beschriftung("· " + gemeinsamMitWem, stil: "swiftly-spielerzeile")
        gtk_label_set_ellipsize(OpaquePointer(wer), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(OpaquePointer(wer), 0)
        anhaengen(zeile, wer)
        return true
    }

    private func gemeinsamMetazeileNachfuehren() {
        let stand = inGruppe ? "\(gemeinsam.lage.gruppe?.name ?? "")|\(gemeinsamMitWem)" : ""
        guard stand != gemeinsam.metastand else { return }
        gemeinsam.metastand = stand
        metazeileAuffrischen()
    }

    /// Die Spalte „Gemeinsam · Filmabend" in den Einstellungen des Players:
    /// wer dabei ist, und darunter der Ausgang. Die Namen tun nichts (iOS:
    /// `PlayerEbenen.swift:342-360`).
    func gemeinsamSpalte() -> Widget? {
        guard inGruppe, let g = gemeinsam.lage.gruppe else { return nil }
        return ebenenspalte(String(format: uebersetzt("Gemeinsam · %@"), g.name)) { raum in
            for name in g.teilnehmer {
                let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
                gtk_widget_add_css_class(reihe, "swiftly-teilnehmer")
                let bild: Widget! = gtk_image_new_from_icon_name("avatar-default-symbolic")
                gtk_image_set_pixel_size(OpaquePointer(bild), 14)
                gtk_widget_set_size_request(bild, 18, -1)
                gtk_widget_add_css_class(bild, "swiftly-sehrleise")
                anhaengen(reihe, bild)
                let l = beschriftung(name)
                gtk_label_set_xalign(OpaquePointer(l), 0)
                gtk_label_set_ellipsize(OpaquePointer(l), PANGO_ELLIPSIZE_END)
                gtk_label_set_max_width_chars(OpaquePointer(l), 1)
                gtk_widget_set_hexpand(l, 1)
                anhaengen(reihe, l)
                anhaengen(raum, reihe)
            }
            let knopf: Widget! = gtk_button_new()
            gtk_widget_add_css_class(knopf, "swiftly-ebenenzeile")
            gtk_widget_add_css_class(knopf, "swiftly-verlassen")
            let reihe = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 8)
            let bild: Widget! = gtk_image_new_from_icon_name("system-log-out-symbolic")
            gtk_image_set_pixel_size(OpaquePointer(bild), 14)
            gtk_widget_set_size_request(bild, 18, -1)
            anhaengen(reihe, bild)
            let l = beschriftung(uebersetzt("Gruppe verlassen"))
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_widget_set_hexpand(l, 1)
            anhaengen(reihe, l)
            gtk_button_set_child(alsKnopf(knopf), reihe)
            beschriften(knopf, uebersetzt("Gruppe verlassen"))
            // Verlassen heißt schliessen (Entwurf A).
            beiSignal(knopf, "clicked") { [weak self] in self?.spielerSchliessen() }
            anhaengen(raum, knopf)
        }
    }

    // MARK: Der Rückweg

    /// „Filmabend verlassen · Wieder beitreten" — Rückgängig statt
    /// Nachfrage, acht Sekunden lang (iOS: `Rueckwegstreifen`). Dieselbe
    /// Stelle wie jeder Hinweis: unten mittig, über allem.
    private func gemeinsamStreifenZeigen() {
        guard let alt = gemeinsam.lage.zuletztVerlassen else {
            if let s = gemeinsam.streifen {
                gtk_widget_set_can_target(s, 0)
                blenden(s, auf: 0, dauer: 0.2, kennlinie: .easeInOut)
            }
            return
        }
        let streifen = gemeinsam.streifen ?? gemeinsamStreifenBauen()
        guard let streifen else { return }
        gtk_label_set_text(OpaquePointer(gemeinsam.streifenText),
                           String(format: uebersetzt("%@ verlassen"), alt.name))
        gtk_widget_set_can_target(streifen, 1)
        blenden(streifen, auf: 1, dauer: 0.2, kennlinie: .easeOut)
    }

    private func gemeinsamStreifenBauen() -> Widget? {
        guard let decke = fensterdecke else { return nil }
        let streifen = stapel(GTK_ORIENTATION_HORIZONTAL, abstand: 12)
        gtk_widget_add_css_class(streifen, "swiftly-rueckweg")
        gtk_widget_set_halign(streifen, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(streifen, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(streifen, 34)
        gtk_widget_set_margin_start(streifen, 24)
        gtk_widget_set_margin_end(streifen, 24)
        gtk_widget_set_opacity(streifen, 0)
        let text = beschriftung("", stil: "swiftly-rueckwegtext")
        gtk_label_set_ellipsize(OpaquePointer(text), PANGO_ELLIPSIZE_END)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        anhaengen(streifen, text)
        let knopf: Widget! = gtk_button_new()
        gtk_widget_add_css_class(knopf, "swiftly-rueckwegknopf")
        gtk_button_set_child(alsKnopf(knopf), beschriftung(uebersetzt("Wieder beitreten")))
        beschriften(knopf, uebersetzt("Wieder beitreten"))
        beiSignal(knopf, "clicked") { [weak self] in
            guard let self else { return }
            let sitzung = self.gemeinsamSitzung
            Task.detached { await sitzung.wiederBeitreten() }
        }
        anhaengen(streifen, knopf)
        gtk_overlay_add_overlay(OpaquePointer(decke), streifen)
        gemeinsam.streifen = streifen
        gemeinsam.streifenText = text
        return streifen
    }

    // MARK: Fehler

    /// **Ein Fehler der Gruppe muss zu sehen sein, wo man gerade ist** — im
    /// Hauptfenster wie im Player. Derselbe Baustein wie ``melden(_:)``
    /// (`swiftly-hinweis`, drei Sekunden), nur über dem ganzen Fenster:
    /// `hinweisfeld` hängt an der Detailseite, und die ist nicht immer da.
    private func gemeinsamHinweis(_ text: String) {
        guard let decke = fensterdecke else { return }
        let feld: Widget
        if let da = gemeinsam.hinweis {
            feld = da
        } else {
            let neu: Widget! = beschriftung("", stil: "swiftly-hinweis", umbruch: true)
            gtk_label_set_max_width_chars(OpaquePointer(neu), 60)
            gtk_widget_set_halign(neu, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(neu, GTK_ALIGN_END)
            gtk_widget_set_margin_bottom(neu, 32)
            gtk_widget_set_margin_start(neu, 24)
            gtk_widget_set_margin_end(neu, 24)
            gtk_widget_set_can_target(neu, 0)
            gtk_overlay_add_overlay(OpaquePointer(decke), neu)
            gemeinsam.hinweis = neu
            feld = neu
        }
        gtk_label_set_text(OpaquePointer(feld), text)
        gtk_widget_set_visible(feld, 1)
        gtk_widget_set_opacity(feld, 1)
        gemeinsam.hinweistakt += 1
        let meins = gemeinsam.hinweistakt
        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            aufHauptfaden {
                guard self.gemeinsam.hinweistakt == meins, let feld = self.gemeinsam.hinweis
                else { return }
                sanft(auf: feld, von: 1, nach: 0) { gtk_widget_set_opacity(feld, $0) }
            }
        }
    }

    // MARK: Texte

    /// „mit Paul und Tom" — ohne einen selbst.
    var gemeinsamMitWem: String {
        guard let g = gemeinsam.lage.gruppe else { return "" }
        let andere = g.andere(als: benutzername.isEmpty ? nil : benutzername)
        guard !andere.isEmpty else { return uebersetzt("noch niemand dabei") }
        return String(format: uebersetzt("mit %@"), Self.gemeinsamListe(andere))
    }

    /// „Paul und Tom schauen gerade".
    func gemeinsamWer(_ g: SyncPlayGruppe) -> String {
        var gesehen = Set<String>()
        let namen = g.teilnehmer.filter { gesehen.insert($0).inserted }
        guard !namen.isEmpty else { return uebersetzt("Noch niemand dabei") }
        let liste = Self.gemeinsamListe(namen)
        return String(format: uebersetzt(namen.count == 1 ? "%@ schaut gerade" : "%@ schauen gerade"),
                      liste)
    }

    /// „Paul, Tom und Anna" in der Sprache der Oberfläche. `ListFormatter`
    /// gibt es auf Linux nicht, das Format der neuen Foundation schon.
    static func gemeinsamListe(_ namen: [String]) -> String {
        namen.formatted(.list(type: .and).locale(Locale(identifier: oberflaechenkatalog.sprache)))
    }

    /// Bei einer Folge die Serie mit Staffel und Folge — sonst weiß man in
    /// der Tafel nicht, welche Folge die Gruppe schauen wird.
    static func gemeinsamTitelzeile(_ titel: Item) -> String {
        guard titel.type == "Episode", let serie = titel.seriesName, !serie.isEmpty else {
            return titel.name
        }
        if let staffel = titel.parentIndexNumber, let folge = titel.indexNumber {
            return "\(serie) · " + String(format: uebersetzt("Staffel %lld · Folge %lld"), staffel, folge)
        }
        return "\(serie) · \(titel.name)"
    }

    static func gemeinsamZustandText(_ z: SyncPlayGruppe.Zustand?) -> String? {
        switch z {
        case .laeuft: uebersetzt("Läuft gerade")
        case .angehalten: uebersetzt("Angehalten")
        case .wartet: uebersetzt("Wartet auf alle")
        case .leer, nil: nil
        }
    }
}
