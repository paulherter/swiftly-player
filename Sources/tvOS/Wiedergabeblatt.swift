import JellyfinKit
import SwiftUI
import VLCKit

/// Die Einstellungen zur laufenden Wiedergabe — hinter dem Knopf oben rechts.
///
/// **Eine Achse statt zwei.** Die Fassung davor war Apples Muster fürs
/// iPhone im Querformat: drei Listen nebeneinander. Am Finger stimmt das, man
/// tippt direkt hin. Auf der Fernbedienung heißt es, erst quer zwischen
/// Spalten zu wandern und dann in jeder senkrecht zu suchen, ohne dass
/// irgendwo steht, welche Spalte was ist.
///
/// Jetzt ist alles links–rechts: eine Reihe Kategorien, darunter eine Reihe
/// Karten. Runter, seitlich, drücken — dieselbe Bewegung wie überall sonst in
/// der App.
///
/// Und das Blatt sitzt im unteren Drittel statt über dem ganzen Schirm: wer
/// die Tonspur wechselt, will nicht das Bild verlieren.
struct Wiedergabeblatt: View {
    let flaeche: VLCPlayerView
    let plan: PlaybackPlan
    let titel: String
    @Binding var offen: Bool
    @Binding var tempo: Float
    @Binding var schlafminuten: Int?

    @State private var kategorie: Kategorie = .untertitel
    /// Eigener Stand statt `isSelected`: VLC zieht die Auswahl erst einen
    /// Takt später nach, und die Anzeige hinge sonst hinterher.
    @State private var untertitelWahl: String??
    @State private var tonWahl: String?
    @FocusState private var amChip: Kategorie?
    /// Die Zaehler, im selben Takt nachgefuehrt wie der Player selbst.
    @State private var zaehler: Spielwerte?


    enum Kategorie: String, CaseIterable, Identifiable {
        case untertitel, ton, tempo, schlafzeit, technik
        var id: String { rawValue }
        var name: LocalizedStringKey {
            switch self {
            case .untertitel: "Untertitel"
            case .ton:        "Ton"
            case .tempo:      "Tempo"
            case .schlafzeit: "Schlafzeit"
            case .technik:    "Technik"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45).ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: Stil.grund.opacity(0), location: 0),
                .init(color: Stil.grund.opacity(0.86), location: 0.22),
                .init(color: Stil.grund, location: 0.46),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 560)
            .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                Text(titel)
                    .font(Stil.knopf)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(1)

                HStack(spacing: 16) {
                    ForEach(Kategorie.allCases) { k in
                        Button(k.name) { kategorie = k }
                            .buttonStyle(ChipStil(an: kategorie == k))
                            .focused($amChip, equals: k)
                    }
                }
                .focusSection()
                .padding(.top, 24)

                karten
                    .padding(.top, 34)

                beleg
                    .padding(.top, 34)
            }
            .padding(.horizontal, Stil.randSeite)
            .padding(.bottom, Stil.randOben)
        }
        // **Der Fokus gehoert auf den offenen Abschnitt.**
        //
        // Ohne das nimmt tvOS den letzten Knopf der Reihe: das Blatt zeigte
        // „Untertitel", der Zeiger stand auf „Schlafzeit". Zwei Aussagen an
        // derselben Stelle, und die falsche war die auffaellige.
        .task { amChip = kategorie }
        // **Nur zaehlen, solange jemand hinsieht.** Der Auszug fragt VLC im
        // halben Sekundentakt -- derselbe Takt wie `Wiedergabetakt`, und aus
        // demselben Grund: schneller sieht man nur Flackern, langsamer
        // verpasst man den Ruckler. Steht der Chip woanders, laeuft die
        // Schleife nicht.
        .task(id: kategorie) {
            guard kategorie == .technik else { return }
            while !Task.isCancelled {
                zaehler = Spielwerte(flaeche.statistik)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onExitCommand { offen = false }
    }

    // MARK: Karten

    @ViewBuilder
    private var karten: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 24) {
                switch kategorie {
                case .untertitel:
                    Wahlkarte(name: String(localized: "Aus"), marke: nil,
                              an: untertitelJetzt == nil) {
                        untertitelWahl = .some(nil)
                        flaeche.waehleUntertitel(nil)
                    }
                    // **Kennung ist `trackId`, nicht die Position.**
                    //
                    // VLC gibt bei jedem Lesen frische `Track`-Objekte
                    // heraus, und nach einer Spurwahl sind die alten tot.
                    // Über die Position gekennzeichnet hält SwiftUI die Zeile
                    // für unverändert, behält den alten Rückruf — und der
                    // greift auf ein totes Objekt zu. Genau daraus wurde
                    // „beide angehakt und kein Weg zurück". Steht so seit
                    // Langem in `PlayerSettings` der iPhone-Fassung.
                    ForEach(flaeche.untertitelspuren, id: \.trackId) { spur in
                        Wahlkarte(name: spur.trackName,
                                  marke: format(spur.trackName),
                                  an: untertitelJetzt == spur.trackName) {
                            untertitelWahl = .some(spur.trackName)
                            flaeche.waehleUntertitel(spur)
                        }
                    }

                case .ton:
                    ForEach(flaeche.tonspuren, id: \.trackId) { spur in
                        Wahlkarte(name: spur.trackName, marke: nil,
                                  an: tonJetzt == spur.trackName) {
                            tonWahl = spur.trackName
                            flaeche.waehleTonspur(spur)
                        }
                    }

                case .tempo:
                    ForEach(Tempostufen.werte, id: \.self) { stufe in
                        Wahlkarte(name: Tempostufen.beschriftung(stufe), marke: nil,
                                  an: abs(tempo - stufe) < 0.01) {
                            tempo = stufe
                            flaeche.tempo = stufe
                        }
                    }

                case .schlafzeit:
                    Wahlkarte(name: String(localized: "Aus"), marke: nil,
                              an: schlafminuten == nil) { schlafminuten = nil }
                    ForEach(Schlafzeiten.werte, id: \.self) { minuten in
                        Wahlkarte(name: String(localized: "\(minuten) Minuten"), marke: nil,
                                  an: schlafminuten == minuten) { schlafminuten = minuten }
                    }

                // **Werte, keine Wahl.** Deshalb `Wertfeld` und nicht
                // `Wahlkarte`: nichts hiervon laesst sich druecken, und eine
                // Karte, die aussieht wie die vier daneben, verspraeche das.
                // Aus demselben Grund ist die Reihe hier nicht fokussierbar.
                case .technik:
                    if let z = zaehler {
                        Wertfeld(titel: "Verworfen", wert: "\(z.verworfen)",
                                 warnung: z.verworfen > 0)
                        Wertfeld(titel: "Zu spät", wert: "\(z.zuSpaet)",
                                 warnung: z.zuSpaet > 0)
                        Wertfeld(titel: "Gezeigt", wert: "\(z.gezeigt)")
                        Wertfeld(titel: "Ton verloren", wert: "\(z.tonVerloren)",
                                 warnung: z.tonVerloren > 0)
                        Wertfeld(titel: "Eingang", wert: z.eingang)
                        Wertfeld(titel: "Demuxer", wert: z.demuxer)
                        Wertfeld(titel: "Bild entschlüsselt", wert: "\(z.videoBloecke)")
                        Wertfeld(titel: "Ton entschlüsselt", wert: "\(z.tonBloecke)")
                    } else {
                        Wertfeld(titel: "Zähler", wert: String(localized: "Noch nichts"))
                    }

                    // **Die Zaehler zuerst, die Herkunftsangaben dahinter.**
                    //
                    // Sie standen vorn, weil sie beim Suchen nach dem
                    // Sprungfehler die wichtigsten waren. Fuer den taeglichen
                    // Blick ist es umgekehrt: wer den Reiter oeffnet, will
                    // wissen, ob Bilder verlorengehen. Paul: „ich hab jetzt
                    // glaube ich dropped frames aber kann es nicht sehen
                    // wegen den ganzen Sachen die davor stehen."
                    // **Steht vor den Zaehlern, weil es die Frage davor
                    // beantwortet.** „Es ruckelt, aber nichts fehlt" ist keine
                    // Sache der Zaehler, sondern der Ausgabekadenz — siehe
                    // `Bildtakt`. Ohne diese Zeile sieht man dem Bild nicht
                    // an, ob der Fernseher mitgeschaltet hat.
                    Wertfeld(titel: "Ausgang", wert: ausgangzeile,
                             warnung: !Bildtakt.erlaubt)
                    // **Direct Play und Direct Stream sind nicht dasselbe.**
                    //
                    // Der Haken unten zeigt beide gleich, weil beide das Bild
                    // unangetastet lassen. Beim Direct Stream packt der Server
                    // den Behaelter aber live um — der Anlauf dauert, und
                    // Spulen wird zaeh. Wer nur den Haken sieht, sucht den
                    // Fehler im Player.
                    Wertfeld(titel: "Auslieferung", wert: plan.method.rawValue,
                             warnung: plan.method != .directPlay)
                    // Ohne `mkv_trusted` verwirft VLC 4 den Index der Datei
                    // und ein Sprung landet am Dateianfang. Siehe `oeffnen`.
                    Wertfeld(titel: "MKV-Index", wert: behaelterzeile,
                             warnung: istMkv && !flaeche.matroskaVertraut)
                    // **Die Zahl, an der sich „zu langsam" entscheidet.**
                    //
                    // Direct Play heisst: die Datei muss in Echtzeit ueber die
                    // Leitung. Schafft der Weg vom Server ihre Bitrate nicht,
                    // laeuft der Puffer leer — egal wie richtig alles andere
                    // eingestellt ist. Daneben steht „Eingang", was wirklich
                    // ankommt. Liegt der deutlich darunter, ist die Ursache
                    // gefunden und sie liegt nicht im Player.
                    Wertfeld(titel: "Datei braucht", wert: bedarfzeile,
                             warnung: false)
                }
            }
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .frame(height: 150)
        .focusSection()
    }

    /// Mittlere Bitrate der Datei — Groesse geteilt durch Laufzeit.
    ///
    /// Ohne neues Serverfeld: beides steht schon in der Quelle. Der Wert ist
    /// ein Mittel, Spitzen liegen darueber — genau die lassen den Puffer
    /// leerlaufen.
    private var bedarfzeile: String {
        let dauer = flaeche.durationSeconds
        guard let bytes = plan.quelle?.size, bytes > 0, dauer > 1 else {
            return String(localized: "Unbekannt")
        }
        let bitProSekunde = Double(bytes) * 8 / dauer
        let text = bitProSekunde >= 1_000_000
            ? String(format: "%.1f Mbit/s", bitProSekunde / 1_000_000)
            : String(format: "%.0f kbit/s", bitProSekunde / 1_000)
        return text.replacingOccurrences(of: ".", with: ",") + " Ø"
    }

    private var istMkv: Bool {
        let namen = ["mkv", "matroska", "webm", "mka", "mks"]
        let behaelter = (plan.quelle?.container ?? "").lowercased()
        return namen.contains { behaelter.contains($0) }
    }

    /// Behälter der Datei, Endung der ausgelieferten Adresse, und ob der
    /// MKV-Kniff gegriffen hat — die drei Angaben, aus denen sich die
    /// Entscheidung nachrechnen lässt.
    private var behaelterzeile: String {
        guard istMkv else { return String(localized: "kein Matroska") }
        let endung = plan.url.pathExtension.lowercased()
        let adresse = endung.isEmpty ? String(localized: "ohne Endung") : "." + endung
        let kniff = flaeche.matroskaVertraut
            ? String(localized: "vertraut")
            : String(localized: "MISSTRAUT")
        return "\(kniff) · \(adresse)"
    }

    /// Was der Fernseher aus der Bildrate der Datei gemacht hat.
    ///
    /// Drei Faelle, und der mittlere ist der, den Paul treffen kann: die
    /// Anpassung ist am Geraet abgeschaltet. Dann steht die Rate zwar fest,
    /// aber der Ausgang bleibt auf 60 Hz und das Bild judert weiter.
    private var ausgangzeile: String {
        // **VLCs Wert, nicht der des Servers.**
        //
        // Umgeschaltet wird auf die Angabe des Servers, weil die frueh genug
        // da ist. Angezeigt wird, was VLC im Strom vorfindet — sonst zeigte
        // die Zeile bei falschen Metadaten denselben falschen Wert, auf den
        // wir hereingefallen sind, und der Fehler bliebe unsichtbar.
        let gemessen = Bildtakt.rate(von: flaeche.player)
        let behauptet = plan.quelle.flatMap(Dateiangaben.videospur)?.bildrate
        guard let rate = gemessen ?? behauptet else {
            return String(localized: "Unbekannt")
        }
        let text = String(format: "%.3f", rate)
            .replacingOccurrences(of: ".", with: ",")
        // **`maximumFramesPerSecond` ist der Grundtakt, nicht der laufende.**
        //
        // Ich hatte die Zahl als Beweis danebengestellt: „angepasst" sei nur
        // Absicht, erst der Schirmtakt zeige, ob der Fernseher es getan hat.
        // Paul las darauf „23,976 fps · angepasst · 50 Hz" — ein Widerspruch,
        // den es nicht gibt: der Wechsel hatte stattgefunden, aber die
        // Auskunft folgt dem Inhaltsmodus nicht, sie nennt das eingestellte
        // Format. Als Beweis taugt sie also nicht, als Grundtakt schon — und
        // genau dagegen rechnet `passt`, was weiterhin richtig ist.
        //
        // Steht hier eine Zahl, die nicht aufgeht, kostet dieser Titel ein
        // Schwarzbild. Das ist die Auskunft, die man wirklich braucht.
        let grund = " · " + String(localized: "Grundtakt") + " \(Bildtakt.schirmtakt)"
        guard gemessen != nil else {
            return text + " " + String(localized: "fps · laut Server") + grund
        }
        if let ziel = Bildtakt.angefordert {
            let zielText = String(format: "%.0f", ziel)
            return text + " " + String(localized: "fps → \(zielText) Hz") + grund
        }
        switch Bildtakt.stand {
        case .bereit:       return text + " " + String(localized: "fps · ohne Wechsel") + grund
        case .abgeschaltet: return text + " " + String(localized: "fps · Anpassung aus") + grund
        case .unerreichbar: return text + " " + String(localized: "fps · Anzeige stumm") + grund
        }
    }

    /// Eine Aussage, keine Auswahl — deshalb Fußzeile und keine Spalte.
    /// Nebeneinander mit Auswahllisten sah es aus, als könnte man es drücken.
    private var beleg: some View {
        HStack(spacing: 12) {
            Belegzeile(direktplay: plan.isLossless,
                       hinweis: plan.isLossless ? nil : plan.method.rawValue)
            if let text = dateizeile {
                Text("· " + text)
                    .font(.system(size: 27))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
        }
    }

    /// Container, Bild und Ton in einer Zeile — Formulierungen aus
    /// `Dateiangaben`, geteilt mit dem iPhone.
    private var dateizeile: String? {
        guard let quelle = plan.quelle else { return nil }
        var teile: [String] = []
        if let behaelter = quelle.container { teile.append(behaelter.uppercased()) }
        if let video = Dateiangaben.videospur(quelle) {
            teile.append(Dateiangaben.video(video, quelle))
        }
        if let ton = Dateiangaben.tonspuren(quelle).first { teile.append(ton.kurz) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    // MARK: Was gerade gilt

    private var untertitelJetzt: String? {
        if let wahl = untertitelWahl { return wahl }
        return flaeche.gewaehlterUntertitel?.trackName
    }

    private var tonJetzt: String? {
        tonWahl ?? flaeche.gewaehlteTonspur?.trackName
    }

    /// Ausgeschrieben statt gerechnet — eine erste Fassung schnitt Nullen per
    /// Zeichenkette weg und machte aus „0,75" ein „,75".
    /// Das Untertitelformat aus dem Spurnamen ziehen, wenn es dort steht.
    ///
    /// Nicht Zierde: `DeviceProfile` muss jedes Format als `Embed` oder
    /// `External` führen, sonst brennt der Server es ins Bild und
    /// transkodiert. Wer sieht, dass eine Spur PGS ist, versteht auch, warum
    /// ausgerechnet sie den Beleg kippen kann.
    private func format(_ name: String) -> String? {
        let bekannt = ["SRT", "ASS", "SSA", "PGS", "VTT", "SUB", "DVBSUB"]
        let gross = name.uppercased()
        return bekannt.first { gross.contains($0) }
    }
}

/// VLCs Zaehlwerk, uebersetzt.
///
/// **Warum das ueberhaupt jemand sehen will:** diese App transkodiert nie.
/// Ob das gutgeht, sieht man einer Wiedergabe nicht an — ein Bild, das
/// stockt, und ein Bild, das still Einzelbilder wegwirft, sehen aus drei
/// Metern gleich aus. `verworfen` ist der Unterschied. Steht dort eine Null,
/// laeuft die Datei wirklich glatt; steigt sie waehrend des Zusehens, ist
/// die Datei zu schwer fuer das Geraet, und zwar unabhaengig davon, was der
/// Server meldet.
///
/// Die Rohwerte sind kumulativ seit Beginn der Wiedergabe, nicht pro
/// Sekunde — deshalb steht hier auch nichts von „pro Sekunde".
struct Spielwerte {
    let verworfen: UInt64
    let zuSpaet: UInt64
    let gezeigt: UInt64
    let tonVerloren: UInt64
    let videoBloecke: UInt64
    let tonBloecke: UInt64
    /// Bitraten kommen als Byte pro Sekunde in `Float` — hier gleich als
    /// Text, damit die Umrechnung an einer Stelle steht.
    let eingang: String
    let demuxer: String

    init?(_ roh: VLCMedia.Stats?) {
        guard let roh else { return nil }
        // **Hat VLC die Struktur gar nicht gefuellt, kommt Speicherschrott.**
        //
        // `statistics` liefert sie auch dann, wenn das Medium noch keine hat;
        // die Felder stehen dann auf dem, was zufaellig im Speicher lag. Paul
        // sah „Millionen verworfene Frames und Trilliarden gezeigte". Eine
        // Milliarde Bilder waeren bei 60 Hz ueber ein halbes Jahr am Stueck —
        // was darueber liegt, ist keine Messung.
        let grenze: UInt64 = 1_000_000_000
        guard roh.displayedPictures < grenze, roh.lostPictures < grenze,
              roh.latePictures < grenze, roh.decodedVideo < grenze,
              roh.decodedAudio < grenze, roh.lostAudioBuffers < grenze
        else { return nil }
        verworfen    = roh.lostPictures
        zuSpaet      = roh.latePictures
        gezeigt      = roh.displayedPictures
        tonVerloren  = roh.lostAudioBuffers
        videoBloecke = roh.decodedVideo
        tonBloecke   = roh.decodedAudio
        eingang      = Spielwerte.rate(roh.inputBitrate)
        demuxer      = Spielwerte.rate(roh.demuxBitrate)
    }

    /// VLC misst in Byte je Sekunde. Mal acht sind Bit, und ab einem Mbit
    /// schreibt sich das lesbarer in Mbit/s.
    private static func rate(_ bytesProSekunde: Float) -> String {
        let bit = Double(bytesProSekunde) * 8
        if bit <= 0 { return "—" }
        if bit >= 1_000_000 {
            return String(format: "%.1f Mbit/s", bit / 1_000_000)
        }
        return String(format: "%.0f kbit/s", bit / 1_000)
    }
}

/// Ein abgelesener Wert im Technik-Auszug.
///
/// Sieht der `Wahlkarte` bewusst **nicht** gleich: keine Fokusflaeche, kein
/// Druck, kein Haken. Wer eine Zahl anfassen will, soll gar nicht erst
/// hinlangen.
///
/// Der Akzent bleibt aussen vor (E2) — eine auffaellige Zahl ist eine
/// Warnung, keine Auswahl, und traegt deshalb `Stil.warnung`.
struct Wertfeld: View {
    let titel: LocalizedStringKey
    let wert: String
    var warnung = false

    @Environment(\.isFocused) private var fokus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel)
                .font(.system(size: 25))
                .foregroundStyle(Stil.schriftSehrLeise)
                .lineLimit(1)
            Text(wert)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(warnung ? Stil.warnung : Stil.schrift)
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(.horizontal, 28)
        .frame(height: 130, alignment: .leading)
        .background(fokus ? Stil.fokusflaeche : Stil.flaeche,
                    in: RoundedRectangle(cornerRadius: Stil.ecke))
        // **Fokussierbar, obwohl es keine Taste ist.**
        //
        // Auf dem Fernseher scrollt eine Reihe nur, wenn der Fokus in ihr
        // wandern kann. Die Technikreihe ist inzwischen laenger als der
        // Schirm, und ohne das kam man an die hinteren Felder nicht heran —
        // Paul: „man kann ja nicht durch scrollen bei Technik". Ein
        // fokussierbares Feld ohne Aktion ist harmlos; angetippt passiert
        // nichts.
        .focusable()
        .animation(Stil.fokusAnimation, value: fokus)
        // Eine Zahl ist keine Taste — VoiceOver soll sie als Wertepaar
        // vorlesen, nicht als Bedienelement anbieten (E8).
        .accessibilityElement(children: .combine)
    }
}

/// Eine Karte in der Werte-Reihe.
struct Wahlkarte: View {
    let name: String
    let marke: String?
    let an: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.system(size: 29, weight: an ? .semibold : .medium))
                        .foregroundStyle(an ? Stil.akzent : Stil.schrift)
                        .lineLimit(1)
                    if let marke {
                        Text(marke)
                            .font(Stil.plakette)
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
                Spacer(minLength: 0)
                // Der Haken bleibt Akzent, auch wenn die Karte den Fokus hat
                // — Auswahl und Fokus sind zwei verschiedene Aussagen.
                if an {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .frame(width: 380, height: 130, alignment: .leading)
            .padding(.horizontal, 26)
        }
        .buttonStyle(KartenStil())
        // Haken und Akzentfarbe sagen, was gewaehlt ist — beides stumm.
        .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
    }
}

/// Fokus auf einer Wahlkarte: die ruhige Fläche, wie bei Zeilen und Chips.
struct KartenStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .background(fokus ? Stil.fokusflaeche : Stil.flaeche,
                            in: RoundedRectangle(cornerRadius: Stil.ecke))
                .scaleEffect(fokus ? 1.04 : 1)
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}
