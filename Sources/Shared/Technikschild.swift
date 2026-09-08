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
                zeile("\(String(localized: "Gezeigt")) \(werte.gezeigt)")
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

    private func zeile(_ text: String, farbe: Color = Stil.schriftLeise) -> some View {
        Text(verbatim: text).foregroundStyle(farbe)
    }
}
