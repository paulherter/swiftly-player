import Foundation
import Testing

@testable import SwiftlyCore

@Suite struct AirPlayCheckTests {
    private func source(video: String, audio: String, channels: Int = 2) -> String {
        """
        {"Id":"q1","Container":"mkv","MediaStreams":[
        {"Type":"Video","Codec":"\(video)","Index":0},
        {"Type":"Audio","Codec":"\(audio)","Index":1,"Channels":\(channels),"IsDefault":true}]}
        """
    }

    @Test func h264WithAacGoesOverAirPlayOnTheAudioTrack() {
        let v = AirPlayCheck.verdict(sourceJson: source(video: "h264", audio: "aac"))
        #expect(v?.fitting == true)
        #expect(v?.audioTrack == 1)
        #expect(v?.obstacles.isEmpty == true)
    }

    @Test func dtsNamesTheAudioObstacle() throws {
        let v = try #require(AirPlayCheck.verdict(sourceJson: source(video: "h264", audio: "dts", channels: 6)))
        #expect(!v.fitting)
        #expect(v.audioTrack == nil)
        #expect(v.obstacles.first?.kind == .audio)
        #expect(v.obstacles.first?.codecShown == "DTS")
    }

    @Test func noSourceNoVerdictAndRemuxRefusalOnlyForARawMatroskaPlan() {
        #expect(AirPlayCheck.verdict(sourceJson: "nonsense") == nil)
        #expect(AirPlayCheck.remuxRefusal(directPlay: false, hasTranscodingUrl: true, container: "mkv") == nil)
        #expect(AirPlayCheck.remuxRefusal(directPlay: false, hasTranscodingUrl: false, container: "mkv")?.fitting == false)
    }
}
