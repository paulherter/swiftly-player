import Foundation
import Testing
@testable import JellyfinKit

/// The rules both players run by.
///
/// They lived in the views for a long time, outside any checks, written
/// twice, once per platform. That is where they drifted
/// apart: on the TV a series showed "0 Min." because
/// a check was missing that the iPhone had. So they live here now,
/// where `swift test` runs them every time.
@MainActor
@Suite("Wiedergabetakt")
struct PlaybackTickTests {

    private func measurement(duration: Double = 3600, position: Double = 0,
                         goodPoint: Double = 0, showsImage: Bool = true,
                         seeksToStart: Bool = false, running: Bool = true,
                         tracks: Bool = true) -> PlaybackTick.Reading {
        .init(duration: duration, position: position, goodPoint: goodPoint,
              showsImage: showsImage, seeksToStart: seeksToStart, running: running,
              hasAudioTracks: tracks)
    }

    private func tick(_ state: inout PlaybackTick.Snapshot,
                      _ m: PlaybackTick.Reading,
                      restoring: Bool = false,
                      atPush: Bool = false,
                      sinceStart: Date = Date(),
                      now: Date = Date()) -> PlaybackTick.WorkItem {
        PlaybackTick.compute(&state, measurement: m, restoring: restoring,
                               atPush: atPush,
                               sinceStart: sinceStart, now: now)
    }

    // MARK: - Jumps

    /// A running title, one minute after opening.
    private func ongoing(at spot: Double) -> (PlaybackTick.Snapshot, Date) {
        var s = PlaybackTick.Snapshot()
        let start = Date().addingTimeInterval(-60)
        _ = tick(&s, measurement(position: spot), sinceStart: start)
        return (s, start)
    }

    @Test("Ein Sprung setzt die Anzeige sofort aufs Ziel")
    func jumpImmediate() {
        var (s, _) = ongoing(at: 300)
        PlaybackTick.jumped(&s, target: PlaybackTick.target(um: 30, state: s))
        #expect(s.position == 330)
    }

    @Test("Solange VLC noch die alte Zeit meldet, bleibt die Anzeige auf dem Ziel")
    func jumpHolds() {
        var (s, start) = ongoing(at: 300)
        let now = Date()
        PlaybackTick.jumped(&s, target: 330, now: now)
        for i in 1...8 {
            _ = tick(&s, measurement(position: 300 + Double(i) * 0.5), sinceStart: start,
                     now: now.addingTimeInterval(Double(i) * 0.5))
            #expect(s.position == 330)
        }
    }

    @Test("VLC kommt an: ab da sofort VLCs Zeit, auch ein Schlüsselbild vor dem Ziel")
    func jumpHandoff() {
        var (s, start) = ongoing(at: 300)
        let now = Date()
        PlaybackTick.jumped(&s, target: 330, now: now)
        _ = tick(&s, measurement(position: 329), sinceStart: start, now: now.addingTimeInterval(0.5))
        #expect(s.position == 329)
        #expect(s.leap == nil)
        _ = tick(&s, measurement(position: 329.5), sinceStart: start, now: now.addingTimeInterval(1))
        #expect(s.position == 329.5)
    }

    @Test("Die Anzeige ist VLCs Zeit: nach Abspielen, nach einem Sprung, nach Pause — nichts hochgerechnet")
    func timeEpisode() {
        var (s, start) = ongoing(at: 100)
        var now = Date()
        func step(_ vlc: Double) -> Double {
            now = now.addingTimeInterval(0.25)
            PlaybackTick.timeAdopt(&s, reported: vlc, atPush: false,
                                           sinceStart: start, now: now)
            return s.position
        }
        // Playing: every report appears as it arrives.
        let play = [100.0, 100.25, 100.5, 100.75, 101, 101.25]
        #expect(play.map(step) == play)
        // Jump forward: the target while VLC still has the old time, then VLC.
        PlaybackTick.jumped(&s, target: 131.25, now: now)
        let postJump = [101.25, 101.25, 130.9, 131.1, 131.35, 131.6].map(step)
        #expect(postJump == [131.25, 131.25, 130.9, 131.1, 131.35, 131.6])
        // Pause: VLC stands still, and so does the display.
        let pause = [131.7, 131.7, 131.7, 131.7].map(step)
        #expect(pause == [131.7, 131.7, 131.7, 131.7])
    }

    @Test("Mehrmals schnell vor: jeder Sprung zählt vom letzten Ziel")
    func jumpSeries() {
        var (s, start) = ongoing(at: 300)
        let now = Date()
        PlaybackTick.jumped(&s, target: PlaybackTick.target(um: 30, state: s), now: now)
        _ = tick(&s, measurement(position: 300.5), sinceStart: start, now: now.addingTimeInterval(0.5))
        PlaybackTick.jumped(&s, target: PlaybackTick.target(um: 30, state: s), now: now)
        #expect(s.position == 360)
    }

    @Test("Überspringen, gleich danach 30 s vor: vom Ziel des Überspringens, ohne Rückfall")
    func jumpPostSkip() {
        var (s, start) = ongoing(at: 60)
        let now = Date()
        PlaybackTick.jumped(&s, target: 551, now: now)
        // VLC still reports the old position, then right away the second jump.
        _ = tick(&s, measurement(position: 60.2), sinceStart: start, now: now.addingTimeInterval(0.25))
        PlaybackTick.jumped(&s, target: PlaybackTick.target(um: 30, state: s),
                                  now: now.addingTimeInterval(0.3))
        #expect(s.position == 581)
        _ = tick(&s, measurement(position: 60.4), sinceStart: start, now: now.addingTimeInterval(0.5))
        #expect(s.position == 581, "nicht zurück auf das Ziel des Überspringens")
        _ = tick(&s, measurement(position: 551.1), sinceStart: start, now: now.addingTimeInterval(0.75))
        #expect(s.position == 581, "auch nicht, wenn VLC dort kurz vorbeikommt")
        _ = tick(&s, measurement(position: 580.6), sinceStart: start, now: now.addingTimeInterval(1))
        #expect(s.position == 580.6)
        #expect(s.leap == nil)
    }

    @Test("Kommt VLC nie an, gilt nach dem Deckel wieder seine Zeit")
    func jumpCap() {
        var (s, start) = ongoing(at: 300)
        let now = Date()
        PlaybackTick.jumped(&s, target: 900, now: now)
        _ = tick(&s, measurement(position: 305), sinceStart: start,
                 now: now.addingTimeInterval(PlaybackTick.jumpCeiling - 0.5))
        #expect(s.position == 900)
        _ = tick(&s, measurement(position: 306), sinceStart: start,
                 now: now.addingTimeInterval(PlaybackTick.jumpCeiling))
        #expect(s.position == 306)
    }

    @Test("Kein Sprung hinter das Ende oder vor den Anfang")
    func jumpLimits() {
        var (s, _) = ongoing(at: 3590)
        PlaybackTick.jumped(&s, target: 3620)
        #expect(s.position == 3600)
        PlaybackTick.jumped(&s, target: -10)
        #expect(s.position == 0)
    }

    @Test("Ein Folgenwechsel vergisst den offenen Sprung")
    func jumpSwitch() {
        var (s, _) = ongoing(at: 300)
        PlaybackTick.jumped(&s, target: 330)
        PlaybackTick.newTitle(&s, startReported: true)
        #expect(s.leap == nil)
    }

    @Test("Solange VLC einstellt, bleibt der Ladeschirm und nichts wird gemeldet")
    func seeksToStart() {
        var s = PlaybackTick.Snapshot()
        let a = tick(&s, measurement(position: 900, seeksToStart: true))
        #expect(!s.firstImagePresent)
        #expect(s.position == 0)
        #expect(!a.startReport)
    }

    @Test("Beim ersten Bild faellt der Ladeschirm, Spuren und Start folgen")
    func firstImage() {
        var s = PlaybackTick.Snapshot()
        let a = tick(&s, measurement(position: 900))
        #expect(a.loadingScreenGone)
        #expect(s.firstImagePresent)
        #expect(a.tracksApply)
        #expect(a.startReport)
    }

    @Test("Start und Spurwechsel geschehen genau einmal")
    func onlyInTimes() {
        var s = PlaybackTick.Snapshot()
        _ = tick(&s, measurement(position: 900))
        let second = tick(&s, measurement(position: 901))
        #expect(!second.startReport)
        #expect(!second.tracksApply)
    }

    @Test("Zwanzig Sekunden ergeben zwei Fortschrittsmeldungen")
    func reportSpacing() {
        var s = PlaybackTick.Snapshot(firstImagePresent: true, tracksSet: true,
                                     startReported: true)
        var messages = 0
        for i in 1...40 where tick(&s, measurement(position: Double(i))).progressReport {
            messages += 1
            _ = i
        }
        #expect(messages == 2)
    }

    @Test("Liegt der Finger am Regler, bleibt die Zeit stehen")
    func atSlider() {
        var s = PlaybackTick.Snapshot(position: 1200, firstImagePresent: true,
                                     tracksSet: true, startReported: true)
        _ = tick(&s, measurement(position: 30), atPush: true)
        #expect(s.position == 1200)
    }

    /// When rebuilding after a network change, VLC's time sits at the end of the file;
    /// the dead stream looks like an ending.
    @Test("Beim Wiederaufbau gilt die letzte gute Stelle")
    func againLayout() {
        var s = PlaybackTick.Snapshot(position: 1200, firstImagePresent: true,
                                     tracksSet: true, startReported: true)
        _ = tick(&s, measurement(position: 3599, goodPoint: 1210), restoring: true)
        #expect(s.position == 1210)
    }

    /// The start jump goes along as a media option; until then VLC reports values of the
    /// stream without the jump.
    @Test("Ein Ruecksprung kurz nach dem Oeffnen ist Aufbauzucken")
    func buildTwitch() {
        var s = PlaybackTick.Snapshot(position: 1200, firstImagePresent: true,
                                     tracksSet: true, startReported: true)
        _ = tick(&s, measurement(position: 3))
        #expect(s.position == 1200)
    }

    // MARK: - Episode switch in the same loop

    /// Without a reset the state treats `startReported` as done, and
    /// the server only hears progress for the next title, without a
    /// session ever having been opened. That is exactly what happened on two
    /// platforms.
    @Test("Meldet die Schleife den Start, wird er nach dem Wechsel neu gemeldet")
    func switchLoopReport() {
        var s = PlaybackTick.Snapshot(position: 1200, firstImagePresent: true,
                                     tracksSet: true, startReported: true,
                                     sinceMessage: 4)
        PlaybackTick.newTitle(&s, startReported: false)
        #expect(s.position == 0)
        // The loading screen comes back.
        #expect(!s.firstImagePresent)
        #expect(!s.tracksSet)
        #expect(s.sinceMessage == 0)
        #expect(tick(&s, measurement(position: 2)).startReport)
    }

    @Test("Meldet der Wechsel selbst, meldet die Schleife nicht noch einmal")
    func switchReportSelf() {
        var s = PlaybackTick.Snapshot(position: 1200, firstImagePresent: true,
                                     tracksSet: true, startReported: true)
        PlaybackTick.newTitle(&s, startReported: true)
        #expect(!tick(&s, measurement(position: 2)).startReport)
    }

    /// Measured in the tvOS simulator: after switching at 75 s,
    /// `Progress 76 s` went out for the new episode. VLC kept the video output and
    /// clock of the old episode, and the tick took both for the new one.
    @Test("Nach dem Wechsel zählt die alte Bildausgabe nicht, die alte Zeit wird nie gemeldet")
    func switchOldClock() {
        var s = PlaybackTick.Snapshot(position: 75, firstImagePresent: true,
                                     tracksSet: true, startReported: true, sinceMessage: 6)
        PlaybackTick.newTitle(&s, startReported: true)
        let sinceStart = Date()
        // VLC: old clock, old video output, no picture yet from the new media.
        let alt = TimeAssumption.imageBelongsMedium(videoOutput: true, shownImages: 0,
                                                    afterChange: true)
        #expect(!alt)
        for _ in 0..<8 {
            let a = tick(&s, measurement(position: 75.4, showsImage: alt), sinceStart: sinceStart)
            #expect(!a.progressReport)
            #expect(!a.loadingScreenGone)
        }
        #expect(s.position == 0)
        // First frame of the new episode: its time counts immediately.
        let new = TimeAssumption.imageBelongsMedium(videoOutput: true, shownImages: 3,
                                                    afterChange: true)
        _ = tick(&s, measurement(position: 2, showsImage: new), sinceStart: sinceStart)
        #expect(s.position == 2)
    }

    /// Measured: with the first frame of the new episode VLC reported
    /// 6130 s, and the real time a few seconds later.
    @Test("Nach dem Wechsel gilt keine Zeit, die noch nicht gespielt sein kann")
    func switchNonsenseTime() {
        var s = PlaybackTick.Snapshot(position: 75, firstImagePresent: true,
                                     tracksSet: true, startReported: true)
        PlaybackTick.newTitle(&s, startReported: true)
        let sinceStart = Date().addingTimeInterval(-2)
        let a = tick(&s, measurement(position: 6130), sinceStart: sinceStart)
        #expect(s.position == 0)
        #expect(a.progressReport)   // report tracks again, with 0, not 6130
        _ = tick(&s, measurement(position: 76), sinceStart: sinceStart)
        #expect(s.position == 0)
        _ = tick(&s, measurement(position: 2.5), sinceStart: sinceStart)
        #expect(s.position == 2.5)
        // Once arrived, every jump counts again.
        _ = tick(&s, measurement(position: 900), sinceStart: sinceStart)
        #expect(s.position == 900)
    }

    @Test("Beim Öffnen an späterer Stelle gilt die Wechselsperre nicht")
    func openWithoutSwitchLock() {
        var s = PlaybackTick.Snapshot(position: 1200)
        _ = tick(&s, measurement(position: 1201))
        #expect(s.position == 1201)
    }

    @Test("Beim ersten Öffnen gilt die Bildausgabe ohne gezähltes Bild")
    func firstOpenImageOutput() {
        #expect(TimeAssumption.imageBelongsMedium(videoOutput: true, shownImages: 0,
                                                 afterChange: false))
        #expect(!TimeAssumption.imageBelongsMedium(videoOutput: false, shownImages: 9,
                                                  afterChange: true))
    }

    /// The start on switching goes out before the track choice, without indices.
    /// The first report after that carries them, and comes right away.
    @Test("Nach dem Wechsel meldet der Takt die Spuren sofort, nicht erst nach zehn Sekunden")
    func switchTracksImmediate() {
        var s = PlaybackTick.Snapshot(position: 75, firstImagePresent: true,
                                     tracksSet: true, startReported: true)
        PlaybackTick.newTitle(&s, startReported: true)
        let a = tick(&s, measurement(position: 1))
        #expect(a.tracksApply)
        #expect(a.progressReport)
        #expect(!a.startReport)
        // After that, at the usual interval again.
        let b = tick(&s, measurement(position: 1.5))
        #expect(!b.progressReport)
    }

    @Test("Beim Öffnen trägt der Start die Spuren, kein Fortschritt hinterher")
    func openNoExtraProgress() {
        var s = PlaybackTick.Snapshot()
        let a = tick(&s, measurement(position: 1))
        #expect(a.startReport)
        #expect(!a.progressReport)
        #expect(!tick(&s, measurement(position: 1.5)).progressReport)
    }
}

/// When the loading screen may give way.
///
/// The deadlines are the core: too short, and you watch VLC settling in;
/// too long, and a stuck setup stays covered forever.
@Suite("Zeitannahme")
struct TimeAssumptionTests {

    private func forward(_ seconds: TimeInterval) -> Date {
        Date().addingTimeInterval(-seconds)
    }

    @Test("Steht das Bild und wird nicht eingesteuert, weicht der Ladeschirm sofort")
    func imagePresent() {
        #expect(TimeAssumption.imagePresent(showsImage: true, seeksToStart: false, sinceStart: forward(1)))
    }

    @Test("Ohne Bild bleibt er, bis die Notbremse greift")
    func emergencyBrake() {
        #expect(!TimeAssumption.imagePresent(showsImage: false, seeksToStart: false, sinceStart: forward(5)))
        #expect(TimeAssumption.imagePresent(showsImage: false, seeksToStart: false, sinceStart: forward(13)))
    }

    /// The TV case: with large files settling in takes
    /// longer than twelve seconds. If the loading screen gave way there, you saw the film
    /// start at second zero until the jump landed.
    @Test("Waehrend des Einsteuerns greift die Notbremse nicht")
    func settleOutlastsEmergencyBrake() {
        #expect(!TimeAssumption.imagePresent(showsImage: true, seeksToStart: true, sinceStart: forward(15)))
    }

    /// VLC gives up on settling in by itself after twenty seconds; the deadline
    /// lies behind that, but catches the case that this gets stuck too.
    @Test("Irgendwann weicht er auch beim Einsteuern")
    func settleHasEnd() {
        #expect(TimeAssumption.imagePresent(showsImage: true, seeksToStart: true, sinceStart: forward(30)))
    }

    @Test("Ein Ruecksprung kurz nach dem Oeffnen wird verworfen, spaeter nicht")
    func jumpBack() {
        #expect(TimeAssumption.position(reported: 5, untilFrom: 1200, sinceStart: forward(2)) == nil)
        #expect(TimeAssumption.position(reported: 5, untilFrom: 1200, sinceStart: forward(20)) == 5)
    }
}

@Suite("Folgenende")
struct EpisodesEndTests {

    @Test("Der Knopf erscheint gegen Ende, aber nicht in der Mitte")
    func button() {
        #expect(EpisodeEnd.buttonShow(position: 3500, duration: 3600))
        #expect(!EpisodeEnd.buttonShow(position: 1800, duration: 3600))
    }

    /// Otherwise it would practically always be on screen during an intro
    /// or a short extra.
    @Test("Bei kurzen Titeln erscheint er nie")
    func short() {
        #expect(!EpisodeEnd.buttonShow(position: 200, duration: 240))
    }

    /// The offer is generous, the action is not: this acts without
    /// anyone having asked for it.
    @Test("Weitergeschaltet wird erst am Ende, nicht schon beim Angebot")
    func advance() {
        #expect(!EpisodeEnd.advance(position: 3500, duration: 3600, sinceOpen: 600))
        #expect(EpisodeEnd.advance(position: 3599.5, duration: 3600, sinceOpen: 600))

        // **The case with `:start-time`.** VLC reports the position
        // immediately, but not yet the length in the same milliseconds.
        // Without a settling period the app moved on 629 ms after opening.
        #expect(!EpisodeEnd.advance(position: 3721, duration: 3721, sinceOpen: 0.6))
        #expect(EpisodeEnd.advance(position: 3721, duration: 3721, sinceOpen: 6))
    }
}

@Suite("Wiedergabestufen")
struct PlaybackLevelsTests {

    @Test("Die Stufen stehen fest und beginnen unter dem Normaltempo")
    func levels() {
        #expect(SpeedLevels.values == [0.75, 1.0, 1.25, 1.5, 2.0])
        #expect(SleepTimes.values == [15, 30, 45, 60, 90])
    }

    /// This used to use `String(format: "%g", …)` with a hard-coded
    /// replacement of the decimal point. In English that read as "1,25×".
    @Test("Normaltempo heisst 1x, nicht 1,0x")
    func wholeNumber() {
        #expect(SpeedLevels.label(1.0) == "1×")
        #expect(SpeedLevels.label(2.0) == "2×")
    }

    @Test("Das Trennzeichen folgt der Sprache")
    func separatorCharacter() {
        let text = SpeedLevels.label(1.25)
        #expect(text.hasSuffix("×"))
        #expect(text.contains("125") == false)
        #expect(text.dropLast().contains(",") || text.dropLast().contains("."))
    }
}

@Suite("Spielzeit")
struct PlayTimeTests {

    @Test("Unter einer Stunde ohne Stundenteil")
    func short() {
        #expect(PlayTime.text(0) == "0:00")
        #expect(PlayTime.text(65) == "1:05")
        #expect(PlayTime.text(3599) == "59:59")
    }

    @Test("Ab einer Stunde mit Stundenteil")
    func long() {
        #expect(PlayTime.text(3600) == "1:00:00")
        #expect(PlayTime.text(5025) == "1:23:45")
    }

    /// VLC also reports nonsense now and then during setup.
    @Test("Unsinn ergibt null, keinen Absturz")
    func unsinn() {
        #expect(PlayTime.text(-5) == "0:00")
        #expect(PlayTime.text(.nan) == "0:00")
        #expect(PlayTime.text(.infinity) == "0:00")
    }
}
