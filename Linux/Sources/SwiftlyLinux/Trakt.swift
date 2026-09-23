import CGtk
import Foundation
import JellyfinKit

/// **Trakt auf Linux und Windows** — dieselbe Anbindung wie auf Apple
/// (`Sources/Shared/Traktkonto.swift`), mit derselben Logik aus dem Paket
/// (`TraktClient`, `Traktmelder`). Hier steht nur Ablage, Seite und die
/// Aufrufe aus dem Spieler.
///
/// **Ohne `Trakt.json` im Bau gibt es nichts davon** — keine Zeile in den
/// Einstellungen, kein Melder. Die Datei liegt nicht im Repo; siehe
/// `TraktZugang` im Paket.
final class Traktlage: @unchecked Sendable {
    let client: TraktClient? = TraktZugang.ausPaket.map { TraktClient(zugang: $0) }

    /// Je Jellyfin-Konto ein Zugang, wie auf Apple — was die Kinder sehen,
    /// gehört nicht in den Verlauf der Eltern. Nur auf dem Hauptfaden.
    var tokens: [String: TraktToken] = Traktlage.lesen()

    /// Der Stand der Anmeldeseite. Nur auf dem Hauptfaden.
    var code: TraktGeraetecode?
    var codeBis = Date.distantPast
    var fehler: String?
    var holt = false
    var vorgang: Task<Void, Never>?
    /// „Läuft ab in 9:58" — vergisst sich selbst, wenn GTK es abräumt.
    var restfeld: Widget?

    lazy var melder: Traktmelder? = client.map { client in
        Traktmelder(
            client: client,
            geaendert: { neu, kennung in
                guard let kennung else { return }
                aufHauptfaden { traktlage.merken(neu, konto: kennung) }
            },
            protokoll: { zeile in Protokoll.schreib("[Trakt] " + zeile) })
    }

    var verfuegbar: Bool { client != nil }

    func merken(_ neu: TraktToken?, konto: String) {
        tokens[konto] = neu
        Traktlage.schreiben(tokens)
    }

    // MARK: Ablage

    /// **Neben der Sitzung, mit denselben Rechten** (Datei 0600) — dieselbe
    /// Abwägung wie beim Seerr-Zugang in `Speicher.swift`: ein Schlüsselbund
    /// kostete hier eine neue Abhängigkeit.
    private static var datei: URL {
        Plattform.einstellungsordner.appendingPathComponent("trakt.json")
    }

    private static func lesen() -> [String: TraktToken] {
        guard let daten = try? Data(contentsOf: datei) else { return [:] }
        return (try? JSONDecoder().decode([String: TraktToken].self, from: daten)) ?? [:]
    }

    private static func schreiben(_ tokens: [String: TraktToken]) {
        guard !tokens.isEmpty else {
            try? FileManager.default.removeItem(at: datei)
            return
        }
        do {
            try FileManager.default.createDirectory(at: Plattform.einstellungsordner,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(tokens).write(to: datei, options: [.atomic])
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: datei.path)
            #endif
        } catch {
            Protokoll.schreib("[Trakt] Zugang ließ sich nicht sichern: \(error.localizedDescription)")
        }
    }
}

let traktlage = Traktlage()

extension App {

    private var traktkonto: String? { bund?.aktives.kontoschluessel }
    private var traktToken: TraktToken? { traktkonto.flatMap { traktlage.tokens[$0] } }

    // MARK: Wiedergabe — neben den Meldungen an Jellyfin

    /// Der Token geht vor jedem Start mit durch die Reihe — so gilt nach
    /// einem Kontowechsel sofort der richtige, ohne eigenen Haken im Wechsel.
    func traktStart(_ client: JellyfinClient, titel: Item, ticks: Int64) {
        guard let melder = traktlage.melder else { return }
        let token = traktToken
        melder.tokenSetzen(token, kennung: traktkonto)
        guard token != nil else { return }
        melder.melden(.start(titelID: titel.id,
                             ziel: { await TraktZiel.aufloesen(titel, client: client) },
                             stelle: Double(ticks) / 10_000_000,
                             dauer: titel.runtimeSeconds ?? 0))
    }

    func traktLaufzustand(laeuft: Bool, stelle: Double) {
        traktlage.melder?.melden(.laufzustand(laeuft: laeuft, stelle: stelle))
    }

    func traktSprung(auf stelle: Double) {
        traktlage.melder?.melden(.sprung(stelle: stelle))
    }

    func traktStopp(titel: Item, ticks: Int64) {
        traktlage.melder?.melden(.stopp(titelID: titel.id, stelle: Double(ticks) / 10_000_000))
    }

    // MARK: Einstellungen

    /// Die Zeile unter Seerr — nur mit Zugangsdaten im Bau.
    func traktZeile(_ raum: Widget!) {
        guard traktlage.verfuegbar else { return }
        let da = traktToken != nil
        anhaengen(raum, zeilenstrich())
        anhaengen(raum, wertezeile(symbol: "object-select-symbolic",
                                   titel: "Trakt",
                                   unter: uebersetzt("Trägt ein, was du schaust"),
                                   wert: da ? uebersetzt("Verbunden") : nil,
                                   pfeil: !da) { [weak self] in
            self?.unterseiteOeffnen(.trakt)
        })
    }

    /// Die Seite — derselbe Aufbau wie auf dem Mac
    /// (`Sources/macOS/TraktEinstellungenView.swift`): Kopf, Erklärung,
    /// dann „Verbunden" oder der Weg dorthin, darunter der Hinweis aufs
    /// Plugin.
    func traktSeiteBauen(_ block: Widget!) {
        let kopf = unterseitenkopf("Trakt")
        gtk_widget_set_margin_bottom(kopf, 10)
        anhaengen(block, kopf)
        // **Wer die Seite verlaesst, bricht das Nachfragen ab** — sonst fragte
        // die App zehn Minuten lang weiter. Beim Neuaufbau derselben Seite
        // wird der Kopf auch abgeraeumt; dann steht sie danach wieder offen.
        beiSignal(kopf, "destroy") {
            aufHauptfaden { if app.offeneUnterseite != .trakt { app.traktAbbrechen() } }
        }

        let text = beschriftung(
            uebersetzt("Swiftly meldet an Trakt, was du schaust. Ab 80 Prozent steht der Titel dort als gesehen."),
            stil: "swiftly-koerper", umbruch: true)
        gtk_widget_add_css_class(text, "dim-label")
        gtk_label_set_xalign(OpaquePointer(text), 0)
        anhaengen(block, text)

        if let token = traktToken {
            let g = einstellungsgruppe(uebersetzt("Verbunden"))
            gtk_widget_set_margin_top(g.aussen, 26)
            anhaengen(g.raum, wertezeile(symbol: "network-transmit-receive-symbolic",
                                         titel: token.benutzer ?? "Trakt",
                                         wert: uebersetzt("Aktiv")))
            anhaengen(g.raum, zeilenstrich())
            // „Trennen", nicht „Abmelden" — wie bei Seerr.
            anhaengen(g.raum, wertezeile(symbol: "window-close-symbolic",
                                         titel: uebersetzt("Verbindung trennen")) { [weak self] in
                self?.traktTrennen()
            })
            anhaengen(block, g.aussen)
        } else {
            traktAnmeldeteil(block)
        }

        let hinweis = beschriftung(
            uebersetzt("Hat dein Server das Trakt-Plugin, brauchst du das hier nicht. Sonst landet alles doppelt bei Trakt."),
            stil: "swiftly-zweitzeile", umbruch: true)
        gtk_widget_add_css_class(hinweis, "swiftly-sehrleise")
        gtk_label_set_xalign(OpaquePointer(hinweis), 0)
        gtk_widget_set_margin_top(hinweis, 14)
        anhaengen(block, hinweis)
    }

    private func traktAnmeldeteil(_ block: Widget!) {
        let teil = stapel(GTK_ORIENTATION_VERTICAL, abstand: 0)
        gtk_widget_set_margin_top(teil, 26)
        anhaengen(block, teil)

        if let code = traktlage.code {
            let satz = beschriftung(String(format: uebersetzt("Geh auf %@ und gib diesen Code ein."),
                                           code.adresseKurz),
                                    stil: "swiftly-koerper", umbruch: true)
            gtk_label_set_xalign(OpaquePointer(satz), 0)
            anhaengen(teil, satz)

            let feld = beschriftung(code.nutzercode, stil: "swiftly-codegross")
            gtk_label_set_selectable(OpaquePointer(feld), 1)
            gtk_widget_set_halign(feld, GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(feld, 1)
            gtk_widget_set_margin_top(feld, 16)
            anhaengen(teil, feld)

            let rest = beschriftung("", stil: "swiftly-zweitzeile")
            gtk_widget_add_css_class(rest, "swiftly-sehrleise")
            gtk_label_set_xalign(OpaquePointer(rest), 0)
            gtk_widget_set_margin_top(rest, 10)
            anhaengen(teil, rest)
            traktlage.restfeld = rest
            // Nur vergessen, wenn es noch dieses Feld ist — beim Neuaufbau
            // steht womoeglich schon das naechste drin.
            let kiste = Zeigerkiste(rest)
            beiSignal(rest, "destroy") {
                if traktlage.restfeld == kiste.widget { traktlage.restfeld = nil }
            }
            traktRestZeigen()

            // Mit dem Code in der Adresse — dann muss nichts abgetippt werden.
            let oeffnen = hauptknopf(uebersetzt("Trakt öffnen"), symbol: "go-next-symbolic")
            gtk_widget_set_margin_top(oeffnen, 20)
            let ziel = code.direktadresse
            beiSignal(oeffnen, "clicked") { imBrowser(ziel) }
            anhaengen(teil, oeffnen)
            return
        }

        if traktlage.holt {
            let l = beschriftung(uebersetzt("Hole Code…"), stil: "swiftly-koerper")
            gtk_widget_add_css_class(l, "dim-label")
            gtk_label_set_xalign(OpaquePointer(l), 0)
            anhaengen(teil, l)
            return
        }

        if let fehler = traktlage.fehler {
            let l = beschriftung(fehler, stil: "swiftly-zweitzeile", umbruch: true)
            gtk_widget_add_css_class(l, "swiftly-warnung")
            gtk_label_set_xalign(OpaquePointer(l), 0)
            gtk_widget_set_margin_bottom(l, 20)
            anhaengen(teil, l)
        }
        let knopf = hauptknopf(traktlage.fehler == nil ? uebersetzt("Mit Trakt verbinden")
                                                       : uebersetzt("Neuer Code"),
                               symbol: "object-select-symbolic")
        beiSignal(knopf, "clicked") { [weak self] in self?.traktVerbinden() }
        anhaengen(teil, knopf)
    }

    private func traktRestZeigen() {
        guard let feld = traktlage.restfeld else { return }
        let sekunden = max(0, Int(traktlage.codeBis.timeIntervalSinceNow))
        let text = String(format: uebersetzt("Läuft ab in %d:%02d"), sekunden / 60, sekunden % 60)
        gtk_label_set_text(OpaquePointer(feld), text)
    }

    /// Nur neu bauen, wenn die Seite noch offen ist — wer weitergeklickt
    /// hat, soll nicht zurückgeholt werden.
    private func traktSeiteAuffrischen() {
        guard offeneUnterseite == .trakt else { return }
        unterseiteOeffnen(.trakt, schub: .ohne)
    }

    private func traktVerbinden() {
        guard let client = traktlage.client, let konto = traktkonto else { return }
        traktlage.vorgang?.cancel()
        traktlage.code = nil
        traktlage.fehler = nil
        traktlage.holt = true
        traktSeiteAuffrischen()
        traktlage.vorgang = Task.detached { [self] in
            do {
                let code = try await client.geraetecode()
                aufHauptfaden {
                    traktlage.holt = false
                    traktlage.code = code
                    traktlage.codeBis = Date().addingTimeInterval(code.gueltig)
                    self.traktSeiteAuffrischen()
                }
                // Der Sekundentakt für „Läuft ab in" — endet mit dem Vorgang.
                let takt = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        aufHauptfaden { self.traktRestZeigen() }
                    }
                }
                defer { takt.cancel() }
                var neu = try await client.freigabeAbwarten(code)
                neu.benutzer = await client.benutzername(neu)
                let fertig = neu
                guard !Task.isCancelled else { return }
                aufHauptfaden {
                    traktlage.merken(fertig, konto: konto)
                    traktlage.code = nil
                    if self.traktkonto == konto {
                        traktlage.melder?.tokenSetzen(fertig, kennung: konto)
                    }
                    self.traktSeiteAuffrischen()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let text = Self.traktText(error)
                aufHauptfaden {
                    traktlage.holt = false
                    traktlage.code = nil
                    traktlage.fehler = text
                    self.traktSeiteAuffrischen()
                }
            }
        }
    }

    /// Beim Verlassen der Seite: nicht zehn Minuten weiterfragen.
    func traktAbbrechen() {
        traktlage.vorgang?.cancel()
        traktlage.vorgang = nil
        traktlage.code = nil
        traktlage.holt = false
        traktlage.fehler = nil
    }

    private func traktTrennen() {
        guard let konto = traktkonto else { return }
        let alt = traktlage.tokens[konto]
        traktlage.merken(nil, konto: konto)
        traktlage.melder?.tokenSetzen(nil, kennung: konto)
        if let alt, let client = traktlage.client {
            Task.detached { await client.widerrufen(alt) }
        }
        traktSeiteAuffrischen()
    }

    private static func traktText(_ fehler: any Error) -> String {
        switch fehler as? TraktFehler {
        case .codeAbgelaufen: uebersetzt("Der Code ist abgelaufen. Hol dir einen neuen.")
        case .abgelehnt:      uebersetzt("Trakt hat die Verbindung nicht freigegeben.")
        case .ratenlimit:     uebersetzt("Trakt bremst gerade. Versuch es in ein paar Minuten noch mal.")
        default:              uebersetzt("Trakt ist gerade nicht erreichbar.")
        }
    }
}
