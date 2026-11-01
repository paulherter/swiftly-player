import Foundation
import Testing
@testable import JellyfinKit

/// The server answers on UDP 7359 with its ID, name and address; the page shows
/// each server once and not the one already offered elsewhere.
@Suite struct ServerDiscoveryTests {

    private func server(_ id: String, _ name: String, _ address: String) -> FoundServer {
        FoundServer(id: id, name: name, address: address)
    }

    @Test func answerOfJellyfinIsRead() throws {
        let answer = #"{"Address":"http://192.168.1.5:8096","Id":"a1b2","Name":"Wohnzimmer","EndpointAddress":null}"#
        let found = try #require(ServerDiscovery.read(Data(answer.utf8)))
        #expect(found == server("a1b2", "Wohnzimmer", "http://192.168.1.5:8096"))
    }

    @Test(arguments: [
        "who is JellyfinServer?",
        #"{"Address":"","Id":"a1b2","Name":"x"}"#,
        #"{"Address":"http://192.168.1.5:8096","Id":"","Name":"x"}"#,
        #"{"Name":"x"}"#,
    ])
    func otherAnswersAreIgnored(_ text: String) {
        #expect(ServerDiscovery.read(Data(text.utf8)) == nil)
    }

    @Test func eachServerOnceSortedByName() {
        let first = [server("2", "Wohnzimmer", "http://192.168.1.5:8096")]
        let next = [server("1", "Büro", "http://10.0.0.2:8096"),
                    server("2", "Wohnzimmer", "http://192.168.1.6:8096")]
        let all = ServerDiscovery.merged(first, next)
        #expect(all.map(\.id) == ["1", "2"])
        // The newer answer wins: the server may have a new address.
        #expect(all[1].address == "http://192.168.1.6:8096")
    }

    @Test func serverAlreadyOfferedIsHidden() {
        let found = [server("1", "Büro", "http://10.0.0.2:8096"),
                     server("2", "Wohnzimmer", "http://192.168.1.5:8096/")]
        let shown = ServerDiscovery.shown(found, except: ["192.168.1.5:8096", nil])
        #expect(shown.map(\.id) == ["1"])
    }

    @Test func otherPortIsAnotherServer() {
        let found = [server("1", "Test", "http://192.168.1.5:8097")]
        #expect(ServerDiscovery.shown(found, except: ["192.168.1.5:8096"]).count == 1)
    }

    @Test func shortAddressWithoutScheme() {
        #expect(server("1", "x", "http://192.168.1.5:8096/").shortAddress == "192.168.1.5:8096")
        #expect(server("1", "x", "https://media.home.arpa").shortAddress == "media.home.arpa")
    }

    @Test func broadcastAddressOfInterface() {
        // 192.168.1.23/24 → 192.168.1.255
        #expect(ServerDiscovery.broadcast(address: 0xC0A8_0117, netmask: 0xFFFF_FF00) == 0xC0A8_01FF)
        // 10.1.2.3/22 → 10.1.3.255
        #expect(ServerDiscovery.broadcast(address: 0x0A01_0203, netmask: 0xFFFF_FC00) == 0x0A01_03FF)
    }
}
