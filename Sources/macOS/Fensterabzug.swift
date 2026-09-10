#if DEBUG
import AppKit
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
#endif
