import Foundation
import Testing
@testable import JellyfinKit

@Suite("Abschnitte einlesen")
struct SectionInReadTests {

    /// Exactly the shape `MediaSegmentDto` has in the OpenAPI description of the
    /// server, read off, not reconstructed.
    private let answer = """
    { "Items": [
        { "Id": "a1", "ItemId": "e1", "Type": "Intro",
          "StartTicks": 0, "EndTicks": 900000000 },
        { "Id": "a2", "ItemId": "e1", "Type": "Outro",
          "StartTicks": 13200000000, "EndTicks": 13800000000 }
      ], "TotalRecordCount": 2, "StartIndex": 0 }
    """.data(using: .utf8)!

    @Test("Ticks werden zu Sekunden — Faktor zehn Millionen")
    func ticks() throws {
        let a = try JSONDecoder().decode(SectionResponse.self, from: answer)
        #expect(a.items.count == 2)
        #expect(a.items[0].art == .introSegment)
        #expect(a.items[0].from == 0)
        #expect(a.items[0].until == 90)          // 900,000,000 ticks
        #expect(a.items[1].art == .credits)
        #expect(a.items[1].from == 1320)
    }

    @Test("Eine leere Liste ist der Normalfall, kein Fehler")
    func empty() throws {
        let d = #"{ "Items": [], "TotalRecordCount": 0, "StartIndex": 0 }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(SectionResponse.self, from: d).items.isEmpty)
    }

    @Test("Fehlt Items ganz, ist es auch leer")
    func withoutItems() throws {
        let d = #"{ "TotalRecordCount": 0 }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(SectionResponse.self, from: d).items.isEmpty)
    }

    @Test("Eine unbekannte Art wirft nicht, sie heißt unbekannt")
    func unknownArt() throws {
        // This used to read "Intro": the test checked the known kind,
        // and the unknown one threw away the whole response.
        let d = #"{ "Items": [ { "Type": "Werbepause2030", "StartTicks": 0, "EndTicks": 10000000 },"#
            + #" { "Type": "Intro", "StartTicks": 0, "EndTicks": 900000000 } ] }"#
        let a = try JSONDecoder().decode(SectionResponse.self, from: Data(d.utf8))
        #expect(a.items.count == 2)
        #expect(a.items[0].art == .unknown)
        #expect(a.items[0].until == 1)
        #expect(a.items[1].art == .introSegment)
    }

    @Test("Ein kaputter Abschnitt nimmt die anderen nicht mit")
    func brokenSection() throws {
        let d = #"{ "Items": [ { "Type": "Intro", "StartTicks": "neun", "EndTicks": 1 },"#
            + #" { "Type": "Outro", "StartTicks": 0, "EndTicks": 10000000 }, 42, null ] }"#
        let a = try JSONDecoder().decode(SectionResponse.self, from: Data(d.utf8))
        #expect(a.items.map(\.art) == [.credits])
    }
}

@Suite("Welcher Knopf gilt")
struct SectionLogicTests {

    private let introSegment = Segment(art: .introSegment, from: 12, until: 90)
    private let credits  = Segment(art: .credits,  from: 1320, until: 1380)

    // MARK: - Without sections nothing may change

    @Test("Ohne Abschnitte gilt allein die Restzeitregel")
    func withoutSections() {
        // 1400 of 1500 s counts as "near the end" after the episode ends.
        #expect(SectionLogic.offering(position: 1400, duration: 1500, sections: [],
                                        hasNextEpisode: true) == .nextEpisode)
        #expect(SectionLogic.offering(position: 300, duration: 1500, sections: [],
                                        hasNextEpisode: true) == .nobody)
    }

    @Test("Ohne Abschnitte stimmen die Zeitpunkte auf die Sekunde mit Folgenende")
    func sameTimestamp() {
        for spot in stride(from: 0.0, through: 1500.0, by: 5) {
            let alt = EpisodeEnd.buttonShow(position: spot, duration: 1500)
            let new = SectionLogic.offering(position: spot, duration: 1500,
                                              sections: [], hasNextEpisode: true)
            #expect((new == .nextEpisode) == alt, "bei \(spot) s")
        }
    }

    @Test("Ohne nächste Folge kein Knopf")
    func noNext() {
        #expect(SectionLogic.offering(position: 1400, duration: 1500, sections: [credits],
                                        hasNextEpisode: false) == .nobody)
    }

    // MARK: - Intro

    @Test("Im Vorspann wird das Überspringen angeboten")
    func inIntro() {
        #expect(SectionLogic.offering(position: 30, duration: 1500, sections: [introSegment, credits],
                                        hasNextEpisode: true)
                == .skip(to: 90, art: .introSegment))
    }

    @Test("Vor dem Vorspann und danach nicht")
    func besideIntro() {
        #expect(SectionLogic.offering(position: 5, duration: 1500, sections: [introSegment],
                                        hasNextEpisode: false) == .nobody)
        #expect(SectionLogic.offering(position: 95, duration: 1500, sections: [introSegment],
                                        hasNextEpisode: false) == .nobody)
    }

    @Test("Am Rand: die Anfangssekunde zählt dazu, die Endsekunde nicht")
    func edges() {
        #expect(SectionLogic.offering(position: 12, duration: 1500, sections: [introSegment],
                                        hasNextEpisode: false)
                == .skip(to: 90, art: .introSegment))
        #expect(SectionLogic.offering(position: 90, duration: 1500, sections: [introSegment],
                                        hasNextEpisode: false) == .nobody)
    }

    @Test("Kurz vor Schluss des Vorspanns nicht mehr — der Knopf würde nur aufblitzen")
    func shortPreEnd() {
        #expect(SectionLogic.offering(position: 89, duration: 1500, sections: [introSegment],
                                        hasNextEpisode: false) == .nobody)
    }

    @Test("Rückblick, Vorschau und Werbung werden auch angeboten")
    func otherKinds() {
        for art in [Segment.Art.lookBack, .preview, .ads] {
            let a = Segment(art: art, from: 10, until: 60)
            #expect(SectionLogic.offering(position: 20, duration: 1500, sections: [a],
                                            hasNextEpisode: false)
                    == .skip(to: 60, art: art))
        }
    }

    @Test("Ein unbekannter Abschnitt wird nicht angeboten")
    func unknown() {
        let a = Segment(art: .unknown, from: 10, until: 60)
        #expect(SectionLogic.offering(position: 20, duration: 1500, sections: [a],
                                        hasNextEpisode: false) == .nobody)
    }

    // MARK: - Credits

    @Test("Mit Abspannangabe bis zum Ende gilt sie und nicht die Restzeit")
    func creditsApplies() {
        let untilEnd = Segment(art: .credits, from: 1320, until: 1499)
        // 1200 of 1500 would not be anything by the remaining-time rule, nor by credits.
        #expect(SectionLogic.offering(position: 1200, duration: 1500, sections: [untilEnd],
                                        hasNextEpisode: true) == .nobody)
        #expect(SectionLogic.offering(position: 1320, duration: 1500, sections: [untilEnd],
                                        hasNextEpisode: true) == .nextEpisode)
    }

    @Test("Abspann vor dem Dateiende wird übersprungen, danach kommt „Nächste Folge“")
    func creditsWithSceneAfter() {
        // `credits` ends 120 s before the end: another scene lies behind it.
        #expect(SectionLogic.offering(position: 1330, duration: 1500, sections: [credits],
                                        hasNextEpisode: true)
                == .skip(to: 1380, art: .credits))
        #expect(SectionLogic.offering(position: 1330, duration: 1500, sections: [credits],
                                        hasNextEpisode: false)
                == .skip(to: 1380, art: .credits),
                "auch in der letzten Folge will man zur Szene danach")
        #expect(SectionLogic.offering(position: 1400, duration: 1500, sections: [credits],
                                        hasNextEpisode: true) == .nextEpisode)
        #expect(!SectionLogic.cardDue(position: 1400, duration: 1500, sections: [credits],
                                              hasNextEpisode: true),
                "die Szene nach dem Abspann bekommt keine Karte ins Bild")
        #expect(!SectionLogic.cardDue(position: 1491, duration: 1500, sections: [credits],
                                              hasNextEpisode: true),
                "auch nicht kurz vor Schluss — sonst schnitte der Countdown sie ab")
    }

    @Test("Toleranz am Dateiende: zwei Sekunden davor zählt noch als bis zum Ende")
    func creditsTolerance() {
        let tight = Segment(art: .credits, from: 1400, until: 1498)
        let prior = Segment(art: .credits, from: 1400, until: 1497)
        #expect(SectionLogic.offering(position: 1410, duration: 1500, sections: [tight],
                                        hasNextEpisode: true) == .nextEpisode)
        #expect(SectionLogic.offering(position: 1410, duration: 1500, sections: [prior],
                                        hasNextEpisode: true)
                == .skip(to: 1497, art: .credits))
    }

    @Test("Abspann bis zum Ende ohne nächste Folge: kein Knopf")
    func creditsUntilEndLastEpisode() {
        let untilEnd = Segment(art: .credits, from: 1320, until: 1500)
        #expect(SectionLogic.offering(position: 1330, duration: 1500, sections: [untilEnd],
                                        hasNextEpisode: false) == .nobody)
    }

    // MARK: - Minimum length and card

    @Test("Abschnitte unter drei Sekunden bekommen keinen Knopf")
    func minLength() {
        let short = Segment(art: .introSegment, from: 10, until: 12.9)
        let enough = Segment(art: .introSegment, from: 10, until: 13)
        #expect(SectionLogic.offering(position: 10, duration: 1500, sections: [short],
                                        hasNextEpisode: false) == .nobody)
        #expect(SectionLogic.offering(position: 10, duration: 1500, sections: [enough],
                                        hasNextEpisode: false)
                == .skip(to: 13, art: .introSegment))
    }

    @Test("Ein zu kurzer Abspann zählt nicht — dann gilt die Restzeitregel")
    func shortCredits() {
        let short = Segment(art: .credits, from: 1498, until: 1500)
        #expect(SectionLogic.offering(position: 1400, duration: 1500, sections: [short],
                                        hasNextEpisode: true) == .nextEpisode)
    }

    @Test("Ohne Abspann-Abschnitt nie eine Karte, nur der Knopf in der Steuerung")
    func cardWithoutSections() {
        #expect(SectionLogic.offering(position: 1400, duration: 1500, sections: [],
                                        hasNextEpisode: true) == .nextEpisode)
        #expect(!SectionLogic.cardDue(position: 1400, duration: 1500, sections: [],
                                              hasNextEpisode: true))
        #expect(!SectionLogic.cardDue(position: 1499, duration: 1500, sections: [],
                                              hasNextEpisode: true))
        let intro = Segment(art: .introSegment, from: 10, until: 60)
        #expect(!SectionLogic.cardDue(position: 1499, duration: 1500, sections: [intro],
                                              hasNextEpisode: true))
    }

    @Test("Die Füllung dauert sieben Sekunden, aber nie über das Dateiende hinaus")
    func countdownLength() {
        #expect(SectionLogic.countdown(position: 1320, duration: 1500) == 7)
        #expect(SectionLogic.countdown(position: 1496, duration: 1500) == 4)
        #expect(SectionLogic.countdown(position: 1500, duration: 1500) == 1)
    }

    @Test("Mit Abspann bis zum Ende kommt die Karte mit dem Abspann")
    func cardWithCredits() {
        let untilEnd = Segment(art: .credits, from: 1320, until: 1500)
        #expect(!SectionLogic.cardDue(position: 1319, duration: 1500, sections: [untilEnd],
                                              hasNextEpisode: true))
        #expect(SectionLogic.cardDue(position: 1320, duration: 1500, sections: [untilEnd],
                                             hasNextEpisode: true))
    }

    @Test("Ein früher Abspann zeigt den Knopf früher als die Restzeitregel")
    func earlierCredits() {
        let early = Segment(art: .credits, from: 1100, until: 1500)
        #expect(!EpisodeEnd.buttonShow(position: 1100, duration: 1500),
                "nach der alten Regel wäre hier noch nichts")
        #expect(SectionLogic.offering(position: 1100, duration: 1500, sections: [early],
                                        hasNextEpisode: true) == .nextEpisode)
    }

    @Test("Ein sehr späterer Abspann unterdrückt den Knopf, den die Restzeit gezeigt hätte")
    func laterCredits() {
        let late = Segment(art: .credits, from: 1490, until: 1500)
        #expect(EpisodeEnd.buttonShow(position: 1400, duration: 1500),
                "nach der alten Regel stünde er hier")
        #expect(SectionLogic.offering(position: 1400, duration: 1500, sections: [late],
                                        hasNextEpisode: true) == .nobody,
                "die Angabe des Servers gilt allein — sonst erschiene er zweimal")
    }

    @Test("Der Vorspann gewinnt gegen den Abspann, wenn die Stelle in ihm liegt")
    func introWins() {
        // Contrived, but it costs nothing to pin the order down.
        let everywhere = Segment(art: .credits, from: 0, until: 1500)
        #expect(SectionLogic.offering(position: 30, duration: 1500,
                                        sections: [everywhere, introSegment],
                                        hasNextEpisode: true)
                == .skip(to: 90, art: .introSegment))
    }

    /// findroid#1123: after jumping to the segment end the player stood
    /// just before it, rounded to milliseconds or on the preceding
    /// keyframe, and offered the same jump again. With automatic skipping
    /// that becomes a loop. Here: the target no longer lies in the section,
    /// and everything up to ``Abschnittslogik/mindestrest`` before it does not offer it.
    @Test("Nach dem Sprung ans Abschnittsende kein zweites Angebot — auch leicht davor")
    func noSecondOffering() throws {
        // An end that cannot be written evenly in milliseconds.
        let json = #"{"Type":"Intro","StartTicks":120000000,"EndTicks":899999999}"#
        let intro = try JSONDecoder().decode(Segment.self, from: Data(json.utf8))
        guard case let .skip(to, _) = SectionLogic.offering(
            position: 20, duration: 1500, sections: [intro], hasNextEpisode: true) else {
            Issue.record("kein Angebot im Vorspann"); return
        }
        // The way the player jumps: whole milliseconds, truncated.
        let landed = Double(Int(to * 1000)) / 1000
        for beside in [0, 0.001, 0.5, 1.0, SectionLogic.minRemaining - 0.01] {
            #expect(SectionLogic.offering(position: landed - beside, duration: 1500,
                                            sections: [intro], hasNextEpisode: true)
                    == .nobody, "gelandet \(beside) s vor dem Ende")
        }
    }
}

@Suite("Automatisch überspringen")
struct SectionAutomaticTests {
    private let parts = [Segment(art: .introSegment, from: 10, until: 70),
                         Segment(art: .lookBack, from: 80, until: 120),
                         Segment(art: .credits, from: 1300, until: 1400)]

    @Test("Im Intro: ans Ende des Intros")
    func intro() {
        let a = SectionLogic.automatic(position: 12, duration: 1400, sections: parts, hasNextEpisode: true)
        #expect(a?.offering == .skip(to: 70, art: .introSegment))
    }

    @Test("Rückblick wird nicht automatisch übersprungen")
    func recap() {
        #expect(SectionLogic.automatic(position: 90, duration: 1400, sections: parts, hasNextEpisode: true) == nil)
    }

    @Test("Abspann bis zum Dateiende: nächste Folge, ohne Folge nichts")
    func credits() {
        #expect(SectionLogic.automatic(position: 1301, duration: 1400, sections: parts, hasNextEpisode: true)?.offering == .nextEpisode)
        #expect(SectionLogic.automatic(position: 1301, duration: 1400, sections: parts, hasNextEpisode: false) == nil)
    }

    @Test("Abspann mit Szene danach: springt ans Ende des Abspanns")
    func creditsThenScene() {
        let a = SectionLogic.automatic(position: 1301, duration: 1500, sections: parts, hasNextEpisode: true)
        #expect(a?.offering == .skip(to: 1400, art: .credits))
    }

    @Test("Außerhalb der Abschnitte nichts")
    func outside() {
        #expect(SectionLogic.automatic(position: 500, duration: 1400, sections: parts, hasNextEpisode: true) == nil)
    }
}
