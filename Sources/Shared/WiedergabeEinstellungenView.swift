import JellyfinKit
import SwiftUI

/// Alles, was die Wiedergabe betrifft.
///
/// Bewusst getrennt von den Einstellungen: dort steht, was die App betrifft —
/// Darstellung und Server. Stünde Qualität an beiden Stellen, müsste man
/// raten, welche gilt.
struct WiedergabeEinstellungenView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var offeneListe: Liste?
    /// Welche Liste **gezeigt** wird — bleibt beim Schließen stehen.
    ///
    /// **Ohne das faehrt nichts hinaus.** Haengt der Inhalt an `offeneListe`,
    /// verschwindet er im selben Moment, in dem die Bewegung anfangen soll.
    /// SwiftUI hat dann nichts mehr zu bewegen und blendet.
    ///
    /// **Von Anfang an gesetzt, nicht erst beim ersten Öffnen.** Sonst würde
    /// die Karte beim ersten Mal im selben Zug eingehängt *und* geöffnet —
    /// und was gerade erst entsteht, kann nicht von unten hereinfahren. Mit
    /// einem Anfangswert hängt sie von Beginn an da, außerhalb des Bildes,
    /// und es wechselt nur noch `offeneListe`.
    @State private var gezeigteListe: Liste? = .ton

    private enum Liste: String, Identifiable {
        case bitrate, ton, untertitel, zurueck, vor, puffer
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Derselbe Grund wie jede andere Seite. Er war kurz ein eigener
            // (`gruppengrund`), weil reines Schwarz unter einer Karte die
            // ganze Strecke auf einmal war; seit der Grund #101010 ist,
            // betraegt der Sprung ein Fuenftel davon und braucht keine
            // Ausnahme mehr.
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
                // Titel neben dem Pfeil, nicht darunter — siehe
                // `EinstellungenView`.
                Unterseitenkopf(titel: String(localized: "Wiedergabe")) { zurueck() }
                ScrollView { inhalt }
                    .scrollIndicators(.hidden)
            }
            blatt
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            if breit {
                // **Null, seit die Gruppen Karten sind.** Jede Karte traegt links
                // und rechts schon `Stil.rand` — bei 56 dazwischen standen
                // 112 Punkt zwischen zwei Karten, und dafuer sind sie zu
                // schmal. Den Abstand tragen jetzt die Karten selbst.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        qualitaet
                        sprache
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    verhalten.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                qualitaet
                sprache
                verhalten
            }

        }
        .padding(.bottom, 40)
    }

    private var qualitaet: some View {
        // Wandelt der Server nicht um, ist nichts zu wählen: Direct Play steht
        // fest an, die Bitrate ist gesperrt.
        let frei = model.umwandelnErlaubt
        let directPlay = model.immerDirectPlay || !frei
        let waehlen: (() -> Void)? = directPlay ? nil : { oeffne(.bitrate) }

        return Einstellungsgruppe(titel: "Qualität") {
            Wahlzeile(symbol: "play.fill", titel: Text("Immer Direct Play"),
                      unter: Text("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                      an: Binding(get: { directPlay },
                                  set: { model.immerDirectPlay = $0 }))
                .disabled(!frei)
            Blattlinie()
            Wertzeile(symbol: "chart.bar", titel: Text("Höchste Bitrate"),
                      wert: Bitrate.text(model.bitratenGrenze),
                      gedimmt: directPlay, aktion: waehlen)
        }
    }

    private var sprache: some View {
        Einstellungsgruppe(titel: "Sprache") {
            Wertzeile(symbol: "speaker.wave.2", titel: Text("Ton"),
                      wert: model.tonSprache.isEmpty ? String(localized: "Wie die Datei") : model.tonSprache,
                      aktion: { oeffne(.ton) })
            Blattlinie()
            Wertzeile(symbol: "captions.bubble", titel: Text("Untertitel"),
                      wert: model.untertitelSprache.isEmpty ? String(localized: "Aus") : model.untertitelSprache,
                      aktion: { oeffne(.untertitel) })
            Blattlinie()
            Wahlzeile(symbol: "text.alignleft", titel: Text("Untertitel automatisch"),
                      unter: Text("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                      an: Binding(get: { model.untertitelAutomatisch },
                                  set: { model.untertitelAutomatisch = $0 }))
        }
    }

    @AppStorage("technikschild") private var technikschild = false

    private var verhalten: some View {
        Einstellungsgruppe(titel: "Verhalten") {
            Wahlzeile(symbol: "forward.end.fill", titel: Text("Nächste Folge automatisch"),
                      an: Binding(get: { model.naechsteAutomatisch },
                                  set: { model.naechsteAutomatisch = $0 }))
            Blattlinie()
            // **Der Schalter fuer das Technikschild.**
            //
            // Er steht hier bei „Verhalten" und nicht bei den Bildregeln: er
            // aendert nichts an der Wiedergabe, er zeigt nur, was sie tut.
            // Aus, bis ihn jemand sucht — wie bei Downloads und Seerr.
            Wahlzeile(symbol: "waveform.badge.magnifyingglass",
                      titel: Text("Technische Daten im Player"),
                      an: $technikschild)
            Blattlinie()
            Wertzeile(symbol: "gobackward", titel: Text("Zurückspulen"),
                      wert: "\(model.zurueckSekunden) s",
                      aktion: { oeffne(.zurueck) })
            Blattlinie()
            Wertzeile(symbol: "goforward", titel: Text("Vorspulen"),
                      wert: "\(model.vorSekunden) s",
                      aktion: { oeffne(.vor) })
            Blattlinie()
            // **Steht bei „Verhalten", nicht bei der Qualitaet.** Sie aendert
            // nichts am Bild — nur, wie viel Vorrat der Player haelt, bevor
            // eine wackelige Leitung durchschlaegt.
            Wertzeile(symbol: "wifi.exclamationmark", titel: Text("Puffer"),
                      wert: model.pufferstufe.name,
                      aktion: { oeffne(.puffer) })
        }
    }

    /// Blatt öffnen: erst den Inhalt setzen, **dann** zeigen — und zwar in
    /// zwei Durchgängen, nicht in einem.
    ///
    /// **Sonst misst sich die Karte, während sie schon fährt.** Beide Zeilen
    /// standen hier untereinander und landeten damit in derselben
    /// Aktualisierung: die Karte bekam ihren Inhalt und ihre Bewegung
    /// gleichzeitig. Ihre Höhe ist aber das, woran die Bewegung hängt — beim
    /// **ersten** Öffnen war sie null (es gab noch keinen Inhalt), und dann
    /// stand die Rubrik schon an ihrem Platz, während der Rest hineinfuhr.
    ///
    /// Danach fiel es nicht mehr auf, weil der vorige Inhalt stehen bleibt und
    /// die Höhe schon ungefähr stimmte. Beim Wechsel von einer langen auf eine
    /// kurze Liste wäre es wiedergekommen.
    ///
    /// Der `Task` schiebt das Zeigen um einen Durchgang: dazwischen wird die
    /// Karte einmal mit ihrem neuen Inhalt gemessen — geschlossen und
    /// unsichtbar. Das kostet einen Bildaufbau und nichts sonst.
    private func oeffne(_ liste: Liste) {
        gezeigteListe = liste
        Task { @MainActor in offeneListe = liste }
    }

    /// Schließen — und der Inhalt bleibt stehen, dauerhaft.
    ///
    /// **Kein Zeitgeber mehr.** Vorher wurde `gezeigteListe` nach 400 ms
    /// geleert; solange blieb unten ein Stück der Karte sichtbar und
    /// verschwand dann ruckartig. Die Karte wird jetzt nur verschoben, ist
    /// also draußen, sobald die Bewegung durch ist — abzuräumen gibt es
    /// nichts. Was bleibt, ist eine Liste im Speicher, und die kostet nichts.
    private func schliesseBlatt() {
        offeneListe = nil
    }

    /// **Ein Blatt, nicht fünf.**
    ///
    /// Hier stand ein `switch` über `gezeigteListe`, und jeder Fall baute ein
    /// eigenes `Auswahlblatt` — mit eigener Gattung (`Bitrate`, `Sprachwahl`,
    /// `Spanne`). Für SwiftUI sind das **verschiedene Ansichten**: beim
    /// Wechsel wird die alte ausgehängt und eine neue eingehängt, und die
    /// kommt mit `offen == true` zur Welt. Die Karte sitzt dann sofort an
    /// ihrem Platz, und das Auffahren fällt aus.
    ///
    /// Zu sehen war es genau dann, wenn man schnell genug war: schliessen,
    /// sofort das nächste antippen — dann fuhr nichts mehr hoch. War man
    /// langsam, stimmte es zufällig, weil die alte Ansicht schon draussen war
    /// und der Unterschied nicht auffiel.
    ///
    /// Dieselbe Regel wie „nie in ein `if offen`", nur als `switch`. Deshalb
    /// jetzt **ein** Blatt über einer gemeinsamen Zeile: die Kennung bleibt,
    /// es wechselt nur der Inhalt.
    private var blatt: some View {
        Auswahlblatt(offen: Binding(get: { offeneListe != nil },
                                    set: { if !$0 { schliesseBlatt() } }),
                     titel: blatttitel,
                     eintraege: blatteintraege,
                     beschriftung: { $0.text },
                     istGewaehlt: { $0.gewaehlt },
                     waehlen: { $0.tun() })
    }

    private var blatttitel: LocalizedStringKey {
        switch gezeigteListe {
        case .bitrate:    "Höchste Bitrate"
        case .ton:        "Ton"
        case .untertitel: "Untertitel"
        case .zurueck:    "Zurückspulen"
        case .vor:        "Vorspulen"
        case .puffer:     "Puffer"
        case nil:         ""
        }
    }

    private var blatteintraege: [Auswahleintrag] {
        switch gezeigteListe {
        case .bitrate:
            Bitrate.stufen.map { stufe in
                Auswahleintrag(id: "b\(stufe.wert)", text: Bitrate.text(stufe.wert),
                               gewaehlt: stufe.wert == model.bitratenGrenze) {
                    model.bitratenGrenze = stufe.wert
                }
            }
        case .puffer:
            Pufferstufe.allCases.map { stufe in
                Auswahleintrag(id: stufe.rawValue, text: stufe.name,
                               gewaehlt: stufe == model.pufferstufe) {
                    model.pufferstufe = stufe
                }
            }
        case .ton:
            Sprachwahl.alle.map { wahl in
                Auswahleintrag(id: "t\(wahl.wert)", text: wahl.name,
                               gewaehlt: wahl.name == model.tonSprache) {
                    model.tonSprache = wahl.wert
                }
            }
        case .untertitel:
            Sprachwahl.alle(aus: String(localized: "Aus")).map { wahl in
                Auswahleintrag(id: "u\(wahl.wert)", text: wahl.name,
                               gewaehlt: wahl.name == model.untertitelSprache) {
                    model.untertitelSprache = wahl.wert
                }
            }
        case .zurueck:
            Spanne.stufen.map { stufe in
                Auswahleintrag(id: "z\(stufe.wert)", text: "\(stufe.wert) s",
                               gewaehlt: stufe.wert == model.zurueckSekunden) {
                    model.zurueckSekunden = stufe.wert
                }
            }
        case .vor:
            Spanne.stufen.map { stufe in
                Auswahleintrag(id: "v\(stufe.wert)", text: "\(stufe.wert) s",
                               gewaehlt: stufe.wert == model.vorSekunden) {
                    model.vorSekunden = stufe.wert
                }
            }
        case nil:
            []
        }
    }



}


/// Eine Zeile in einem Auswahlblatt, unabhaengig davon, was sie waehlt.
///
/// **Damit es nur ein Blatt gibt.** Die fuenf Listen fuehren verschiedene
/// Gattungen; ohne eine gemeinsame Zeile waeren es fuenf verschiedene
/// Ansichten, und jeder Wechsel haenge die eine aus und die andere ein —
/// siehe `blatt`.
struct Auswahleintrag: Identifiable {
    let id: String
    let text: String
    let gewaehlt: Bool
    let tun: () -> Void
}

// MARK: - Zeilen

/// Zeile mit Schalter.
struct Wahlzeile: View {
    /// **Gesperrt heisst gedaempft.** `Wertzeile` nimmt `gedimmt` von aussen;
    /// hier stand die Sperre bislang fest auf `false`, und „Immer Direct
    /// Play" sah bedienbar aus, obwohl `.disabled` daran hing. Der Zustand
    /// kommt aus der Umgebung, damit das `.disabled` der Aufrufstelle reicht
    /// und keine zweite Angabe danebenstehen muss, die auseinanderlaufen kann.
    @Environment(\.isEnabled) private var bedienbar
    let symbol: String
    /// Bewusst `Text` und nicht `String` oder `LocalizedStringKey`: die
    /// Zeilen tragen mal eine feste Beschriftung — `Text("Sprache")`, wird
    /// übersetzt —, mal einen Wert vom Server wie den Servernamen, der
    /// unverändert bleiben muss (`Text(verbatim:)`). `Text` kann beides,
    /// zwei Erzeuger je Zeilentyp wären der umständlichere Weg zum selben.
    let titel: Text
    var unter: Text?
    @Binding var an: Bool

    var body: some View {
        Zeilenaufbau(symbol: symbol, titel: titel, unter: unter,
                     gedimmt: !bedienbar) {
            Schalter(an: $an)
        }
    }
}

/// Zeile mit Wert, wahlweise antippbar.
struct Wertzeile: View {
    let symbol: String
    let titel: Text
    var unter: Text?
    /// Der gewählte Wert — kommt teils vom Server (Sprachname), teils aus
    /// einer eigenen Liste. Bleibt deshalb eine Zeichenkette und wird dort
    /// übersetzt, wo er entsteht.
    var wert: String?
    var gedimmt = false
    var aktion: (() -> Void)?

    var body: some View {
        let rumpf = Zeilenaufbau(symbol: symbol, titel: titel, unter: unter,
                                 gedimmt: gedimmt) {
            HStack(spacing: 8) {
                if let wert {
                    Text(wert)
                        // Der Wert wächst mit wie der Titel daneben — sonst folgte die
                        // halbe Zeile der Systemschrift und die andere Hälfte nicht.
                        .mitwachsend(15)
                        .foregroundStyle(Stil.schriftLeise)
                }
                if aktion != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        // Siehe RootView: 28 Prozent sind 2,50:1.
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
        }
        if let aktion {
            Button(action: aktion) { rumpf }.buttonStyle(Stil.Druckknopf())
        } else {
            rumpf
        }
    }
}

/// Symbol, Text, rechts etwas.
struct Zeilenaufbau<Rechts: View>: View {
    @Environment(\.breit) private var breit
    let symbol: String
    let titel: Text
    var unter: Text?
    var gedimmt: Bool
    @ViewBuilder var rechts: () -> Rechts

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                // **Listenzeile: 15 Semifett.** 16 Regular war genauso laut
                // wie der Erklaertext darunter — der Name fuehrt, der Wert
                // folgt. Leiter in BRAND.md, Abschnitt 2.
                titel.mitwachsend(15, .semibold)
                    // **Gedaempft, nicht durchscheinend** (BRAND 5).
                    //
                    // Hier stand `Stil.schrift.opacity(0.4)` auf der ganzen
                    // Zeile. Zwei Schaeden in einem Wert: gerechnet sind das
                    // 3,57:1 auf `grund` — unter 4,5, und BRAND 1 fuehrt
                    // „weiss 40 %" namentlich als verboten. Und der innere
                    // `foregroundStyle` der Unterzeile gewinnt gegen den
                    // aeusseren, also wurde die Unterzeile **nicht** gedimmt
                    // und stand mit 5,58:1 heller da als ihr eigener Titel.
                    // Die Rangfolge kippte genau im gesperrten Zustand.
                    .foregroundStyle(gedimmt ? Stil.schriftSehrLeise : Stil.schrift)
                if let unter {
                    unter
                        .mitwachsend(12)
                        // Gesperrt tragen Titel und Unterzeile denselben Ton:
                        // der Abstand zwischen ihnen bleibt so erhalten,
                        // statt sich umzudrehen.
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            rechts()
        }
        // Das Symbol links und alles, was `rechts()` liefert, folgen dem
        // Zustand der Zeile; die Textspalte setzt sich ihren Ton selbst.
        .foregroundStyle(gedimmt ? Stil.schriftSehrLeise : Stil.schrift)
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

