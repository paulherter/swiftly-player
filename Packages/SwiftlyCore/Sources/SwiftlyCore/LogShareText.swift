import Foundation

/// The "Share log" file as the core words it (`logShare*`): version line, system line, `Stand`, the lines of
/// the last hour or the "no lines" note. The host keeps the ring it collects lines in and the share sheet.
public enum LogShareText {
    public static let fileName = logShareFileName()

    public static func text(version: String, system: String, now: Date, excerpt: [String]) -> String {
        logShareText(
            versionLine: logShareVersionLineApple(version: version), system: system,
            stamp: logShareStamp(unixSeconds: now.timeIntervalSince1970), excerptLines: excerpt)
    }

    public static func systemMacOS(_ v: OperatingSystemVersion) -> String {
        logShareSystemMacos(major: Int64(v.majorVersion), minor: Int64(v.minorVersion), patch: Int64(v.patchVersion))
    }

    public static func systemIOS(_ v: OperatingSystemVersion, model: String) -> String {
        logShareSystemIos(major: Int64(v.majorVersion), minor: Int64(v.minorVersion), patch: Int64(v.patchVersion), model: model)
    }
}
