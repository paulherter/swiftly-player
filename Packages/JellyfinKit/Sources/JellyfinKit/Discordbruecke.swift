import Foundation

/// **Der Draht zu Discord — was gerade laeuft, im eigenen Profil.**
///
/// Discord nimmt so etwas ueber eine Verbindung zum eigenen Rechner
/// entgegen — `127.0.0.1`, kein fremder Server. Kein Merkmal, kein Konto,
/// keine Anmeldung: wer Discord offen hat, hat den Draht; wer nicht, hat ihn
/// nicht. Das ist auch der Grund, warum hier nichts schiefgehen kann, was
/// jemandem schadet: es gibt keine Gegenstelle ausserhalb dieses Rechners.
///
/// **Was ausdruecklich nicht gesendet wird.** Die Bildadressen dieses Servers
/// tragen `ApiKey` im Klartext (siehe ``Adressgeheimnis``). Ein Plakat an
/// Discord zu reichen hiesse, den Serverzugang zu veroeffentlichen — an eine
/// Stelle, die ihn zwischenspeichert und weiterreicht. Deshalb steht dort das
/// Swiftly-Zeichen und daneben Text. Wer das aendern will, muss zuerst eine
/// Adresse ohne Merkmal haben, nicht umgekehrt.
///
/// Die Verbindung ist ein Zusatz und darf nie im Weg stehen: jeder Fehler
/// endet hier, wird ueber ``Spur`` gemeldet und sonst nichts. Kein Werfen
/// nach aussen, kein Warten, kein Wiederholen im Sekundentakt.
public actor Discordbruecke {

    /// Die Anwendung, unter der Discord die Anzeige fuehrt. Ihr Name steht
    /// beim Nutzer als „schaut …", ihr Zeichen ist das grosse Bild.
    private let anwendung: String
    private var leitung: URLSessionWebSocketTask?
    private var steht = false

    public init(anwendung: String) {
        self.anwendung = anwendung
    }

    // MARK: Verbinden

    /// **Ueber das Netz zu 127.0.0.1, nicht ueber eine Steckdose im
    /// Dateisystem — und das ist der Unterschied zwischen „geht" und „geht
    /// nicht".**
    ///
    /// Discord bietet beides an: eine Unix-Steckdose in `$TMPDIR` und
    /// denselben Dienst als WebSocket auf 6463 bis 6472. Der erste Bau nahm
    /// die Steckdose, wie es die meisten Anleitungen zeigen. **Auf dem Mac
    /// kann das nicht funktionieren**, und zwar aus zwei Gruenden
    /// nacheinander: eine App im Sandkasten bekommt als `TMPDIR` ihren
    /// **eigenen** Ordner im Behaelter, nicht den der Sitzung, in dem
    /// Discords Steckdose liegt — sie sucht also an der falschen Stelle. Und
    /// selbst mit dem richtigen Pfad laesst der Sandkasten die Verbindung
    /// nicht zu; der Pfad ist ausserdem `/var/folders/<zufaellig>/T/`, also
    /// gar nicht benennbar.
    ///
    /// Am 10.09.2026 am Geraet nachgesehen: im Protokoll stand keine einzige
    /// Zeile, und der Behaelter-Temp enthielt erwartungsgemaess keine
    /// Steckdose.
    ///
    /// Eine Netzverbindung nach `127.0.0.1` darf die App dagegen —
    /// `com.apple.security.network.client` steht ohnehin da, sonst gaebe es
    /// keinen Server. Und der Weg traegt **alle drei** Fassungen mit
    /// derselben Zeile, statt Unix-Steckdose hier und benannte Roehre auf
    /// Windows.
    private func verbinden() async -> Bool {
        if steht, leitung != nil { return true }
        for port in 6463...6472 {
            var teile = URLComponents()
            teile.scheme = "ws"
            teile.host = "127.0.0.1"
            teile.port = port
            teile.path = "/"
            teile.queryItems = [.init(name: "v", value: "1"),
                                .init(name: "client_id", value: anwendung)]
            guard let url = teile.url else { continue }
            var anfrage = URLRequest(url: url)
            // **Discord verlangt eine Herkunft.** Ohne sie weist es den
            // Handschlag ab; es unterscheidet damit einen Aufruf aus einer
            // Webseite von einem beliebigen Programm auf dem Rechner.
            anfrage.setValue("https://discord.com", forHTTPHeaderField: "Origin")
            let aufgabe = URLSession.shared.webSocketTask(with: anfrage)
            aufgabe.resume()
            // Discord meldet sich mit `DISPATCH`/`READY`, sobald es die
            // Verbindung annimmt. Kommt nichts, ist der Port ein anderer
            // Dienst oder eine tote Instanz.
            do {
                _ = try await aufgabe.receive()
                leitung = aufgabe
                steht = true
                Spur.sag("[Discord] verbunden auf Port \(port)")
                return true
            } catch {
                aufgabe.cancel(with: .goingAway, reason: nil)
            }
        }
        return false
    }

    private func trennen() {
        leitung?.cancel(with: .goingAway, reason: nil)
        leitung = nil
        steht = false
    }

    // MARK: Anzeigen

    /// Setzt, was im Profil steht. `nil` raeumt die Anzeige ab.
    public func zeigen(_ anzeige: Discordanzeige?) async {
        guard await verbinden(), let leitung else { return }
        var arg: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let anzeige { arg["activity"] = anzeige.alsWoerterbuch }
        let rahmen: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": arg,
            "nonce": UUID().uuidString,
        ]
        guard let daten = try? JSONSerialization.data(withJSONObject: rahmen),
              let text = String(data: daten, encoding: .utf8) else { return }
        do {
            try await leitung.send(.string(text))
        } catch {
            // Discord beendet, Leitung tot. Beim naechsten Mal neu aufbauen —
            // nicht hier in einer Schleife, das waere ein Zaehler ohne Zweck.
            Spur.sag("[Discord] Leitung weg: \(error)")
            trennen()
        }
    }

    public func schliessen() {
        trennen()
    }
}

/// **Was im Profil steht.**
///
/// Bewusst ohne SwiftUI und ohne Kenntnis von ``Item``: die drei Fassungen,
/// die das benutzen, bauen ihre Zeilen selbst zusammen — auf dem Mac aus
/// einem `Item`, auf Linux und Windows aus dem, was der Spieler kennt.
public struct Discordanzeige: Sendable {

    /// Die fette Zeile. Der Film, oder bei einer Serie deren Name.
    public let titel: String
    /// Die Zeile darunter. Bei einer Serie „S2:E1 · Folgenname", sonst leer.
    public let unterzeile: String?
    /// Anfang und Ende der laufenden Wiedergabe als Zeitpunkte.
    ///
    /// **Discord zeichnet den Balken selbst**, aus diesen zwei Zahlen — man
    /// schickt keinen Fortschritt und schon gar nicht im Sekundentakt. Wer
    /// pausiert, schickt sie weg: ein Balken, der weiterlaeuft, waehrend das
    /// Bild steht, ist schlimmer als keiner.
    public let von: Date?
    public let bis: Date?

    public init(titel: String, unterzeile: String? = nil, von: Date? = nil, bis: Date? = nil) {
        self.titel = titel
        self.unterzeile = unterzeile
        self.von = von
        self.bis = bis
    }

    var alsWoerterbuch: [String: Any] {
        var d: [String: Any] = [
            // 3 heisst „schaut". Discord kennt spielen, streamen, hoeren,
            // schauen und mitmachen; fuer einen Videoabspieler ist es diese.
            "type": 3,
            "details": titel,
            "assets": ["large_image": "logo", "large_text": "Swiftly Player"],
        ]
        if let unterzeile, !unterzeile.isEmpty { d["state"] = unterzeile }
        if let von, let bis {
            d["timestamps"] = ["start": Int(von.timeIntervalSince1970 * 1000),
                               "end": Int(bis.timeIntervalSince1970 * 1000)]
        }
        return d
    }
}

extension Discordanzeige: Equatable {
    /// **Auf die Sekunde, nicht auf den Augenblick.**
    ///
    /// Die Zeitpunkte entstehen aus `Date()` und der Stelle im Film; zwischen
    /// zwei Takten wandern sie um Bruchteile, auch wenn sich nichts geaendert
    /// hat. Ein Vergleich auf `Date` waere deshalb **immer** verschieden, die
    /// Sperre gegen unnoetiges Senden wirkungslos, und es ginge mehrmals je
    /// Sekunde ein Rahmen an Discord hinaus.
    public static func == (a: Self, b: Self) -> Bool {
        func sekunde(_ d: Date?) -> Int? { d.map { Int($0.timeIntervalSince1970) } }
        return a.titel == b.titel && a.unterzeile == b.unterzeile
            && sekunde(a.von) == sekunde(b.von) && sekunde(a.bis) == sekunde(b.bis)
    }
}
