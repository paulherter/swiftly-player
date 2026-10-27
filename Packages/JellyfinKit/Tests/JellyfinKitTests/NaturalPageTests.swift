import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JellyfinKit

/// **A page of the natural list, fetched by ID.**
///
/// A jump in the letter strip asks for hundreds of titles; in one query their IDs made an
/// address the server refused, and the jump stopped short. The page must arrive in
/// batches and in the list's order, whatever order the server answers in.
@Suite("Seite der natürlichen Liste", .serialized)
struct NaturalPageTests {

    /// Answers every request with the titles it asked for, **in reverse order**, and counts
    /// the requests and their IDs.
    final class Spy: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var idsPerRequest: [Int] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }

        override func startLoading() {
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let ids = parts?.queryItems?.first { $0.name == "Ids" }?.value?
                .split(separator: ",").map(String.init) ?? []
            Self.lock.lock(); Self.idsPerRequest.append(ids.count); Self.lock.unlock()
            let items = ids.reversed().map { #"{"Id":"\#($0)","Name":"\#($0)","Type":"Movie"}"# }
            let body = Data(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":\#(ids.count)}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func spyClient() async -> JellyfinClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Spy.self]
        let c = JellyfinClient(baseURL: URL(string: "https://tv.example.de")!,
                               deviceID: "dev-42", deviceName: "Prüfgerät",
                               urlSession: URLSession(configuration: config))
        await c.setSession(Session(accessToken: "tok", userID: "u1",
                                   userName: "Testnutzer",
                                   serverURL: URL(string: "https://tv.example.de")!))
        return c
    }

    @Test("Viele Titel in Paketen zu höchstens 100 IDs, in der Reihenfolge der Liste")
    func batches() async throws {
        Spy.idsPerRequest = []
        let list = (0..<250).map { Item(id: "t\($0)", name: "Titel \($0)") }
        let page = try await (await spyClient()).naturalPage(list, since: 0, count: 250)
        #expect(Spy.idsPerRequest.sorted() == [50, 100, 100])
        #expect(page.items.map(\.id) == list.map(\.id))
        #expect(page.totalRecordCount == 250)
    }

    @Test("Ab einer Stelle: nur der Ausschnitt, und eine leere Seite ohne Anfrage")
    func slice() async throws {
        Spy.idsPerRequest = []
        let list = (0..<30).map { Item(id: "t\($0)", name: "Titel \($0)") }
        let client = await spyClient()
        let page = try await client.naturalPage(list, since: 20, count: 60)
        #expect(page.items.map(\.id) == (20..<30).map { "t\($0)" })
        let empty = try await client.naturalPage(list, since: 30, count: 60)
        #expect(empty.items.isEmpty)
        #expect(Spy.idsPerRequest == [10])
    }
}
