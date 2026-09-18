import Foundation
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple-Plattformen gibt es das Modul nicht — der
// Import ist deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Was die Gegenstelle von uns will.
public enum Fernbefehl: Sendable, Equatable {
    case pause
    case weiter
    case umschalten
    case stopp
    /// Absolute Zielstelle in Sekunden.
    case springenAuf(Double)
    case vor
    case zurueck
    case naechste
    case vorige
}

/// Fernsteuerung über Jellyfins Socket.
///
/// Ohne die taucht die Sitzung im Dashboard zwar auf, lässt sich aber nicht
/// bedienen — genau das war der Fall. Es fehlten **zwei** Dinge, nicht eins:
///
/// 1. `Sessions/Capabilities/Full` sagt dem Server überhaupt erst, dass diese
///    Sitzung Befehle annimmt. Ohne den Aufruf blendet das Dashboard die
///    Knöpfe aus.
/// 2. Der Socket, über den die Befehle dann ankommen. Es gibt keinen Abruf
///    dafür; der Server schickt von sich aus.
///
/// Der Server erwartet außerdem ein Lebenszeichen. Bleibt es aus, wirft er die
/// Verbindung nach kurzer Zeit weg.
public actor Fernsteuerung {
    private let basis: URL
    private let token: String
    private let geraeteID: String
    private let sitzung: URLSession

    private var aufgabe: URLSessionWebSocketTask?
    private var lauscher: Task<Void, Never>?
    private var herzschlag: Task<Void, Never>?
    private var weitergabe: (@Sendable (Fernbefehl) -> Void)?
    /// Wie oft die Verbindung hintereinander abgerissen ist. Steuert die
    /// Wartezeit vor dem nächsten Versuch und wird bei Erfolg zurückgesetzt.
    private var abrisse = 0

    public init(basis: URL, token: String, geraeteID: String,
                sitzung: URLSession = .shared) {
        self.basis = basis
        self.token = token
        self.geraeteID = geraeteID
        self.sitzung = sitzung
    }

    /// Verbindet und ruft `bei` für jeden eingehenden Befehl auf.
    public func starten(bei weitergabe: @escaping @Sendable (Fernbefehl) -> Void) {
        self.weitergabe = weitergabe
        guard aufgabe == nil else { return }

        var teile = URLComponents(url: basis.appendingPathComponent("socket"),
                                  resolvingAgainstBaseURL: false)
        teile?.scheme = basis.scheme == "http" ? "ws" : "wss"
        teile?.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "deviceId", value: geraeteID),
        ]
        guard let url = teile?.url else { return }

        let neu = sitzung.webSocketTask(with: url)
        neu.resume()
        aufgabe = neu
        lauschen()
        schlagen()
    }

    /// Baut die Verbindung nach einem Abriss neu auf.
    ///
    /// Vorher hörte die Fernsteuerung beim ersten Abriss endgültig auf, in der
    /// Annahme, ein Netzwechsel würde sie schon wieder anstoßen. Ein Server,
    /// der neu startet, ist aber kein Netzwechsel: die Sitzung blieb dann bis
    /// zum nächsten Start der App stumm. Die Wartezeit verdoppelt sich bis
    /// eine halbe Minute, damit ein dauerhaft toter Server nicht im Sekunden-
    /// takt angeklopft wird.
    private func neuVerbinden() async {
        guard let weitergabe else { return }
        abrisse += 1
        let warten = min(30, 1 << min(abrisse, 5))
        try? await Task.sleep(for: .seconds(warten))
        guard !Task.isCancelled, aufgabe == nil else { return }
        starten(bei: weitergabe)
    }

    public func beenden() {
        weitergabe = nil          // sperrt den Wiederaufbau
        abrisse = 0
        lauscher?.cancel(); lauscher = nil
        herzschlag?.cancel(); herzschlag = nil
        aufgabe?.cancel(with: .goingAway, reason: nil)
        aufgabe = nil
    }

    private func lauschen() {
        lauscher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let aufgabe = await self.laufende else { return }
                do {
                    let nachricht = try await aufgabe.receive()
                    if case let .string(text) = nachricht {
                        await self.verarbeiten(text)
                    }
                    // Es kam etwas an, die Leitung steht: die Zählung der
                    // Abrisse beginnt beim nächsten Mal wieder bei null.
                    await self.zaehlungZuruecksetzen()
                } catch {
                    guard !Task.isCancelled else { return }
                    await self.leitungVerloren()
                    return
                }
            }
        }
    }

    private var laufende: URLSessionWebSocketTask? { aufgabe }

    private func zaehlungZuruecksetzen() { abrisse = 0 }

    private func leitungVerloren() async {
        aufgabe?.cancel(with: .abnormalClosure, reason: nil)
        aufgabe = nil
        herzschlag?.cancel(); herzschlag = nil
        await neuVerbinden()
    }

    /// Alle 30 Sekunden ein Lebenszeichen, sonst räumt der Server auf.
    private func schlagen() {
        herzschlag = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                // `try?` verschluckt den Abbruch; ohne diese Zeile ginge nach
                // dem Beenden noch ein Lebenszeichen hinaus.
                guard !Task.isCancelled, let self else { return }
                await self.senden(#"{"MessageType":"KeepAlive"}"#)
            }
        }
    }

    private func senden(_ text: String) {
        aufgabe?.send(.string(text)) { _ in }
    }

    private func verarbeiten(_ text: String) {
        guard let daten = text.data(using: .utf8),
              let roh = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              let art = roh["MessageType"] as? String else { return }

        switch art {
        case "ForceKeepAlive":
            senden(#"{"MessageType":"KeepAlive"}"#)

        case "Playstate":
            guard let inhalt = roh["Data"] as? [String: Any],
                  let befehl = inhalt["Command"] as? String else { return }
            let ziel = inhalt["SeekPositionTicks"] as? Int64
            if let fern = Self.uebersetzen(befehl, ziel: ziel) { weitergabe?(fern) }

        default:
            break
        }
    }

    static func uebersetzen(_ befehl: String, ziel: Int64?) -> Fernbefehl? {
        switch befehl {
        case "Pause":         return .pause
        case "Unpause":       return .weiter
        case "PlayPause":     return .umschalten
        case "Stop":          return .stopp
        case "Seek":          return ziel.map { .springenAuf(Double($0) / 10_000_000) }
        case "FastForward":   return .vor
        case "Rewind":        return .zurueck
        case "NextTrack":     return .naechste
        case "PreviousTrack": return .vorige
        default:              return nil
        }
    }
}

extension JellyfinClient {

    /// Meldet dem Server, was diese Sitzung kann.
    ///
    /// Ohne diesen Aufruf zeigt das Dashboard die Sitzung nur an; die Knöpfe
    /// zum Pausieren und Stoppen bleiben grau.
    public func faehigkeitenMelden() async throws {
        struct Faehigkeiten: Encodable {
            let PlayableMediaTypes: [String]
            let SupportedCommands: [String]
            let SupportsMediaControl: Bool
            let SupportsPersistentIdentifier: Bool
        }
        let koerper = Faehigkeiten(
            PlayableMediaTypes: ["Video", "Audio"],
            SupportedCommands: ["Play", "Playstate", "PlayNext", "PlayMediaSource",
                                "DisplayMessage", "SetAudioStreamIndex",
                                "SetSubtitleStreamIndex", "Mute", "Unmute",
                                "ToggleMute", "SetVolume"],
            SupportsMediaControl: true,
            SupportsPersistentIdentifier: true)

        let req = try rohAnfrage("Sessions/Capabilities/Full", method: "POST")
        var mitKoerper = req
        mitKoerper.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mitKoerper.httpBody = try JSONEncoder().encode(koerper)

        let (_, antwort) = try await rohSitzung.data(for: mitKoerper)
        guard let http = antwort as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.transport("Fähigkeiten konnten nicht gemeldet werden.")
        }
    }

    /// Eine Fernsteuerung für die laufende Anmeldung.
    public func fernsteuerung() throws -> Fernsteuerung {
        let s = try requireSessionForReporting()
        return Fernsteuerung(basis: s.serverURL, token: s.accessToken, geraeteID: geraeteKennung)
    }
}
