// One place for how Swiftly asks the engine to deliver lossless surround audio. The app and the
// headless probe both call it, so the probe tests what the app really does.
import AetherEngine

extension LoadOptions {
    /// - TrueHD Atmos and DTS:X: the engine renders objects and heights into a 7.1.4 bed and hands
    ///   it to the system (lossless 24-bit PCM; Apple TV wraps it as Dolby MAT for an Atmos receiver,
    ///   iOS plays Spatial Audio, AirPlay gets APAC). Needs the trait in Package.swift; plain
    ///   TrueHD / DTS-HD MA 7.1 without objects keeps the channel bridge below.
    /// - Channel bridge: Apple TV cannot bitstream TrueHD or DTS-HD. On tvOS the safe, never silent
    ///   choice is E-AC-3 5.1 (works behind ARC soundbars and receivers); FLAC 7.1 would drop to
    ///   stereo behind a legacy ARC link, and the engine cannot tell the links apart. iPhone, iPad
    ///   and Mac decode the audio themselves, so they get FLAC 7.1.
    public mutating func applySwiftlyAudioPolicy() {
        objectAudioRendering = .render(.l714)
        #if os(tvOS)
        audioBridgeMode = .surroundCompat
        #else
        audioBridgeMode = .lossless
        #endif
    }
}
