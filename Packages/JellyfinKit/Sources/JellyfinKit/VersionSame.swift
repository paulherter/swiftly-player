import Foundation

/// **Is the version over there newer than ours?**
///
/// Lives in the package and not with the Windows version because the GTK layer
/// has no test target: what is there cannot be checked. A rule like "1.0.10 is
/// newer than 1.0.9" should be checked, since as strings it would be older and
/// the error would only show at the tenth release.
public enum VersionComparison {

    /// Number by number, from the left. Missing places count as zero so "1.1" and
    /// "1.1.0" are the same.
    ///
    /// - Parameters:
    ///   - dort: the offered version, e.g. "1.0.4"
    ///   - hier: our own
    ///   - buildThere: the build number of the offered version, if the release names
    ///     one
    ///   - bauHier: our own build number
    public static func newer(there: String, here: String,
                             buildThere: Int? = nil, buildHere: Int = 0) -> Bool {
        let a = parts(there), b = parts(here)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        // **Same version, and still something newer may be over there.** A release
        // can appear again with the same number but a fix. Without the build number
        // the app would report "up to date".
        //
        // If the release names none, an equal number counts as the same state. That is
        // the safe side: better to not offer once than to offer every viewer an update
        // to what they already have.
        guard let buildThere else { return false }
        return buildThere > buildHere
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// **The build number from the text of a release.**
    ///
    /// The tag does not carry it: `v1.0.3` stays `v1.0.3` even if the same version
    /// goes out a second time. The text has it, as "build 7" or "Bau 7".
    ///
    /// The **largest** number named is searched, not the first: a text that tells
    /// the history of several builds names the older one first.
    public static func buildNumber(fromText text: String) -> Int? {
        let small = text.lowercased()
        var largest: Int?
        for word in ["build ", "bau "] {
            var since = small.startIndex
            while let fund = small.range(of: word, range: since..<small.endIndex) {
                since = fund.upperBound
                // **Whole word only.** "Umbau 12", "Ausbau 3", "rebuild 9" contain the same
                // sequence, and such a number in the text would offer every user an update to
                // what they already have, on every start.
                if fund.lowerBound > small.startIndex,
                   small[small.index(before: fund.lowerBound)].isLetter { continue }
                let digits = small[fund.upperBound...].prefix(while: \.isNumber)
                if let figure = Int(digits), figure > (largest ?? 0) { largest = figure }
            }
        }
        return largest
    }
}
