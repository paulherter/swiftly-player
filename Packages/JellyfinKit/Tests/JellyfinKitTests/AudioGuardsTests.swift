import Foundation
import Testing
@testable import JellyfinKit

@Suite("Tonwacht")
struct AudioGuardsTests {

    @Test("Echter Gerätewechsel im Betrieb baut neu auf")
    func normal() {
        #expect(AudioWatch.outputNewBuildUp(realDeviceSwitch: true,
                                            playsNow: true, sinceTakeover: 30))
    }

    @Test("Im Anlauf nicht — daran ist der Apple TV gestorben")
    func rampUp() {
        #expect(!AudioWatch.outputNewBuildUp(realDeviceSwitch: true,
                                             playsNow: true, sinceTakeover: 4.9))
        #expect(AudioWatch.outputNewBuildUp(realDeviceSwitch: true,
                                            playsNow: true, sinceTakeover: 5.1))
    }

    @Test("Was kein Gerätewechsel ist, zählt nicht")
    func noSwitch() {
        // `categoryChange` and `routeConfigurationChange` fire when the
        // app sets up its own audio session.
        #expect(!AudioWatch.outputNewBuildUp(realDeviceSwitch: false,
                                             playsNow: true, sinceTakeover: 30))
    }

    @Test("Ein angehaltener Player braucht keinen neuen Ausgang")
    func halted() {
        #expect(!AudioWatch.outputNewBuildUp(realDeviceSwitch: true,
                                             playsNow: false, sinceTakeover: 30))
    }
}
