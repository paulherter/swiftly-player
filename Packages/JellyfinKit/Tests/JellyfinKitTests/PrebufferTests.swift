import Foundation
import Testing
@testable import JellyfinKit

@Suite struct PrebufferTests {
    @Test func firstAgainstEnd() {
        #expect(!Prebuffer.now(position: 1000, duration: 2600, creditsFrom: nil, networkFavorable: true))
        #expect(Prebuffer.now(position: 2600 - Prebuffer.secondsLeft, duration: 2600,
                                creditsFrom: nil, networkFavorable: true))
    }

    @Test func offCredits() {
        #expect(Prebuffer.now(position: 2300, duration: 2600, creditsFrom: 2290, networkFavorable: true))
        #expect(!Prebuffer.now(position: 2280, duration: 2600, creditsFrom: 2290, networkFavorable: true))
    }

    @Test func notOverExpensiveNetwork() {
        #expect(!Prebuffer.now(position: 2550, duration: 2600, creditsFrom: nil, networkFavorable: false))
    }

    @Test func notShortTitles() {
        #expect(!Prebuffer.now(position: 200, duration: 240, creditsFrom: nil, networkFavorable: true))
        #expect(!Prebuffer.now(position: .nan, duration: 2600, creditsFrom: nil, networkFavorable: true))
    }

    @Test func planExpires() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(Prebuffer.freshValue(prepared: t, now: t.addingTimeInterval(60)))
        #expect(!Prebuffer.freshValue(prepared: t, now: t.addingTimeInterval(Prebuffer.lifetime)))
    }

    @Test func startOnlyDirectPlayOverNetwork() {
        let network = URL(string: "https://server.example/Videos/1/stream.mkv?static=true")!
        #expect(Prebuffer.startLoad(address: network, method: .directPlay))
        #expect(!Prebuffer.startLoad(address: network, method: .transcode))
        #expect(!Prebuffer.startLoad(address: URL(fileURLWithPath: "/tmp/a.mkv"), method: .directPlay))
    }
}
