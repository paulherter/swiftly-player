/// **Double to Int without crashing the app.**
///
/// `Int(x)` traps if `x` is NaN, infinite or too large. On 64 bit that rarely
/// shows; on Android `armeabi-v7a` (32-bit TVs) `Int` is only 32 bits wide, and
/// a stray `RunTimeTicks` value from the server (runtime above 2^31 minutes) or
/// a bitrate from a file with a wrong runtime (above 2.1 Gbit/s) is enough for
/// the Swift core to take the whole app down via JNI.
///
/// NaN becomes 0, anything out of range the limit. Rounding is like `Int(x)`:
/// toward zero.
extension Int {
    public init(capped value: Double) {
        if value.isNaN { self = 0 }
        else if value >= Double(Int.max) { self = .max }
        else if value <= Double(Int.min) { self = .min }
        else { self = Int(value) }
    }
}
