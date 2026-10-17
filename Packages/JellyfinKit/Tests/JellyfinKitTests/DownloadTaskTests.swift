import Testing
@testable import JellyfinKit

@Suite struct DownloadTaskTests {
    @Test func toAndBack() {
        let text = DownloadTask.description(id: "abc", generation: 42, file: "abc.mkv")
        #expect(DownloadTask.dismantle(text)
                == .init(id: "abc", generation: 42, file: "abc.mkv"))
    }

    @Test func oldFormGetsNull() {
        #expect(DownloadTask.dismantle("abc\u{1F}abc.mp4")
                == .init(id: "abc", generation: 0, file: "abc.mp4"))
    }

    @Test func unusable() {
        #expect(DownloadTask.dismantle(nil) == nil)
        #expect(DownloadTask.dismantle("nur-ein-teil") == nil)
        #expect(DownloadTask.dismantle("\u{1F}datei") == nil)
    }

    /// The reported case: pause, resume, and then the cancellation
    /// of the old task arrives.
    @Test func lateMessageOldTaskCountsNot() {
        let alt = 7, new = 9
        #expect(!DownloadTask.applies(reported: alt, current: new))
        #expect(DownloadTask.applies(reported: new, current: new))
    }

    @Test func unknownTitleCounts() {
        #expect(DownloadTask.applies(reported: 3, current: nil))
    }
}
