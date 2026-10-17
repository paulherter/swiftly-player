import Testing
@testable import JellyfinKit

@Suite("VLC-Kennung")
struct VLCIdTests {

    /// This is how libVLC builds the ID: first character in the low-order byte.
    private func identifier(_ s: String) -> UInt32 {
        s.utf8.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    @Test("Niederwertiges Byte zuerst")
    func byteRailsEpisode() {
        #expect(VLCId.symbolText(identifier("mp4a")) == "mp4a")
        #expect(VLCId.symbolText(identifier("a52 ")) == "a52")
        // Read the other way round it would come out as "462h"; that was the bug.
        #expect(VLCId.symbolText(identifier("h264")) != "462h")
        #expect(VLCId.symbolText(0) == nil)
        #expect(VLCId.symbolText(0x0000_0001) == nil)
    }

    @Test("Videocodecs in Jellyfins Schreibweise")
    func videoCodecNames() {
        #expect(VLCId.videoCodecName(identifier("h264")) == "h264")
        #expect(VLCId.videoCodecName(identifier("hevc")) == "hevc")
        #expect(VLCId.videoCodecName(identifier("VP90")) == "vp9")
        #expect(VLCId.videoCodecName(identifier("av01")) == "av1")
        #expect(VLCId.videoCodecName(identifier("mp4v")) == "mpeg4")
        #expect(VLCId.videoCodecName(identifier("mp4a")) == nil)
    }
}
