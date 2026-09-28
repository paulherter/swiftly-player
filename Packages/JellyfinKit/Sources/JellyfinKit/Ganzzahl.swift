/// **Double nach Int, ohne dass die App stirbt.**
///
/// `Int(x)` bricht das Programm ab, wenn `x` NaN, unendlich oder zu groß
/// ist. Auf 64 Bit fällt das kaum auf; auf Android mit `armeabi-v7a`
/// (32-Bit-Fernseher) ist `Int` aber nur 32 Bit breit — dort reichen ein
/// verrutschter `RunTimeTicks`-Wert des Servers (Laufzeit in Minuten über
/// 2^31) oder eine Bitrate aus einer Datei mit falscher Laufzeit
/// (über 2,1 Gbit/s), und der Swift-Kern reißt über JNI die ganze App mit.
///
/// NaN wird 0, alles außerhalb des Bereichs der Rand. Gerundet wird wie
/// `Int(x)`: zur Null hin.
extension Int {
    public init(gekappt wert: Double) {
        if wert.isNaN { self = 0 }
        else if wert >= Double(Int.max) { self = .max }
        else if wert <= Double(Int.min) { self = .min }
        else { self = Int(wert) }
    }
}
