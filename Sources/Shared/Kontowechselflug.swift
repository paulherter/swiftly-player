import JellyfinKit
import OSLog
import QuartzCore
import SwiftUI

// MARK: - Kontowechsel, geteilt von iPhone, iPad, Mac und Fernseher
//
// Ablauf und Kurve des Kontowechsels und der Auftritt der Reihen danach.
// Lag bis 1.0.5 in `Sources/iOS/Uebergaenge.swift`. Die Bühne steht je
// Plattform: UIKit (iPhone, iPad, Fernseher) in
// `Sources/Shared/KontowechselbuehneUIKit.swift`, am Mac in
// `Sources/macOS/Kontowechselbuehne.swift`. Feder und Karte aus dem
// Abzeichen stehen in `Sources/Shared/Uebergaenge.swift`. Die Unterschiede
// des Fernsehers stehen als `#if os(tvOS)` an der Stelle, an der sie
// gelten: Zielgröße des Profilbilds, Rand, Ring, und die Seite blendet aus
// statt wegzufahren.

// MARK: - Kontowechsel

/// **Der Kontowechsel aus der Profilauswahl, Variante „ruhig"** (Versuch
/// `experiment-glas`; Paul, 26.09., Entwurf D im Design-Canvas).
///
/// **Die Bewegung läuft im Render-Server, nicht im Hauptlauf.** Bis Runde 6
/// zeichnete SwiftUI das fliegende Bild Bild für Bild, und die Profilseite
/// ging per Navigation zurück — beides hing am Hauptlauf, und genau der hat
/// beim Wechsel zu tun (Startseite aufbauen, Konto, Ablage). Am Gerät war
/// das am Anfang und gegen Ende als Ruckeln zu sehen. Jetzt:
///
/// 1. **Tipp:** ein Standbild des Schirms (`snapshotView`, im Render-Server
///    kopiert) liegt über allem und fährt als Seite nach rechts weg;
///    daneben fliegt das Profilbild als fertige Ebene. Beides sind
///    Core-Animation-Animationen mit vorab gerechneten Stützpunkten (120 je
///    Sekunde) — sie laufen weiter, auch wenn der Hauptlauf hängt.
/// 2. **Erst danach**, einen Durchlauf später, springt der Stapel ohne
///    Animation zurück — unter dem Standbild, unsichtbar.
/// 3. **Wechsel:** 0,3 s vor der Ruhe (``wechselVorRuhe``).
/// 4. **Tausch:** erst wenn das Bild ruht, steht dort das echte, und die
///    Ebene geht einen Durchgang später.
/// 5. **Reihen:** 30 ms danach gestaffelt (``Reihenauftritt``).
///
/// Im Protokoll (Kategorie `kontowechsel`) steht jede Stufe mit Zeit; im
/// Debug-Bau dazu jedes zu lange Bild (``Bildzeitmesser``).
///
/// **Auf dem Fernseher** derselbe Ablauf, mit Fokus statt Tipp: ein Druck
/// auf ein Konto im Kontenstreifen startet ihn, die Seite **blendet aus**
/// statt nach rechts wegzufahren (tvOS schiebt keine Seiten, es überblendet),
/// und der Fokus steht danach auf dem Profilbild oben rechts — das Profil
/// ist sofort wieder erreichbar (``HauptView``, `profilFokus`).
@MainActor @Observable
final class Kontowechselflug {
    static let geteilt = Kontowechselflug()

    struct Flug {
        let konto: String
        /// Das echte Bild im Kopf steht schon (Schritt 4).
        var ersetzt = false
    }

    private(set) var flug: Flug?
    /// Zwischen Tipp und Freigabe — solange hält die Startseite ihre Reihen
    /// zurück.
    private(set) var wartet = false
    /// Steigt nach dem Tipp: `HauptView` leert damit die Stapel, ohne
    /// Animation, unter dem Standbild.
    private(set) var zurueck = 0
    /// Wo das Profilbild oben steht, global — gemeldet von ``Profilziel``
    /// (iPhone), der Seitenleiste (iPad breit) oder der Profilzeile (Mac).
    @ObservationIgnored var ziel: CGRect = .zero
    /// So groß ist das Bild dort — 34 oben rechts, 26 in der Mac-Leiste.
    @ObservationIgnored var zielgroesse: CGFloat = Kurve.zielgroesse
    /// Ab hier beginnt der Inhalt (rechts der Seitenleiste). Nur dieser
    /// Teil fährt als Seite weg; die Leiste bleibt stehen. 0 ohne Leiste.
    @ObservationIgnored var inhaltAb: CGFloat = 0
    /// Konten, von denen beim Tipp bekannt war, dass sie kein Bild haben:
    /// dann trägt das Bild oben den Buchstaben schon im ersten Durchgang.
    private(set) var ohneBild: Set<URL> = []

    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "kontowechsel")

    /// Ins Systemprotokoll **und** in die Protokolldatei der App — die holt
    /// `Werkzeuge/protokoll-holen.sh` vom Gerät, mit Zeitstempel je Zeile.
    static func notiz(_ text: String) {
        log.info("\(text, privacy: .public)")
        Protokoll.schreib("[Kontowechsel] \(text)")
    }
    static let zeichen = OSSignposter(subsystem: "de.paulherter.swiftly", category: "kontowechsel")
    /// Das alte Profil tritt zurück: ab 80 ms, linear über 0,2 s.
    static var abheben: Animation { .linear(duration: 0.2).delay(0.08) }

    /// **Wann das Konto wirklich wechselt**: 0,3 s bevor das Bild ruht. Der
    /// Wechsel und alles, was an ihm hängt, kostet den Hauptlauf Zeit; kurz
    /// vor der Ruhe bewegt sich das Bild nur noch um Bruchteile eines
    /// Punkts, und das neue Profilbild steht im Kopf, bevor getauscht wird.
    static var wechselVorRuhe: Double { Kontowechselkurve.wechselVorRuhe }

    /// **Nur, wenn es wirklich oben rechts steht.** Das Ziel meldet sich
    /// auch mitten im Schieben einer Seite, und dann steht es ein Drittel
    /// des Schirms weiter links — dorthin soll nichts fliegen.
    func zielMelden(_ rahmen: CGRect) {
        guard rahmen.width > 0 else { return }
        let fenster = Kontowechselbuehne.fensterbreite ?? rahmen.maxX
        #if os(tvOS)
        // Der Fernseher hält 80 Punkt Rand, und die Kopfleiste steht fest —
        // nichts schiebt sich hier seitlich herein.
        let rand: CGFloat = 200
        #else
        let rand: CGFloat = 60
        #endif
        if rahmen.maxX > fenster - rand {
            ziel = rahmen
            zielgroesse = Kurve.zielgroesse
            inhaltAb = 0
        }
    }

    /// **Das Profilbild in einer Seitenleiste** (iPad breit, Mac): es steht
    /// links unten, nicht oben rechts, und gilt dort immer. `groesse` ist
    /// der Kreis selbst, `inhaltAb` die rechte Kante der Leiste.
    func zielInLeisteMelden(_ rahmen: CGRect, groesse: CGFloat, inhaltAb: CGFloat) {
        guard rahmen.width > 0 else { return }
        ziel = rahmen
        zielgroesse = groesse
        self.inhaltAb = inhaltAb
    }

    /// **Dieser Wechsel hat die Stapel schon geleert** (beim Druck, über
    /// ``zurueck``). `HauptView` fragt das bei `kontowechsel` ab, statt auf
    /// ``wartet`` zu schauen: öffnet jemand das Profil mitten im Flug,
    /// schließt ``abschliessen()`` ihn ab, `wartet` ist schon falsch, wenn
    /// SwiftUI den geänderten Zähler meldet — und das Leeren dort nahm die
    /// eben geöffnete Profilseite wieder weg (Selbsttest tvOS, 27.09.2026,
    /// `-profiltipp 300`). Einmal gelesen, verbraucht.
    @ObservationIgnored private var stapelGeleert = false
    func stapelSchonGeleert() -> Bool {
        defer { stapelGeleert = false }
        return stapelGeleert
    }

    /// Tipp auf ein Konto. `bild` ist das Profilbild so, wie es fliegen
    /// soll (``Profilzeichen``), `flaeche` die Farbe unter ihm in der Karte.
    /// Der laufende Wechsel — Stufen, die noch ausstehen, und die Bühne.
    /// Ein Wechsel kann früher fertig werden als geplant (``abschliessen``);
    /// dann läuft sein Zeitplan ins Leere, weil jede Stufe nur einmal geht.
    private final class Lauf {
        let nummer: Int
        var wechseln: (() -> Void)?
        var buehne: Kontowechselbuehne.Teile?
        init(nummer: Int, wechseln: @escaping () -> Void) {
            self.nummer = nummer
            self.wechseln = wechseln
        }
    }
    @ObservationIgnored private var lauf: Lauf?
    @ObservationIgnored private var laeufe = 0

    func starten(konto: String, bild: some View, von: CGRect, flaeche: Color,
                 adresse: URL?, wechseln: @escaping () -> Void) {
        guard !wartet else {
            Self.notiz("wechsel: zweiter tipp ignoriert")
            return
        }
        let jetzt = CACurrentMediaTime()
        laeufe += 1
        let meiner = Lauf(nummer: laeufe, wechseln: wechseln)
        lauf = meiner
        wartet = true
        stapelGeleert = false
        if let adresse, Bildspeicher.geteilt.bild(adresse) == nil { ohneBild.insert(adresse) }
        #if DEBUG && canImport(UIKit)
        Bildzeitmesser.geteilt.starten()
        #endif
        let ruhig = Stil.bewegungReduziert
        var kurve: Kurve?
        if !ruhig, von.width > 0, ziel.width > 0 {
            kurve = Kurve(von: CGPoint(x: von.midX, y: von.midY), groesse: von.width,
                          nach: CGPoint(x: ziel.midX, y: ziel.midY), zielgroesse: zielgroesse)
        }
        // Die Bühne steht je Plattform: am iPhone Ebenen im Render-Server,
        // am Mac eine Auflage über dem Fenster. Ohne Fenster keine Bewegung.
        meiner.buehne = Kontowechselbuehne.spielen(kurve: kurve, bild: bild, von: von, flaeche: flaeche,
                                                   inhaltAb: inhaltAb, ruhig: ruhig, start: jetzt)
        if meiner.buehne == nil { kurve = nil }
        if kurve != nil { flug = Flug(konto: konto) }
        #if DEBUG && canImport(UIKit)
        Bildzeitmesser.geteilt.kurve = kurve
        #endif
        Self.notiz("wechsel 1: tipp, flug \(kurve == nil ? "aus" : "an"), standbild faehrt weg")
        // Einen Durchlauf später: dann sind die Animationen schon beim
        // Render-Server, und was der Stapel kostet, hält sie nicht auf.
        Task { @MainActor in
            await Task.yield()
            self.zurueck += 1
            Self.notiz("wechsel 1b: stapel leer (unter dem standbild)")
        }
        Task { @MainActor in
            func bis(_ t: Double) async {
                try? await Task.sleep(for: .seconds(max(0, t - (CACurrentMediaTime() - jetzt))))
            }
            @MainActor func gilt() -> Bool { self.lauf === meiner }
            await bis(kurve.map { $0.rechnung.wechsel } ?? (ruhig ? 0.15 : 0.45))
            guard gilt() else { return }
            self.wechselAusfuehren(meiner)
            if let kurve {
                await bis(kurve.tausch)
                guard gilt() else { return }
                Self.notiz("wechsel 4: bild ruht, tausch gegen das echte (\(Int(kurve.tausch * 1000)) ms nach tipp)")
                self.flug?.ersetzt = true
            }
            try? await Task.sleep(for: .milliseconds(30))
            guard gilt() else { return }
            Self.notiz("wechsel 5: reihen duerfen kommen")
            self.wartet = false
            if let kurve {
                await bis(kurve.ringEnde + 0.1)
                guard gilt() else { return }
            }
            self.beenden(meiner)
        }
    }

    private func wechselAusfuehren(_ l: Lauf) {
        guard let w = l.wechseln else { return }
        l.wechseln = nil
        stapelGeleert = true
        Self.notiz("wechsel 2: konto wechselt, laden beginnt")
        let intervall = Self.zeichen.beginInterval("kontoWechseln")
        let a = CACurrentMediaTime()
        w()
        Self.zeichen.endInterval("kontoWechseln", intervall)
        Self.notiz("wechsel 2a: wechsel im hauptlauf \(Int((CACurrentMediaTime() - a) * 1000)) ms")
    }

    private func beenden(_ l: Lauf) {
        guard lauf === l else { return }
        lauf = nil
        flug = nil
        wartet = false
        #if DEBUG && canImport(UIKit)
        Bildzeitmesser.geteilt.anhalten()
        #endif
    }

    /// **Die Profilseite geht auf, während der Wechsel noch läuft**
    /// (Paul, 26.09.: das Profil oben ist sofort wieder antippbar). Dann
    /// ist alles Ausstehende sofort erledigt: das Konto wechselt jetzt,
    /// Standbild und fliegendes Bild gehen, das echte Bild steht, und die
    /// Startseite darf ihre Reihen bauen — im Hintergrund, unter der Seite.
    func abschliessen() {
        guard let l = lauf else { return }
        Self.notiz("wechsel: profil geoeffnet, rest sofort")
        wechselAusfuehren(l)
        l.buehne?.abbrechen()
        flug?.ersetzt = true
        beenden(l)
    }

    /// **Der Bogen des Profilbilds** — die Rechnung steht im Paket
    /// (``Kontowechselkurve``, mit Tests), damit Linux, Windows und Android
    /// denselben Bogen fliegen. Hier nur die Übersetzung in Punkte.
    struct Kurve {
        let rechnung: Kontowechselkurve
        let nach: CGPoint
        var groesse: CGFloat { CGFloat(rechnung.groesse) }
        /// Die Größe des Bilds am Ziel.
        var zielgroesse: CGFloat { CGFloat(rechnung.ziel) }
        /// Wann das Bild ruht (auf 0,3 pt) — Sekunden nach dem Tipp.
        var tausch: Double { rechnung.tausch }
        /// Wann es zum ersten Mal auf Zielhöhe zurückfällt: da ploppt der Ring.
        var landung: Double { rechnung.landung }
        var ringEnde: Double { rechnung.ringEnde }

        static var wachsen: Double { Kontowechselkurve.wachsen }
        #if os(tvOS)
        /// Das Profilbild der Kopfleiste (60), mit der Lupe des Fokus, der
        /// dort nach dem Wechsel steht (``Stil/fokusLupeKlein``).
        static let zielgroesse: CGFloat = 60 * Stil.fokusLupeKlein
        #else
        /// Oben rechts am iPhone und iPad.
        static let zielgroesse: CGFloat = 34
        #endif

        init(von: CGPoint, groesse: CGFloat, nach: CGPoint, zielgroesse: CGFloat = Self.zielgroesse) {
            self.nach = nach
            rechnung = Kontowechselkurve(von: (Double(von.x), Double(von.y)), groesse: Double(groesse),
                                         nach: (Double(nach.x), Double(nach.y)),
                                         zielgroesse: Double(zielgroesse))
        }

        func lage(_ t: Double) -> (x: CGFloat, y: CGFloat, s: CGFloat) {
            let b = rechnung.lage(t)
            return (CGFloat(b.x), CGFloat(b.y), CGFloat(b.s))
        }

        static func feder(_ von: CGFloat, _ nach: CGFloat, _ v0: Double,
                          _ r: Double, _ z: Double, _ t: Double) -> CGFloat {
            CGFloat(Kontowechselkurve.feder(Double(von), Double(nach), v0, r, z, t))
        }
    }
}

/// **Eine Reihe der Startseite, die nach dem Wechsel einploppt** — wie im
/// Entwurf D: 80 ms je Reihe, Deckkraft linear in 0,22 s, Versatz 14 pt und
/// Maßstab 0,96 über eine Feder 0,55/0,82. Nur Deckkraft, Maßstab und
/// Versatz: nichts davon ändert das Layout, also springt nichts. Ausblenden
/// geht schnell und ohne Staffel.
struct Reihenauftritt: ViewModifier {
    let index: Int
    let da: Bool

    func body(content: Content) -> some View {
        let ruhig = Stil.bewegungReduziert
        let verzug = Double(index) * Kontowechselkurve.reihenStaffel
        content
            .scaleEffect(da || ruhig ? 1 : Kontowechselkurve.reihenMass, anchor: .top)
            .offset(y: da || ruhig ? 0 : Kontowechselkurve.reihenVersatz)
            .animation(ruhig ? Stil.blendeReduziert
                       : da ? .spring(response: 0.55, dampingFraction: 0.82).delay(verzug)
                            : .easeOut(duration: 0.12), value: da)
            .opacity(da ? 1 : 0)
            .animation(ruhig ? Stil.blendeReduziert
                       : da ? .linear(duration: Kontowechselkurve.reihenBlende).delay(verzug) : .easeOut(duration: 0.12), value: da)
    }
}

extension View {
    func reihenauftritt(_ index: Int, da: Bool) -> some View {
        modifier(Reihenauftritt(index: index, da: da))
    }
}

/// Meldet den globalen Rahmen einer Ansicht, ohne Zustand zu setzen — für
/// den Kontowechsel (Profilseite am iPhone und am Mac).
struct Rahmenmelder: ViewModifier {
    let melden: (CGRect) -> Void
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { melden($0) }
    }
}
