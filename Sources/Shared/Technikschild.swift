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

    private var quelle: MediaSource? { plan.quelle }
    private var video: MediaStream? { quelle.flatMap(Dateiangaben.videospur) }
    private var ton: MediaStream? { quelle.flatMap(Dateiangaben.tonspuren)?.first }
    private var untertitel: MediaStream? {
        quelle.flatMap(Dateiangaben.untertitelspuren)?.first
    }

    private var grad: CGFloat { fern ? 22 : 12 }
    private var abstand: CGFloat { fern ? 7 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: abstand) {
            kopfzeile

            // Der Grund steht direkt unter dem Wort, nicht am Ende: wer
            // „Transkodiert" liest, will als Nächstes wissen, woran es lag.
            if plan.method == .transcode, let grund = plan.reasons.first {
                zeile(grund.text, farbe: Stil.warnung)
            }

            if let bild = Technikangaben.bildzeile(
                breite: video?.width, hoehe: video?.height,
                // Farbtiefe liefert der Server in unserem Modell nicht mit;
                // der Umfang schon, und der ist die Angabe, an der auf dem
                // Fernseher der HDR-Schalter haengt.
                tiefe: nil,
                umfang: video?.videoRangeType?.rawValue) {
                zeile(bild)
            }
            if let v = videozeile { zeile(v) }
            if let t = tonzeile { zeile(t) }
            if let u = untertitelzeile { zeile(u) }
            if let d = dateizeile { zeile(d) }

            if let b = bedarfzeile { zeile(b) }
            if let m = matroskazeile { zeile(m) }
            if let z = zeitzeile { zeile(z) }
            #if os(tvOS)
            taktzeile
            #endif

            if let werte {
                // **Eine Haarlinie, kein Abstand.** Was darüber steht,
                // beschreibt die Datei und ändert sich nie; was darunter
                // steht, zählt beim Laufen hoch. Zwei Sorten Zahl, und man
                // soll sie beim Überfliegen auseinanderhalten.
                Rectangle().fill(Stil.rand)
                    .frame(width: fern ? 260 : 150, height: 1)
                    .padding(.vertical, abstand / 2)

                zeile("\(String(localized: "Eingang")) \(werte.eingang)")
                zeile("\(String(localized: "Demuxer")) \(werte.demuxer)")
                zeigtzeile(werte)
                verlustzeile(werte)
                stromzeile(werte)
            }
        }
        .font(.system(size: grad, weight: .medium, design: .monospaced))
        .foregroundStyle(Stil.schrift)
        // **Eine feste Breite, sonst laeuft die laengste Zeile hinaus.**
        //
        // Ein `VStack` in einer Auflage bekommt so viel Platz, wie er will —
        // und die Zeile mit den drei Zaehlern ist die laengste. Sie stand auf
        // dem Fernseher halb ausserhalb des Schildes. Mit einer Breite bricht
        // sie um, statt zu fliehen.
        .frame(width: fern ? 420 : 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, fern ? 20 : 12)
        .padding(.vertical, fern ? 16 : 10)
        .background {
            // Deckend, nicht durchscheinend: das Schild liegt über bewegtem
            // Bild, und über bewegtem Bild ist jede Transparenz mal lesbar
            // und mal nicht. Dieselbe Entscheidung wie bei den Leisten.
            RoundedRectangle(cornerRadius: fern ? 14 : Stil.ecke)
                .fill(Stil.grund.opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: fern ? 14 : Stil.ecke)
                .strokeBorder(Stil.rand)
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
            .font(.system(size: grad + 2, weight: .bold, design: .monospaced))
            .foregroundStyle(Technikangaben.gewicht(plan.method) == .gut
                             ? Stil.akzent : Stil.warnung)
    }

    private var videozeile: String? {
        guard let name = Technikangaben.codecname(video?.codec) else { return nil }
        var text = "\(String(localized: "Bild")) \(name)"
        if let rate = Technikangaben.bildrate(video?.bildrate) { text += " · \(rate) fps" }
        return text
    }

    private var tonzeile: String? {
        guard let name = Technikangaben.codecname(ton?.codec) else { return nil }
        var text = "\(String(localized: "Ton")) \(name)"
        if let k = Technikangaben.kanalwort(ton?.channels) { text += " · \(k)" }
        if let sprache = Technikangaben.sprache(ton?.language) { text += " · \(sprache)" }
        return text
    }

    private var untertitelzeile: String? {
        guard let name = Technikangaben.codecname(untertitel?.codec) else { return nil }
        var text = "\(String(localized: "Untertitel")) \(name)"
        if let sprache = Technikangaben.sprache(untertitel?.language) { text += " · \(sprache)" }
        return text
    }

    /// Container und Grösse — was auf der Platte liegt.
    ///
    /// **`Dateiangaben.container` bringt die Groesse schon mit.** Hier stand
    /// zusaetzlich `groesse(quelle)`, und weil auch die mit ihrem eigenen
    /// Trennzeichen kommt, las man auf dem Schild „Datei MP4 · 0,3 GB ·  ·
    /// 0,3 GB". Zwei Bausteine, die beide mehr tun, als ihr Name sagt — und
    /// ich habe sie addiert, statt einen zu lesen.
    private var dateizeile: String? {
        guard let quelle, let c = Dateiangaben.container(quelle) else { return nil }
        return "\(String(localized: "Datei")) \(c.uppercased())"
    }

    /// **Die Zeile, wegen der es das Schild gibt.**
    ///
    /// Verworfene und zu späte Bilder sind der Unterschied zwischen „läuft"
    /// und „läuft gerade noch": ein Bild, das stockt, und eines, das still
    /// Einzelbilder wegwirft, sehen aus drei Metern gleich aus. Steht hier
    /// eine Null, war es das Netz oder der Server; steht hier eine Zahl, war
    /// es der Dekoder.
    private func verlustzeile(_ w: Spielwerte) -> some View {
        let schlecht = w.verworfen > 0 || w.zuSpaet > 0 || w.tonVerloren > 0
        return Text(verbatim: "\(String(localized: "Verworfen")) \(w.verworfen)"
                    + " · \(String(localized: "zu spät")) \(w.zuSpaet)"
                    + " · \(String(localized: "Ton weg")) \(w.tonVerloren)")
            .foregroundStyle(schlecht ? Stil.warnung : Stil.schriftLeise)
    }

    /// **Was die Datei im Mittel braucht** — Groesse geteilt durch Laufzeit.
    ///
    /// Die Zahl daneben zu haben ist der ganze Punkt: steht unter „Eingang"
    /// weniger, als hier steht, kommt der Strom nicht nach, und der Rest —
    /// Ruckeln, wandernder Ton — folgt daraus. Spitzen liegen ueber dem
    /// Mittel; wer knapp darueber liegt, hat trotzdem ein Problem.
    private var bedarfzeile: String? {
        guard let bytes = quelle?.size, bytes > 0,
              let dauer = flaeche?.durationSeconds, dauer > 1,
              let text = Technikangaben.bitrate(Double(bytes) * 8 / dauer)
        else { return nil }
        return "\(String(localized: "Datei braucht")) \(text) Ø"
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
        return Text(verbatim: text)
            .foregroundStyle(hinkt ? Stil.warnung : Stil.schriftLeise)
    }

    /// **Was am Strom selbst kaputt war.**
    ///
    /// Beschaedigte Bloecke sind die Zahl hinter „da waren Bildfehler",
    /// Spruenge die hinter „der Ton wandert weg". Beide sagen etwas, das die
    /// verworfenen Bilder nicht sagen: dort ist der Dekoder ueberfordert,
    /// hier kam schon kaputt an, was er dekodieren sollte.
    private func stromzeile(_ w: Spielwerte) -> some View {
        let schlecht = w.beschaedigt > 0 || w.spruenge > 0
        return Text(verbatim: "\(String(localized: "Beschädigt")) \(w.beschaedigt)"
                    + " · \(String(localized: "Sprünge")) \(w.spruenge)")
            .foregroundStyle(schlecht ? Stil.warnung : Stil.schriftLeise)
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
        return Text(verbatim: "\(String(localized: "Takt")) \(rate ?? "?") fps"
                    + " · \(wort) · \(String(localized: "Schirm")) \(takt) Hz")
            .foregroundStyle(passt ? Stil.schriftLeise : Stil.warnung)
    }
    #endif

    private func zeile(_ text: String, farbe: Color = Stil.schriftLeise) -> some View {
        Text(verbatim: text).foregroundStyle(farbe)
    }
}
