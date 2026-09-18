import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// **Der Draht zu Discord — was gerade laeuft, im eigenen Profil.**
///
/// Discord nimmt so etwas nicht ueber das Netz entgegen, sondern ueber eine
/// oertliche Steckverbindung, die sein Programm auf demselben Rechner
/// bereitstellt. Kein Merkmal, kein Konto, keine Anmeldung: wer Discord offen
/// hat, hat den Draht; wer nicht, hat ihn nicht. Das ist auch der Grund,
/// warum hier nichts schiefgehen kann, was jemandem schadet — es gibt keinen
/// Server, an den etwas ginge.
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
///
/// # Auf dem Mac im App Store geht das nicht, und das ist keine Frage der
/// # Muehe
///
/// Am 10.09.2026 beides ausprobiert, nicht ueberlegt:
///
/// **Die Steckdose ist der richtige Weg — und der Sandkasten sperrt sie.**
/// Von einem Programm ohne Sandkasten aus laeuft sie einwandfrei; Discord
/// nimmt den Handschlag an und bestaetigt `SET_ACTIVITY` mit dem, was es
/// anzeigen wird. Eine App im Sandkasten bekommt als `TMPDIR` aber ihren
/// **eigenen** Ordner im Behaelter, sucht also an der falschen Stelle; und
/// mit dem richtigen Pfad — `/var/folders/<zufaellig>/T/discord-ipc-0` —
/// laesst der Sandkasten die Verbindung nicht zu. Als Ausnahme benennbar ist
/// er wegen des zufaelligen Teils ohnehin nicht.
///
/// **Der Netzweg waere erlaubt und traegt nicht.** Discord hoert auf 6463
/// bis 6472, und dorthin duerfte die App. Aber: mit unserer Herkunft weist
/// es mit `4001 Invalid Origin` ab, mit einer erlaubten oeffnet die Leitung
/// und **schweigt** — kein `READY`, keine Antwort. Dieser Weg ist fuer
/// Erweiterungen mit OAuth-Freigabe gedacht, nicht fuer eine Anzeige.
///
/// Damit bleibt fuer den Mac nur ein Bau **ohne** Sandkasten, also ausserhalb
/// des App Store. Auf Linux und Windows gibt es die Frage nicht.
///
/// Wer das spaeter noch einmal angeht: die zwei Messungen oben sind der
/// Ausgangspunkt, nicht die Vermutung, es koenne schon irgendwie gehen.
/// **Auf Windows liegt der Draht als benannte Roehre, nicht als Steckdose.**
///
/// `\\.\pipe\discord-ipc-0`, sonst **dasselbe Protokoll** — derselbe
/// Rahmen aus Griff und Laenge, derselbe Handschlag, dieselben Rahmen. Nur
/// `CreateFileW` und `WriteFile` treten an die Stelle von `socket` und
/// `write`.
///
/// Und ein Unterschied, der die Sache hier einfacher macht: es gibt nur
/// **einen** Ort. Roehren haengen an keinem Ordner, den eine Verpackung
/// verschieben koennte — die Suche nach Flatpak- und Snap-Ablagen entfaellt.
///
/// **Auf diesem Rechner nicht gebaut**: hier gibt es kein Windows. Der Bau
/// laeuft in der VM.
#if os(Windows)
import WinSDK

public actor Discordbruecke {

    private let anwendung: String
    private var roehre: HANDLE?

    public init(anwendung: String) {
        self.anwendung = anwendung
    }

    private func verbinden() -> Bool {
        if roehre != nil { return true }
        for n in 0...9 {
            let weg = #"\\.\pipe\discord-ipc-"# + String(n)
            let griff = weg.withCString(encodedAs: UTF16.self) { zeiger in
                // **`GENERIC_READ` ist `UInt32`, `GENERIC_WRITE` ist
                // `Int32`.** Swifts WinSDK-Abbildung typisiert die beiden
                // verschieden; das Oder nimmt den Typ des linken Werts, und
                // der rechte passt dann nicht. In der VM nachgemessen, nicht
                // aus dem Fehler geraten.
                //
                // Und die naheliegende Abkuerzung traegt nicht:
                // `DWORD(bitPattern: GENERIC_READ | GENERIC_WRITE)` ist schon
                // `UInt32`, und `DWORD(bitPattern:)` will `Int32`. Die
                // Umwandlung gehoert um den **rechten** Wert.
                CreateFileW(zeiger,
                            GENERIC_READ | DWORD(bitPattern: GENERIC_WRITE),
                            0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            guard let griff, griff != INVALID_HANDLE_VALUE else {
                // **Der erste Fehlversuch sagt, ob der Aufruf ueberhaupt
                // richtig gebaut ist.**
                //
                // Von der Windows-Sitzung vorgeschlagen, und der Vorschlag
                // ist gut: ohne diese Zeile laesst sich nicht einmal
                // belegen, dass `CreateFileW` versucht wurde. Mit ihr trennt
                // ein einziger Wert die beiden Faelle, die sonst gleich
                // aussehen — **2** (`ERROR_FILE_NOT_FOUND`) heisst „die
                // Roehre ist nicht da, der Aufruf ist in Ordnung", alles
                // andere heisst „der Aufruf ist falsch gebaut".
                //
                // Damit ist die Windows-Bahn auch ohne Discord messbar, und
                // genau darum ging es: nicht Discord zu installieren, um
                // etwas zu pruefen, das sich anders pruefen laesst.
                if n == 0 {
                    Spur.sag("[Discord] Roehre 0 nicht zu oeffnen, "
                             + "GetLastError=\(GetLastError()) "
                             + "(2 = nicht da, alles andere = Aufruf falsch)")
                }
                continue
            }
            roehre = griff
            if senden(0, ["v": 1, "client_id": anwendung]) {
                Spur.sag("[Discord] verbunden ueber \(weg)")
                return true
            }
            CloseHandle(griff)
            roehre = nil
        }
        Spur.sag("[Discord] keine Roehre gefunden — zehn Nummern abgesucht")
        return false
    }

    /// Derselbe Rahmen wie unter Unix: Griff und Laenge als je vier Byte
    /// little-endian, dann der Koerper.
    private func senden(_ griff: UInt32, _ inhalt: [String: Any]) -> Bool {
        guard let roehre,
              let daten = try? JSONSerialization.data(withJSONObject: inhalt) else { return false }
        var kopf = Data()
        var g = griff.littleEndian
        var l = UInt32(daten.count).littleEndian
        withUnsafeBytes(of: &g) { kopf.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { kopf.append(contentsOf: $0) }
        let alles = kopf + daten
        return alles.withUnsafeBytes { roh -> Bool in
            var ab = 0
            while ab < roh.count {
                var geschrieben: DWORD = 0
                let ok = WriteFile(roehre,
                                   roh.baseAddress!.advanced(by: ab),
                                   DWORD(roh.count - ab), &geschrieben, nil)
                if !ok || geschrieben == 0 { return false }
                ab += Int(geschrieben)
            }
            return true
        }
    }

    private func trennen() {
        if let roehre { CloseHandle(roehre) }
        roehre = nil
    }

    public func zeigen(_ anzeige: Discordanzeige?) {
        guard verbinden() else { return }
        var arg: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let anzeige { arg["activity"] = anzeige.alsWoerterbuch }
        let rahmen: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": arg,
            "nonce": UUID().uuidString,
        ]
        if !senden(1, rahmen) {
            Spur.sag("[Discord] Roehre weg, wird beim naechsten Mal neu aufgebaut")
            trennen()
        }
    }

    public func schliessen() {
        guard roehre != nil else { return }
        _ = senden(2, [:])
        trennen()
    }
}


#else

public actor Discordbruecke {

    /// Die Anwendung, unter der Discord die Anzeige fuehrt. Ihr Name steht
    /// beim Nutzer als „schaut …", ihr Zeichen ist das grosse Bild.
    private let anwendung: String
    private var draht: Int32 = -1
    private var verbunden = false

    public init(anwendung: String) {
        self.anwendung = anwendung
    }

    // MARK: Verbinden

    /// **Zehn moegliche Stellen, und das ist kein Uebermass.**
    ///
    /// Discord nummeriert seine Steckdosen durch (`discord-ipc-0` bis `-9`);
    /// laeuft schon eine Instanz, nimmt die naechste die 1. Und je nachdem,
    /// wie Discord installiert ist, liegen sie woanders: unter Flatpak in
    /// dessen eigenem Laufzeitordner, unter Snap in dessen. Wer nur an einer
    /// Stelle nachsieht, hat es bei sich zum Laufen gebracht und bei der
    /// Haelfte der Nutzer nicht.
    private func stellen() -> [String] {
        let umg = ProcessInfo.processInfo.environment
        var wurzeln: [String] = []
        #if os(macOS)
        // Auf dem Mac liegt sie im temporaeren Ordner der Sitzung.
        wurzeln.append(umg["TMPDIR"] ?? NSTemporaryDirectory())
        #else
        if let x = umg["XDG_RUNTIME_DIR"] { wurzeln.append(x) }
        wurzeln.append(contentsOf: [umg["TMPDIR"], umg["TMP"], umg["TEMP"], "/tmp"].compactMap { $0 })
        if let x = umg["XDG_RUNTIME_DIR"] {
            wurzeln.append("\(x)/app/com.discordapp.Discord")   // Flatpak
            wurzeln.append("\(x)/snap.discord")                 // Snap
        }
        #endif
        var wege: [String] = []
        for w in wurzeln {
            let sauber = w.hasSuffix("/") ? String(w.dropLast()) : w
            for n in 0...9 { wege.append("\(sauber)/discord-ipc-\(n)") }
        }
        return wege
    }

    private func oeffnen(_ weg: String) -> Int32 {
        // Ein Unix-Pfad in `sockaddr_un` ist auf 104 Zeichen begrenzt. Laenger
        // heisst nicht „geht nicht", sondern „schneidet still ab" — und dann
        // verbindet man sich mit etwas anderem oder mit nichts.
        guard weg.utf8.count < 104 else { return -1 }
        // **`SOCK_STREAM` ist nicht auf beiden Systemen dasselbe.** Auf
        // Linux ist es eine Aufzaehlung mit `rawValue`, auf Darwin schon ein
        // `Int32`. Hier steht deshalb beides.
        #if canImport(Glibc)
        let art = Int32(SOCK_STREAM.rawValue)
        #else
        let art = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, art, 0)
        guard fd >= 0 else { return -1 }
        var adresse = sockaddr_un()
        adresse.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &adresse.sun_path) { ziel in
            weg.utf8.enumerated().forEach { ziel[$0.offset] = $0.element }
        }
        let groesse = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &adresse) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, groesse) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }

    // MARK: Rahmen

    private enum Griff: UInt32 { case handschlag = 0, rahmen = 1, schluss = 2 }

    private func senden(_ griff: Griff, _ inhalt: [String: Any]) -> Bool {
        guard draht >= 0,
              let daten = try? JSONSerialization.data(withJSONObject: inhalt) else { return false }
        var kopf = Data()
        var g = griff.rawValue.littleEndian
        var l = UInt32(daten.count).littleEndian
        withUnsafeBytes(of: &g) { kopf.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { kopf.append(contentsOf: $0) }
        let alles = kopf + daten
        return alles.withUnsafeBytes { roh -> Bool in
            var ab = 0
            while ab < roh.count {
                let n = write(draht, roh.baseAddress!.advanced(by: ab), roh.count - ab)
                if n <= 0 { return false }
                ab += n
            }
            return true
        }
    }

    /// Verbindet, falls noetig. Gibt zurueck, ob danach eine Leitung steht.
    private func sicherstellen() -> Bool {
        if verbunden, draht >= 0 { return true }
        for weg in stellen() {
            let fd = oeffnen(weg)
            guard fd >= 0 else { continue }
            draht = fd
            if senden(.handschlag, ["v": 1, "client_id": anwendung]) {
                verbunden = true
                schonGeklagt = false
                Spur.sag("[Discord] verbunden ueber \(weg)")
                return true
            }
            close(fd); draht = -1
        }
        // **Auch der Fehlschlag sagt etwas.** Hier stand nichts, und damit
        // war „Discord laeuft nicht" von „wir werden gar nicht gefragt" nicht
        // zu unterscheiden — genau die Ununterscheidbarkeit, an der am
        // 10.09.2026 schon die Uebernahme stundenlang haengengeblieben ist,
        // diesmal in meinem eigenen neuen Code.
        //
        // Einmal je Anlauf, nicht bei jedem Takt: sonst fuellt es das
        // Protokoll, sobald jemand Discord nicht offen hat.
        if !schonGeklagt {
            schonGeklagt = true
            let wege = stellen()
            Spur.sag("[Discord] keine Steckdose gefunden — \(wege.count) Stellen "
                     + "abgesucht, zuerst \(wege.first ?? "—")")
        }
        return false
    }

    /// Damit die Klage einmal kommt und nicht bei jedem Takt.
    private var schonGeklagt = false

    private func trennen() {
        if draht >= 0 { close(draht) }
        draht = -1
        verbunden = false
    }

    // MARK: Anzeigen

    /// Setzt, was im Profil steht. `nil` raeumt die Anzeige ab.
    public func zeigen(_ anzeige: Discordanzeige?) {
        guard sicherstellen() else { return }
        var arg: [String: Any] = ["pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let anzeige { arg["activity"] = anzeige.alsWoerterbuch }
        let rahmen: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": arg,
            "nonce": UUID().uuidString,
        ]
        Spur.sag("[Discord] sende: \(anzeige.map(\.kurzfassung) ?? "nichts")")
        if !senden(.rahmen, rahmen) {
            // Discord beendet, Leitung tot. Beim naechsten Mal neu aufbauen —
            // nicht hier in einer Schleife, das waere ein Zaehler ohne Zweck.
            Spur.sag("[Discord] Leitung weg, wird beim naechsten Mal neu aufgebaut")
            trennen()
        }
    }

    public func schliessen() {
        guard verbunden else { return }
        _ = senden(.schluss, [:])
        trennen()
    }
}

#endif

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

    /// **Das Zeichen als Adresse, nicht als hinterlegter Name.**
    ///
    /// Der uebliche Weg ist, ein Bild im Entwicklerportal zu hinterlegen und
    /// hier seinen Namen zu nennen. Am 10.09.2026 hat sich das als der
    /// schlechtere erwiesen: das Portal zeigt heute nur noch Hintergrund,
    /// Titelbild und Vorschauvideo — alles falsche Formate —, und die
    /// klassischen Bilder waren dort nicht mehr zu finden. Gegengemessen:
    /// `oauth2/applications/<id>/assets` gab **null** Eintraege zurueck, und
    /// Discord verwarf `large_image` stillschweigend.
    ///
    /// Discord nimmt aber eine **Adresse** und holt sie sich selbst; in der
    /// Antwort steht sie dann als `mp:external/…` zurueck. Damit braucht
    /// niemand ein Portal anzufassen, und das Zeichen ist dasselbe, das auch
    /// die Linux-Fassung als Programmzeichen benutzt — eine Datei, nicht
    /// zwei, die auseinanderlaufen koennen.
    ///
    /// Sie zeigt in das oeffentliche Repository. Wird es umbenannt, bleibt
    /// das Bild leer; der Rest der Anzeige steht weiter.
    static let zeichen = "https://raw.githubusercontent.com/paulherter/swiftly-player/main/Linux/Ressourcen/icons/hicolor/512x512/apps/de.paulherter.swiftly.png"

    /// Fuer das Protokoll — was hinausgeht, in einer Zeile.
    var kurzfassung: String {
        let spanne = (von != nil && bis != nil)
            ? "Balken \(Int(bis!.timeIntervalSince(von!))) s"
            : "ohne Balken"
        return "\(titel) · \(unterzeile ?? "—") · \(spanne)"
    }

    var alsWoerterbuch: [String: Any] {
        var d: [String: Any] = [
            // 3 heisst „schaut". Discord kennt spielen, streamen, hoeren,
            // schauen und mitmachen; fuer einen Videoabspieler ist es diese.
            "type": 3,
            "details": titel,
            "assets": ["large_image": Self.zeichen, "large_text": "Swiftly Player"],
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
