import Foundation
import Testing
// Auf Linux liegt URLSession nicht in Foundation, sondern in einem
// eigenen Modul. Auf Apple-Plattformen gibt es das Modul nicht — der
// Import ist deshalb bedingt und dort wirkungslos.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

// .serialized, weil sich die Tests den statischen Mitschnitt der Spy-Klasse
// teilen — parallel überschreiben sie sich gegenseitig.
@Suite("Anmelde-Anfrage", .serialized)
struct AuthRequestTests {

    /// Fängt die Anfrage ab, statt sie zu senden — so lässt sich prüfen, was
    /// die App tatsächlich verschickt.
    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var captured: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            // httpBody ist nach dem Durchlauf durch URLSession nur noch als
            // Stream lesbar — deshalb hier einsammeln.
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(buf, maxLength: 4096)
                    if read <= 0 { break }
                    data.append(buf, count: read)
                }
                buf.deallocate(); stream.close()
                req.httpBody = data
            }
            Self.captured = req

            let body = Data(#"{"AccessToken":"tok","ServerId":"s","User":{"Id":"u1","Name":"Paul"}}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func spyClient() -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Spy.self]
        return JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                              deviceID: "dev-42", deviceName: "iPhone von Paul",
                              urlSession: URLSession(configuration: config))
    }

    @Test("Schickt Username und Pw in Jellyfins Schreibweise")
    func bodyUsesServerFieldNames() async throws {
        _ = try await spyClient().authenticate(username: "paul", password: "geheim ✓")
        let req = try #require(Spy.captured)
        let body = try #require(req.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["Username"] == "paul")
        #expect(json["Pw"] == "geheim ✓", "Passwort kam verändert an: \(json["Pw"] ?? "nil")")
        #expect(json.keys.count == 2, "Unerwartete Felder: \(json.keys.sorted())")
    }

    @Test("Setzt den Authorization-Header ohne Token")
    func authorizationHeaderShape() async throws {
        _ = try await spyClient().authenticate(username: "paul", password: "x")
        let header = try #require(Spy.captured?.value(forHTTPHeaderField: "Authorization"))
        #expect(header.hasPrefix("MediaBrowser "))
        #expect(header.contains(#"Client="Swiftly""#))
        #expect(header.contains(#"DeviceId="dev-42""#))
        #expect(!header.contains("Token="), "Beim Login darf noch kein Token mitgehen")
    }

    @Test("Trifft den richtigen Endpunkt")
    func endpoint() async throws {
        _ = try await spyClient().authenticate(username: "paul", password: "x")
        #expect(Spy.captured?.url?.path == "/Users/AuthenticateByName")
        #expect(Spy.captured?.httpMethod == "POST")
    }
}

// MARK: - Fernsteuerung

@Suite("Fernbefehle")
struct FernbefehlTests {

    @Test("Jellyfins Namen werden richtig übersetzt")
    func namen() {
        #expect(Fernsteuerung.uebersetzen("Pause", ziel: nil) == .pause)
        #expect(Fernsteuerung.uebersetzen("Unpause", ziel: nil) == .weiter)
        #expect(Fernsteuerung.uebersetzen("PlayPause", ziel: nil) == .umschalten)
        #expect(Fernsteuerung.uebersetzen("Stop", ziel: nil) == .stopp)
        #expect(Fernsteuerung.uebersetzen("NextTrack", ziel: nil) == .naechste)
    }

    @Test("Seek rechnet Ticks in Sekunden um")
    func springen() {
        // Jellyfin zählt in 100-Nanosekunden-Schritten.
        #expect(Fernsteuerung.uebersetzen("Seek", ziel: 12_000_000_000) == .springenAuf(1200))
        // Ohne Ziel ist der Befehl nicht ausführbar.
        #expect(Fernsteuerung.uebersetzen("Seek", ziel: nil) == nil)
    }

    @Test("Unbekanntes wird verworfen statt geraten")
    func unbekannt() {
        #expect(Fernsteuerung.uebersetzen("Beam", ziel: nil) == nil)
    }
}

@Suite("Zeile für Neuzugänge")
struct NeuzugangTests {

    private func item(typ: String, folge: Int? = nil, staffel: Int? = nil,
                      kinder: Int? = nil, jahr: Int? = nil, name: String = "X") -> Item {
        let json = """
        {"Id":"1","Name":"\(name)","Type":"\(typ)"
        \(folge.map { ",\"IndexNumber\":\($0)" } ?? "")
        \(staffel.map { ",\"ParentIndexNumber\":\($0)" } ?? "")
        \(kinder.map { ",\"ChildCount\":\($0)" } ?? "")
        \(jahr.map { ",\"ProductionYear\":\($0)" } ?? "")}
        """
        return try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
    }

    // Die Zeilen sind übersetzt, der Wortlaut hängt also an der Sprache des
    // Geräts. Geprüft wird deshalb die Aussage, nicht die Formulierung: welche
    // Zahl auftaucht und welche nicht. Genau daran hing auch der Fehler, den
    // diese Tests festhalten — dort stand die Zahl der neuen Folgen, wo die
    // Zahl der Staffeln erwartet wurde.

    @Test("Eine Folge nennt ihre Staffel, nicht ihre Nummer")
    func folge() {
        let zeile = item(typ: "Episode", folge: 4, staffel: 3).neuzugangszeile
        #expect(zeile?.contains("3") == true)
        #expect(zeile?.contains("4") == false)
        // Ohne Staffel wenigstens die Folge.
        #expect(item(typ: "Episode", folge: 4).neuzugangszeile?.contains("4") == true)
    }

    @Test("Ganze Staffel nennt die Staffelnummer")
    func staffel() {
        #expect(item(typ: "Season", folge: 2).neuzugangszeile?.contains("2") == true)
        // Ohne Nummer trägt der Name die Aussage, etwa „Specials" — und der
        // kommt vom Server, wird also nicht übersetzt.
        #expect(item(typ: "Season", name: "Specials").neuzugangszeile == "Specials")
    }

    @Test("Bei einer Serie zählt ChildCount neue Folgen, nicht Staffeln")
    func serie() {
        let acht = item(typ: "Series", kinder: 8).neuzugangszeile
        #expect(acht?.contains("8") == true)
        // Der Fehler war, dass hier „Staffeln" stand. In beiden Sprachen darf
        // das Wort nicht vorkommen.
        #expect(acht?.lowercased().contains("staffel") == false)
        #expect(acht?.lowercased().contains("season") == false)
        // Einzahl und Mehrzahl unterscheiden sich.
        #expect(item(typ: "Series", kinder: 1).neuzugangszeile != acht)
        // Ohne Zahl bleibt das Jahr.
        #expect(item(typ: "Series", jahr: 2024).neuzugangszeile == "2024")
    }

    @Test("Filme zeigen das Jahr")
    func film() {
        #expect(item(typ: "Movie", jahr: 2021).neuzugangszeile == "2021")
    }
}

@Suite("Sprachvergleich")
struct SprachTests {

    @Test("Erkennt die üblichen Schreibweisen")
    func schreibweisen() {
        #expect(Sprache.passt("Surround 5.1 - [German]", zu: "Deutsch"))
        #expect(Sprache.passt("deutsch (AC3)", zu: "Deutsch"))
        #expect(Sprache.passt("ger", zu: "Deutsch"))
        #expect(Sprache.passt("full - [English]", zu: "English"))
    }

    @Test("Verwechselt nichts")
    func keineFalschtreffer() {
        #expect(!Sprache.passt("Surround 5.1 - [English]", zu: "Deutsch"))
        // Ohne Vorgabe darf nie etwas passen — sonst würde eine leere
        // Einstellung stillschweigend die erste Spur wählen.
        #expect(!Sprache.passt("[German]", zu: ""))
    }
}

// MARK: - Adressen im Protokoll

@Suite("Adressgeheimnis")
struct AdressgeheimnisTests {

    @Test("Entfernt das Zugangsmerkmal aus der Stromadresse")
    func schwaerztApiKey() throws {
        let url = try #require(URL(string:
            "https://tv.example.de/Videos/abc/stream?static=true&api_key=GEHEIM123&mediaSourceId=xy"))
        let text = url.ohneGeheimnis
        #expect(!text.contains("GEHEIM123"))
        // Der Rest muss lesbar bleiben, sonst nützt das Protokoll nichts.
        #expect(text.contains("static=true"))
        #expect(text.contains("mediaSourceId=xy"))
        #expect(text.contains("/Videos/abc/stream"))
    }

    @Test("Entfernt auch das Quick-Connect-Geheimnis")
    func schwaerztSecret() throws {
        let url = try #require(URL(string:
            "https://tv.example.de/QuickConnect/Connect?secret=ABC"))
        #expect(!url.ohneGeheimnis.contains("ABC"))
    }

    @Test("Adressen ohne Abfrage bleiben unverändert")
    func laesstHarmloseInRuhe() throws {
        let url = try #require(URL(string: "https://tv.example.de/System/Info/Public"))
        #expect(url.ohneGeheimnis == "https://tv.example.de/System/Info/Public")
    }
}

// MARK: - Quellenwahl

@Suite("Plan waehlt die verlustfreie Quelle")
struct QuellenwahlTests {

    private func quelle(_ id: String, direkt: Bool, strom: Bool = false) -> MediaSource {
        MediaSource(id: id, name: id, container: "mkv", size: 1,
                    supportsDirectPlay: direkt, supportsDirectStream: strom,
                    supportsTranscoding: true, transcodingUrl: "/t.m3u8",
                    mediaStreams: [])
    }

    private func plan(_ quellen: [MediaSource]) throws -> PlaybackPlan? {
        try PlaybackPlan.make(
            from: PlaybackInfoResponse(mediaSources: quellen, playSessionId: "s"),
            itemID: "abc",
            profile: .vlc(),
            streamURL: { id, quelle, _ in
                URL(string: "https://x.de/Videos/\(id)/stream?mediaSourceId=\(quelle ?? "")")!
            },
            serverBase: URL(string: "https://x.de")!)
    }

    /// Bei mehreren Fassungen eines Films — bei Jellyfin ein ueblicher Aufbau —
    /// wurde bisher blind die erste genommen. Stand dort ausgerechnet die, die
    /// umgewandelt werden muesste, wandelte die App um, obwohl daneben eine
    /// Fassung lag, die direkt laeuft.
    @Test("Nimmt die direkt abspielbare Fassung, nicht die erste")
    func bevorzugtDirectPlay() throws {
        let ergebnis = try #require(try plan([
            quelle("umwandeln", direkt: false),
            quelle("direkt", direkt: true),
        ]))
        #expect(ergebnis.method == .directPlay)
        #expect(ergebnis.mediaSourceID == "direkt")
    }

    @Test("Direct Stream schlaegt Umwandeln")
    func bevorzugtDirectStream() throws {
        let ergebnis = try #require(try plan([
            quelle("umwandeln", direkt: false),
            quelle("umpacken", direkt: false, strom: true),
        ]))
        #expect(ergebnis.method == .directStream)
        #expect(ergebnis.mediaSourceID == "umpacken")
    }

    /// Bei Gleichstand bleibt es bei der Reihenfolge des Servers — der sortiert
    /// selbst schon sinnvoll.
    @Test("Bei Gleichstand bleibt die erste Quelle")
    func behaeltReihenfolge() throws {
        let ergebnis = try #require(try plan([
            quelle("eins", direkt: true),
            quelle("zwei", direkt: true),
        ]))
        #expect(ergebnis.mediaSourceID == "eins")
    }

    @Test("Ohne Quelle kein Plan")
    func ohneQuelle() throws {
        #expect(try plan([]) == nil)
    }
}

// MARK: - Serveradresse

@Suite("Serveradresse")
struct ServeradresseTests {

    /// Der ueberwiegende Teil selbst gehosteter Jellyfin-Server laeuft im
    /// Heimnetz ohne Zertifikat. Wer die Adresse ohne Schema eintippt, bekam
    /// `https://` — und einen Fehler, dessen Ursache nicht zu erraten ist.
    @Test("IP-Adressen bekommen http, nicht https")
    func ipBekommtHTTP() throws {
        let url = try #require(AppModelURLNormalizer.normalize("192.168.1.5:8096"))
        #expect(url.scheme == "http")
        #expect(url.host() == "192.168.1.5")
        #expect(url.port == 8096)
    }

    @Test("Namen im Heimnetz bekommen http")
    func lokalBekommtHTTP() throws {
        let url = try #require(AppModelURLNormalizer.normalize("kiste.local:8096"))
        #expect(url.scheme == "http")
    }

    @Test("Oeffentliche Namen bekommen https")
    func oeffentlichBekommtHTTPS() throws {
        let url = try #require(AppModelURLNormalizer.normalize("tv.paulherter.de"))
        #expect(url.scheme == "https")
    }

    @Test("Ein angegebenes Schema wird nicht angetastet")
    func schemaBleibt() throws {
        #expect(AppModelURLNormalizer.normalize("http://tv.example.de")?.scheme == "http")
        #expect(AppModelURLNormalizer.normalize("https://192.168.1.5")?.scheme == "https")
    }

    @Test("Ausweichadresse fuer den zweiten Versuch")
    func ausweich() throws {
        let url = try #require(AppModelURLNormalizer.normalize("tv.example.de"))
        #expect(AppModelURLNormalizer.andersHerum(url)?.scheme == "http")
        // Wer schon auf http ist, hat keine Ausweichadresse mehr noetig.
        let lokal = try #require(AppModelURLNormalizer.normalize("192.168.1.5"))
        #expect(AppModelURLNormalizer.andersHerum(lokal) == nil)
    }

    /// **Tailscale vergibt aus 100.64.0.0/10, dem CGNAT-Bereich.**
    ///
    /// Ein Nutzer erreichte seinen Jellyfin unter `100.110.192.87:8096` und
    /// kam nicht durch. Am Normalisierer lag es nicht — jedes IP-Literal gilt
    /// als Heimnetz, also wird `http://` vorgesetzt, und das ist richtig.
    /// Gesperrt hat ATS: `NSAllowsLocalNetworking` deckt RFC1918, `.local`
    /// und `localhost`, aber **nicht** CGNAT, und seine blosse Anwesenheit
    /// schaltete `NSAllowsArbitraryLoads` ab. Der Test haelt die Halbe fest,
    /// die hier pruefbar ist; die andere steht im Info.plist.
    @Test func tailscaleAdresseGehtUeberHTTP() throws {
        #expect(AppModelURLNormalizer.istImHeimnetz("100.110.192.87"))
        let url = try #require(AppModelURLNormalizer.normalize("100.110.192.87:8096"))
        #expect(url.scheme == "http")
        #expect(url.port == 8096)
    }
}

// MARK: - Spuren und Sprachen

@Suite("Spurbeschriftung")
struct SpurTests {

    private func spur(_ sprache: String?, codec: String?, kanaele: Int?) -> MediaStream {
        MediaStream(codec: codec, type: "Audio", language: sprache, displayTitle: nil,
                    channels: kanaele, isDefault: nil, index: 0, height: nil, width: nil)
    }

    /// Bei null Kanaelen stand „-1.1" in der Zeile.
    @Test("Kaputte Kanalzahl erzeugt keinen Unsinn")
    func nullKanaele() {
        #expect(!spur("ger", codec: "ac3", kanaele: 0).kurz.contains("-1"))
        #expect(!spur("ger", codec: "ac3", kanaele: nil).kurz.contains("-1"))
        #expect(spur("ger", codec: "ac3", kanaele: 2).kurz.contains("Stereo"))
        #expect(spur("ger", codec: "dts", kanaele: 6).kurz.contains("5.1"))
        #expect(spur("ger", codec: "dts", kanaele: 8).kurz.contains("7.1"))
    }

    /// `contains` auf dem Anzeigenamen liess „Slovenian" als Englisch gelten,
    /// weil dort „en" vorkommt.
    @Test("Sprachabgleich trifft keine Teilwoerter")
    func keineTeilwoerter() {
        #expect(Sprache.passt("English", zu: "English"))
        #expect(Sprache.passt("eng", zu: "English"))
        #expect(Sprache.passt("Deutsch (Kommentar)", zu: "Deutsch"))
        #expect(!Sprache.passt("Slovenian", zu: "English"))
        #expect(!Sprache.passt("Armenian", zu: "English"))
        #expect(!Sprache.passt("Italiano", zu: "Deutsch"))
    }
}

// MARK: - Nachsichtiges Einlesen

@Suite("Antworten mit Luecken")
struct EinlesenTests {

    /// Ein einziger Eintrag ohne Namen liess vorher die **ganze** Liste
    /// scheitern — der Bildschirm blieb leer, ohne dass etwas gesagt wurde.
    @Test("Ein kaputter Eintrag kippt nicht die ganze Liste")
    func kaputterEintrag() throws {
        let json = """
        {"Items":[{"Id":"a","Name":"Guter Film"},{"Id":"b"},{"Id":"c","Name":"Noch einer"}],
         "TotalRecordCount":3}
        """
        let antwort = try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
        #expect(antwort.items.count == 2)
        #expect(antwort.items.map(\.id) == ["a", "c"])
    }

    /// `TotalRecordCount` fehlt bei manchen Endpunkten. Nicht optional
    /// eingelesen scheiterte die gesamte Antwort.
    @Test("Fehlende Gesamtzahl ist kein Grund zu scheitern")
    func ohneGesamtzahl() throws {
        let json = #"{"Items":[{"Id":"a","Name":"Film"}]}"#
        let antwort = try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
        #expect(antwort.items.count == 1)
        #expect(antwort.totalRecordCount == 1)
    }
}

// MARK: - Bildrate im Datenstrom

/// **Eine Nebenangabe darf die Wiedergabe nicht verhindern.**
///
/// `RealFrameRate` wird nur gebraucht, damit der Fernseher seinen Ausgang
/// früh genug umstellt. Wirft das Auspacken daran, fällt die ganze Antwort —
/// und der Titel lässt sich gar nicht mehr abspielen, ohne dass irgendetwas
/// auf die Bildrate hinweist.
@Suite("Bildrate im Medienstrom")
struct BildrateTests {
    private func strom(_ inhalt: String) throws -> MediaStream {
        let json = """
        {"Codec":"h264","Type":"Video","Width":1920,"Height":1080,\(inhalt)}
        """
        return try JSONDecoder().decode(MediaStream.self, from: Data(json.utf8))
    }

    @Test("Nimmt die Zahl, wie sie im Datenblatt steht")
    func alsZahl() throws {
        #expect(try strom("\"RealFrameRate\":23.976").bildrate == 23.976)
    }

    @Test("Nimmt sie auch als Zeichenkette")
    func alsText() throws {
        #expect(try strom("\"RealFrameRate\":\"25\"").bildrate == 25)
    }

    @Test("Unbrauchbares wirft nicht, es fehlt nur")
    func unbrauchbar() throws {
        #expect(try strom("\"RealFrameRate\":true").bildrate == nil)
        #expect(try strom("\"RealFrameRate\":null").bildrate == nil)
        #expect(try strom("\"RealFrameRate\":{\"a\":1}").bildrate == nil)
    }

    @Test("Fehlt sie ganz, bleibt der Strom trotzdem lesbar")
    func fehlt() throws {
        #expect(try strom("\"Index\":0").bildrate == nil)
    }

    @Test("Schwankende Bildrate meldet lieber nichts")
    func schwankend() throws {
        let stark = try strom("\"RealFrameRate\":30,\"AverageFrameRate\":24")
        #expect(stark.bildrate == nil)
        let leicht = try strom("\"RealFrameRate\":23.976,\"AverageFrameRate\":24")
        #expect(leicht.bildrate == 23.976)
    }
}

// MARK: - Profil zum Umpacken

/// **Umpacken heißt nicht umrechnen.**
///
/// Das Profil für den Serversprung darf dem Server nur erlauben, denselben
/// Strom in einen anderen Behälter zu legen. Nennt es andere Codecs als die,
/// die wir ohnehin direkt abspielen, rechnet der Server das Bild neu — und
/// genau dagegen gibt es diese App.
