import Testing
@testable import JellyfinKit

@Suite("VLC-Kennung")
struct VLCKennungTests {

    /// So baut libVLC die Kennung: erstes Zeichen im niederwertigen Byte.
    private func kennung(_ s: String) -> UInt32 {
        s.utf8.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    @Test("Niederwertiges Byte zuerst")
    func bytereihenfolge() {
        #expect(VLCKennung.zeichen(kennung("mp4a")) == "mp4a")
        #expect(VLCKennung.zeichen(kennung("a52 ")) == "a52")
        // Andersherum gelesen käme „462h" heraus — das war der Fehler.
        #expect(VLCKennung.zeichen(kennung("h264")) != "462h")
        #expect(VLCKennung.zeichen(0) == nil)
        #expect(VLCKennung.zeichen(0x0000_0001) == nil)
    }

    @Test("Videocodecs in Jellyfins Schreibweise")
    func videocodecs() {
        #expect(VLCKennung.videocodec(kennung("h264")) == "h264")
        #expect(VLCKennung.videocodec(kennung("hevc")) == "hevc")
        #expect(VLCKennung.videocodec(kennung("VP90")) == "vp9")
        #expect(VLCKennung.videocodec(kennung("av01")) == "av1")
        #expect(VLCKennung.videocodec(kennung("mp4v")) == "mpeg4")
        #expect(VLCKennung.videocodec(kennung("mp4a")) == nil)
    }
}
