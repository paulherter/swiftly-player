import JellyfinKit
import SwiftUI

/// Das Technikschild über dem laufenden Bild — **die Auskunft, die einen
/// Fehlerbericht brauchbar macht.**
///
/// **Warum es ein Schild ist und kein Reiter.** Vorher standen dieselben
/// Zahlen als Reiter „Technik" im Wiedergabeblatt. Das ist die falsche Form
/// für die Frage, die sie beantworten: „läuft es gerade rund?" ist keine
/// Frage, die man einmal stellt, sondern eine, der man beim Laufen zusieht.
/// Ein Blatt verdeckt das Bild und geht wieder zu; man liest eine Zahl,
/// schliesst, sieht wieder Ruckeln und weiss nicht, ob die Zahl dazu gehörte.
/// Streamyfin loest es als bleibendes Schild, und aus demselben Grund.
///
/// **Es nimmt keine Eingaben.** `allowsHitTesting(false)` steht an der
/// Aufrufstelle, nicht hier — das Schild ist eine Auskunft, kein Bedienteil,
/// und es darf der Steuerung darunter nichts wegnehmen. Auf dem Fernseher
/// gilt dasselbe für den Fokus.
///
/// **Oben links, und zwar immer.** Unten liegen überall die Steuerung und der
/// Regler, rechts oben auf iPhone und iPad der Schliessen-Knopf. Oben links
/// ist die einzige Ecke, die in allen vier Playern frei ist — und ein Schild,
/// das je nach Gerät woanders sitzt, muss man suchen.
///
/// **Was darauf steht, und was nicht mehr** (22.09.2026, „viel zu riesig").
/// Das Schild war mit jeder Messung eine Zeile länger geworden, bis es am
/// Telefon quer fast das ganze Bild deckte. Sichtbar bleibt jetzt nur, was
/// ein Zuschauer wissen will: wie der Server ausliefert und warum, was für
/// Bild, Ton und Untertitel, wie gross und dicht die Datei ist, und ob der
/// Puffer reicht. Alles, was nur beim Suchen eines Fehlers hilft — Takt,
/// Stelle, Matroska-Kniff, Dekoder- und Zeigezähler, Schirmfrequenz —, steht
/// nur im Messmodus (`technikschildMessen`, siehe dort).
///
/// **Die Kernzeilen stehen immer, gekappt wird nur der Rest.** Kopf, Grund,
/// Bild, Ton, Untertitel, Datei und Puffer tragen `kern()` und stehen, egal
/// wie hoch sie werden — ein langer Grund wird gekürzt, nicht weggelassen.
/// Was darüber hinausgeht (verlorene Bilder), nimmt `Kappliste` nur, solange
/// `hoechstanteil` der angebotenen Höhe reicht. Vorher galt die Kappung für
/// alle Zeilen, und am iPhone quer fielen bei einer Umrechnung Ton und
/// Puffer weg (Paul, 22.09.2026: „vielleicht fehlen Infos"). Kein Scrollen:
/// das Schild nimmt keine Eingaben, also könnte auch niemand scrollen.
struct Technikschild: View {
    /// Was der Server ausliefert und warum — die wichtigste Zeile.
    let plan: PlaybackPlan
    /// Was VLC beim Laufen zählt. `nil`, solange nichts gemessen ist.
    let werte: Spielwerte?
    /// Die Abspielflaeche — fuer Laufzeit, Stelle und den Matroska-Kniff.
    /// Alles, was nur der Player weiss und der Server nicht.
    var flaeche: VLCPlayerView?
    /// Wie gross das Schild insgesamt ausfällt. Der Fernseher wird aus drei
    /// Metern gelesen, das iPhone aus dreissig Zentimetern.
    var fern = false
    /// Gemessene Bildwiederholrate des Schirms, nur auf iOS gefuellt.
    var schirmHertz: Double?

    /// **Der Messmodus: alle Zeilen, ohne Höchsthöhe.**
    ///
    /// Kein Schalter in den Einstellungen — das ist Werkzeug für die Suche
    /// nach einem Fehler, nicht für Zuschauer. Gesetzt wird er als
    /// Startargument (`-technikschildMessen YES`), am Mac auch mit
    /// `defaults write`. Nur `#if DEBUG` reichte nicht: auf die Testgeräte
    /// kommen Debug-Bauten, und dort sollte das Schild genauso schlank sein
    /// wie bei allen anderen.
    @AppStorage("technikschildMessen") private var messen = false

    /// Bis hierhin dürfen Zusatzzeilen das Schild verlängern — die
    /// Kernzeilen zählen mit, stehen aber auch darüber hinaus.
    ///
    /// **Gerechnet, nicht geschätzt** (iPhone quer, 390 pt hoch): unter der
    /// Titelzeile bleiben dem Schild gut 275 pt, 55 % davon sind 152. Die
    /// sieben Kernzeilen brauchen bei 12 pt Schrift und 4 pt Abstand 120 pt,
    /// mit zweizeiligem Grund und umbrechender Bildzeile 154 — dann fällt die
    /// Verlustzeile weg, die Kernzeilen nicht. Mit 0,4 (110 pt) war schon der
    /// Normalfall ohne Verlustzeile zu lang. Am Fernseher (1080, 24 pt,
    /// 7 pt Abstand) bleiben gut 740 pt; die Kernzeilen brauchen höchstens 305.
    static let hoechstanteil: CGFloat = 0.55

    private var quelle: MediaSource? { plan.quelle }
    private var video: MediaStream? { quelle.flatMap(Dateiangaben.videospur) }
    private var ton: MediaStream? { quelle.flatMap(Dateiangaben.tonspuren)?.first }
    private var untertitel: MediaStream? {
        quelle.flatMap(Dateiangaben.untertitelspuren)?.first
    }

    private var abstand: CGFloat { fern ? 7 : 4 }

    var body: some View {
        Kappliste(abstand: abstand, anteil: messen ? nil : Self.hoechstanteil) {
            kopfzeile.kern()

            // Der Grund steht direkt unter dem Wort, nicht am Ende: wer
            // „Transkodiert" liest, will als Nächstes wissen, woran es lag.
            // Zwei Zeilen reichen für Art und Codec; der Rest der Klammer
            // darf gekürzt werden, ausserhalb des Messmodus.
            if plan.method == .transcode, let grund = plan.reasons.first {
                Text(verbatim: grund.text).foregroundStyle(Stil.warnung)
                    .lineLimit(messen ? nil : 2)
                    .kern()
            }

            if let b = bildzeile { angabe(String(localized: "Bild"), b).kern() }
            if let t = tonzeile { angabe(String(localized: "Ton"), t).kern() }
            if let u = untertitelzeile { angabe(String(localized: "Untertitel"), u).kern() }
            if let d = dateizeile { angabe(String(localized: "Datei"), d).kern() }

            if let werte {
                pufferzeile(werte).kern()
                // Ausserhalb des Messmodus nur, wenn etwas verloren ging —
                // dann ist es die Antwort auf „warum ruckelt das?".
                if messen || verlust(werte) { verlustzeile(werte) }
            }

            if messen {
                if let m = matroskazeile { messzeile(m, auffaellig: false) }
                if let z = zeitzeile { messzeile(z, auffaellig: false) }
                #if os(tvOS)
                taktzeile
                #endif
                if let werte {
                    // **Eine Haarlinie, kein Abstand.** Was darüber steht,
                    // beschreibt die Datei; was darunter steht, zählt beim
                    // Laufen hoch.
                    Rectangle().fill(Stil.rand)
                        .frame(width: fern ? 260 : 150, height: 1)
                        .padding(.vertical, abstand / 2)

                    messzeile("\(String(localized: "Demuxer")) \(werte.demuxer)", auffaellig: false)
                    zeigtzeile(werte)
                    laufzeile(werte)
                    schirmzeile()
                    dekodierzeile(werte)
                    stromzeile(werte)
                }
            }
        }
        .clipped()
        // **Die Leiter statt eigener Grade, und Ziffern statt Monospace.**
        // Vorher stand das ganze Schild in einem Monospace-Schnitt mit eigenen
        // Zahlen (12/24). Der Schnitt macht jede Zeile ein Fünftel breiter, und
        // bei fester Breite heisst breiter: öfter zwei Zeilen. Gleich breite
        // Ziffern reichen, damit die Zähler beim Hochzählen nicht zittern.
        .font(Stil.klein.monospacedDigit())
        .foregroundStyle(Stil.schrift)
        // **Eine feste Breite, sonst laeuft die laengste Zeile hinaus.**
        //
        // Ein `VStack` in einer Auflage bekommt so viel Platz, wie er will —
        // und die Zeile mit den drei Zaehlern ist die laengste. Sie stand auf
        // dem Fernseher halb ausserhalb des Schildes. Mit einer Breite bricht
        // sie um, statt zu fliehen. Die Höhe reicht `Kappliste` durch: sie
        // braucht die angebotene, um die Höchsthöhe daraus zu nehmen.
        .frame(width: fern ? 420 : 260, alignment: .leading)
        .padding(.horizontal, fern ? 20 : 12)
        .padding(.vertical, fern ? 16 : 10)
        .background {
            // Deckend, nicht durchscheinend: das Schild liegt über bewegtem
            // Bild, und über bewegtem Bild ist jede Transparenz mal lesbar
            // und mal nicht. Dieselbe Entscheidung wie bei den Leisten.
            // **0,88 statt 0,82.** Die kritischste Farbe auf dem Schild ist
            // `warnung` (#E8833A), und die trug auf 0,82 über einem weißen
            // Bild nur 4,38:1 — Grenze 4,5. Mit 0,88 sind es 5,40:1.
            RoundedRectangle(cornerRadius: fern ? Stil.eckeKlein : Stil.ecke, style: .continuous)
                // 0,78 wie die Kachelmarke und der Haken auf der Folgenzeile
                // — dieselbe Aufgabe, dieselbe Zahl. Vorher 0,88.
                .fill(Stil.grund.opacity(0.78))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Zeilen

    /// Die Auslieferungsart, und sie ist die einzige farbige Zeile.
    ///
    /// Direct Play und Direct Stream stehen gleich da — beide sind
    /// verlustfrei, und die Unterscheidung interessiert nur, wer sie sucht.
    /// Nur die Umrechnung faellt auf, weil sie das eine ist, was diese App zu
    /// vermeiden verspricht.
    private var kopfzeile: some View {
        Text(verbatim: Technikangaben.auslieferung(plan.method))
            // Eine Stufe über den Zeilen, halbfett: Bold steht genau einmal,
            // am Seitentitel.
            .font(Stil.kachel.weight(.semibold))
            .foregroundStyle(Technikangaben.gewicht(plan.method) == .gut
                             ? Stil.akzent : Stil.warnung)
    }

    /// Codec, Auflösung und HDR-Art in einer Zeile.
    ///
    /// **Welche HDR-Art die Datei trägt** (Nutzerwunsch, 22.09.2026): HDR10,
    /// HDR10+, Dolby Vision mit Profil, HLG oder SDR. Das Format der Datei,
    /// nicht der Ausgang — ob das Gerät HDR ausgibt oder VLC auf SDR abbildet,
    /// weiß hier niemand zuverlässig (`Technikangaben.dynamik`). Die Bildrate
    /// steht nur im Messmodus: sie erklärt Ruckeln am Schirmtakt, und das ist
    /// eine Frage für die Fehlersuche.
    private var bildzeile: String? {
        let teile = [
            Technikangaben.codecname(video?.codec),
            Technikangaben.bildzeile(breite: video?.width, hoehe: video?.height,
                                     tiefe: nil, umfang: nil),
            Technikangaben.dynamik(video),
            messen ? Technikangaben.bildrate(video?.bildrate).map { "\($0) fps" } : nil
        ].compactMap { $0 }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    private var tonzeile: String? {
        guard let name = Technikangaben.codecname(ton?.codec) else { return nil }
        var text = name
        if let k = Technikangaben.kanalwort(ton?.channels) { text += " · \(k)" }
        if let sprache = Technikangaben.sprache(ton?.language) { text += " · \(sprache)" }
        return text
    }

    private var untertitelzeile: String? {
        guard let name = Technikangaben.codecname(untertitel?.codec) else { return nil }
        var text = name
        if let sprache = Technikangaben.sprache(untertitel?.language) { text += " · \(sprache)" }
        return text
    }

    /// Container, Grösse und was die Datei im Mittel braucht.
    ///
    /// **`Dateiangaben.container` bringt die Groesse schon mit.** Hier stand
    /// zusaetzlich `groesse(quelle)`, und weil auch die mit ihrem eigenen
    /// Trennzeichen kommt, las man auf dem Schild „Datei MP4 · 0,3 GB ·  ·
    /// 0,3 GB". Zwei Bausteine, die beide mehr tun, als ihr Name sagt — und
    /// ich habe sie addiert, statt einen zu lesen.
    ///
    /// **Die mittlere Bitrate steht hier und nicht mehr als eigene Zeile**
    /// („Datei braucht"): Groesse geteilt durch Laufzeit. Neben dem Eingang
    /// in der Pufferzeile sagt sie, ob der Strom nachkommt. Spitzen liegen
    /// ueber dem Mittel; wer knapp darueber liegt, hat trotzdem ein Problem.
    private var dateizeile: String? {
        guard let quelle, let c = Dateiangaben.container(quelle) else { return nil }
        guard let rate = Technikangaben.bitrate(bytesJeSekunde.map { $0 * 8 }) else { return c }
        return "\(c) · Ø \(rate)"
    }

    /// Groesse durch Laufzeit. `nil`, solange eins davon fehlt.
    private var bytesJeSekunde: Double? {
        guard let bytes = quelle?.size, bytes > 0,
              let dauer = flaeche?.durationSeconds, dauer > 1 else { return nil }
        return Double(bytes) / dauer
    }

    /// **Wie viel Vorrat vor der Nadel liegt, und was ankommt.**
    ///
    /// VLC nennt keine Puffersekunden, aber es zaehlt beides, was man dafuer
    /// braucht: was aus dem Netz kam und was der Demuxer davon schon
    /// verbraucht hat. Die Differenz, geteilt durch das, was die Datei je
    /// Sekunde braucht, sind Sekunden (`Zaehlwerk.vorratSekunden`).
    ///
    /// Genau diese Zahl zeigt ein anderer Client, der dieselbe Datei am
    /// selben Server glatt abspielt, mit gut elf Sekunden an. Sie sagt als
    /// einzige vorher, ob es gleich haengt: geht sie gegen null, steht das
    /// Bild ein bis zwei Sekunden spaeter. Der Mittelwert als Nenner ist grob
    /// — fuer „reicht der Vorrat oder nicht" genau genug; im Messmodus
    /// stehen die Bytes ungerechnet daneben.
    private func pufferzeile(_ w: Spielwerte) -> some View {
        let sekunden = bytesJeSekunde.flatMap { w.werk.vorratSekunden(bytesJeSekunde: $0) }
        var teile: [String] = []
        if let sekunden { teile.append(komma(sekunden) + " s") }
        if messen { teile.append("\(w.werk.vorratBytes / 1024) KiB") }
        teile.append("\(String(localized: "Eingang")) \(w.eingang)")
        return angabe(String(localized: "Puffer"), teile.joined(separator: " · "),
                      auffaellig: (sekunden ?? .infinity) < 2)
    }

    private func komma(_ wert: Double) -> String {
        String(format: "%.1f", wert).replacingOccurrences(of: ".", with: ",")
    }

    private func verlust(_ w: Spielwerte) -> Bool {
        w.verworfen > 0 || w.zuSpaet > 0 || w.tonVerloren > 0
    }

    /// **Die Zeile, wegen der es das Schild gibt.**
    ///
    /// Verworfene und zu späte Bilder sind der Unterschied zwischen „läuft"
    /// und „läuft gerade noch": ein Bild, das stockt, und eines, das still
    /// Einzelbilder wegwirft, sehen aus drei Metern gleich aus. Steht hier
    /// eine Null, war es das Netz oder der Server; steht hier eine Zahl, war
    /// es der Dekoder.
    private func verlustzeile(_ w: Spielwerte) -> some View {
        messzeile("\(String(localized: "Verworfen")) \(w.verworfen)"
                  + " · \(String(localized: "zu spät")) \(w.zuSpaet)"
                  + " · \(String(localized: "Ton weg")) \(w.tonVerloren)",
                  auffaellig: verlust(w))
    }

    /// Eine Angabe für Zuschauer: Name leise, Wert hell. Fällt sie auf,
    /// steht sie ganz in `warnung` und mit Zeichen — wie `messzeile`.
    @ViewBuilder
    private func angabe(_ name: String, _ wert: String, auffaellig: Bool = false) -> some View {
        if auffaellig {
            messzeile("\(name) \(wert)", auffaellig: true)
        } else {
            Text(verbatim: name).foregroundStyle(Stil.schriftLeise)
                + Text(verbatim: " \(wert)").foregroundStyle(Stil.schrift)
        }
    }

    /// **Hat der Matroska-Kniff gegriffen?**
    ///
    /// `:demux=mkv_trusted` ist der Unterschied zwischen einem Sprung von
    /// einer Sekunde und einem von zwanzig — und ob er gilt, entscheidet die
    /// **Endung der ausgelieferten Adresse**, nicht der Container der Datei.
    /// Genau daran ist es schon einmal auseinandergegangen, deshalb steht
    /// beides hier.
    private var matroskazeile: String? {
        let namen = ["mkv", "matroska", "webm", "mka", "mks"]
        let behaelter = (quelle?.container ?? "").lowercased()
        guard namen.contains(where: { behaelter.contains($0) }) else { return nil }
        let endung = plan.url.pathExtension.lowercased()
        let adresse = endung.isEmpty ? String(localized: "ohne Endung") : "." + endung
        let kniff = (flaeche?.matroskaVertraut ?? false)
            ? String(localized: "vertraut") : String(localized: "MISSTRAUT")
        return "\(String(localized: "Matroska")) \(kniff) · \(adresse)"
    }

    /// Wo im Film wir stehen. **Damit ein Bildschirmfoto eine Stelle nennt**
    /// und nicht nur einen Zustand: „bei 41:12" ist nachstellbar, „irgendwo
    /// in der Mitte" nicht.
    private var zeitzeile: String? {
        guard let flaeche, flaeche.durationSeconds > 1 else { return nil }
        return "\(String(localized: "Stelle")) \(uhr(flaeche.positionSeconds))"
            + " / \(uhr(flaeche.durationSeconds))"
    }

    private func uhr(_ sekunden: Double) -> String {
        let ganz = Int(max(0, sekunden))
        let s = ganz % 60, m = (ganz / 60) % 60, h = ganz / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// **Die Zahl, die den Player entlastet oder ueberfuehrt.**
    ///
    /// Was tatsaechlich je Sekunde auf dem Schirm landet, neben dem, was die
    /// Datei vorgibt. Stehen beide gleich, kommt jedes Bild puenktlich an —
    /// dann entsteht das, was man sieht, danach: am Takt des Schirms oder in
    /// der Datei selbst. Steht die erste darunter, ohne dass „verworfen"
    /// steigt, haengt der Dekoder.
    private func zeigtzeile(_ w: Spielwerte) -> some View {
        let soll = video?.bildrate
        // Der Zusatz sagt, worueber gemittelt wird — sonst haelt man die
        // Zahl fuer einen Momentanwert und liest jede Schwankung als Ereignis.
        var text = "\(String(localized: "Zeigt Ø")) "
        if let ist = w.zeigtProSekunde {
            text += String(format: "%.1f", ist).replacingOccurrences(of: ".", with: ",")
        } else {
            text += "—"
        }
        text += " fps · \(String(localized: "Gezeigt")) \(w.gezeigt)"
        // **Ein kurzes Fenster rauscht.**
        //
        // Zwei Sekunden sind rund achtundvierzig Bilder; ein Bild mehr oder
        // weniger an der Fensterkante sind schon 0,5 fps. Bei einem halben
        // Bild Toleranz stand die Zeile deshalb orange, obwohl der Schnitt
        // ueber acht Sekunden genau auf der Rate der Datei lag. Erst zwei
        // Bilder Abstand sind mehr als die Kante.
        let hinkt = if let ist = w.zeigtProSekunde, let soll { ist < soll - 2 } else { false }
        return messzeile(text, auffaellig: hinkt)
    }

    /// **Die einzige Zahl, die Haengen wirklich misst.**
    ///
    /// Ein Film laeuft in Echtzeit: in einer Sekunde rueckt die Stelle um
    /// eine Sekunde vor. `Lauf 100 %` heisst, die Wiedergabe haelt Schritt
    /// mit der Uhr; alles darunter ist verlorene Zeit, und zwar genau die,
    /// die man als Stocken sieht.
    ///
    /// Sie steht hier, weil `Gezeigt` das Gegenteil behauptet, wenn es eng
    /// wird: VLC zeichnet ein stehendes Bild neu, solange nichts nachkommt,
    /// und zaehlt jede Wiederholung als gezeigtes Bild. Beim Haengen laeuft
    /// dieser Zaehler also *schneller*. Am 08.09.2026 standen so 1015
    /// gezeigte Bilder bei Stelle 0:28, wo 671 hingehoert haetten — waehrend
    /// das Bild sichtbar stand.
    private func laufzeile(_ w: Spielwerte) -> some View {
        var text = "\(String(localized: "Lauf")) "
        if let anteil = w.laufAnteil {
            text += "\(Int((anteil * 100).rounded())) %"
        } else {
            text += "—"
        }
        // Unter 97 Prozent ist kein Messrauschen mehr: das sind mehr als
        // anderthalb Sekunden auf eine Minute.
        let haengt = (w.laufAnteil ?? 1) < 0.97
        return messzeile(text, auffaellig: haengt)
    }

    /// **Mit wie viel Hertz der Schirm diese App bedient -- gemessen.**
    ///
    /// Die Zahl entscheidet, ob eine Datei ueberhaupt glatt laufen *kann*:
    /// 23,976 gehen in 60 Hz nicht auf (2,503), in 120 Hz nahezu (5,005).
    /// Steht hier 60 auf einem Geraet, das 120 koennte, ruckelt jeder
    /// Schwenk, ohne dass ein einziges Bild verlorengeht -- und genau dann
    /// zeigt jede andere Zahl auf diesem Schild sauber an.
    @ViewBuilder private func schirmzeile() -> some View {
        if let hz = schirmHertz {
            let knapp = hz < 70
            messzeile("\(String(localized: "Schirm")) \(Int(hz.rounded())) Hz",
                      auffaellig: knapp)
        }
    }

    /// **Die Zeile, die Dekoder und Ausgabe trennt.**
    ///
    /// Wenn der Vorrat voll ist und die Stelle trotzdem zurueckbleibt, liegt
    /// der Engpass hinter dem Demuxer -- und dafuer gibt es genau zwei
    /// Stellen. Steht hier die Bildrate der Datei, rechnet der Dekoder
    /// schnell genug und die Ausgabe haelt nicht Schritt. Steht hier
    /// weniger, ist der Dekoder selbst zu langsam.
    private func dekodierzeile(_ w: Spielwerte) -> some View {
        let soll = video?.bildrate
        var text = "\(String(localized: "Dekodiert Ø")) "
        if let ist = w.dekodiertProSekunde {
            text += String(format: "%.1f", ist).replacingOccurrences(of: ".", with: ",")
        } else {
            text += "—"
        }
        text += " fps"
        // Zwei Bilder Abstand, wie bei der Zeigt-Zeile: darunter ist es die
        // Kante des Fensters und kein Ereignis.
        let hinkt = if let ist = w.dekodiertProSekunde, let soll { ist < soll - 2 } else { false }
        return messzeile(text, auffaellig: hinkt)
    }

    /// **Was am Strom selbst kaputt war.**
    ///
    /// Beschaedigte Bloecke sind die Zahl hinter „da waren Bildfehler",
    /// Spruenge die hinter „der Ton wandert weg". Beide sagen etwas, das die
    /// verworfenen Bilder nicht sagen: dort ist der Dekoder ueberfordert,
    /// hier kam schon kaputt an, was er dekodieren sollte.
    private func stromzeile(_ w: Spielwerte) -> some View {
        let schlecht = w.beschaedigt > 0 || w.spruenge > 0
        return messzeile("\(String(localized: "Beschädigt")) \(w.beschaedigt)"
                         + " · \(String(localized: "Sprünge")) \(w.spruenge)",
                         auffaellig: schlecht)
    }

    #if os(tvOS)
    /// **Die Zeile, die Ruckeln ohne Verlust erklaert.**
    ///
    /// Am 08.09.2026 gemessen, an zwei Bildschirmfotos 22 Sekunden
    /// auseinander: 539 gezeigte Bilder in 22 Sekunden — genau die Rate der
    /// Datei —, dabei kein verworfenes, kein zu spaetes, nichts
    /// Beschaedigtes, kein neuer Sprung. Und es ruckelte trotzdem sichtbar.
    ///
    /// Wenn jedes Bild ankommt und puenktlich gezeigt wird und es trotzdem
    /// stockt, liegt es nicht mehr an der Wiedergabe, sondern am **Takt des
    /// Schirms**: 23,976 gehen in 60 Hz nicht auf, also wird jedes zweite
    /// Bild dreimal und jedes andere zweimal gezeigt. Die Bewegung laeuft
    /// abwechselnd zu schnell und zu langsam, und **kein Zaehler meldet
    /// etwas**, weil kein Bild verlorengeht. Genau dafuer gibt es
    /// `Bildtakt` — und ohne diese Zeile war nicht zu sehen, ob er greift.
    private var taktzeile: some View {
        let gemessen = flaeche.flatMap { Bildtakt.rate(von: $0.player) }
        let behauptet = video?.bildrate
        let rate = Technikangaben.bildrate(gemessen ?? behauptet)
        let takt = Bildtakt.schirmtakt

        let wort: String
        let passt: Bool
        if let ziel = Bildtakt.angefordert {
            // **Auf die Stelle genau, nicht gerundet.** Hier stand `%.0f`,
            // und aus 23,976 wurde „24 Hz" — genau die Verwechslung, um die
            // es bei dieser Zeile geht. Angefordert wird der echte Wert;
            // dass der Schirm ihn als 24 meldet, ist seine Rundung, nicht
            // unsere.
            wort = String(localized: "angefordert \(Technikangaben.bildrate(ziel) ?? "?") Hz")
            passt = true
        } else {
            switch Bildtakt.stand {
            case .bereit:
                wort = String(localized: "ohne Wechsel")
                // Ohne Wechsel geht es nur auf, wenn der Schirm ohnehin passt.
                passt = (gemessen ?? behauptet).map {
                    abs(($0 * 2).rounded() - $0 * 2) < 0.5
                        && Int(($0 * 2).rounded()) % 2 == 0
                        ? Int($0.rounded()) != 0 && takt % Int($0.rounded()) == 0
                        : takt % 24 == 0
                } ?? false
            case .abgeschaltet:
                wort = String(localized: "Anpassung aus")
                passt = false
            case .inSwiftlyAus:
                // Kein Mangel, sondern eine Wahl — deshalb nicht orange.
                wort = String(localized: "in Swiftly aus")
                passt = true
            case .unerreichbar:
                wort = String(localized: "Anzeige stumm")
                passt = false
            }
        }
        return messzeile("\(String(localized: "Takt")) \(rate ?? "?") fps"
                         + " · \(wort) · \(String(localized: "Schirm")) \(takt) Hz",
                         auffaellig: !passt)
    }
    #endif

    /// **Eine Messzeile, die auffällt — und zwar nicht nur farbig.**
    ///
    /// An acht Stellen wurde eine Zeile von `schriftLeise` auf `warnung`
    /// umgefärbt und sonst nichts geändert: gleicher Wortlaut, gleicher Grad,
    /// kein Zeichen. Wer Orange nicht von Grau trennt, sah acht Zeilen, die
    /// alle gleich aussahen, und damit sagte das Schild ihm nichts — dabei ist
    /// genau das sein Zweck. BRAND 1 sagt es als Regel: „Status zusätzlich
    /// über Form, nicht nur über Farbe."
    ///
    /// Das Zeichen ist dasselbe, das `Belegzeile` in `Stil.swift` für denselben
    /// Anlass nimmt — `exclamationmark.triangle.fill`. Zwei Zeichen für eine
    /// Bedeutung wären eine zweite Sprache.
    @ViewBuilder private func messzeile(_ text: String, auffaellig: Bool) -> some View {
        if auffaellig {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Stil.plakette)
                Text(verbatim: text)
            }
            // `warnung` auf der Schildfläche: 5,40:1 bei 0,88 Deckkraft.
            .foregroundStyle(Stil.warnung)
        } else {
            Text(verbatim: text).foregroundStyle(Stil.schriftLeise)
        }
    }
}

/// **Eine Spalte mit Höchsthöhe, die weglässt statt zu scrollen.**
///
/// Kernzeilen (`kern()`) stehen immer. Die übrigen nimmt sie von oben,
/// solange sie in `anteil` der angebotenen Höhe passen, und hört bei der
/// ersten auf, die nicht mehr passt — auch wenn eine kürzere danach noch
/// Platz hätte. Die Reihenfolge ist die Rangfolge; eine spätere Zeile, die
/// eine frühere überholt, wäre ein Loch in der Mitte.
///
/// Die angebotene Höhe ist die der Auflage über dem Bild: die Aufrufstellen
/// legen das Schild in einen Rahmen bis an alle Ränder, und der reicht seine
/// Höhe durch. Ohne Angebot (`nil`) oder ohne `anteil` gibt es keine Grenze.
private struct Kappliste: Layout {
    var abstand: CGFloat
    var anteil: CGFloat?

    /// Die Grösse jeder Zeile, die steht — `nil` für die weggelassenen.
    private func masse(_ angebot: ProposedViewSize, _ zeilen: Subviews) -> [CGSize?] {
        var grenze = CGFloat.infinity
        if let anteil, let hoehe = angebot.height, hoehe.isFinite { grenze = hoehe * anteil }
        var summe: CGFloat = 0
        var voll = false
        var ergebnis: [CGSize?] = []
        for zeile in zeilen {
            let groesse = zeile.sizeThatFits(ProposedViewSize(width: angebot.width, height: nil))
            let neu = summe + (summe == 0 ? 0 : abstand) + groesse.height
            let kern = zeile[Kernzeile.self]
            if !kern && (voll || neu > grenze) {
                voll = true
                ergebnis.append(nil)
                continue
            }
            summe = neu
            ergebnis.append(groesse)
        }
        return ergebnis
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let stehen = masse(proposal, subviews).compactMap { $0 }
        let hoehe = stehen.map(\.height).reduce(0, +) + abstand * CGFloat(max(stehen.count - 1, 0))
        return CGSize(width: proposal.width ?? stehen.map(\.width).max() ?? 0, height: hoehe)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let masse = masse(proposal, subviews)
        var y = bounds.minY
        for (zeile, groesse) in zip(subviews, masse) {
            if let groesse {
                zeile.place(at: CGPoint(x: bounds.minX, y: y),
                            proposal: ProposedViewSize(width: bounds.width, height: groesse.height))
                y += groesse.height + abstand
            } else {
                // Platziert werden muss jede Zeile, sonst setzt SwiftUI sie
                // in die Mitte. Die übrigen landen ohne Grösse unter dem
                // Schild, und `clipped` im Schild schneidet sie ab.
                zeile.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), proposal: .zero)
            }
        }
    }
}

/// Markiert eine Zeile, die `Kappliste` nie weglässt.
private struct Kernzeile: LayoutValueKey {
    static let defaultValue = false
}

private extension View {
    /// Eine Kernzeile des Technikschilds — steht immer, siehe `Kappliste`.
    func kern() -> some View { layoutValue(key: Kernzeile.self, value: true) }
}
