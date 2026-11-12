import CoreMedia
import VideoToolbox

/// What the host tells the core about AV1 decoding: the core direct-plays AV1 Dolby Vision 10.0 on the own engine
/// only where this is true and asks the server for a transcode elsewhere. Probed once.
/// Mac only (M3 or newer): an iPhone with AV1 hardware showed green pictures on direct play of DV 10, so iPhone,
/// iPad and Apple TV keep the transcode until that is proven on a device.
enum HardwareAV1 {
    #if os(macOS)
    static let isSupported: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    #else
    static let isSupported = false
    #endif
}
