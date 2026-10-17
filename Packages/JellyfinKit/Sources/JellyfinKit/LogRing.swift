import Foundation

/// **What a user can send us when something does not work.**
///
/// The file log exists only in the developer build. When someone reports
/// "loads forever", the line that says what it is stuck on is missing, and the
/// problem often cannot be reproduced on our side (own VPN, own network). So all
/// builds keep the last lines in memory, and the profile hands them out through
/// the share sheet ("Protokoll teilen").
///
/// Memory only: nothing lands in `Documents` or in a backup, and after a restart
/// it is gone. Whoever shares must have reproduced the problem in the same
/// session; the file says so as well when it is empty.
public final class LogRing: @unchecked Sendable {

    public static let shared = LogRing()

    private let barrier = NSLock()
    private var rows: [(time: Date, text: String)] = []
    private let limit: Int

    public init(limit: Int = 4000) {
        self.limit = limit
    }

    /// Redaction happens **on entry**, not only on sharing, so a credential never
    /// sits in memory in plain text either.
    public func append(_ text: String, now: Date = Date()) {
        let clean = LogRedaction.text(text)
        barrier.lock(); defer { barrier.unlock() }
        rows.append((now, clean))
        // Trim in batches, not by shifting one line at every entry.
        if rows.count > limit + limit / 8 {
            rows.removeFirst(rows.count - limit)
        }
    }

    /// The lines of the last `seconds`, oldest first, with time of day.
    public func excerpt(seconds: TimeInterval = 3600, now: Date = Date()) -> [String] {
        let cutoffTime = now.addingTimeInterval(-seconds)
        barrier.lock()
        let pick = rows.filter { $0.time >= cutoffTime }
        barrier.unlock()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "HH:mm:ss.SSS"
        return pick.map { "\(format.string(from: $0.time)) \($0.text)" }
    }
}

/// **Credentials in free text.**
///
/// ``Foundation/URL/withoutSecret`` only works where an address exists as a
/// `URL`. But VLC and the system write addresses into their own messages as
/// text, where the token used to appear in plain text. The same names as there,
/// plus the `Authorization` header and credentials in the address
/// (`http://name:passwort@…`).
public enum LogRedaction {

    private static let names = "api_key|apikey|x-emby-token|x-mediabrowser-token|token|accesstoken|access_token|secret|pw|password"

    nonisolated(unsafe) private static let muster: [(NSRegularExpression, String)] = [
        // name="value": Jellyfin's Authorization header
        (try! NSRegularExpression(pattern: "(?i)\\b(\(names))(\\s*[=:]\\s*)\"[^\"]*\""), "$1$2\"…\""),
        // name=value: query values and header lines
        (try! NSRegularExpression(pattern: "(?i)\\b(\(names))(\\s*[=:]\\s*)[^&\\s\"',;)]+"), "$1$2…"),
        // scheme://name:passwort@
        (try! NSRegularExpression(pattern: "(?i)([a-z][a-z0-9+.-]*://)[^/\\s@:]+:[^/\\s@]+@"), "$1…@"),
    ]

    public static func text(_ raw: String) -> String {
        var text = raw
        for (rule, substitute) in muster {
            let section = NSRange(text.startIndex..., in: text)
            text = rule.stringByReplacingMatches(in: text, range: section, withTemplate: substitute)
        }
        return text
    }
}
