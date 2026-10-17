import Foundation
import Testing
@testable import JellyfinKit

@Suite struct EpisodesCardTests {
    @Test func springIsCriticallyDamped() {
        let f = EpisodeCard.spring(10)
        #expect(f.stiffness == 100 && f.damping == 20)
        #expect(EpisodeCard.springTravel(0, omega: 10) == 0)
        // For the swap the card covers almost the whole image.
        #expect(EpisodeCard.springTravel(EpisodeCard.swap, omega: EpisodeCard.zoomOmega) > 0.98)
        // No overshoot.
        #expect(EpisodeCard.springTravel(3, omega: 10) <= 1)
    }

    @Test func fadeWaitsSwap() {
        #expect(EpisodeCard.fadeOff(imageSince: 0.2) == EpisodeCard.swap)
        #expect(EpisodeCard.fadeOff(imageSince: 1.5) == 1.5)
    }

    @Test func frameGoesFromCardImage() {
        let k = (x: 548.0, y: 171.0, b: 240.0, h: 135.0)
        let a = EpisodeCard.frameRect(card: k, whole: (844, 390), zoom: 0)
        #expect(a.x == 548 && a.b == 240)
        let e = EpisodeCard.frameRect(card: k, whole: (844, 390), zoom: 1)
        #expect(e.x == 0 && e.y == 0 && e.b == 844 && e.h == 390)
    }

    @Test func noCreditsInLastThirtySeconds() {
        let broad = SectionLogic.cardDue(position: 1400, duration: 1500, sections: [],
                                                hasNextEpisode: true, remainingWindow: 30)
        let near = SectionLogic.cardDue(position: 1471, duration: 1500, sections: [],
                                               hasNextEpisode: true, remainingWindow: 30)
        #expect(!broad && near)
        // Without a window the old behavior stays.
        #expect(!SectionLogic.cardDue(position: 1471, duration: 1500, sections: [],
                                              hasNextEpisode: true))
        // The countdown then runs to the end, not seven seconds.
        #expect(SectionLogic.countdown(position: 1471, duration: 1500, sections: [],
                                          remainingWindow: 30) == 29)
        let credits = Segment(art: .credits, from: 1320, until: 1500)
        #expect(SectionLogic.countdown(position: 1400, duration: 1500, sections: [credits],
                                          remainingWindow: 30) == 7)
    }

    @Test func withCreditsAppliesCredits() {
        let credits = Segment(art: .credits, from: 1320, until: 1500)
        #expect(SectionLogic.cardDue(position: 1320, duration: 1500, sections: [credits],
                                             hasNextEpisode: true, remainingWindow: 30))
        let withScene = Segment(art: .credits, from: 1300, until: 1380)
        #expect(!SectionLogic.cardDue(position: 1480, duration: 1500, sections: [withScene],
                                              hasNextEpisode: true, remainingWindow: 30))
    }
}

@Suite struct CardControlsTests {
    private func layer() -> OfferingLayer {
        var e = OfferingLayer()
        e.cardWaitsControls = true
        return e
    }

    @Test func controlsCoveredAndHoldsAn() {
        var e = layer()
        _ = e.tick(offering: .nextEpisode, cardDue: true, running: true, elapsed: 2)
        e.controls(opened: true)
        #expect(e.display == .nothing)
        // While open nothing advances, not even past the length.
        let jumped = e.tick(offering: .nextEpisode, cardDue: true, running: true, elapsed: 60)
        #expect(!jumped && e.nextAtEnd)
        e.controls(opened: false)
        guard case let .card(share) = e.display else { Issue.record("keine Karte"); return }
        #expect(abs(share - 2 / OfferingLayer.countdown) < 0.001)
    }

    @Test func cancelSaysNextOff() {
        var e = layer()
        _ = e.tick(offering: .nextEpisode, cardDue: true, running: true, elapsed: 1)
        let toward = e.close()
        #expect(toward)
        #expect(e.display == .nothing && !e.nextAtEnd && !e.cardCounts)
    }

    @Test func withoutToggleHowUntilFrom() {
        var e = OfferingLayer()
        _ = e.tick(offering: .nextEpisode, cardDue: true, running: true, elapsed: 1)
        e.controls(opened: true)
        #expect(e.display == .nothing && !e.nextAtEnd)
    }
}

/// Seeking all the way to the end goes straight to the next episode.
@Suite struct JumpEndTests {
    @Test func endDoesNotSwitchPastCountdown() {
        var e = OfferingLayer()
        e.cardWaitsControls = true
        _ = e.tick(offering: .nextEpisode, cardDue: true, running: true, elapsed: 0)
        #expect(e.cardCounts)
        #expect(!EpisodeEnd.advance(position: 1500, duration: 1500, sinceOpen: 600,
                                           cardCounts: e.cardCounts))
        // Without a card (cancelled or none) as before.
        #expect(EpisodeEnd.advance(position: 1500, duration: 1500, sinceOpen: 600))
    }

    @Test func atEndCountsCountdownNext() {
        var e = OfferingLayer()
        _ = e.tick(offering: .nextEpisode, cardDue: true, running: false, elapsed: 0)
        var done = false
        for _ in 0..<40 where !done {
            done = e.tick(offering: .nextEpisode, cardDue: true, running: false,
                            elapsed: 0.5, atEnd: true)
        }
        #expect(done)
    }

    @Test func jumpSetsCountdownBack() {
        var e = OfferingLayer()
        _ = e.tick(offering: .nextEpisode, cardDue: true, running: true, elapsed: 5)
        e.jumped()
        guard case let .card(share) = e.display else { Issue.record("keine Karte"); return }
        #expect(share == 0)
    }

    @Test func atEndLimit() {
        #expect(EpisodeEnd.atEnd(position: 1499, duration: 1500))
        #expect(!EpisodeEnd.atEnd(position: 1498, duration: 1500))
    }
}

@Suite struct CardsStatusTests {
    @Test func narrowPhonesGetSmallerCard() {
        #expect(EpisodeCard.width(EpisodeCard.iPhone, safeWidth: 667, large: false) == 200.1)
        #expect(EpisodeCard.width(EpisodeCard.iPhone, safeWidth: 814, large: false) == 240)
        #expect(EpisodeCard.width(EpisodeCard.iPhone, safeWidth: 1366, large: true) == 300)
    }

    @Test func swipe() {
        #expect(EpisodeCard.dragged(-100, 50) == (-20, 50))
        #expect(EpisodeCard.swipedAway(x: 80, y: 0, momentumX: 80, momentumY: 0))
        #expect(EpisodeCard.swipedAway(x: 30, y: 0, momentumX: 200, momentumY: 0))
        #expect(!EpisodeCard.swipedAway(x: 30, y: 20, momentumX: 60, momentumY: 40))
    }

    /// Without a first frame the card gives way to the loading screen, which
    /// holds the close button. With a frame it fades out as usual.
    @Test func cardSoftWithoutImage() {
        #expect(!EpisodeCard.yields(since: EpisodeCard.swap, imageSince: nil))
        #expect(!EpisodeCard.yields(since: EpisodeCard.atMostCovers - 0.1, imageSince: nil))
        #expect(EpisodeCard.yields(since: EpisodeCard.atMostCovers, imageSince: nil))
        #expect(!EpisodeCard.yields(since: 30, imageSince: 1.2))
        #expect(EpisodeCard.atMostCovers > EpisodeCard.swap + EpisodeCard.imageFade)
    }
}
