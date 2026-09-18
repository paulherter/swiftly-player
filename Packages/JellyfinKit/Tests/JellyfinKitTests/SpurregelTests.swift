import Foundation
import Testing
@testable import JellyfinKit

@Suite("Spuren: Zuordnung, Regel, Gedächtnis")
struct SpurregelTests {

    private func ut(_ index: Int, _ sprache: String, forced: Bool = false, extern: Bool = false,
                    codec: String = "subrip", titel: String? = nil) -> MediaStream {
        MediaStream(codec: codec, type: "Subtitle", language: sprache, displayTitle: nil,
                    channels: nil, isDefault: nil, index: index, height: nil, width: nil,
                    isForced: forced, isExternal: extern, title: titel,
                    deliveryUrl: extern ? "/Videos/x/y/Subtitles/\(index)/0/Stream.srt" : nil)
    }

    private func ton(_ index: Int, _ sprache: String, codec: String = "aac", kanaele: Int = 2,
                     titel: String? = nil) -> MediaStream {
        MediaStream(codec: codec, type: "Audio", language: sprache, displayTitle: nil,
                    channels: kanaele, isDefault: nil, index: index, height: nil, width: nil,
                    title: titel)
    }

    private func vlc(_ kennung: String, _ name: String, sprache: String? = nil,
                     codec: String? = nil) -> Abspielerspur {
        Abspielerspur(kennung: kennung, name: name, sprache: sprache, codec: codec, kanaele: nil)
    }

    // MARK: Zuordnung

    @Test("Gleiche Namen: die Position entscheidet, nicht der Name")
    func gleicheNamen() {
        let stroeme = [ton(1, "ger"), ut(2, "ger", forced: true), ut(3, "ger")]
        let z = Spurzuordnung.bilden(
            ton: [vlc("audio/1", "Deutsch", sprache: "ger", codec: "AAC")],
            untertitel: [vlc("spu/2", "Deutsch", sprache: "ger"), vlc("spu/3", "Deutsch", sprache: "ger")],
            stroeme: stroeme, dateien: [])
        #expect(z.ton == [1])
        #expect(z.untertitel == [2, 3])
    }

    @Test("Abweichende Anzahl: nur Belegtes wird zugeordnet")
    func anzahlWeichtAb() {
        // VLC lässt die mittlere Spur weg.
        let stroeme = [ton(1, "ger", codec: "dts"), ton(2, "eng", codec: "truehd"), ton(3, "jpn")]
        let z = Spurzuordnung.bilden(
            ton: [vlc("audio/1", "German", sprache: "German", codec: "DTS"),
                  vlc("audio/3", "Japanese", sprache: "jpn", codec: "AAC")],
            untertitel: [], stroeme: stroeme, dateien: [])
        #expect(z.ton == [1, 3])

        // Nichts zu belegen: lieber nichts als geraten.
        let ohne = Spurzuordnung.bilden(ton: [vlc("audio/1", "Spur 1")], untertitel: [],
                                        stroeme: [ton(1, "ger"), ton(2, "eng")], dateien: [])
        #expect(ohne.ton == [nil])
    }

    @Test("Sprache widerspricht bei gleicher Anzahl: nicht blind nach Position")
    func widerspruch() {
        let stroeme = [ut(3, "eng"), ut(4, "ger")]
        let z = Spurzuordnung.bilden(ton: [], untertitel: [vlc("spu/4", "Deutsch", sprache: "ger")],
                                     stroeme: [ut(4, "ger")], dateien: [])
        #expect(z.untertitel == [4])
        let vertauscht = Spurzuordnung.bilden(
            ton: [], untertitel: [vlc("spu/1", "German", sprache: "German"), vlc("spu/2", "English", sprache: "eng")],
            stroeme: stroeme, dateien: [])
        #expect(vertauscht.untertitel == [4, nil])
    }

    @Test("Externe Datei über den MD5 der Adresse, getrennt von den eingebetteten")
    func externeSpur() throws {
        let md5 = "0123456789abcdef0123456789abcdef"
        let stroeme = [ton(1, "ger"), ut(2, "ger", forced: true), ut(5, "eng", extern: true)]
        let datei = Untertiteldatei(index: 5, adresse: try #require(URL(string: "https://s/x.srt")), merkmal: md5)
        let z = Spurzuordnung.bilden(
            ton: [vlc("audio/1", "Deutsch")],
            untertitel: [vlc("\(md5)/spu/0", "Track 1"), vlc("spu/2", "Deutsch", sprache: "ger")],
            stroeme: stroeme, dateien: [datei])
        #expect(z.untertitel == [5, 2])
        #expect(z.untertitelposition(index: 5) == 0)

        // Ohne Merkmal: Reihenfolge, wenn es aufgeht.
        let ohne = Untertiteldatei(index: 5, adresse: datei.adresse, merkmal: nil)
        let z2 = Spurzuordnung.bilden(ton: [], untertitel: [vlc("spu/2", "D"), vlc("\(md5)/spu/0", "T")],
                                      stroeme: stroeme, dateien: [ohne])
        #expect(z2.untertitel == [2, 5])
    }

    @Test("Externe Adressen kommen vom Server, mit Schlüssel")
    func externeAdressen() throws {
        let stroeme = [ut(2, "ger"), ut(5, "eng", extern: true)]
        let dateien = Untertiteldatei.aus(stroeme: stroeme, server: try #require(URL(string: "https://tv.example")),
                                          schluessel: "abc", merkmal: { _ in "m" })
        #expect(dateien.count == 1)
        #expect(dateien.first?.index == 5)
        #expect(dateien.first?.adresse.absoluteString == "https://tv.example/Videos/x/y/Subtitles/5/0/Stream.srt?ApiKey=abc")
        #expect(dateien.first?.merkmal == "m")
    }

    @Test("DeliveryUrl, Title und Server-Vorgaben kommen an")
    func decodiert() throws {
        let json = #"{"Id":"q","DefaultAudioStreamIndex":2,"DefaultSubtitleStreamIndex":-1,"MediaStreams":[{"Type":"Subtitle","Index":4,"IsExternal":true,"IsForced":true,"Title":"Forced","DeliveryUrl":"/Videos/a/b/Subtitles/4/0/Stream.srt"}]}"#
        let quelle = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        #expect(quelle.defaultAudioStreamIndex == 2)
        #expect(quelle.defaultSubtitleStreamIndex == -1)
        let strom = try #require(quelle.mediaStreams?.first)
        #expect(strom.deliveryUrl == "/Videos/a/b/Subtitles/4/0/Stream.srt")
        #expect(strom.title == "Forced")
        #expect(strom.isForced == true && strom.isExternal == true)
    }

    // MARK: Regel

    private func regel(_ stroeme: [MediaStream], gemerkt: Spurgedaechtnis.Wahl? = nil, vorgabe: Int? = nil,
                       automatisch: Bool = false, tonindex: Int? = 1, tonwunsch: String = "",
                       wunsch: String = "") -> Spurregel.Untertitel {
        Spurregel.untertitel(stroeme: stroeme, gemerkt: gemerkt, serverVorgabe: vorgabe,
                             automatisch: automatisch, tonindex: tonindex, tonwunsch: tonwunsch,
                             wunschsprache: wunsch)
    }

    @Test("Ohne Einstellung: erzwungene an, sonst aus — nicht die erste")
    func erzwungenOderAus() {
        #expect(regel([ton(1, "ger"), ut(2, "ger"), ut(3, "ger", forced: true)]) == .strom(3))
        #expect(regel([ton(1, "ger"), ut(2, "ger"), ut(3, "eng")]) == .aus)
        // Bei mehreren erzwungenen die in der Tonsprache.
        #expect(regel([ton(1, "ger"), ut(2, "eng", forced: true), ut(3, "ger", forced: true)]) == .strom(3))
    }

    @Test("Externe erzwungene Spur zählt mit")
    func externErzwungen() {
        #expect(regel([ton(1, "ger"), ut(2, "eng"), ut(7, "ger", forced: true, extern: true)]) == .strom(7))
    }

    @Test("Vorgaben-Reihenfolge: Handwahl, automatisch, Server, erzwungen")
    func reihenfolge() {
        let stroeme = [ton(1, "eng"), ut(2, "ger", forced: true), ut(3, "ger"), ut(4, "eng")]
        let englischGemerkt = Spurabdruck(strom: stroeme[3], in: stroeme)
        // Handwahl schlägt alles, auch „aus".
        #expect(regel(stroeme, gemerkt: .spur(englischGemerkt), vorgabe: 3, automatisch: true, wunsch: "Deutsch") == .strom(4))
        #expect(regel(stroeme, gemerkt: .aus, vorgabe: 2) == .aus)
        // Automatisch, Ton fremd: volle Spur der Wunschsprache vor der Server-Vorgabe.
        #expect(regel(stroeme, vorgabe: 4, automatisch: true, wunsch: "Deutsch") == .strom(3))
        // Server-Vorgabe ohne „automatisch" nur, wenn erzwungen.
        #expect(regel(stroeme, vorgabe: 4) == .strom(2))
        #expect(regel([ton(1, "ger"), ut(2, "ger"), ut(3, "ger", forced: true), ut(4, "ger", forced: true)], vorgabe: 4) == .strom(4))
        // Mit „automatisch" gilt die Server-Vorgabe auch voll.
        #expect(regel([ton(1, "ger"), ut(2, "ger", forced: true), ut(4, "eng")], vorgabe: 4, automatisch: true, wunsch: "Deutsch") == .strom(4))
        // Server sagt „keine": erzwungene bleiben an.
        #expect(regel(stroeme, vorgabe: -1) == .strom(2))
    }

    @Test("Schalter aus: die Wunschsprache schaltet nichts dazu")
    func schalterAus() {
        #expect(regel([ton(1, "eng"), ut(2, "ger"), ut(3, "eng")], wunsch: "Deutsch") == .aus)
    }

    @Test("Ton: Handwahl, dann Tonsprache der App, dann Server, sonst Datei")
    func tonregel() {
        let stroeme = [ton(1, "ger", codec: "ac3", kanaele: 6), ton(2, "eng", codec: "truehd", kanaele: 8), ton(3, "eng", codec: "aac")]
        let gemerkt = Spurabdruck(strom: stroeme[2], in: stroeme)
        #expect(Spurregel.ton(stroeme: stroeme, gemerkt: gemerkt, wunschsprache: "Deutsch", serverVorgabe: 1) == 3)
        #expect(Spurregel.ton(stroeme: stroeme, gemerkt: nil, wunschsprache: "English", serverVorgabe: 1) == 2)
        #expect(Spurregel.ton(stroeme: stroeme, gemerkt: nil, wunschsprache: "", serverVorgabe: 2) == 2)
        #expect(Spurregel.ton(stroeme: stroeme, gemerkt: nil, wunschsprache: "", serverVorgabe: nil) == nil)
    }

    @Test("Nächste Folge trifft die gemerkte Spur, auch bei gleichen Namen und neuer Reihenfolge")
    func naechsteFolge() {
        let folge1 = [ton(1, "ger"), ut(2, "ger", forced: true, titel: "Forced"), ut(3, "ger", titel: "Full")]
        let gewaehlt = Spurabdruck(strom: folge1[2], in: folge1, name: "Deutsch")
        // Folge 2: andere Indizes, volle Spur zuerst.
        let folge2 = [ton(0, "ger"), ut(5, "ger", titel: "Full"), ut(6, "ger", forced: true, titel: "Forced")]
        #expect(regel(folge2, gemerkt: .spur(gewaehlt), tonindex: 0) == .strom(5))
        // Ohne Titel entscheidet „erzwungen".
        let folge3 = [ton(0, "ger"), ut(8, "ger", forced: true), ut(9, "ger")]
        #expect(regel(folge3, gemerkt: .spur(gewaehlt), tonindex: 0) == .strom(9))
        // Die Sprache fehlt: Normalfall statt einer fremden Sprache.
        let folge4 = [ton(0, "eng"), ut(8, "eng")]
        #expect(regel(folge4, gemerkt: .spur(gewaehlt), tonindex: 0) == .aus)
    }

    @Test("Alte Einträge (Spurname) bleiben lesbar")
    func altereintrag() {
        let stroeme = [ton(1, "eng"), ut(2, "ger", forced: true), ut(3, "ger")]
        #expect(regel(stroeme, gemerkt: .name("Deutsch")) == .strom(3))
        #expect(regel(stroeme, gemerkt: .name("Deutsch Forced")) == .strom(2))
    }

    // MARK: Gedächtnis und Meldung

    @Test("Gedächtnis je Serie, für Ton und Untertitel, übersteht einen Neustart")
    func gedaechtnis() throws {
        let name = "SpurregelTests"
        let ablage = try #require(UserDefaults(suiteName: name))
        ablage.removePersistentDomain(forName: name)
        // Ein Eintrag aus der alten Fassung.
        ablage.set(["alt": "English"], forKey: "utJeTitel")
        let abdruck = Spurabdruck(strom: ton(2, "eng"), in: [ton(1, "ger"), ton(2, "eng")])
        Spurgedaechtnis(ablage: ablage).merkeUntertitel(.aus, fuer: "serie")
        Spurgedaechtnis(ablage: ablage).merkeTon(abdruck, fuer: "serie")
        Spurgedaechtnis(ablage: ablage).merkeUntertitel(.spur(abdruck), fuer: "film")
        let neu = Spurgedaechtnis(ablage: ablage)
        #expect(neu.untertitel(fuer: "serie") == .aus)
        #expect(neu.ton(fuer: "serie") == abdruck)
        #expect(neu.untertitel(fuer: "film") == .spur(abdruck))
        #expect(neu.untertitel(fuer: "alt") == .name("English"))
        #expect(neu.untertitel(fuer: "anderes") == nil)
        #expect(neu.ton(fuer: "film") == nil)
    }

    @Test("Meldung trägt die Spurindizes, ohne Angabe fehlen sie")
    func meldung() throws {
        let plan = PlaybackPlan.vonDerPlatte(try #require(URL(string: "https://s/a")), container: nil)
        let mit = JellyfinClient.meldekoerper(itemID: "i", plan: plan, positionTicks: 0, paused: false,
                                              spuren: Spurindizes(ton: 2, untertitel: -1))
        let text = String(decoding: try JSONEncoder().encode(mit), as: UTF8.self)
        #expect(text.contains(#""AudioStreamIndex":2"#))
        #expect(text.contains(#""SubtitleStreamIndex":-1"#))
        let ohne = JellyfinClient.meldekoerper(itemID: "i", plan: plan, positionTicks: 0, paused: false,
                                               spuren: Spurindizes())
        let leer = String(decoding: try JSONEncoder().encode(ohne), as: UTF8.self)
        #expect(!leer.contains("StreamIndex"))
    }
}
