#if !os(macOS)
import AVFoundation
#endif
import Foundation
import JellyfinKit
import MediaPlayer

/// Was das System über die laufende Wiedergabe wissen muss.
///
/// Zwei Dinge, die bisher fehlten, obwohl die App den Audio-Hintergrundmodus
/// beansprucht:
///
/// 1. **Sperrbildschirm und Kontrollzentrum.** Ohne `MPNowPlayingInfoCenter`
///    steht dort nichts, und die Taste am Kopfhörer tut nichts. Apple sieht das
///    Bedienen dieser Schnittstelle als Nachweis, dass der Hintergrundmodus
///    berechtigt beansprucht wird — Apps ohne sie werden regelmäßig moniert.
/// 2. **Unterbrechungen.** Kommt ein Anruf, entzieht iOS die Tonsitzung. Ohne
///    Zuhören bleibt danach alles stehen, und die Oberfläche behauptet weiter,
///    es liefe.
@MainActor
final class Wiedergabezentrale {

    /// Was die Zentrale am Player auslösen darf.
    struct Griffe {
        let abspielen: () -> Void
        let anhalten: () -> Void
        let umschalten: () -> Void
        let springenAuf: (Double) -> Void
        let vor: () -> Void
        let zurueck: () -> Void
        /// `nil`, wenn es keine nächste Folge gibt.
        let naechste: (() -> Void)?
    }

    private var griffe: Griffe?

    /// **Die Zentrale merkt sich selbst, was läuft.**
    ///
    /// Nicht die Ansicht fragen (deren Kopie veraltet), nicht VLC (hinkt
    /// nach), nicht das System (schickt auf dem Fernseher stur „anhalten").
    /// Drei Wahrheiten, die sich widersprechen, waren die Ursache für einen
    /// ganzen Nachmittag. Hier steht eine, und sie wird bei jedem Befehl und
    /// bei jedem Nachziehen fortgeschrieben.
    private var spieltGerade = true
    /// Wann zuletzt über die Zentrale umgeschaltet wurde.
    ///
    /// **Der Grund, warum es zehn Anläufe gebraucht hat.** `standNachziehen`
    /// läuft im Sekundentakt und trug den Stand der Ansicht ein — und der
    /// bleibt auf „läuft", weil ein Befehl über die Zentrale die Ansicht gar
    /// nicht erreicht. Die frische Entscheidung wurde also jede Sekunde vom
    /// veralteten Wert überschrieben, und der nächste Druck hielt wieder an.
    ///
    /// Deshalb hat der Takt hier zwei Sekunden lang nichts zu melden.
    private var seitBefehl: Date?
    #if !os(macOS)
    private var beobachter: NSObjectProtocol?
    #endif
    /// Ob beim Beginn der Unterbrechung überhaupt etwas lief — nur dann wird
    /// danach weitergespielt.
    private var liefVorher = false

    // MARK: - An- und abmelden

    func uebernehmen(_ griffe: Griffe) {
        self.griffe = griffe
        befehleEinrichten()
        #if !os(macOS)
        unterbrechungenBeobachten()
        #endif
    }

    func abgeben() {
        let zentrale = MPRemoteCommandCenter.shared()
        for befehl in [zentrale.playCommand, zentrale.pauseCommand,
                       zentrale.togglePlayPauseCommand, zentrale.nextTrackCommand,
                       zentrale.skipForwardCommand, zentrale.skipBackwardCommand,
                       zentrale.changePlaybackPositionCommand] {
            befehl.removeTarget(nil)
            befehl.isEnabled = false
        }
        #if !os(macOS)
        if let beobachter {
            NotificationCenter.default.removeObserver(beobachter)
            self.beobachter = nil
        }
        #endif
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        griffe = nil
    }

    // MARK: - Was auf dem Sperrbildschirm steht

    /// - Parameter sprungweite: dieselben Werte wie im Player, damit die
    ///   Knöpfe auf dem Sperrbildschirm dasselbe tun wie die auf dem Schirm.
    func melden(item: Item, position: Double, dauer: Double, tempo: Float,
                laeuft: Bool, sprungweite: (zurueck: Int, vor: Int)) {
        var eintrag: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: laeuft ? Double(tempo) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        // Dauer nur melden, wenn sie steht — eine Null macht aus dem Balken
        // auf dem Sperrbildschirm einen Strich ohne Bedeutung.
        if dauer > 0 { eintrag[MPMediaItemPropertyPlaybackDuration] = dauer }
        if let serie = item.seriesName {
            eintrag[MPMediaItemPropertyAlbumTitle] = serie
            if let kuerzel = item.folgenkuerzel {
                eintrag[MPMediaItemPropertyArtist] = kuerzel
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = eintrag
        zustandMelden(laeuft)

        let zentrale = MPRemoteCommandCenter.shared()
        zentrale.skipBackwardCommand.preferredIntervals = [NSNumber(value: sprungweite.zurueck)]
        zentrale.skipForwardCommand.preferredIntervals = [NSNumber(value: sprungweite.vor)]
    }

    /// Nur die Stelle nachziehen — billiger als der ganze Eintrag, und beim
    /// Anhalten muss die Rate sofort stimmen, sonst läuft die Uhr auf dem
    /// Sperrbildschirm weiter.
    func standNachziehen(position: Double, laeuft: Bool, tempo: Float) {
        guard var eintrag = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        eintrag[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        eintrag[MPNowPlayingInfoPropertyPlaybackRate] = laeuft ? Double(tempo) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = eintrag
        // Nicht überschreiben, solange die eigene Entscheidung frisch ist.
        if let seitBefehl, Date().timeIntervalSince(seitBefehl) < 2 {
            zustandMelden(spieltGerade)
            return
        }
        spieltGerade = laeuft
        zustandMelden(laeuft)
    }

    /// **Den Zustand melden, nicht nur die Rate.**
    ///
    /// Die Rate steht im Eintrag und beschreibt, wie schnell gespielt wird. Ob
    /// überhaupt gespielt wird, ist eine andere Angabe — und das System
    /// entscheidet danach, welchen Befehl es beim Druck auf die
    /// Wiedergabetaste schickt.
    ///
    /// Ohne sie glaubte tvOS durchgehend, es liefe, und schickte jedesmal
    /// `pauseCommand`. Deshalb hielt der erste Druck an und jeder weitere tat
    /// nichts: es kam nie `play`, nie `togglePlayPause`, immer nur „anhalten".
    /// Gefunden hat es
    private func zustandMelden(_ laeuft: Bool) {
        MPNowPlayingInfoCenter.default().playbackState = laeuft ? .playing : .paused
    }

    /// **Alle drei Systembefehle laufen hier zusammen.**
    ///
    /// Auf dem Fernseher schickt tvOS beim Druck auf die Wiedergabetaste
    /// hartnäckig `pause` — auch dann, wenn längst angehalten ist. Am Gerät
    /// zweimal hintereinander nachgemessen. Welchen der drei Befehle das
    /// System schickt, sagt deshalb nichts darüber, was gemeint ist; gemeint
    /// ist immer „das Gegenteil von jetzt".
    private func umschalten() {
        seitBefehl = Date()
        if spieltGerade { spieltGerade = false; griffe?.anhalten() }
        else            { spieltGerade = true;  griffe?.abspielen() }
        zustandMelden(spieltGerade)
    }

    // MARK: - Befehle von außen

    /// **Jeder Befehl wird ausdrücklich auf den Hauptlauf gehoben.**
    ///
    /// Die Klasse ist `@MainActor`, und Swift nimmt deshalb an, dass auch
    /// diese Rückrufe dort laufen — sonst würde der Aufruf von `umschalten()`
    /// gar nicht übersetzen. `MPRemoteCommandCenter` ruft sie aber auf einem
    /// beliebigen Thread. Die Zusicherung gilt also, ohne eingehalten zu
    /// werden.
    ///
    /// Sichtbar wurde es am Fernseher, und zwar an einer Stelle, die mit Ton
    /// nichts zu tun hat: eine eingebaute Anzeige erschien erst, **nachdem
    /// der Fokus gewechselt hatte**. Der Zustand war längst gesetzt — nur
    /// hatte ihn niemand auf dem Hauptlauf gesetzt, und deshalb kam kein
    /// Neuzeichnen. Dasselbe traf die Wiedergabe: angehalten wurde, aber die
    /// Oberfläche erfuhr es nicht und nahm nichts mehr an.
    private func befehleEinrichten() {
        let zentrale = MPRemoteCommandCenter.shared()

        // **Der Befehl des Systems ist ein Vorschlag, unser Zustand ist die
        // Wahrheit.**
        //
        // Auf dem Fernseher schickt tvOS beim Druck auf die Wiedergabetaste
        // hartnäckig `pause` — auch dann, wenn längst angehalten ist, und
        // auch dann, wenn wir den Zustand ordentlich melden und alle drei
        // Befehle freigeschaltet sind. Am Gerät nachgemessen: zweimal
        // hintereinander „anhalten". Wer sich darauf verlässt, hält an und
        // kommt nie wieder los.
        //
        // Deshalb prüfen beide Befehle, was gerade gilt, und tun das
        // Gegenteil, wenn das System danebenliegt. Für den Sperrbildschirm
        // am Telefon ändert das nichts — dort trifft der Befehl ohnehin zu.
        zentrale.playCommand.removeTarget(nil)
        zentrale.playCommand.isEnabled = true
        zentrale.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.umschalten() }
            return .success
        }

        zentrale.pauseCommand.removeTarget(nil)
        zentrale.pauseCommand.isEnabled = true
        zentrale.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.umschalten() }
            return .success
        }

        zentrale.togglePlayPauseCommand.removeTarget(nil)
        zentrale.togglePlayPauseCommand.isEnabled = true
        zentrale.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.umschalten() }
            return .success
        }

        zentrale.skipForwardCommand.removeTarget(nil)
        zentrale.skipForwardCommand.isEnabled = true
        zentrale.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.griffe?.vor() }
            return .success
        }

        zentrale.skipBackwardCommand.removeTarget(nil)
        zentrale.skipBackwardCommand.isEnabled = true
        zentrale.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.griffe?.zurueck() }
            return .success
        }

        zentrale.changePlaybackPositionCommand.removeTarget(nil)
        zentrale.changePlaybackPositionCommand.isEnabled = true
        zentrale.changePlaybackPositionCommand.addTarget { [weak self] befehl in
            guard let ziel = befehl as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let stelle = ziel.positionTime
            Task { @MainActor in self?.griffe?.springenAuf(stelle) }
            return .success
        }

        zentrale.nextTrackCommand.removeTarget(nil)
        zentrale.nextTrackCommand.isEnabled = griffe?.naechste != nil
        zentrale.nextTrackCommand.addTarget { [weak self] _ in
            guard let naechste = self?.griffe?.naechste else { return .noSuchContent }
            naechste()
            return .success
        }

        // Vorheriger Titel gibt es nicht — den Knopf grau zu lassen ist
        // ehrlicher, als ihn ins Leere zeigen zu lassen.
        zentrale.previousTrackCommand.isEnabled = false
    }

    // MARK: - Anrufe und gezogene Kopfhörer

    // Der ganze Abschnitt entfällt auf dem Mac: `AVAudioSession` gibt es dort
    // nicht. Das ist keine Lücke — macOS entzieht einer App den Ton nicht,
    // wenn nebenbei etwas klingelt, es mischt. Es gibt also nichts, worauf
    // gehört werden müsste.
    #if !os(macOS)
    private func unterbrechungenBeobachten() {
        if let beobachter { NotificationCenter.default.removeObserver(beobachter) }
        beobachter = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] nachricht in
            // Die beiden Werte hier herausziehen und nur sie weiterreichen:
            // `Notification` ist nicht `Sendable`, und über die Aktorgrenze
            // gereicht wäre es ein Datenwettlauf.
            let roh = nachricht.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let hinweis = nachricht.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.unterbrechung(art: roh, hinweis: hinweis) }
        }
    }

    private func unterbrechung(art roh: UInt?, hinweis: UInt?) {
        guard let roh, let art = AVAudioSession.InterruptionType(rawValue: roh) else { return }

        switch art {
        case .began:
            liefVorher = (MPNowPlayingInfoCenter.default()
                .nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
            griffe?.anhalten()
        case .ended:
            // Nur weiterspielen, wenn das System es nahelegt **und** vorher
            // etwas lief. Sonst startet ein Anruf während einer Pause die
            // Wiedergabe.
            let sollWeiter = AVAudioSession.InterruptionOptions(rawValue: hinweis ?? 0)
                .contains(.shouldResume)
            if liefVorher, sollWeiter { griffe?.abspielen() }
            liefVorher = false
        @unknown default:
            break
        }
    }
    #endif
}
