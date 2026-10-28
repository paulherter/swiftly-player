import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **Sending a film to another device: what goes out, what comes in, and who is
/// offered.**
///
/// The request and the message are tested against each other: what the sender
/// builds must be what the receiver reads, once the server has turned the query
/// into its `Play` message.
@Suite("Abspielen auf: Auftrag, Ziele, Spuren")
struct PlayOnTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func client() async -> JellyfinClient {
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "iphone", deviceName: "Prüfgerät")
        await c.setSession(Session(accessToken: "tok", userID: "u1", userName: "Testnutzer",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    private func query(_ req: URLRequest) throws -> [String: String] {
        let url = try #require(req.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: - The request

    @Test("Der Auftrag geht als POST an die Sitzung, mit allen Angaben in Jellyfins Namen")
    func request() async throws {
        let order = PlayOrder(itemID: "e1", start: 812.5, mediaSourceID: "m1",
                              tracks: TrackIndices(audio: 2, subtitle: 5))
        let req = try await client().playOnRequest(session: "s9", order: order)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/Sessions/s9/Playing")
        let q = try query(req)
        #expect(q["playCommand"] == "PlayNow")
        #expect(q["itemIds"] == "e1")
        #expect(q["startPositionTicks"] == "8125000000")
        #expect(q["mediaSourceId"] == "m1")
        #expect(q["audioStreamIndex"] == "2")
        #expect(q["subtitleStreamIndex"] == "5")
        #expect(q["startIndex"] == nil)
    }

    @Test("Untertitel aus geht als -1, ohne Wahl fehlt die Angabe")
    func subtitleOff() async throws {
        let off = PlayOrder(itemID: "e1", start: 0, mediaSourceID: nil,
                            tracks: TrackIndices(audio: nil, subtitle: -1))
        let q = try query(try await client().playOnRequest(session: "s", order: off))
        #expect(q["subtitleStreamIndex"] == "-1")
        #expect(q["audioStreamIndex"] == nil)
        #expect(q["mediaSourceId"] == nil)
        #expect(q["startPositionTicks"] == "0")
    }

    // MARK: - The message

    @Test("Die Nachricht des Servers wird zum selben Auftrag")
    func roundTrip() async throws {
        let sent = PlayOrder(itemID: "4f2a", start: 812.5, mediaSourceID: "m1",
                             tracks: TrackIndices(audio: 2, subtitle: -1))
        let q = try query(try await client().playOnRequest(session: "s", order: sent))
        // What Jellyfin's `SessionManager` forwards, built from the query.
        let message = """
        {"MessageType":"Play","MessageId":"x","Data":{"ItemIds":["\(q["itemIds"]!)"],\
        "StartPositionTicks":\(q["startPositionTicks"]!),"PlayCommand":"\(q["playCommand"]!)",\
        "ControllingUserId":"u1","MediaSourceId":"\(q["mediaSourceId"]!)",\
        "AudioStreamIndex":\(q["audioStreamIndex"]!),"SubtitleStreamIndex":\(q["subtitleStreamIndex"]!)}}
        """
        #expect(PlayOrder.read(message) == sent)
    }

    @Test("Angehängte Folgen: es startet die genannte, StartIndex zählt")
    func followingEpisodes() throws {
        let plain = #"{"MessageType":"Play","Data":{"ItemIds":["e1","e2","e3"],"PlayCommand":"PlayNow"}}"#
        #expect(PlayOrder.read(plain)?.itemID == "e1")
        let indexed = #"{"MessageType":"Play","Data":{"ItemIds":["e1","e2"],"StartIndex":1,"PlayCommand":"PlayNow"}}"#
        #expect(PlayOrder.read(indexed)?.itemID == "e2")
        let past = #"{"MessageType":"Play","Data":{"ItemIds":["e1"],"StartIndex":4,"PlayCommand":"PlayNow"}}"#
        #expect(PlayOrder.read(past) == nil)
    }

    @Test("Nur PlayNow: Warteschlange und Fremdes werden abgelehnt")
    func onlyPlayNow() {
        #expect(PlayOrder.read(#"{"MessageType":"Play","Data":{"ItemIds":["e1"],"PlayCommand":"PlayNext"}}"#) == nil)
        #expect(PlayOrder.read(#"{"MessageType":"Play","Data":{"ItemIds":[],"PlayCommand":"PlayNow"}}"#) == nil)
        #expect(PlayOrder.read(#"{"MessageType":"Playstate","Data":{"Command":"Pause"}}"#) == nil)
        #expect(PlayOrder.read("kein JSON") == nil)
    }

    @Test("Ein Feld falscher Art kostet nur dieses Feld")
    func robust() {
        let raw = #"{"MessageType":"Play","Data":{"ItemIds":["e1"],"StartPositionTicks":"viel","AudioStreamIndex":1}}"#
        let order = PlayOrder.read(raw)
        #expect(order?.itemID == "e1")
        #expect(order?.start == 0)
        #expect(order?.audioIndex == 1)
        #expect(order?.subtitleIndex == nil)
    }

    // MARK: - The targets

    private func session(id: String = "s1", device: String? = "appletv",
                         name: String = "Wohnzimmer", user: String? = "u1",
                         program: String = "Swiftly Player", takesCommands: Bool = true,
                         media: [String] = ["Video", "Audio"],
                         secondsAgo: TimeInterval? = 5) -> RemoteSession {
        RemoteSession(id: id, userIdentifier: user, devicesIdentifier: device, deviceName: name,
                      program: program, takesCommands: takesCommands, running: nil, state: nil,
                      lastActivity: secondsAgo.map { now.addingTimeInterval(-$0) },
                      playableMediaTypes: media)
    }

    @Test("Fehlt die eigene Sitzung in der Liste, werden die Fähigkeiten neu gemeldet")
    func reportAgain() {
        let own = session(id: "s0", device: "iphone", name: "iPhone")
        #expect(!PlayTargets.mustReport([own, session()], ownDevicesIdentifier: "iphone"))
        // After a server restart: the TV is listed, this device is not.
        #expect(PlayTargets.mustReport([session()], ownDevicesIdentifier: "iphone"))
        #expect(PlayTargets.mustReport([], ownDevicesIdentifier: "iphone"))
    }

    private func targets(_ s: [RemoteSession]) -> [RemoteSession] {
        PlayTargets.targets(from: s, ownDevicesIdentifier: "iphone", ownUserIdentifier: "u1", now: now)
    }

    @Test("Ein Swiftly-Fernseher ohne laufenden Titel wird angeboten")
    func idleTV() {
        #expect(targets([session()]).map(\.id) == ["s1"])
    }

    @Test("Jede Bedingung für sich schließt aus")
    func conditions() {
        #expect(targets([session(device: "iphone")]).isEmpty)
        #expect(targets([session(device: nil)]).isEmpty)
        #expect(targets([session(user: "anna")]).isEmpty)
        #expect(targets([session(user: nil)]).isEmpty)
        #expect(targets([session(takesCommands: false)]).isEmpty)
        #expect(targets([session(media: ["Audio"])]).isEmpty)
        #expect(targets([session(secondsAgo: 91)]).isEmpty)
        #expect(targets([session(program: "Jellyfin Web")]).isEmpty)
        #expect(targets([session(program: "Swiftly Music")]).isEmpty)
    }

    @Test("Liest PlayableMediaTypes aus /Sessions")
    func decodesMediaTypes() throws {
        let raw = #"{"Id":"s1","DeviceId":"tv","SupportsRemoteControl":true,"PlayableMediaTypes":["Video"]}"#
        let s = try JSONDecoder().decode(RemoteSession.self, from: Data(raw.utf8))
        #expect(s.playableMediaTypes == ["Video"])
        let without = #"{"Id":"s1","DeviceId":"tv","SupportsRemoteControl":true}"#
        #expect(try JSONDecoder().decode(RemoteSession.self, from: Data(without.utf8)).playableMediaTypes == [])
    }

    @Test("Ein Eintrag je Gerät, die frischeste Sitzung, nach Namen sortiert")
    func onePerDevice() {
        let list = targets([
            session(id: "alt", secondsAgo: 60),
            session(id: "neu", secondsAgo: 2),
            session(id: "k", device: "shield", name: "Küche", secondsAgo: 30),
        ])
        #expect(list.map(\.id) == ["k", "neu"])
    }

    @Test("Der gewählte Ausgang findet die aktuelle Sitzung seines Geräts")
    func resolve() throws {
        let output = try #require(PlayOutput(session: session(id: "alt")))
        #expect(output == PlayOutput(deviceID: "appletv", name: "Wohnzimmer"))
        let fresh = targets([session(id: "neu")])
        #expect(PlayTargets.session(for: output, in: fresh)?.id == "neu")
        #expect(PlayTargets.session(for: output, in: []) == nil)
    }

    @Test("Der Ausgang wird unter festen Schlüsseln gespeichert")
    func outputKeys() throws {
        let data = try JSONEncoder().encode(PlayOutput(deviceID: "tv", name: "Гостиная"))
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(raw == ["deviceId": "tv", "name": "Гостиная"])
    }

    // MARK: - The tracks

    private func audio(_ index: Int, _ language: String) -> MediaStream {
        MediaStream(codec: "aac", type: "Audio", language: language, displayTitle: nil,
                    channels: 2, isDefault: nil, index: index, height: nil, width: nil)
    }

    private func subtitle(_ index: Int, _ language: String, forced: Bool = false) -> MediaStream {
        MediaStream(codec: "subrip", type: "Subtitle", language: language, displayTitle: nil,
                    channels: nil, isDefault: nil, index: index, height: nil, width: nil,
                    isForced: forced)
    }

    @Test("Gesendete Spuren schlagen die eigene Regel, unbekannte nicht")
    func orderedTracks() {
        let streams = [audio(1, "ger"), audio(2, "eng"), subtitle(3, "rus"), subtitle(4, "ger", forced: true)]
        // The TV would choose German audio and the forced German subtitle.
        #expect(TrackRule.audio(streams: streams, remembered: nil, preferredLanguage: "Deutsch",
                                serverPreGift: nil, ordered: 2) == 2)
        #expect(TrackRule.audio(streams: streams, remembered: nil, preferredLanguage: "Deutsch",
                                serverPreGift: nil, ordered: 9) == 1)
        func sub(_ ordered: Int?) -> TrackRule.Subtitle {
            TrackRule.subtitle(streams: streams, remembered: nil, serverPreGift: nil, automatic: false,
                               audioIndex: 1, tonwunsch: "Deutsch", preferredLanguage: "",
                               ordered: ordered)
        }
        #expect(sub(nil) == .feed(4))
        #expect(sub(-1) == .off)
        #expect(sub(3) == .feed(3))
        #expect(sub(9) == .feed(4))
    }

    @Test("Was der Sender schickt, ist was er selbst gespielt hätte")
    func startIndices() {
        let streams = [audio(1, "ger"), audio(2, "eng"), subtitle(3, "rus")]
        // English audio from the server's default, Russian subtitles automatically.
        let automatic = TrackRule.startIndices(streams: streams, rememberedAudio: nil,
                                               rememberedSubtitle: nil, serverAudio: 2,
                                               serverSubtitle: nil, automatic: true,
                                               audioLanguage: "", subtitleLanguage: "Русский")
        #expect(automatic == TrackIndices(audio: 2, subtitle: 3))
        let none = TrackRule.startIndices(streams: streams, rememberedAudio: nil,
                                          rememberedSubtitle: nil, serverAudio: nil,
                                          serverSubtitle: nil, automatic: false,
                                          audioLanguage: "", subtitleLanguage: "")
        #expect(none == TrackIndices(audio: nil, subtitle: -1))
    }

    @Test("Der Auftrag für einen Titel nimmt die gewählte Version und ihre Spuren")
    func titleOrder() throws {
        let raw = """
        {"Id":"f1","Name":"Film","Type":"Movie","MediaSources":[
          {"Id":"v1","MediaStreams":[{"Type":"Audio","Index":1,"Language":"ger"}],"DefaultAudioStreamIndex":1},
          {"Id":"v2","MediaStreams":[{"Type":"Audio","Index":1,"Language":"ger"},
                                     {"Type":"Audio","Index":2,"Language":"eng"}],"DefaultAudioStreamIndex":2}]}
        """
        let film = try JSONDecoder().decode(Item.self, from: Data(raw.utf8))
        func order(_ source: String?) -> PlayOrder {
            PlayOrder.title(film, start: 30, sourceID: source, rememberedAudio: nil,
                            rememberedSubtitle: nil, automatic: false,
                            audioLanguage: "", subtitleLanguage: "")
        }
        #expect(order("v2") == PlayOrder(itemIDs: ["f1"], start: 30, mediaSourceID: "v2",
                                         audioIndex: 2, subtitleIndex: -1))
        #expect(order(nil).mediaSourceID == "v1")
        #expect(order(nil).audioIndex == 1)

        let bare = try JSONDecoder().decode(Item.self, from: Data(#"{"Id":"f2","Name":"Film"}"#.utf8))
        let without = PlayOrder.title(bare, start: 0, sourceID: nil, rememberedAudio: nil,
                                      rememberedSubtitle: nil, automatic: true,
                                      audioLanguage: "", subtitleLanguage: "")
        #expect(without == PlayOrder(itemIDs: ["f2"], start: 0))
    }
}
