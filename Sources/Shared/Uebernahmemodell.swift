import Foundation
import JellyfinKit
import Observation

/// Hält nach, ob auf einem anderen Gerät gerade etwas läuft.
///
/// **Warum ein eigener Halter und nicht ein `.task` in der Ansicht.** Die
/// Frage stellt sich auf allen vier Plattformen, das Abzeichen sieht überall
/// gleich aus, und die Regel dahinter steckt in ``Uebernahme`` im Paket. Was
/// hier liegt, ist nur das Abfragen im Takt — und das gehört nicht in eine
/// Ansicht, die bei jedem Neuzeichnen von vorn beginnen würde.
///
/// Wie ``Startseitenmodell`` und ``Bibliotheksmodell``.
@MainActor
@Observable
final class Uebernahmemodell {

    /// Alles, was übernommen werden kann — jüngste Regung zuerst.
    private(set) var angebote: [Fremdsitzung] = []
    /// Der letzte geschriebene Grund — damit dieselbe Auskunft nicht alle
    /// zehn Sekunden erneut im Protokoll steht.
    private var letzterGrund: String?

    /// Das erste davon, für den Fall, dass es nur eins gibt.
    var angebot: Fremdsitzung? { angebote.first }

    /// Mehr als eins? Dann fragt die Oberfläche, statt zu raten.
    var mehrereDa: Bool { angebote.count > 1 }

    /// Was schiefging — für eine Meldung in der Ansicht.
    var fehler: String?

    /// **Jemand hat auf das Abzeichen getippt.**
    ///
    /// Das Abzeichen steht seit dem 10.09.2026 in ``Kopfziele`` und damit auf
    /// jeder Wurzelseite — die Wiedergabe haengt aber an **einer** Stelle,
    /// in ``HauptView``. Ein Schalter hier ist der kurze Weg dazwischen:
    /// die Ansicht legt ihn um, wer den Player haelt, raeumt ihn ab. Eine
    /// Schliessung durch die Umgebung zu reichen waere derselbe Weg mit mehr
    /// Teilen.
    var angetippt = false

    /// Läuft die Übernahme gerade? Sperrt den Knopf, damit ein zweiter Druck
    /// nicht zwei Wiedergaben startet.
    private(set) var uebernimmt = false

    private var takt: Task<Void, Never>?

    /// **Fuenf Sekunden.**
    ///
    /// Hier standen zehn, mit der Begruendung, der Fortschrittsbericht der
    /// anderen Seite komme im selben Takt — schnelleres Fragen erfahre also
    /// nichts Neues. **Das stimmt fuer die Stelle, es stimmt aber nicht fuer
    /// den Fall, auf den es ankommt.**
    ///
    /// Wonach hier gesucht wird, ist nicht ein neuer Sekundenstand, sondern
    /// eine Sitzung, die es vorher **gar nicht gab**. Und die meldet sich
    /// beim Server sofort, wenn drueben jemand auf Abspielen drueckt — nicht
    /// im Zehnsekundentakt. Die ganze Wartezeit entstand also allein hier.
    /// Am 10.09.2026 als zu traege gemeldet, und zu Recht.
    ///
    /// Es bleibt eine Abfrage, die laeuft, solange jemand auf der Startseite
    /// steht; deshalb fuenf und nicht eine. Zwei Anfragen je zehn Sekunden
    /// sind fuer einen Heimserver nichts, zehn waeren eine Sorte Fleiss, die
    /// niemandem nuetzt.
    ///
    /// **Der richtige Weg ist ein zweiter Weg, nicht der Ersatz dieses
    /// einen.** Jellyfin schickt Sitzungsaenderungen von sich aus ueber den
    /// Steuerkanal, wenn man sie mit `SessionsStart` bestellt — dann stuende
    /// das Angebot sofort da. Hier stand zuerst, der Takt koenne dann
    /// entfallen; die Mac-Sitzung hat das noch in derselben Nacht
    /// zurechtgerueckt, und sie hat recht: **er wird zum Rueckfall.** Steht
    /// die Leitung, gilt, was sie meldet; steht sie nicht, fragt der Takt
    /// weiter.
    ///
    /// Sonst taeuscht man eine traege Anzeige gegen eine, die bei einem
    /// Abriss einfach stehenbleibt — und **das faellt niemandem auf, weil
    /// nichts fehlschlaegt.** Genau diese Sorte Fehler hat den 10.09. eine
    /// halbe Nacht gekostet.
    ///
    /// Ein Umbau darauf ist erst seit heute ueberhaupt pruefbar: vorher war
    /// der Steuerkanal stumm, und eine ausbleibende Meldung liess sich nicht
    /// von „nichts Neues" unterscheiden.
    static let taktsekunden: Double = 5

    func starten(_ model: AppModel) {
        guard takt == nil else { return }
        takt = Task { [weak self] in
            while !Task.isCancelled {
                await self?.einmalFragen(model)
                try? await Task.sleep(for: .seconds(Self.taktsekunden))
            }
        }
    }

    func beenden() {
        takt?.cancel()
        takt = nil
        angebote = []
    }

    private func einmalFragen(_ model: AppModel) async {
        // **Wer zusieht, fragt nicht.**
        //
        // Im Player kommt es aufs Bild an, und der Server haette alle fuenf
        // Sekunden eine Anfrage mehr zu beantworten. Vorher hing das an der
        // Startseite (`.task(id: abspielen == nil)`) und galt damit nur fuer
        // Wiedergaben, die dort begonnen haben. Hier gilt es fuer jede.
        guard !Spielstand.spielerLaeuft else { return }
        // `model.session` statt `client.currentSession()`: der Client ist ein
        // Aktor, die Sitzung liegt hier ohnehin schon auf dem Hauptakteur.
        guard let client = model.client,
              let benutzer = model.session?.userID else { angebote = []; return }
        let sitzungen: [Fremdsitzung]
        do {
            sitzungen = try await client.fremdsitzungen()
        } catch {
            // **Still nach aussen, laut im Protokoll.** Gefragt wird alle
            // zehn Sekunden; eine Fehlermeldung auf der Startseite waere
            // Laerm. Aber der Unterschied zwischen „nichts laeuft" und „die
            // Frage kam nicht an" muss irgendwo stehen, sonst sucht ihn beim
            // naechsten Mal wieder jemand von vorn.
            Protokoll.schreib("[Uebernahme] Abfrage fehlgeschlagen: \(error)")
            angebote = []
            return
        }
        angebote = Uebernahme.angebote(aus: sitzungen,
                                       eigeneGeraeteID: AppModel.deviceID,
                                       eigeneBenutzerID: benutzer)
        // **Warum nichts angeboten wird, muss ablesbar sein.** Fuenf Gruende
        // sehen von aussen gleich aus -- das Abzeichen fehlt schlicht. In der
        // ausgelieferten Fassung faellt das hier heraus.
        if angebote.isEmpty {
            let gruende = sitzungen.map { s in
                let wer = s.geraetename ?? s.programm ?? "?"
                let warum = Uebernahme.warumNicht(s, eigeneGeraeteID: AppModel.deviceID,
                                                  eigeneBenutzerID: benutzer) ?? "taugt"
                return "\(wer): \(warum)"
            }
            let zeile = "[Uebernahme] \(sitzungen.count) Sitzungen, kein Angebot"
                + (gruende.isEmpty ? "" : " — " + gruende.joined(separator: " · "))
            // **Nur bei Aenderung.** Gefragt wird alle zehn Sekunden, und die
            // Antwort ist fast immer dieselbe: „1 Sitzungen, kein Angebot —
            // Mac: wir selbst". Im Protokoll vom 22.09. stand die Zeile
            // dutzendfach im Sekundentakt und hat alles zugeschrieben, was
            // sonst darin zu lesen gewesen waere. Wer eine Auskunft so oft
            // wiederholt, macht sie unlesbar.
            if zeile != letzterGrund {
                letzterGrund = zeile
                Protokoll.schreib(zeile)
            }
        } else {
            letzterGrund = nil
        }
    }

    /// Das andere Gerät anhalten und hier weitermachen.
    ///
    /// **Erst drüben beenden, dann hier starten, und den Fehler nicht
    /// schlucken.** Läuft dort weiter, während hier dasselbe beginnt, stehen
    /// zwei Tonspuren im Raum und niemand versteht, warum. Geht es schief,
    /// wird hier deshalb gar nicht gestartet.
    ///
    /// **Beenden, nicht anhalten.** Pausiert bleibt die Verbindung zum Server
    /// offen, die Sitzung steht weiter in der Übersicht, und auf dem anderen
    /// Gerät liegt noch der Player über allem — man müsste ihn von Hand
    /// schließen.
    ///
    /// **Erst prüfen, ob hier etwas startet, dann drüben beenden** (Audit
    /// 16.09., T1-M7). Umgekehrt hielt der Fernseher an, und scheiterte
    /// danach der Plan, lief nirgends mehr etwas — ohne Meldung.
    ///
    /// **Die Stelle nach dem Beenden** (T1-N5): die Sitzungsabfrage hinkt bis
    /// zu zehn Sekunden nach. Das andere Gerät meldet beim Beenden seine
    /// genaue Stelle; die wird kurz abgewartet (`Uebernahme.startstelle`).
    ///
    /// - Returns: Titel, Stelle und Plan, oder `nil` samt Meldung. -
    /// Parameter sitzung: Welche übernommen werden soll. Bei mehreren hat die
    /// Oberfläche gefragt; bei einer ist es schlicht die eine.
    func uebernehmen(_ sitzung: Fremdsitzung,
                     model: AppModel) async -> (item: Item, ab: Double, plan: PlaybackPlan)? {
        guard let titel = sitzung.laeuft,
              let client = model.client, !uebernimmt else { return nil }
        uebernimmt = true
        defer { uebernimmt = false }

        async let planAbruf = model.plan(for: titel.id)
        async let gespeichertAbruf = model.item(id: titel.id)
        async let sitzungenAbruf = try? client.fremdsitzungen()
        guard let plan = await planAbruf else {
            let wo = model.serverName ?? String(localized: "dem Server")
            fehlerZeigen(String(localized: "Die Wiedergabe hat nicht geklappt. Von \(wo) kamen keine Daten zum Abspielen."),
                         model: model)
            return nil
        }
        let vorher = await gespeichertAbruf?.userData?.playbackPositionTicks
        // Die frischeste Stelle, die die Sitzung kennt — die aus dem Abzeichen
        // kann eine Abfrage alt sein.
        let frisch = await sitzungenAbruf?.first { $0.id == sitzung.id }?.stand?.stelle
        let sitzungsstelle = frisch ?? sitzung.stand?.stelle ?? 0

        do {
            try await client.fremdbefehl(.beenden, an: sitzung.id)
        } catch {
            fehlerZeigen(lesbarerFehler(error), model: model)
            return nil
        }

        // Auf den Stopp des anderen Geräts warten, höchstens anderthalb
        // Sekunden. Kommt nichts, gilt die Sitzungsstelle.
        var nachher: Int64?
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(250))
            let jetzt = await model.item(id: titel.id)?.userData?.playbackPositionTicks
            if jetzt != vorher { nachher = jetzt; break }
        }
        let ab = Uebernahme.startstelle(sitzung: sitzungsstelle, gespeichertVorher: vorher,
                                        gespeichertNachher: nachher)
        Protokoll.schreib("[Uebernahme] Sitzung \(Int(sitzungsstelle)) s, nach Stopp "
            + "\(nachher.map { String(Int(Double($0) / 10_000_000)) } ?? "—") s → ab \(Int(ab)) s")
        // Damit das Abzeichen nicht noch einen Takt lang stehenbleibt.
        angebote = []
        return (titel, ab, plan)
    }

    /// Bisher landete `fehler` nirgends — die Ansichten lesen ihn nicht.
    /// `errorMessage` zeigen sie an.
    private func fehlerZeigen(_ text: String, model: AppModel) {
        fehler = text
        model.errorMessage = text
    }

    /// Dasselbe, aber gleich als fertiger ``Abspielwunsch``.
    ///
    /// **Warum das hier steht und nicht in den Ansichten.** Diese sechs
    /// Zeilen standen zeichengleich in `Sources/tvOS/HauptView.swift` und
    /// `Sources/Shared/HomeView.swift` — von mir selbst, am selben
    /// Nachmittag, beim Übertragen der Übernahme von einer Plattform auf die
    /// andere. Byte für Byte identisch ist genau der Fall, vor dem CLAUDE.md
    /// warnt; die tvOS-Sitzung hat ihn im Tiefendurchgang gefunden.
    func wunsch(fuer sitzung: Fremdsitzung, model: AppModel) async -> Abspielwunsch? {
        guard let (titel, ab, plan) = await uebernehmen(sitzung, model: model) else { return nil }
        return Abspielwunsch(item: titel, plan: plan, startAt: ab)
    }
}

/// Wie eine fremde Sitzung benannt und bebildert wird.
///
/// **Geteilt, nicht je Plattform.** Fernseher, Telefon und Mac zeigen
/// dasselbe Abzeichen; eine zweite Fassung davon liefe innerhalb einer Woche
/// auseinander. Genau der Fall, den CLAUDE.md meint.
extension Fremdsitzung {
    /// „Game of Thrones · S1 E5" oder schlicht der Filmtitel.
    ///
    /// Serverdaten, also `String` und nicht `LocalizedStringKey`: sonst
    /// würde ein Filmtitel als Übersetzungsschlüssel nachgeschlagen.
    /// **Liegt jetzt im Paket** (``Fremdsitzung/titelzeile``). Sie hing hier
    /// und war fuer die Linux-Fassung unerreichbar; dort stand deshalb eine
    /// eigene, kuerzere Zusammensetzung.

    /// Das Symbol zum Geraet. **Welches Geraet** es ist, entscheidet
    /// ``Fremdsitzung/geraeteart`` im Paket — die Zuordnung darf nicht
    /// auseinanderlaufen. Welches *Zeichen* dafuer steht, bleibt Sache der
    /// Plattform: hier SF Symbols, auf Linux Adwaita.
    var geraetezeichen: String {
        switch geraeteart {
        case .telefon:   "iphone"
        case .tablet:    "ipad"
        case .rechner:   "laptopcomputer"
        case .fernseher: "tv"
        case .unbekannt: "play.tv"
        }
    }
}

