#if !os(macOS)
import AVFoundation
import UIKit
/// Das, was `MPMediaItemArtwork` auf dieser Plattform erwartet.
typealias Systembild = UIImage
#else
import AppKit
typealias Systembild = NSImage
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
    /// Wann dieser Player die Zentrale bekommen hat — fuer die Schonfrist
    /// beim Routenwechsel.
    private var seitUebernahme = Date.distantPast
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
        seitUebernahme = Date()
        unterbrechungenBeobachten()
        routenwechselBeobachten()
        #endif
    }

    func abgeben() {
        #if !os(macOS)
        if let routenbeobachter {
            NotificationCenter.default.removeObserver(routenbeobachter)
            self.routenbeobachter = nil
        }
        #endif
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
        titelbild = nil
        titelbildFuer = nil
        griffe = nil
    }

    // MARK: - Was auf dem Sperrbildschirm steht

    /// - Parameter sprungweite: dieselben Werte wie im Player, damit die
    ///   Knöpfe auf dem Sperrbildschirm dasselbe tun wie die auf dem Schirm.
    func melden(item: Item, position: Double, dauer: Double, tempo: Float,
                laeuft: Bool, sprungweite: (zurueck: Int, vor: Int),
                // **Ohne Vorgabewert, und zwar mit Absicht.** Mit `= nil`
                // uebersetzten alle drei Aufrufer weiter, gaben aber nichts
                // mit — der Sperrbildschirm blieb grau, und niemand merkte es.
                // Kommt eine vierte Plattform dazu, soll der Uebersetzer
                // meckern, nicht der Nutzer.
                bildURL: URL?) {
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
        // Das schon geladene Titelbild sofort mitgeben — sonst blitzt bei
        // jedem Takt der graue Kasten auf, weil `nowPlayingInfo` als Ganzes
        // ersetzt wird und der alte Eintrag mit verschwindet.
        if let bild = titelbild, titelbildFuer == item.id {
            eintrag[MPMediaItemPropertyArtwork] = bild
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = eintrag
        zustandMelden(laeuft)
        titelbildHolen(bildURL, fuer: item.id)

        let zentrale = MPRemoteCommandCenter.shared()
        zentrale.skipBackwardCommand.preferredIntervals = [NSNumber(value: sprungweite.zurueck)]
        zentrale.skipForwardCommand.preferredIntervals = [NSNumber(value: sprungweite.vor)]
    }

    // MARK: - Das Titelbild auf dem Sperrbildschirm

    /// Das geladene Bild und der Titel, zu dem es gehoert.
    ///
    /// **Beides zusammen, nicht nur das Bild.** `melden` laeuft im Takt und
    /// ersetzt `nowPlayingInfo` vollstaendig; ohne die Zuordnung stuende beim
    /// Folgenwechsel eine Weile das Bild der vorigen Folge da.
    private var titelbild: MPMediaItemArtwork?
    private var titelbildFuer: String?

    /// Holt das Titelbild einmal je Titel und traegt es nach.
    ///
    /// **Warum ueberhaupt nachtragen und nicht gleich mitgeben:** die Adresse
    /// zeigt auf den Jellyfin-Server, das Bild muss also uebers Netz. Der
    /// Sperrbildschirm soll aber sofort Titel und Balken zeigen, nicht auf ein
    /// Bild warten. Also erst melden, dann nachreichen.
    ///
    /// Bis dahin stand dort ein grauer Kasten — bei Filmen wie bei Serien.
    /// `MPMediaItemPropertyArtwork` wurde schlicht nie gesetzt.
    /// Packt ein geladenes Bild so ein, wie `MPMediaItemArtwork` es verlangt.
    ///
    /// **Der Rueckrufblock muss die angeforderte Groesse liefern, nicht die
    /// vorhandene.** Sperrbildschirm, Kontrollzentrum und CarPlay fragen
    /// verschiedene Kantenlaengen an; wer stur dasselbe Bild zurueckgibt,
    /// bekommt von MediaPlayer eine Ausnahme — im Debug-Bau ein sofortiger
    /// Absturz beim Start der Wiedergabe.
    /// **`nonisolated`, und das ist der Kern.** Die Klasse ist `@MainActor`;
    /// ein hier geschriebener Block erbt diese Isolation. MediaPlayer ruft
    /// ihn aber aus einem eigenen Thread, und Swift 6 bricht dann ab — im
    /// Protokoll steht nur „terminated due to signal 5", ohne ein Wort dazu,
    /// welche Zusicherung gebrochen wurde.
    ///
    /// Dieselbe Falle wie bei VLCKits Rueckrufen, siehe `Zustandsmelder`:
    /// `@MainActor` ist eine Zusicherung, keine Umleitung.
    private nonisolated static func werkstueck(aus bild: Systembild) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: bild.size) { groesse in
            guard groesse != bild.size else { return bild }
            #if os(macOS)
            let neu = NSImage(size: groesse)
            neu.lockFocus()
            bild.draw(in: NSRect(origin: .zero, size: groesse))
            neu.unlockFocus()
            return neu
            #else
            let form = UIGraphicsImageRendererFormat.default()
            form.opaque = false
            return UIGraphicsImageRenderer(size: groesse, format: form).image { _ in
                bild.draw(in: CGRect(origin: .zero, size: groesse))
            }
            #endif
        }
    }

    private func titelbildHolen(_ url: URL?, fuer id: String) {
        // **Hoechstens ein Versuch je Titel.** `melden` laeuft im halben
        // Sekundentakt; ohne diese Sperre liefe bei einem Titel ohne Bild
        // zweimal je Sekunde eine Anfrage los.
        guard titelbildFuer != id else { return }
        titelbildFuer = id
        titelbild = nil
        guard let url else { return }

        Task { [weak self] in
            guard let daten = try? await URLSession.shared.data(from: url).0,
                  let bild = Systembild(data: daten) else { return }
            let werk = Self.werkstueck(aus: bild)
            guard let self, self.titelbildFuer == id else { return }
            self.titelbild = werk
            // Nur ergaenzen, nicht neu aufbauen: zwischen Melden und
            // Ankommen hat sich die Stelle laengst weitergedreht.
            guard var eintrag = MPNowPlayingInfoCenter.default().nowPlayingInfo
            else { return }
            eintrag[MPMediaItemPropertyArtwork] = werk
            MPNowPlayingInfoCenter.default().nowPlayingInfo = eintrag
        }
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
    /// Die Rate steht im Eintrag und beschreibt, wie schnell gespielt wird.
    /// Ob überhaupt gespielt wird, ist eine andere Angabe — und das System
    /// entscheidet danach, welchen Befehl es beim Druck auf die
    /// Wiedergabetaste schickt.
    ///
    /// Ohne sie glaubte tvOS durchgehend, es liefe, und schickte jedesmal
    /// `pauseCommand`. Deshalb hielt der erste Druck an und jeder weitere
    /// tat nichts: es kam nie `play`, nie `togglePlayPause`, immer nur
    /// „anhalten". Gefunden hat es Pauls Blick auf die eingebaute Spur —
    /// dort stand `anhalten · zentrale`, zweimal hintereinander.
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
    /// **Wechselt das Ausgabegeraet, muss der Tonausgang neu aufgebaut werden.**
    ///
    /// Paul: „die Player Audio laeuft nicht, wenn ich Bluetooth-Kopfhoerer
    /// drin habe — erst nachdem ich hin und her gewechselt habe, geht er auf
    /// einmal."
    ///
    /// Genau das ist das Bild eines nicht behandelten Routenwechsels. iOS
    /// meldet ihn, VLCs Tonausgang haengt aber weiter am alten Geraet und
    /// bleibt stumm, bis irgendein anderer Anlass ihn neu aufbaut — beim
    /// Hin- und Herwechseln kommt der irgendwann von selbst.
    ///
    /// Wir haben bisher **nur** auf Unterbrechungen gehoert, nicht auf
    /// Routenwechsel. Das sind zwei verschiedene Meldungen: ein Anruf
    /// unterbricht, ein Kopfhoerer wechselt die Route.
    private var routenbeobachter: NSObjectProtocol?

    private func routenwechselBeobachten() {
        if let routenbeobachter { NotificationCenter.default.removeObserver(routenbeobachter) }
        routenbeobachter = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] nachricht in
            let roh = nachricht.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routenwechsel(grund: roh) }
        }
    }

    private func routenwechsel(grund roh: UInt?) {
        guard let roh,
              let grund = AVAudioSession.RouteChangeReason(rawValue: roh) else { return }
        switch grund {
        // **Nur die zwei, die wirklich ein Gerätewechsel sind.**
        //
        // Hier standen einmal vier — `.categoryChange` und
        // `.routeConfigurationChange` waren dabei. Die feuern aber, wenn die
        // **App selbst** ihre Tonsitzung einrichtet, also unmittelbar beim
        // Start. Auf dem Apple TV hat das eine Kette ausgelöst, die die App
        // umgebracht hat, am Gerät gemessen (03.09.2026, `swiftly.log`):
        //
        //     [Ton] Routenwechsel (8) — Ausgang neu aufbauen
        //     Paused · Position 0 s          angehalten mitten im Start
        //     Playing · Position 9 s         neun Sekunden später
        //     picture is too late (missing 8366 ms)   × hunderte
        //     clock gap → new clock context(1) … (2642)
        //     201 s lang, 35 Kontexte je Sekunde → tvOS räumt die App ab
        //
        // VLC kam aus dem Rückstand nie wieder heraus und drehte sich zu
        // Tode. Koney hat dasselbe gesehen: „unten lief die Zeit, aber es
        // lief nichts."
        //
        // Für Bluetooth reichen die beiden hier: `.newDeviceAvailable`, wenn
        // Kopfhörer dazukommen, `.override`, wenn jemand das Ziel umstellt.
        // Genau die waren auch gemeint — die anderen zwei waren Beifang.
        case .newDeviceAvailable, .override:
            // Die Regel samt Schonfrist steht in `Tonwacht` — mit der
            // Messung, die dahintersteht, und dem Vermerk, dass die fünf
            // Sekunden **geraten** sind.
            guard Tonwacht.ausgangNeuAufbauen(
                echterGeraetewechsel: true,
                spielt: spieltGerade,
                seitUebernahme: Date().timeIntervalSince(seitUebernahme))
            else {
                if spieltGerade {
                    Protokoll.schreib("[Ton] Routenwechsel (\(roh)) im Anlauf — übergangen")
                }
                return
            }
            Protokoll.schreib("[Ton] Routenwechsel (\(roh)) — Ausgang neu aufbauen")
            // **Anhalten und sofort weiter.** VLC baut den Tonausgang beim
            // Fortsetzen neu auf; ohne diesen Anstoss bleibt er auf dem alten
            // Geraet. Ein feinerer Weg waere, nur den Ausgang zu tauschen —
            // den bietet VLCKit nicht an.
            griffe?.anhalten()
            griffe?.abspielen()
        case .oldDeviceUnavailable:
            // Kopfhoerer raus: anhalten, wie es jeder Abspieler tut. Sonst
            // laeuft der Film ploetzlich ueber den Lautsprecher.
            Protokoll.schreib("[Ton] Ausgabegeraet weg — anhalten")
            griffe?.anhalten()
        default:
            break
        }
    }

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
            // **`shouldResume` darf nicht Bedingung sein.**
            //
            // Hier stand `if liefVorher, sollWeiter`. Der Gedanke war richtig
            // — ein Anruf waehrend einer Pause soll die Wiedergabe nicht
            // starten —, aber genau das leistet `liefVorher` schon allein.
            // `shouldResume` setzt iOS nur, wenn es das Fortsetzen nahelegen
            // *will*; bei kurzen Unterbrechungen fehlt es regelmaessig.
            //
            // Am Geraet gemessen: Mitteilungszentrale aufziehen und wieder
            // schliessen. Dreimal derselbe Handgriff, dreimal „pausing" von
            // VLC — beim dritten Mal kam kein „resuming" mehr. Die App zeigte
            // korrekt „angehalten", nur setzte niemand fort, und der
            // Pausenknopf half auch nicht mehr. Paul musste neu starten.
            //
            // Der Hinweis wird trotzdem mitgeschrieben: fehlt er dauerhaft
            // auch bei Anrufen, waere das ein anderer Fehler.
            let sollWeiter = AVAudioSession.InterruptionOptions(rawValue: hinweis ?? 0)
                .contains(.shouldResume)
            Protokoll.schreib("[Ton] Unterbrechung vorbei — lief vorher "
                + "\(liefVorher), shouldResume \(sollWeiter)")
            if liefVorher {
                // **Die Tonsitzung erst wieder aktivieren.** Nach einer
                // Unterbrechung ist sie inaktiv; ein `play` darauf verpufft
                // still, und dann steht das Bild ohne erkennbaren Grund.
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    Protokoll.schreib("[Ton] Sitzung liess sich nicht aktivieren: "
                        + error.localizedDescription)
                }
                griffe?.abspielen()
            }
            liefVorher = false
        @unknown default:
            break
        }
    }
    #endif
}
