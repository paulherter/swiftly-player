import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// What's-new decision, version compare, the sheet's texts and the network error wording: the old Swift code
/// of JellyfinKit (`WhatsNew`, `WhatsNewEntry`, `readableError`) is the oracle for the core exports the Apple
/// app now uses. Literals at the end keep the proof when the old code is gone.
struct WhatsNewErrorTextParityTests {
    private static func json(items: Int, draft: Bool = false, gift: Bool = false) -> Data {
        let lines = (1...max(items, 1)).prefix(items).map {
            #"{"symbol":"star","title":{"en":"T\#($0)","de":"Titel\#($0)"},"detail":{"en":"D\#($0)","de":"Detail\#($0)"}}"#
        }.joined(separator: ",")
        let module = gift ? #","module":{"type":"gift","lookId":"halloween"}"# : ""
        let primary = gift ? #"{"label":"grab","action":"applyLook:halloween"}"# : #"{"label":"continue","action":"dismiss"}"#
        return Data(#"{"version":"1.2.0","variant":"standard","title":{"en":"News","de":"Neuigkeiten"},"items":[\#(lines)]\#(module),"primary":\#(primary),"draft":\#(draft)}"#.utf8)
    }

    private static func name(_ action: WhatsNewAction) -> String {
        switch action {
        case .markSeen: "markSeen"
        case .show: "show"
        case .nothing: "nothing"
        }
    }

    private static func name(_ d: WhatsNew.Decision) -> String {
        switch d {
        case .markSeen: "markSeen"
        case .show: "show"
        case .nothing: "nothing"
        }
    }

    @Test func decisionIsEqualOnTheWholeGrid() {
        let files: [Data?] = [nil, Self.json(items: 3), Self.json(items: 5, gift: true), Self.json(items: 2),
                              Self.json(items: 6), Self.json(items: 4, draft: true), Data("not json".utf8)]
        let seen: [String?] = [nil, "1.0.7", "1.2.0", "1.10.0", "1.9.9", "", "x"]
        let currents = ["1.2.0", "1.2.1", "1.10.0", "1.0.8", "2"]
        var count = 0
        for file in files {
            let hasEntry = file.map { WhatsNewEntry.decoded(from: $0) != nil } ?? false
            for last in seen {
                for used in [true, false] {
                    for current in currents {
                        let old = WhatsNew.decide(lastSeen: last, usedBefore: used, current: current, hasEntry: hasEntry)
                        let new = whatsNewDecide(lastSeen: last, usedBefore: used, current: current, entryJson: file)
                        #expect(Self.name(old) == Self.name(new), "last \(last ?? "nil") used \(used) now \(current) entry \(hasEntry)")
                        count += 1
                    }
                }
            }
        }
        #expect(count == 7 * 7 * 2 * 5)
    }

    @Test func versionCompareIsEqual() {
        let versions = ["1.0.9", "1.0.10", "1.0", "1.0.0", "2", "1.2.3.4", "1.x", "", "10.0", "1.10"]
        for a in versions {
            for b in versions {
                #expect(WhatsNew.isNewer(a, than: b) == versionIsNewer(version: a, than: b), "\(a) vs \(b)")
            }
        }
    }

    @Test func sheetTextsAreEqualToTheOldEntry() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("JellyfinKit/Sources/JellyfinKit/Resources/whatsnew")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        #expect(!names.isEmpty)
        var files = names.map { try! Data(contentsOf: folder.appendingPathComponent($0)) }
        files.append(Self.json(items: 3))
        files.append(Self.json(items: 5, gift: true))
        files.append(Self.json(items: 2))
        files.append(Self.json(items: 4, draft: true))
        for data in files {
            let old = WhatsNewEntry.decoded(from: data)
            for language in ["de", "de-DE", "en", "ru", "fr"] {
                let new = whatsNewSheet(entryJson: data, language: language)
                #expect((old == nil) == (new == nil))
                guard let old, let new else { continue }
                #expect(new.version == old.version)
                #expect(new.title == old.title.localized(language))
                #expect(new.lines.count == old.items.count)
                for (line, item) in zip(new.lines, old.items) {
                    #expect(line.symbol == item.symbol)
                    #expect(line.title == item.title.localized(language))
                    #expect(line.detail == item.detail?.localized(language))
                }
                #expect(new.primaryLabel == old.primary.label)
                #expect(new.primaryAction == old.primary.action)
                #expect(new.giftLookId == (old.module?.type == "gift" ? old.module?.lookId : nil))
            }
        }
    }

    /// The language the old `translated(...)` resolves for this process.
    private static var oldLanguage: String {
        Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
    }

    private static let codes: [Int] = [
        -1, -999, -1000, -1001, -1002, -1003, -1004, -1005, -1006, -1008, -1009, -1011, -1012, -1017, -1018, -1020,
        -1100, -1200, -1201, -1202, -1203, -1204, -1205, -1206, -2000, -3001, 0, 42,
    ]

    @Test func networkWordingIsEqualToReadableError() {
        let language = Self.oldLanguage
        let texts = ["", "A server with the specified hostname could not be found.", "The operation couldn’t be completed.",
                     "SSL certificate problem: self signed certificate", "SSL: no alternative certificate subject name matches target hostname",
                     "certificate has expired", "TLS handshake failed", "The request timed out."]
        for code in Self.codes {
            for text in texts {
                let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: text])
                let old = readableError(error)
                let new = readableNetworkErrorSystem(locale: language, code: Int32(code), description: text)
                #expect(old == new, "code \(code) text '\(text)' old '\(old)' core '\(new)'")
            }
            // Certificate codes never arrive as `.network` (`JellyfinError.init(petition:)` makes `.certificate`
            // of them first), so the old and the core path are only compared for the others.
            if (-1206 ... -1200).contains(code) { continue }
            // `JellyfinError.network(code:)` hands the system text of `URLError(code)` to the same words.
            let old = readableError(JellyfinError.network(code: code))
            let new = readableNetworkErrorSystem(
                locale: language, code: Int32(code), description: URLError(URLError.Code(rawValue: code)).localizedDescription)
            #expect(old == new, "network(\(code)) old '\(old)' core '\(new)'")
        }
    }

    @Test func germanWordingLiterals() {
        func de(_ code: Int32, _ text: String = "x") -> String { readableNetworkErrorSystem(locale: "de", code: code, description: text) }
        #expect(de(-1009) == "Keine Verbindung.")
        #expect(de(-1001) == "Der Server hat nicht geantwortet.")
        #expect(de(-1003) == "Unter dieser Adresse ist kein Server erreichbar.")
        #expect(de(-1004) == "Unter dieser Adresse ist kein Server erreichbar.")
        #expect(de(-1005) == "Die Verbindung zum Server ist abgebrochen.")
        #expect(de(-1202) == "Dem Zertifikat des Servers wird nicht vertraut.")
        #expect(de(-1201) == "Das Zertifikat des Servers ist abgelaufen.")
        #expect(de(-1200) == "Die verschlüsselte Verbindung kam nicht zustande.")
        #expect(de(-1, "SSL certificate problem: self signed certificate") == "Dem Zertifikat des Servers wird nicht vertraut.")
        #expect(de(-1011, "Bad response") == "Bad response")
        #expect(readableNetworkError(locale: "de", code: -1011, description: "Bad response") == "Die Verbindung zum Server hat nicht geklappt.")
    }
}
