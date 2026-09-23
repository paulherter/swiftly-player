#if DEBUG
import AppKit
import OSLog
import SwiftUI

/// **Der Blick auf die eigene Arbeit — ohne Bildschirmzugriff.**
///
/// Eine Sitzung, die an der Oberfläche baut, sieht sie nicht. Am 05.09.2026
/// hat das fünf Runden über Paul gekostet: das aktive Profilbild trug einen
/// Schleier (`disabled` legt in SwiftUI einen darüber), und die gestapelten
/// Kreise in der Seitenleiste lagen in der falschen Reihenfolge. **Beides war
/// grün gebaut.** Ein Bau ist kein Blick.
///
/// Der naheliegende Weg wäre eine Bildschirmaufnahme gewesen. Der ist hier
/// bewusst nicht genommen: eine Aufnahmeberechtigung kann grundsätzlich mehr
/// als das, wofür sie gebraucht wird — sie sieht den ganzen Schirm, also auch
/// alles, was sonst offen ist. Gemessen ginge sie ohnehin nicht:
/// `screencapture -l` antwortet „could not create image from window", und
/// `CGWindowListCreateImage` ist seit macOS 15 abgeschafft.
///
/// Stattdessen **zeichnet die Ansicht sich selbst**. `cacheDisplay(in:to:)`
/// ist AppKits eigener Weg, eine Ansicht in eine Bitmap zu legen; beteiligt
/// ist nur diese App. Das Bild landet neben dem Protokoll im Container, wo
/// eine Sitzung ohnehin liest.
///
/// **Was nicht auf dem Bild ist — wer es liest, muss das wissen:**
///
/// - **Das Videobild des Players.** `VLCOpenGLVideoView` zeichnet in eine
///   eigene Fläche; an seiner Stelle bleibt ein Loch. Die Steuerung darüber
///   ist zu sehen, das Bild darunter nicht.
/// - **Popover, Menüs und die Fensterampel.** AppKit legt sie in eigene
///   Fenster, und abgezeichnet wird genau eines.
///
/// **Nur im Entwicklerbau.** In der ausgelieferten Fassung gibt es diese
/// Datei nicht — dieselbe Klammer wie um `Protokoll.schreib`.
@MainActor
enum Fensterabzug {

    /// Derselbe Ordner wie das Protokoll: unter der Sandbox ist das
    /// `~/Library/Containers/de.paulherter.swiftly/Data/Documents`.
    private static var ordner: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Wer ein Bild will, legt diese Datei an. Sie wird gelöscht, sobald das
    /// Bild steht — die Anwesenheit der Datei ist der Auftrag.
    static var anstoss: URL { ordner.appendingPathComponent("abzug.jetzt") }
    static var bild: URL { ordner.appendingPathComponent("abzug.png") }

    /// **Eine Datei als Auslöser, kein Tastenkürzel.**
    ///
    /// Ein Kürzel müsste jemand drücken, und dann wäre nichts gewonnen — der
    /// Sinn ist ja, dass die Sitzung selbst nachsieht, bevor sie etwas
    /// meldet. Eine Datei im eigenen Container kann sie anlegen.
    ///
    /// Anderthalb Sekunden Takt: langsam genug, um im Betrieb nicht
    /// aufzufallen, schnell genug, um nicht darauf zu warten.
    static func lauschen() {
        let takt = Timer(timeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard FileManager.default.fileExists(atPath: anstoss.path) else { return }
                try? FileManager.default.removeItem(at: anstoss)
                machen()
            }
        }
        // In `.common`, sonst steht der Takt still, solange jemand die Maus
        // gedrückt hält oder ein Menü offen ist.
        RunLoop.main.add(takt, forMode: .common)
    }

    /// Zeichnet das vorderste sichtbare Fenster ab.
    ///
    /// **Ein verdecktes Fenster zeichnet nicht.** macOS stellt das Zeichnen
    /// ein, sobald ein Fenster vollständig hinter anderen liegt; SwiftUI
    /// aktualisiert es dann auch nicht mehr. `cacheDisplay` liefert in dem
    /// Fall das **zuletzt gezeichnete** Bild — und das sieht aus wie „nichts
    /// hat sich geändert".
    ///
    /// Am 10.09.2026 hat mich genau das eine falsche Meldung gekostet: vier
    /// Befehle abgesetzt, viermal dasselbe Bild bekommen, daraus geschlossen,
    /// die Menüsteuerung sei tot — und Paul gebeten, das zu prüfen. Gemessen
    /// war das Fenster verdeckt (`occlusionState` ohne `visible`, kein
    /// Schlüsselfenster, Programm nicht aktiv), weil auf demselben Rechner
    /// Simulatoren liefen.
    ///
    /// Deshalb steht der Zustand jetzt in der Protokollzeile. Ein Werkzeug,
    /// das schweigend Altes zeigt, ist schlimmer als keines.
    ///
    /// **Und der zweite Grund für ein falsches Bild: zwei Instanzen.** Der
    /// Anstoß liegt im Container, und den teilen sich alle Kopien derselben
    /// App. Läuft eine zweite — aus `DerivedData`, aus einem älteren Bau —,
    /// nimmt sie den Auftrag womöglich zuerst, und im Bild steht dann ihr
    /// Fenster. Am 10.09.2026 liefen zwei, und die Zeile, die gesucht wurde,
    /// gab es nur in einer davon. Vor dem Abzug also nachsehen:
    /// `pgrep -f "Contents/MacOS/Swiftly" | wc -l` muss **1** sein.
    static func machen() {
        guard let fenster = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let inhalt = fenster.contentView else {
            Protokoll.schreib("[Abzug] kein sichtbares Fenster")
            return
        }
        let flaeche = inhalt.bounds
        guard flaeche.width > 1, flaeche.height > 1,
              let ablage = inhalt.bitmapImageRepForCachingDisplay(in: flaeche) else {
            Protokoll.schreib("[Abzug] keine Ablage für \(Int(flaeche.width))x\(Int(flaeche.height))")
            return
        }
        inhalt.cacheDisplay(in: flaeche, to: ablage)
        guard let daten = ablage.representation(using: .png, properties: [:]) else {
            Protokoll.schreib("[Abzug] liess sich nicht als PNG schreiben")
            return
        }
        do {
            try daten.write(to: bild)
            let sichtbar = fenster.occlusionState.contains(.visible)
            Protokoll.schreib("[Abzug] \(Int(flaeche.width))x\(Int(flaeche.height)) Punkte, "
                + "\(ablage.pixelsWide)x\(ablage.pixelsHigh) Bildpunkte, \(daten.count) B"
                + (sichtbar ? "" : " — ACHTUNG: Fenster verdeckt, das Bild ist der "
                                 + "letzte gezeichnete Stand und kann alt sein"))
        } catch {
            Protokoll.schreib("[Abzug] \(error)")
        }
    }
}

/// **Der Bildtakt, gemessen statt gefühlt.**
///
/// Paul am 22.09.2026 über das Scrollen: „es fühlt sich an wie 30 Hertz, auf
/// keinen Fall wie 120. Die Animationen dagegen sind total smooth." Zwei
/// Behauptungen in einem Satz, und sie widersprechen sich fast — deshalb
/// gemessen, nicht geraten.
///
/// `NSView.displayLink(target:selector:)` (macOS 14) hängt am Takt **des
/// Bildschirms, auf dem das Fenster steht**, und wird bei jedem Bild gerufen,
/// das dieses Fenster bekommt. Aus den Abständen zwischen den Aufrufen lässt
/// sich ablesen, mit welcher Rate das Fenster tatsächlich läuft und wie viele
/// Bilder dabei ausfallen.
///
/// **Ins vereinheitlichte Protokoll, nicht in `Protokoll.schreib`.** Dessen
/// Datei liegt im Container der App, und darauf hat von außen niemand Zugriff
/// — eine Messung, die niemand lesen kann, ist keine. `Logger` schreibt in
/// das Protokoll, das `log show` hergibt.
///
/// **Nur im Entwicklerbau**, wie der ganze Rest dieser Datei.
final class Bildtakt: NSView {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "bildtakt")
    private var verbindung: CADisplayLink?
    private var letzte: CFTimeInterval = 0
    private var abstaende: [Double] = []
    private var fensterAnfang = CACurrentMediaTime()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        verbindung?.invalidate()
        guard window != nil else { verbindung = nil; return }
        let neu = displayLink(target: self, selector: #selector(takt))
        neu.add(to: .main, forMode: .common)
        verbindung = neu
        if let schirm = window?.screen {
            Self.log.notice("""
                Bildschirm \(schirm.localizedName, privacy: .public),                 maximal \(schirm.maximumFramesPerSecond) Hz,                 Fenster \(Int(self.window?.frame.width ?? 0))x\(Int(self.window?.frame.height ?? 0))
                """)
        }
    }

    @objc private func takt(_ verbindung: CADisplayLink) {
        let jetzt = CACurrentMediaTime()
        defer { letzte = jetzt }
        guard letzte > 0 else { return }
        abstaende.append((jetzt - letzte) * 1000)

        // Alle zwei Sekunden eine Zeile: Rate, Streuung, ausgefallene Bilder.
        guard jetzt - fensterAnfang >= 2 else { return }
        let n = abstaende.count
        guard n > 1 else { abstaende.removeAll(); fensterAnfang = jetzt; return }
        let sortiert = abstaende.sorted()
        let mittel = sortiert[n / 2]
        let soll = verbindung.targetTimestamp - verbindung.timestamp
        let sollMs = soll > 0 ? soll * 1000 : 1000 / 120
        // Als „ausgefallen" zählt, was mehr als das Anderthalbfache des Solls
        // gebraucht hat — ein ausgelassenes Bild und mehr.
        let ausgefallen = abstaende.filter { $0 > sollMs * 1.5 }.count
        let zeile = String(
            format: "%.0f Bilder/s · Mittel %.2f ms · min %.2f · max %.2f · Soll %.2f · %d ausgefallen (%.0f%%)",
            Double(n) / (jetzt - fensterAnfang), mittel, sortiert[0], sortiert[n - 1],
            sollMs, ausgefallen, Double(ausgefallen) * 100 / Double(n))
        Self.log.notice("\(zeile, privacy: .public)")
        abstaende.removeAll()
        fensterAnfang = jetzt
    }
}

/// Hängt den `Bildtakt` ins Fenster.
struct Bildtaktmesser: NSViewRepresentable {
    func makeNSView(context: Context) -> Bildtakt { Bildtakt(frame: .zero) }
    func updateNSView(_ ansicht: Bildtakt, context: Context) {}
}

/// **Eine gemessene Scrollfahrt, statt eines Gefühls.**
///
/// Paul am 22.09.2026: das Scrollen fühle sich auf **allen** Seiten nach 30
/// Hertz an, auch in den Einstellungen, wo kein Bild steht — die Animationen
/// dagegen seien flüssig. Der Unterschied ist die entscheidende Auskunft:
/// eine Animation läuft, einmal übergeben, auf dem Renderserver weiter; ein
/// Scrollvorgang verlangt vom Hauptlauf **je Bild** ein neues. Wenn nur das
/// Scrollen ruckelt, kostet ein Bild zu viel.
///
/// Diese Probe fährt selbst: sie schickt der eigenen App echte
/// Mausrad-Ereignisse über `NSApp.postEvent` — kein Zugriff auf fremde
/// Programme, keine Berechtigung, derselbe Weg, den ein Trackpad nimmt. Der
/// `Bildtakt` daneben schreibt mit, wie viele Bilder dabei ausfallen.
///
/// Gestartet über die Umgebung, damit eine Sitzung sie ohne Zutun auslösen
/// kann:
///
///     SWIFTLY_SCROLLPROBE=1 .../Swiftly.app/Contents/MacOS/Swiftly
///
/// **Nur im Entwicklerbau.**
@MainActor
enum Scrollprobe {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "scrollprobe")
    private static var takt: Timer?
    private static var schritte = 0
    private static weak var flaeche: NSScrollView?
    private static var anfang: CGFloat = 0
    private static var weitesteFahrt: CGFloat = 0
    private static var weite: CGFloat = 0

    static var angefordert: Bool {
        ProcessInfo.processInfo.environment["SWIFTLY_SCROLLPROBE"] != nil
    }

    /// Welcher Bereich vor der Fahrt geöffnet wird. Die Startseite und eine
    /// Bibliotheksseite sind **nicht** dasselbe: die eine liest den
    /// Scrollversatz nur in ihrer Leiste, die andere auch in ihrem eigenen
    /// Rumpf — und genau das ist der Unterschied, den ich messen will.
    ///
    ///     SWIFTLY_SCROLLPROBE=filme   (oder serien, merkliste, start)
    private static var bereich: Kommando? {
        switch ProcessInfo.processInfo.environment["SWIFTLY_SCROLLPROBE"] {
        case "filme": .filme
        case "serien": .serien
        case "merkliste": .merkliste
        case "downloads": .downloads
        default: nil
        }
    }

    /// Wartet, bis die Seite steht, und fährt dann auf und ab.
    static func starten() {
        guard angefordert else { return }
        log.notice("Probe angefordert — Start in 6 s")
        // Erst den Bereich oeffnen, dann warten, bis er steht — eine Probe
        // auf einer Seite, die kuerzer ist als ihr Fenster, misst nichts.
        if let bereich {
            Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    log.notice("oeffne \(bereich.rawValue, privacy: .public)")
                    Kommandopost.senden(bereich)
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 18, repeats: false) { _ in
            MainActor.assumeIsolated { fahren() }
        }
    }

    private static func fahren() {
        guard let fenster = NSApp.windows.first(where: { $0.isVisible }) else {
            log.notice("kein sichtbares Fenster")
            return
        }
        fenster.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // **Erst nachsehen, ob es etwas zu scrollen gibt.** Eine Probe, die
        // nichts bewegt, misst nichts — und haette als „null ausgefallene
        // Bilder" genau wie ein Erfolg ausgesehen.
        flaeche = grosseScrollflaeche(in: fenster.contentView)
        guard let f = flaeche else {
            log.notice("keine Scrollflaeche gefunden — Probe sagt nichts aus")
            return
        }
        // **Eine Seite, die kuerzer ist als ihr Fenster, laesst sich nicht
        // scrollen.** Der erste Lauf lief genau darauf: Inhalt 446 in einem
        // Fenster von 833, weitester Weg 0 Punkt — und haette als „null
        // ausgefallene Bilder" wie ein Erfolg ausgesehen.
        let hoehe = f.documentView?.frame.height ?? 0
        guard hoehe > f.frame.height + 40 else {
            log.notice("""
                Inhalt \(Int(hoehe)) in \(Int(f.frame.height)) — nichts zu scrollen,                 Probe sagt nichts aus
                """)
            return
        }
        weite = hoehe - f.frame.height
        anfang = f.contentView.bounds.origin.y
        weitesteFahrt = 0
        log.notice("""
            Scrollflaeche \(Int(f.frame.width))x\(Int(f.frame.height)),             Inhalt \(Int(f.documentView?.frame.height ?? 0)),             Schluesselfenster \(fenster.isKeyWindow), aktiv \(NSApp.isActive)
            """)
        log.notice("Fahrt beginnt bei \(Int(anfang))")
        schritte = 0
        // 120 Ereignisse je Sekunde, so dicht wie ein Trackpad sie liefert.
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { schritt(fenster) }
        }
        RunLoop.main.add(t, forMode: .common)
        takt = t
    }

    /// **AppKits eigener Weg, nicht ein nachgebautes Ereignis.**
    ///
    /// Der erste Anlauf schickte `NSApp.postEvent` nachgebaute Mausradrollen —
    /// die kommen an einer `NSScrollView` nicht an, gemessen an „weitester Weg
    /// 0 Punkt". Hier wird stattdessen die Schnittansicht selbst bewegt. Das
    /// ist nicht die Gummikante und nicht der Schwung eines Trackpads, aber es
    /// ist genau der Teil, den ich messen will: der Inhalt wandert unter
    /// unseren Auflagen, einmal je Bild, bei 120 Hertz.
    private static func schritt(_ fenster: NSWindow) {
        schritte += 1
        guard let f = flaeche, let dok = f.documentView else { return }
        guard schritte <= 720 else {
            takt?.invalidate(); takt = nil
            log.notice("""
                Fahrt beendet nach \(schritte) Bildern,                 weitester Weg \(Int(weitesteFahrt)) Punkt
                """)
            return
        }
        // Sechs Sekunden: dreimal hinunter, dreimal hinauf, je 120 Bilder.
        let phase = Double(schritte % 240) / 240
        let anteil = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        let ziel = CGPoint(x: 0, y: (dok.isFlipped ? 1 : -1) * weite * anteil)
        f.contentView.scroll(to: ziel)
        f.reflectScrolledClipView(f.contentView)
        let weg = abs(f.contentView.bounds.origin.y - anfang)
        if weg > weitesteFahrt { weitesteFahrt = weg }
    }

    /// Die größte Scrollfläche im Baum — die Seite, nicht eine Reihe darin.
    private static func grosseScrollflaeche(in ansicht: NSView?) -> NSScrollView? {
        guard let ansicht else { return nil }
        var beste: NSScrollView?
        func gehen(_ v: NSView) {
            if let s = v as? NSScrollView,
               s.frame.height > (beste?.frame.height ?? 0) { beste = s }
            v.subviews.forEach(gehen)
        }
        gehen(ansicht)
        return beste
    }
}

/// **Die nackte Vergleichsansicht — die Halbierung.**
///
/// Eine `ScrollView` über hundert schlichten Zeilen, ohne einen einzigen
/// unserer Bausteine: kein Stil, keine Auflage, keine Leiste, kein
/// `seitenscrollen()`, keine Messung. Nur SwiftUI und AppKit.
///
/// Sie beantwortet die eine Frage, die sich anders nicht beantworten lässt:
/// **liegt das Ruckeln an dem, was wir darüberlegen, oder am Fenster?** Fühlt
/// sie sich flüssig an, ist der Unterschied unser Aufbau; fühlt sie sich
/// genauso zäh an, liegt es an Fenster, Rahmenwerk oder Gerät — und dann ist
/// an unseren Seiten nichts zu holen.
///
/// Der Weg dahin geht über die Umgebung, damit niemand sie versehentlich
/// sieht und niemand dafür klicken muss:
///
///     SWIFTLY_NACKT=1 .../Swiftly.app/Contents/MacOS/Swiftly
///
/// **Nur im Entwicklerbau.**
struct NackterVergleich: View {
    static var angefordert: Bool {
        ProcessInfo.processInfo.environment["SWIFTLY_NACKT"] != nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< 100, id: \.self) { nr in
                    Text(verbatim: "Zeile \(nr + 1)")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .frame(height: 46)
                    Divider()
                }
            }
        }
    }
}
#endif
