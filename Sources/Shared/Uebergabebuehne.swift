import JellyfinKit
import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import CoreMotion
#endif
#if !canImport(UIKit)
import AppKit
#endif

// MARK: - „Hier weiterschauen" als Karte (Entwurf B) — iPhone, iPad, Fernseher, Mac
//
// Zeitleiste und Federn stehen im Paket (`Uebergabekarte`); hier nur, was
// Core Animation braucht. **Alles als Stützpunkte im Render-Server**: der
// Player baut sich unter der Karte auf, VLC öffnet, das Netz antwortet — all
// das läuft auf dem Hauptlauf und darf die Bewegung nicht anhalten. Bewegt
// werden nur Lage, Größe und Deckkraft; kein Leuchten, kein Bildschirmfoto.

/// **Eine durchlässige Ebene über allem** — auf iPhone, iPad und Fernseher
/// ein eigenes Fenster über dem der App, am Mac ein Kindfenster. Beides
/// liegt auch über dem Player, der während der Übergabe darunter aufgeht.
/// Koordinaten wie in SwiftUI: oben links, in Punkt.
@MainActor
final class Buehnenhalter {
    let wurzel: CALayer
    private(set) var groesse: CGSize
    let skala: CGFloat
    /// Der Schirm dreht sich (iPhone, iPad) — die neue Größe.
    var beiGroesse: ((CGSize) -> Void)?
    #if canImport(UIKit)
    private var fenster: UIWindow?
    #else
    private var fenster: NSWindow?
    private weak var eltern: NSWindow?
    #endif

    #if canImport(UIKit)
    private final class Durchlass: UIWindow {
        // Tipps gehen hindurch — die Bühne ist nur zu sehen.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private final class Stuetze: UIViewController {
        var groesseWechselt: ((CGSize) -> Void)?
        #if os(iOS)
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

        override func viewWillTransition(to size: CGSize,
                                         with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            groesseWechselt?(size)
        }
        #endif
    }

    private init(fenster: UIWindow, stuetze: Stuetze) {
        self.fenster = fenster
        self.wurzel = stuetze.view.layer
        groesse = fenster.bounds.size
        skala = fenster.screen.scale
        stuetze.groesseWechselt = { [weak self] neu in
            self?.groesse = neu
            self?.beiGroesse?(neu)
        }
    }

    static func aufbauen() -> Buehnenhalter? {
        let szenen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let szene = szenen.first(where: { $0.activationState == .foregroundActive }) ?? szenen.first,
              let haupt = szene.keyWindow else { return nil }
        let f = Durchlass(windowScene: szene)
        f.frame = haupt.frame
        f.windowLevel = UIWindow.Level(rawValue: haupt.windowLevel.rawValue + 1)
        f.backgroundColor = .clear
        let stuetze = Stuetze()
        stuetze.view.backgroundColor = .clear
        stuetze.view.isUserInteractionEnabled = false
        f.rootViewController = stuetze
        f.isHidden = false
        return Buehnenhalter(fenster: f, stuetze: stuetze)
    }

    /// Der Rahmen einer Ansicht in Bühnenkoordinaten.
    func rahmen(von ansicht: UIView) -> CGRect { ansicht.convert(ansicht.bounds, to: nil) }

    func abbauen() {
        fenster?.isHidden = true
        fenster?.rootViewController = nil
        fenster = nil
    }
    #else
    private init(fenster: NSWindow, eltern: NSWindow, wurzel: CALayer, groesse: CGSize) {
        self.fenster = fenster
        self.eltern = eltern
        self.wurzel = wurzel
        self.groesse = groesse
        skala = eltern.backingScaleFactor
    }

    static func aufbauen() -> Buehnenhalter? {
        guard let haupt = NSApp.keyWindow ?? NSApp.mainWindow, let inhalt = haupt.contentView
        else { return nil }
        let rahmen = haupt.convertToScreen(inhalt.convert(inhalt.bounds, to: nil))
        let f = NSWindow(contentRect: rahmen, styleMask: .borderless, backing: .buffered, defer: false)
        f.isOpaque = false
        f.backgroundColor = .clear
        f.hasShadow = false
        f.ignoresMouseEvents = true
        f.isReleasedWhenClosed = false
        let ansicht = NSView(frame: CGRect(origin: .zero, size: rahmen.size))
        ansicht.wantsLayer = true
        f.contentView = ansicht
        // Oben links wie in SwiftUI: eine eigene, gekippte Ebene darin.
        let wurzel = CALayer()
        wurzel.frame = ansicht.bounds
        wurzel.isGeometryFlipped = true
        ansicht.layer?.addSublayer(wurzel)
        haupt.addChildWindow(f, ordered: .above)
        return Buehnenhalter(fenster: f, eltern: haupt, wurzel: wurzel, groesse: rahmen.size)
    }

    /// Der Rahmen einer Ansicht in Bühnenkoordinaten (oben links).
    func rahmen(von ansicht: NSView) -> CGRect {
        let r = ansicht.convert(ansicht.bounds, to: nil)
        let hoehe = eltern?.contentView?.bounds.height ?? groesse.height
        return CGRect(x: r.minX, y: hoehe - r.maxY, width: r.width, height: r.height)
    }

    func abbauen() {
        if let fenster { eltern?.removeChildWindow(fenster); fenster.orderOut(nil) }
        fenster = nil
    }
    #endif

    /// Eine SwiftUI-Ansicht einmal zeichnen — für Bild und Zeilen der Karte.
    func zeichnen(_ inhalt: some View) -> CGImage? {
        let zeichner = ImageRenderer(content: inhalt)
        zeichner.scale = skala
        return zeichner.cgImage
    }
}

/// Plattformmaße und -farben der Übergabe.
@MainActor
enum Uebergabestil {
    static var masse: Uebergabekarte.Masse {
        #if os(tvOS)
        Uebergabekarte.fernseher
        #elseif os(macOS)
        Uebergabekarte.mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? Uebergabekarte.iPad : Uebergabekarte.iPhone
        #endif
    }

    /// So breit ist die Karte am Abzeichen, wenn sie aufgeht.
    static var abzeichenbreite: Double {
        #if os(tvOS)
        60
        #elseif os(macOS)
        32
        #else
        44
        #endif
    }

    static func farbe(_ c: Color) -> CGColor {
        #if canImport(UIKit)
        UIColor(c).cgColor
        #else
        NSColor(c).cgColor
        #endif
    }

    /// Titel und Folge — „The Mentalist" und „Staffel 6 · Folge 7".
    static func zeilen(_ titel: Item) -> (titel: String, unter: String?) {
        if let serie = titel.seriesName, !serie.isEmpty {
            if let s = titel.parentIndexNumber, let f = titel.indexNumber {
                return (serie, String(localized: "Staffel \(s) · Folge \(f)"))
            }
            return (serie, titel.name)
        }
        return (titel.name, nil)
    }

    /// Die Zeilen unter der Karte, links bündig in Kartenbreite; oben Platz
    /// für die Ladelinie.
    static func zeilenansicht(_ z: (titel: String, unter: String?), breite: Double,
                              masse: Uebergabekarte.Masse) -> some View {
        VStack(alignment: .leading, spacing: masse.abstand * 0.25) {
            Text(verbatim: z.titel)
                .font(.system(size: masse.titel, weight: .semibold))
                .foregroundStyle(Stil.schrift)
            if let unter = z.unter {
                Text(verbatim: unter)
                    .font(.system(size: masse.klein))
                    .foregroundStyle(Stil.schriftLeise)
            }
        }
        .lineLimit(1)
        .padding(.top, 2 + masse.abstand * 0.35)
        .frame(width: breite, alignment: .leading)
    }

    static func kartenansicht(_ bild: Image?, groesse: CGSize) -> some View {
        ZStack {
            Stil.flaeche
            if let bild { bild.resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: groesse.width, height: groesse.height)
        .clipped()
    }
}

/// **Bildzeiten während der Übergabe, am Gerät**: jede Bilddauer über 1,5
/// Soll steht mit Zeit, Dauer und Phase im Protokoll — `[Uebergabe]
/// bildzeit`. Die Bewegung läuft im Render-Server; was hier auftaucht, ist
/// der Hauptlauf (Player-Aufbau, Netz).
@MainActor
final class Uebergabebildzeit: NSObject {
    private let rolle: String
    private let phase: (Double) -> String
    private var takt: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var letzte: CFTimeInterval = 0
    private var ausreisser: [String] = []
    private var bilder = 0

    init(rolle: String, phase: @escaping (Double) -> String) {
        self.rolle = rolle
        self.phase = phase
    }

    func starten(ab: CFTimeInterval) {
        start = ab
        #if canImport(UIKit)
        let t = CADisplayLink(target: self, selector: #selector(bild(_:)))
        #else
        guard let t = NSScreen.main?.displayLink(target: self, selector: #selector(bild(_:))) else { return }
        #endif
        t.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        t.add(to: .main, forMode: .common)
        takt = t
    }

    func anhalten() {
        guard let takt else { return }
        takt.invalidate()
        self.takt = nil
        Protokoll.schreib("[Uebergabe] bildzeit \(rolle): \(bilder) bilder, \(ausreisser.count) zu lang"
            + (ausreisser.isEmpty ? "" : ": " + ausreisser.joined(separator: " ")))
    }

    @objc private func bild(_ t: CADisplayLink) {
        bilder += 1
        defer { letzte = t.timestamp }
        guard letzte > 0 else { return }
        let dauer = t.timestamp - letzte
        let soll = max(t.targetTimestamp - t.timestamp, 1.0 / 120)
        guard dauer > soll * 1.5 else { return }
        let seit = t.timestamp - start
        ausreisser.append("\(Int(seit * 1000))ms/\(Int(dauer * 1000))ms/\(phase(seit))")
    }
}

/// Ein Punkt als Stützwert — `NSValue` heißt auf beiden Seiten anders.
private func punkt(_ p: CGPoint) -> NSValue {
    #if canImport(UIKit)
    NSValue(cgPoint: p)
    #else
    NSValue(point: p)
    #endif
}

/// Stützpunkte als Keyframe-Animation — linear zwischen den Punkten, die
/// Kurve steckt in den Punkten selbst.
@MainActor
private func stuetzen(_ pfad: String, _ werte: [Any], beginn: CFTimeInterval, dauer: Double) -> CAKeyframeAnimation {
    let a = CAKeyframeAnimation(keyPath: pfad)
    a.values = werte
    a.calculationMode = .linear
    a.beginTime = beginn
    a.duration = dauer
    a.fillMode = .forwards
    a.isRemovedOnCompletion = false
    return a
}

// MARK: - Empfänger

/// **Die Karte des Empfängers.** Beim Tipp aufs Abzeichen gestartet, läuft
/// neben dem Übernehmen her und wird vom Player abgelöst, sobald sein erstes
/// Bild steht (``bildDa(_:)``).
@MainActor
final class Uebergabebuehne {
    static let geteilt = Uebergabebuehne()
    private init() {}

    /// Läuft gerade eine Übergabe? Dann öffnet der Player ohne eigene Blende
    /// und bleibt hochkant, bis die Karte weg ist.
    private(set) var aktiv = false

    private var halter: Buehnenhalter?
    private var buehne: CALayer?
    private var karte: CALayer?
    private var zeilen: CALayer?
    private var linie: CALayer?
    private var schwarz: CALayer?
    private var beginn: CFTimeInterval = 0
    private var von = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    /// Wann der (letzte) Flug begann — nach einer Drehung neu.
    private var flugAb = Uebergabekarte.kartenStart
    /// So breit ist die Karte gezeichnet; alle Maße skalieren daran.
    private var basis: Double = 1
    private var ruhe = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    private var voll = Uebergabekarte.Lage(x: 0, y: 0, breite: 1)
    private var masse = Uebergabekarte.iPhone
    private var reduziert = false
    private var titelID: String?
    private var bereit: Double?
    private var zoomAb: Double?
    private var lauf = 0
    private var messung: Uebergabebildzeit?

    private var jetzt: Double { CACurrentMediaTime() - beginn }

    private func zeit(_ was: String) {
        Protokoll.schreib("[Uebergabe] Karte +\(Int(jetzt * 1000)) ms \(was)")
    }

    /// **Beim Tipp** — noch bevor das Netz gefragt ist.
    func starten(titel: Item?, model: AppModel) {
        abraeumen()
        guard let h = Buehnenhalter.aufbauen() else { return }
        lauf += 1
        aktiv = true
        halter = h
        beginn = CACurrentMediaTime()
        titelID = titel?.id
        bereit = nil
        zoomAb = nil
        masse = Uebergabestil.masse
        reduziert = Stil.bewegungReduziert
        flugAb = Uebergabekarte.kartenStart
        #if os(iOS)
        // **Querformat fest: der Player steht von Anfang an quer** — er geht
        // unter der Karte quer auf, die Bühne dreht mit und die Karte fliegt
        // in die Querlage (``neuAusrichten(_:)``); nach dem Zoom dreht nichts
        // mehr. Sonst bleibt es hochkant, bis die Karte weg ist.
        let fest = UserDefaults.standard.object(forKey: "querformatFest") as? Bool ?? true
        if !(fest && Orientierung.querformatSperreMoeglich) {
            Orientierung.shared.uebergabeHalten()
        }
        #endif
        VLCPlayerView.uebergabeAufblenden = true

        let b = Double(h.groesse.width), hh = Double(h.groesse.height)
        voll = Uebergabekarte.vollbild(breite: b, hoehe: hh)
        ruhe = Uebergabekarte.ruhelage(breite: b, hoehe: hh, masse: masse)
        if let p = Abzeichenursprung.punkt, !reduziert {
            von = .init(x: p.x, y: p.y, breite: Uebergabestil.abzeichenbreite)
        } else {
            von = ruhe
        }

        let ebene = CALayer()
        ebene.frame = CGRect(origin: .zero, size: h.groesse)
        h.wurzel.addSublayer(ebene)
        buehne = ebene

        // Der Grund über der Seite — die Seite tritt zurück.
        let grund = CALayer()
        grund.frame = ebene.bounds
        grund.backgroundColor = Uebergabestil.farbe(Stil.grund)
        grund.opacity = 0
        ebene.addSublayer(grund)

        let schwarz = CALayer()
        schwarz.frame = ebene.bounds
        schwarz.backgroundColor = Uebergabestil.farbe(.black)  // wie der Grund des Players
        schwarz.opacity = 0
        ebene.addSublayer(schwarz)
        self.schwarz = schwarz

        // Die Karte in voller Größe gezeichnet, verkleinert bewegt.
        let kartengroesse = CGSize(width: voll.breite, height: voll.hoehe)
        basis = voll.breite
        let karte = CALayer()
        karte.bounds = CGRect(origin: .zero, size: kartengroesse)
        karte.masksToBounds = true
        karte.opacity = 0
        karte.contentsGravity = .resizeAspectFill
        ebene.addSublayer(karte)
        self.karte = karte
        let url = titel.flatMap { Uebernahmemodell.kartenbildURL($0, model: model) }
        let vorhanden = url.flatMap { Bildspeicher.geteilt.bild($0) }
        karte.contents = h.zeichnen(Uebergabestil.kartenansicht(vorhanden, groesse: kartengroesse))
        if vorhanden == nil, let url {
            let meiner = lauf
            Task { @MainActor in
                guard let bild = await Bildspeicher.geteilt.laden(url, kante: 1280),
                      meiner == self.lauf, let h = self.halter else { return }
                // Kommt das Bild nach, blendet es über (Standardblende der Ebene).
                self.karte?.contents = h.zeichnen(Uebergabestil.kartenansicht(bild, groesse: kartengroesse))
                self.zeit("Bild nachgeladen")
            }
        }

        // Titel und Folge darunter, mit Platz für die Ladelinie.
        let zeilen = CALayer()
        if let titel {
            let z = Uebergabestil.zeilen(titel)
            let bild = h.zeichnen(Uebergabestil.zeilenansicht(z, breite: ruhe.breite, masse: masse))
            zeilen.contents = bild
            let hoehe = bild.map { CGFloat($0.height) / h.skala } ?? 0
            zeilen.bounds = CGRect(x: 0, y: 0, width: ruhe.breite, height: hoehe)
        }
        zeilen.anchorPoint = CGPoint(x: 0.5, y: 0)
        zeilen.opacity = 0
        ebene.addSublayer(zeilen)
        self.zeilen = zeilen

        let linie = CALayer()
        linie.frame = CGRect(x: 0, y: 0, width: ruhe.breite, height: 2)
        linie.cornerRadius = 1  // halbe Höhe: eine Kapsel
        linie.masksToBounds = true
        linie.backgroundColor = Uebergabestil.farbe(Stil.rand)
        linie.opacity = 0
        let balken = CALayer()
        balken.frame = CGRect(x: 0, y: 0, width: ruhe.breite * 0.3, height: 2)
        balken.cornerRadius = 1
        balken.backgroundColor = Uebergabestil.farbe(Stil.akzent)
        linie.addSublayer(balken)
        zeilen.addSublayer(linie)
        self.linie = linie

        if reduziert { blendenLegen(grund: grund) } else { flugLegen(grund: grund) }
        h.beiGroesse = { [weak self] neu in self?.neuAusrichten(neu) }

        messung = Uebergabebildzeit(rolle: "empfaenger") { [weak self] t in self?.phase(t) ?? "?" }
        messung?.starten(ab: beginn)
        zeit(reduziert ? "blendet auf (reduziert)" : "wächst aus dem Abzeichen")

        // Die Ladelinie nur, wenn das Bild bei 0,75 s noch fehlt.
        let meiner = self.lauf
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Uebergabekarte.ladelinieAb))
            guard meiner == self.lauf, self.aktiv, self.zoomAb == nil,
                  Uebergabekarte.ladelinie(bereit: self.bereit) else { return }
            self.ladelinieZeigen()
        }
    }

    private func phase(_ t: Double) -> String {
        if let z = zoomAb {
            if t >= z + Uebergabekarte.kartenAusVon { return "blende" }
            if t >= z { return "zoom" }
        }
        if t < Uebergabekarte.seiteBis { return "seite" }
        if t < Uebergabekarte.schweben { return "flug" }
        return "schweben"
    }

    /// Flug aus dem Abzeichen und Schweben — gerechnet bis weit über die
    /// längste Wartezeit hinaus; der Zoom legt sich später darüber.
    private func flugLegen(grund: CALayer) {
        guard let karte, let zeilen else { return }
        bahnLegen(ab: 0)

        let kurz = Uebergabekarte.stuetzpunkte(von: 0, bis: 1) { $0 }
        karte.add(stuetzen("opacity", kurz.map { NSNumber(value: Uebergabekarte.kartendeckung($0)) },
                           beginn: beginn, dauer: 1), forKey: "flug.deckung")
        grund.add(stuetzen("opacity", kurz.map { NSNumber(value: Uebergabekarte.seitendeckung($0)) },
                           beginn: beginn, dauer: 1), forKey: "seite")
        zeilen.add(stuetzen("opacity", kurz.map { NSNumber(value: Uebergabekarte.zeilendeckung($0, zoomAb: nil)) },
                            beginn: beginn, dauer: 1), forKey: "zeilen.an")
    }

    /// Die Bahn der wartenden Karte ab `ab` (Sekunden seit dem Tipp).
    private func bahnLegen(ab: Double) {
        guard let karte, let zeilen else { return }
        let bis = Uebergabekarte.schweben + Uebergabekarte.hoechstensWarten + 8
        guard bis > ab else { return }
        let (vo, na, fa) = (von, ruhe, flugAb)
        let lagen = Uebergabekarte.stuetzpunkte(von: ab, bis: bis) {
            Uebergabekarte.warten($0, von: vo, nach: na, ab: fa)
        }
        let v = voll, m = masse, b = basis
        karte.add(stuetzen("position", lagen.map { punkt(CGPoint(x: $0.x, y: $0.y)) },
                           beginn: beginn + ab, dauer: bis - ab), forKey: "flug.ort")
        karte.add(stuetzen("transform.scale", lagen.map { NSNumber(value: $0.breite / b) },
                           beginn: beginn + ab, dauer: bis - ab), forKey: "flug.mass")
        karte.add(stuetzen("cornerRadius", lagen.map {
            NSNumber(value: Uebergabekarte.ecke($0, masse: m, voll: v) * b / $0.breite)
        }, beginn: beginn + ab, dauer: bis - ab), forKey: "flug.ecke")
        zeilen.add(stuetzen("position", lagen.map {
            punkt(CGPoint(x: $0.x, y: Uebergabekarte.zeilenOben($0, masse: m)))
        }, beginn: beginn + ab, dauer: bis - ab), forKey: "flug.ort")
    }

    /// **Der Schirm dreht sich**, während die Karte wartet — meist, weil der
    /// Player darunter quer aufgeht. Die Bühne nimmt die neue Größe an, und
    /// die Karte fliegt von dort, wo sie gerade ist, in die Ruhelage des
    /// neuen Formats; der Zoom geht dann gleich aufs quere Bild.
    private func neuAusrichten(_ neu: CGSize) {
        guard aktiv, let buehne else { return }
        let t = jetzt
        zeit("Drehung auf \(Int(neu.width))×\(Int(neu.height))")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buehne.frame = CGRect(origin: .zero, size: neu)
        for e in buehne.sublayers ?? [] where e !== karte && e !== zeilen {
            e.frame = buehne.bounds
        }
        CATransaction.commit()
        let b = Double(neu.width), hh = Double(neu.height)
        voll = Uebergabekarte.vollbild(breite: b, hoehe: hh)
        let alteRuhe = ruhe
        ruhe = Uebergabekarte.ruhelage(breite: b, hoehe: hh, masse: masse)
        guard !reduziert, zoomAb == nil else {
            if reduziert, let karte, let zeilen {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                karte.position = CGPoint(x: ruhe.x, y: ruhe.y)
                zeilen.position = CGPoint(x: ruhe.x, y: Uebergabekarte.zeilenOben(ruhe, masse: masse))
                CATransaction.commit()
            }
            return
        }
        von = Uebergabekarte.flug(t, von: von, nach: alteRuhe, ab: flugAb)
        flugAb = t
        bahnLegen(ab: t)
    }

    /// Mit reduzierter Bewegung: alles steht, nur Blenden.
    private func blendenLegen(grund: CALayer) {
        guard let karte, let zeilen else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        karte.position = CGPoint(x: ruhe.x, y: ruhe.y)
        karte.transform = CATransform3DMakeScale(ruhe.breite / basis, ruhe.breite / basis, 1)
        karte.cornerRadius = masse.ecke * basis / ruhe.breite
        zeilen.position = CGPoint(x: ruhe.x, y: Uebergabekarte.zeilenOben(ruhe, masse: masse))
        CATransaction.commit()
        for (ebene, ab) in [(grund, 0.0), (karte, Uebergabekarte.kartenStart), (zeilen, Uebergabekarte.kartenStart)] {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0; a.toValue = 1
            a.beginTime = beginn + ab
            a.duration = Uebergabekarte.blende
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            ebene.add(a, forKey: "blende")
        }
    }

    private func ladelinieZeigen() {
        guard let linie, let lauf = linie.sublayers?.first else { return }
        zeit("Ladelinie")
        let an = CABasicAnimation(keyPath: "opacity")
        an.fromValue = 0; an.toValue = 1
        an.beginTime = CACurrentMediaTime()
        an.duration = Uebergabekarte.ladelinieEinblenden
        an.fillMode = .forwards
        an.isRemovedOnCompletion = false
        linie.add(an, forKey: "an")
        let b = linie.bounds.width, w = lauf.bounds.width
        let fahrt = CABasicAnimation(keyPath: "position.x")
        fahrt.fromValue = -w / 2
        fahrt.toValue = b + w / 2
        fahrt.duration = Uebergabekarte.ladelinieTakt
        fahrt.repeatCount = .infinity
        lauf.add(fahrt, forKey: "fahrt")
    }

    /// **Der Player steht** (unsichtbar unter der Karte). Ab hier wartet die
    /// Karte höchstens ``Uebergabekarte/hoechstensWarten`` aufs erste Bild.
    func spielerKommt(_ itemID: String) {
        guard aktiv else { return }
        titelID = itemID
        zeit("Player geöffnet")
        let meiner = lauf
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Uebergabekarte.hoechstensWarten))
            guard meiner == self.lauf, self.aktiv, self.zoomAb == nil else { return }
            self.zeit("kein erstes Bild — Karte gibt trotzdem frei")
            self.zoomen(bereit: self.jetzt)
        }
    }

    /// **Das erste Bild steht** — jetzt zoomt die Karte (frühestens bei
    /// ``Uebergabekarte/schweben``) und gibt das Bild frei.
    func bildDa(_ itemID: String) {
        guard aktiv, zoomAb == nil, itemID == titelID else { return }
        zeit("erstes Bild")
        zoomen(bereit: jetzt)
    }

    private func zoomen(bereit t: Double) {
        guard let karte, let zeilen, let schwarz, let buehne else { return }
        bereit = t
        let z = reduziert ? t : Uebergabekarte.zoomBeginn(bereit: t)
        zoomAb = z
        let ab = beginn + z

        if reduziert {
            let aus = CABasicAnimation(keyPath: "opacity")
            aus.fromValue = 1; aus.toValue = 0
            aus.beginTime = ab
            aus.duration = Uebergabekarte.blendeAus
            aus.fillMode = .forwards
            aus.isRemovedOnCompletion = false
            buehne.add(aus, forKey: "aus")
            beenden(nach: z + Uebergabekarte.blendeAus + 0.05)
            return
        }

        // Aus Lage **und Schwung** der wartenden Karte — kein Halt.
        let start = Uebergabekarte.warten(z, von: von, nach: ruhe, ab: flugAb)
        let schwung = Uebergabekarte.schwung(z, von: von, nach: ruhe, ab: flugAb)
        let dauer = Uebergabekarte.ende
        let lagen = Uebergabekarte.stuetzpunkte(von: 0, bis: dauer) {
            Uebergabekarte.zoom($0, von: start, schwung: schwung, nach: voll)
        }
        let v = voll, m = masse, b = basis
        karte.add(stuetzen("position", lagen.map { punkt(CGPoint(x: $0.x, y: $0.y)) },
                           beginn: ab, dauer: dauer), forKey: "zoom.ort")
        karte.add(stuetzen("transform.scale", lagen.map { NSNumber(value: $0.breite / b) },
                           beginn: ab, dauer: dauer), forKey: "zoom.mass")
        karte.add(stuetzen("cornerRadius", lagen.map {
            NSNumber(value: Uebergabekarte.ecke($0, masse: m, voll: v) * b / $0.breite)
        }, beginn: ab, dauer: dauer), forKey: "zoom.ecke")
        zeilen.add(stuetzen("position", lagen.map {
            punkt(CGPoint(x: $0.x, y: Uebergabekarte.zeilenOben($0, masse: m)))
        }, beginn: ab, dauer: dauer), forKey: "zoom.ort")

        let zeilenAus = CABasicAnimation(keyPath: "opacity")
        zeilenAus.fromValue = 1; zeilenAus.toValue = 0
        zeilenAus.beginTime = ab
        zeilenAus.duration = Uebergabekarte.zeilenAus
        zeilenAus.fillMode = .forwards
        zeilenAus.isRemovedOnCompletion = false
        zeilen.add(zeilenAus, forKey: "zeilen.aus")

        let schwarzAn = CABasicAnimation(keyPath: "opacity")
        schwarzAn.fromValue = 0; schwarzAn.toValue = 1
        schwarzAn.beginTime = ab
        schwarzAn.duration = Uebergabekarte.schwarzDauer
        schwarzAn.fillMode = .forwards
        schwarzAn.isRemovedOnCompletion = false
        schwarz.add(schwarzAn, forKey: "an")

        let aus = Uebergabekarte.stuetzpunkte(von: 0, bis: dauer) {
            NSNumber(value: Uebergabekarte.buehnendeckung(nachZoom: $0))
        }
        buehne.add(stuetzen("opacity", aus, beginn: ab, dauer: dauer), forKey: "aus")
        zeit("Zoom ab +\(Int(z * 1000)) ms")
        beenden(nach: z + dauer)
    }

    private func beenden(nach t: Double) {
        let meiner = lauf
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, t - self.jetzt)))
            guard meiner == self.lauf else { return }
            self.zeit("fertig")
            self.abraeumen()
        }
    }

    /// **Die Übergabe ist gescheitert** (kein Plan, Stopp abgelehnt) oder der
    /// Player wurde während des Wartens geschlossen: die Bühne blendet aus.
    func abbrechen(_ grund: String) {
        guard aktiv, let buehne else { return }
        zeit("abgebrochen: \(grund)")
        VLCPlayerView.uebergabeAufblenden = false
        let aus = CABasicAnimation(keyPath: "opacity")
        aus.fromValue = buehne.presentation()?.opacity ?? 1
        aus.toValue = 0
        aus.duration = Uebergabekarte.blende
        aus.fillMode = .forwards
        aus.isRemovedOnCompletion = false
        buehne.add(aus, forKey: "aus")
        let meiner = lauf
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Uebergabekarte.blende + 0.05))
            guard meiner == self.lauf else { return }
            self.abraeumen()
        }
    }

    /// Der Player ging zu, bevor die Karte ihn freigab.
    func spielerWeg(_ itemID: String) {
        guard aktiv, itemID == titelID, zoomAb == nil else { return }
        abbrechen("Player geschlossen")
    }

    private func abraeumen() {
        messung?.anhalten()
        messung = nil
        halter?.abbauen()
        halter = nil
        buehne = nil; karte = nil; zeilen = nil; linie = nil; schwarz = nil
        guard aktiv else { return }
        aktiv = false
        lauf += 1
        // Gilt für genau diesen Start; kam er nie, nicht für den nächsten.
        VLCPlayerView.uebergabeAufblenden = false
        #if os(iOS)
        // **Quer erst jetzt** — und nur, wenn der Player laut Einstellung
        // quer aufgeht.
        let fest = UserDefaults.standard.object(forKey: "querformatFest") as? Bool ?? true
        Orientierung.shared.uebergabeFreigeben(querformatFest: fest)
        #endif
    }
}

// MARK: - Abgeber

/// **Das Bild des Abgebers geht als Karte — das Spiegelbild des Empfängers.**
///
/// **In einer eigenen Ebene über allem, nicht im Player** (Paul am iPhone,
/// 27.09.): bis dahin wurde die Videofläche im Player selbst bewegt, und
/// dessen Steuerung und Ebenen lagen darüber — die Karte lief darunter und
/// war kaum zu sehen. Jetzt hält der Player an, VLC gibt sein stehendes Bild
/// heraus (``VLCPlayerView/standbild(breite:)``), und die Bühne legt sich mit
/// diesem Bild genau an die Stelle des Videos, deckend über den ganzen
/// Schirm — ab ihrem ersten Bild ist vom Player nichts mehr zu sehen. Die
/// Karte schrumpft mit der Feder des Zooms, schwebt kurz und fliegt mit der
/// Feder des Wachsens hinaus — zum größeren Gerät nach oben, zum kleineren
/// nach unten (``Uebergabekarte/abflugNachOben(von:nach:)``). Erst dann
/// schließt der Player, unter der Bühne (am iPhone dreht es dabei zurück ins
/// Hochformat, unsichtbar unter dem einfarbigen Grund), und der Grund blendet
/// auf die Seite aus.
@MainActor
enum Uebergabeabgang {
    private static var halter: Buehnenhalter?
    private static var messung: Uebergabebildzeit?
    /// Bis die Seite darunter steht: Schließen samt Drehung zurück.
    private static let schliessdauer = 0.5
    #if os(iOS)
    /// Die Schwerkraft beim Abgang — wie das iPhone gerade wirklich gehalten
    /// wird, unabhängig davon, wie die Oberfläche steht.
    private static var bewegung: CMMotionManager?
    #endif

    /// **Die Haltungsmessung aus, auf jedem Weg.** Sie stand nur in
    /// `abflugrichtung` — die läuft aber weder bei reduzierter Bewegung noch,
    /// wenn es gar kein Bild gibt. Dort lief der Bewegungssensor mit 60 Hz
    /// weiter, bis zur nächsten Übergabe, die ihn nur überschrieb.
    private static func bewegungAus() {
        #if os(iOS)
        bewegung?.stopDeviceMotionUpdates()
        bewegung = nil
        #endif
    }

    /// - Parameters:
    ///   - flaeche: die Videofläche des Players.
    ///   - ziel: wer übernimmt („iPhone", „Apple TV" …) — bestimmt die Abflugrichtung.
    ///   - anhalten: sofort — das Bild steht, der Ton ist weg.
    ///   - fertig: die Karte ist draußen — der Player schließt (unter der Bühne).
    static func starten(flaeche: VLCPlayerView, ziel: String, titel: Item, model: AppModel,
                        anhalten: @escaping () -> Void, fertig: @escaping () -> Void) {
        halter?.abbauen()
        halter = nil
        messung?.anhalten()
        messung = nil
        bewegungAus()
        let reduziert = Stil.bewegungReduziert
        let stopp = CACurrentMediaTime()
        func zeit(_ was: String) {
            Protokoll.schreib("[Uebergabe] Abgang +\(Int((CACurrentMediaTime() - stopp) * 1000)) ms \(was)")
        }
        zeit("an \(ziel)\(reduziert ? " (reduziert)" : "")")
        anhalten()
        #if os(iOS)
        let m = CMMotionManager()
        if m.isDeviceMotionAvailable {
            m.deviceMotionUpdateInterval = 1.0 / 60
            m.startDeviceMotionUpdates()
            bewegung = m
        }
        #endif

        #if canImport(UIKit)
        let pixel = Int(flaeche.bounds.width * flaeche.contentScaleFactor)
        #else
        let pixel = Int(flaeche.bounds.width * (flaeche.window?.backingScaleFactor ?? 2))
        #endif
        Task { @MainActor in
            // **Das echte Bild, wenn es eins ist — sonst das Folgenbild.** Am
            // iPhone gab VLCs Standbild am 27.09. nach 74–158 ms ein Bild
            // heraus, das ganz schwarz war; die Karte flog schwarz. Ein fast
            // schwarzes Standbild zählt deshalb nicht.
            var bild = await flaeche.standbild(breite: pixel)
            if let b = bild, let hell = helligkeit(b), hell < 0.04 {
                zeit("Standbild schwarz (Helligkeit \(String(format: "%.3f", hell))) — Folgenbild")
                bild = nil
            } else if bild == nil {
                zeit("kein Standbild — Folgenbild")
            } else {
                zeit("Standbild da")
            }
            var gefuellt = false
            if bild == nil, let url = Uebernahmemodell.kartenbildURL(titel, model: model) {
                let folgenbild: Image?
                if let da = Bildspeicher.geteilt.bild(url) { folgenbild = da }
                else { folgenbild = await Bildspeicher.geteilt.laden(url, kante: 1280) }
                if let folgenbild, let h0 = Buehnenhalter.aufbauen() {
                    let r = h0.rahmen(von: flaeche)
                    let v = Uebergabekarte.vollbild(breite: r.width, hoehe: r.height)
                    bild = h0.zeichnen(Uebergabestil.kartenansicht(folgenbild,
                                       groesse: CGSize(width: v.breite, height: v.hoehe)))
                    h0.abbauen()
                    gefuellt = true
                }
            }
            guard let bild, let h = Buehnenhalter.aufbauen() else {
                zeit("weder Standbild noch Folgenbild — Player schließt wie sonst")
                bewegungAus()
                fertig()
                return
            }
            halter = h
            if gefuellt { zeit("Folgenbild da") }
            #if os(iOS)
            // Die erste Messung kommt nach wenigen Hundertstelsekunden.
            var n = 0
            while bewegung != nil, bewegung?.deviceMotion == nil, n < 6 {
                try? await Task.sleep(for: .milliseconds(20))
                n += 1
            }
            #endif
            spielen(h, bild: bild, rahmen: h.rahmen(von: flaeche), ziel: ziel, titel: titel,
                    reduziert: reduziert, zeit: zeit, fertig: fertig)
        }
    }

    /// **Die Abflugrichtung auf dem Schirm.** Am iPhone und iPad nach der
    /// echten Haltung (Schwerkraft): wer das Telefon beim Wechsel schon wieder
    /// hochkant hält, während der Player quer steht, sieht die Karte zur
    /// physisch oberen Kante fliegen — Richtung Fernseher. Fernseher und Mac:
    /// schlicht oben oder unten.
    private static func abflugrichtung(nachOben: Bool, zeit: (String) -> Void) -> Uebergabekarte.Richtung {
        #if os(iOS)
        defer { bewegungAus() }
        let szene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let g = bewegung?.deviceMotion?.gravity, let lage = szene?.interfaceOrientation else {
            zeit("keine Schwerkraft — Oben der Oberfläche")
            return nachOben ? .oben : .unten
        }
        let oberflaeche: Uebergabekarte.Oberflaeche
        switch lage {
        case .portraitUpsideDown: oberflaeche = .kopfueber
        case .landscapeRight: oberflaeche = .querHomeRechts
        case .landscapeLeft: oberflaeche = .querHomeLinks
        default: oberflaeche = .hoch
        }
        zeit("Schwerkraft \(String(format: "%.2f, %.2f, %.2f", g.x, g.y, g.z)) · Oberfläche \(oberflaeche)")
        return Uebergabekarte.abflugrichtung(schwerkraftX: g.x, schwerkraftY: g.y,
                                             oberflaeche: oberflaeche, nachOben: nachOben)
        #else
        return nachOben ? .oben : .unten
        #endif
    }

    /// Holt das Folgenbild vorab in den Bildspeicher.
    static func vorladen(_ titel: Item, model: AppModel) async {
        guard let url = Uebernahmemodell.kartenbildURL(titel, model: model),
              Bildspeicher.geteilt.bild(url) == nil else { return }
        _ = await Bildspeicher.geteilt.laden(url, kante: 1280)
    }

    /// Mittlere Helligkeit 0…1, auf 16 × 16 Punkte verkleinert.
    private static func helligkeit(_ bild: CGImage) -> Double? {
        let n = 16
        var punkte = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &punkte, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(bild, in: CGRect(x: 0, y: 0, width: n, height: n))
        var summe = 0.0
        for i in stride(from: 0, to: punkte.count, by: 4) {
            summe += 0.2126 * Double(punkte[i]) + 0.7152 * Double(punkte[i + 1]) + 0.0722 * Double(punkte[i + 2])
        }
        return summe / Double(n * n) / 255
    }

    private static func spielen(_ h: Buehnenhalter, bild: CGImage, rahmen r: CGRect, ziel: String,
                                titel: Item, reduziert: Bool, zeit: @escaping (String) -> Void,
                                fertig: @escaping () -> Void) {
        let beginn = CACurrentMediaTime()
        let masse = Uebergabestil.masse
        let schirm = h.groesse

        // Wo das Video in der Fläche stand: eingepasst nach dem Bild selbst.
        let seiten = Double(bild.width) / Double(max(bild.height, 1))
        let vb = min(Double(r.width), Double(r.height) * seiten)
        let voll = Uebergabekarte.Lage(x: r.midX, y: r.midY, breite: vb)
        let karte = Uebergabekarte.ruhelage(breite: schirm.width, hoehe: schirm.height, masse: masse)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let grund = CALayer()
        grund.frame = CGRect(origin: .zero, size: schirm)
        grund.backgroundColor = Uebergabestil.farbe(Stil.grund)
        h.wurzel.addSublayer(grund)
        let schwarz = CALayer()
        schwarz.frame = grund.frame
        schwarz.backgroundColor = Uebergabestil.farbe(.black)  // wie der Grund des Players
        h.wurzel.addSublayer(schwarz)
        let kl = CALayer()
        kl.bounds = CGRect(x: 0, y: 0, width: vb, height: vb / seiten)
        kl.position = CGPoint(x: voll.x, y: voll.y)
        kl.contents = bild
        kl.contentsGravity = .resizeAspect
        kl.masksToBounds = true
        h.wurzel.addSublayer(kl)
        CATransaction.commit()
        h.beiGroesse = { neu in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            grund.frame = CGRect(origin: .zero, size: neu)
            schwarz.frame = grund.frame
            CATransaction.commit()
        }
        zeit("Bühne deckt den Player ab ihrem ersten Bild")

        let raus: Double
        if reduziert {
            bewegungAus()
            for e in [kl, schwarz] {
                let aus = CABasicAnimation(keyPath: "opacity")
                aus.fromValue = 1; aus.toValue = 0
                aus.beginTime = beginn
                aus.duration = Uebergabekarte.blendeAus
                aus.fillMode = .forwards
                aus.isRemovedOnCompletion = false
                e.add(aus, forKey: "aus")
            }
            raus = Uebergabekarte.blendeAus
        } else {
            let z = Uebergabestil.zeilen(titel)
            let zeilen = CALayer()
            let zbild = h.zeichnen(Uebergabestil.zeilenansicht(z, breite: karte.breite, masse: masse))
            zeilen.contents = zbild
            zeilen.bounds = CGRect(x: 0, y: 0, width: karte.breite,
                                   height: zbild.map { CGFloat($0.height) / h.skala } ?? 0)
            zeilen.anchorPoint = CGPoint(x: 0.5, y: 0)
            zeilen.opacity = 0
            h.wurzel.addSublayer(zeilen)

            let oben = Uebergabekarte.abflugNachOben(von: Uebernahmemodell.eigenerName, nach: ziel)
            let richtung = abflugrichtung(nachOben: oben, zeit: zeit)
            raus = Uebergabekarte.abgangRaus(voll: voll, karte: karte, richtung: richtung)
            zeit("fliegt nach \(oben ? "oben" : "unten") (\(String(format: "%.2f, %.2f", richtung.x, richtung.y))), draußen nach \(Int(raus * 1000)) ms")
            let bis = raus + 0.1
            let lagen = Uebergabekarte.stuetzpunkte(von: 0, bis: bis) {
                Uebergabekarte.abgang($0, voll: voll, karte: karte, richtung: richtung)
            }
            kl.add(stuetzen("position", lagen.map { punkt(CGPoint(x: $0.x, y: $0.y)) },
                            beginn: beginn, dauer: bis), forKey: "ort")
            kl.add(stuetzen("transform.scale", lagen.map { NSNumber(value: $0.breite / vb) },
                            beginn: beginn, dauer: bis), forKey: "mass")
            kl.add(stuetzen("cornerRadius", lagen.map {
                NSNumber(value: Uebergabekarte.ecke($0, masse: masse, voll: voll) * vb / $0.breite)
            }, beginn: beginn, dauer: bis), forKey: "ecke")
            zeilen.add(stuetzen("position", lagen.map {
                punkt(CGPoint(x: $0.x, y: Uebergabekarte.zeilenOben($0, masse: masse)))
            }, beginn: beginn, dauer: bis), forKey: "ort")
            zeilen.add(stuetzen("opacity", Uebergabekarte.stuetzpunkte(von: 0, bis: bis) {
                NSNumber(value: Uebergabekarte.abgangZeilendeckung($0))
            }, beginn: beginn, dauer: bis), forKey: "deckung")
            // Spiegel des Empfängers: Schwarz geht, wenn die Karte schrumpft.
            let schwarzAus = CABasicAnimation(keyPath: "opacity")
            schwarzAus.fromValue = 1; schwarzAus.toValue = 0
            schwarzAus.beginTime = beginn + Uebergabekarte.abgangStart
            schwarzAus.duration = Uebergabekarte.schwarzDauer
            schwarzAus.fillMode = .forwards
            schwarzAus.isRemovedOnCompletion = false
            schwarz.add(schwarzAus, forKey: "aus")
        }

        messung = Uebergabebildzeit(rolle: "abgeber") { t in
            if reduziert { return "blende" }
            if t < Uebergabekarte.abgangStart { return "stand" }
            if t < Uebergabekarte.abgangSchwebenAb { return "schrumpfen" }
            if t < Uebergabekarte.abflug { return "schweben" }
            if t < raus { return "abflug" }
            return "schliessen"
        }
        messung?.starten(ab: beginn)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, raus - (CACurrentMediaTime() - beginn))))
            zeit("Karte draußen — Player schließt unter der Bühne")
            fertig()
            try? await Task.sleep(for: .seconds(schliessdauer))
            #if os(iOS)
            // **Erst wenn der Rahmen wirklich zu ist** — am 27.09. stand er
            // nach 0,5 s noch (Schließen samt Drehung dauert länger), und der
            // Grund blendete auf den Player statt auf die Seite. Höchstens 2 s.
            var gewartet = 0
            while Playerrahmen.aktiv != nil, gewartet < 30 {
                try? await Task.sleep(for: .milliseconds(50))
                gewartet += 1
            }
            zeit("Player weg: \(Playerrahmen.aktiv == nil ? "ja" : "nein") — Grund blendet zur Seite")
            #else
            zeit("Grund blendet zur Seite")
            #endif
            let aus = CABasicAnimation(keyPath: "opacity")
            aus.fromValue = 1; aus.toValue = 0
            aus.duration = Uebergabekarte.blende
            aus.fillMode = .forwards
            aus.isRemovedOnCompletion = false
            grund.add(aus, forKey: "aus")
            try? await Task.sleep(for: .seconds(Uebergabekarte.blende + 0.05))
            messung?.anhalten()
            messung = nil
            h.abbauen()
            if halter === h { halter = nil }
        }
    }
}
