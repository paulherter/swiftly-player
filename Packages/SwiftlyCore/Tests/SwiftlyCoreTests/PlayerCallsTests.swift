import Testing

@testable import SwiftlyCore

/// The host's fold of the core's effects: every effect lands in exactly one place, the newest wins, nothing is lost.
@Suite struct PlayerCallsTests {
    @Test func noEffectsIsAnEmptyCall() {
        #expect(PlayerCalls([]).isEmpty)
        #expect(PlayerCalls().isEmpty)
    }

    @Test func everyEffectHasItsPlace() {
        let calls = PlayerCalls([
            .startEpisode(id: "ep2", fromCard: true, since: 0),
            .qualityChosen(directPlay: false, limit: 8),
            .forgetPrepared,
            .close,
            .prepareNext(id: "ep3"),
            .nudge(rating: true),
            .handOver(subtitle: 4, reason: "dts"),
            .streamRebuilt(position: 12.5, paused: true, reason: "stall"),
        ])
        #expect(calls.switchTo?.id == "ep2" && calls.switchTo?.fromCard == true && calls.switchTo?.since == 0)
        #expect(calls.quality?.directPlay == false && calls.quality?.limit == 8)
        #expect(calls.forgetPrepared && calls.close)
        #expect(calls.prepareNext == "ep3" && calls.nudge == true)
        #expect(calls.handOver?.subtitle == 4 && calls.handOver?.reason == "dts")
        #expect(calls.streamRebuilt?.position == 12.5 && calls.streamRebuilt?.paused == true)
        #expect(!calls.isEmpty)
    }

    @Test func theNewestOfTheSameKindWins() {
        let calls = PlayerCalls([
            .startEpisode(id: "a", fromCard: false, since: 1),
            .startEpisode(id: "b", fromCard: true, since: 2),
            .nudge(rating: true), .nudge(rating: false),
        ])
        #expect(calls.switchTo?.id == "b" && calls.switchTo?.since == 2)
        #expect(calls.nudge == false)
    }

    @Test func aSubtitleOnATranscodeIsAReloadOfTheRunningTitleWithTheTrack() {
        let calls = PlayerCalls([.reloadForSubtitle(id: "ep1", subtitle: 4, since: 601.5)])
        #expect(calls.switchTo?.id == "ep1" && calls.switchTo?.since == 601.5 && calls.switchTo?.fromCard == false)
        #expect(calls.reloadSubtitle == 4)
        #expect(calls.quality == nil && !calls.isEmpty)
        // Off is a track choice too: a burned track has to leave the picture.
        #expect(PlayerCalls([.reloadForSubtitle(id: "ep1", subtitle: -1, since: 0)]).reloadSubtitle == -1)
        // A plain episode switch carries no subtitle.
        #expect(PlayerCalls([.startEpisode(id: "ep2", fromCard: true, since: 0)]).reloadSubtitle == nil)
    }

    @Test func aQualityReloadIsTheSameIdAsTheRunningTitle() {
        let calls = PlayerCalls([.qualityChosen(directPlay: true, limit: 0), .forgetPrepared,
                                 .startEpisode(id: "ep1", fromCard: false, since: 601)])
        #expect(calls.switchTo?.id == "ep1" && calls.quality?.directPlay == true && calls.forgetPrepared)
        #expect(calls.close == false && calls.prepareNext == nil)
    }
}
