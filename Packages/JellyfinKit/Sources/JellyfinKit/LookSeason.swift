import Foundation

/// **A day of the year, without the year.** For windows that come back every year.
public struct MonthDay: Sendable, Hashable, Comparable {
    public let month: Int
    public let day: Int

    public init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }

    public static func < (lhs: MonthDay, rhs: MonthDay) -> Bool {
        (lhs.month, lhs.day) < (rhs.month, rhs.day)
    }
}

/// **When a seasonal look is offered and its effects run**: from one day to another, both
/// whole days, every year. A window may run over New Year (1 Dec to 2 Jan).
///
/// The device clock is the source. For a free gift that is enough: someone who sets the
/// clock to October sees bats in March, and nobody loses anything. A window that decides
/// over something paid needs a trusted time instead.
public struct LookSeason: Sendable, Hashable {
    /// Stable part of the stored offer ids (`halloween-2026`).
    public let id: String
    public let from: MonthDay
    /// The last day, included up to its end.
    public let to: MonthDay

    public init(id: String, from: MonthDay, to: MonthDay) {
        self.id = id
        self.from = from
        self.to = to
    }

    /// 24 October to 2 November.
    public static let halloween = LookSeason(id: "halloween", from: MonthDay(month: 10, day: 24),
                                             to: MonthDay(month: 11, day: 2))

    public var crossesNewYear: Bool { to < from }

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        let today = MonthDay(month: parts.month ?? 1, day: parts.day ?? 1)
        if crossesNewYear { return today >= from || today <= to }
        return today >= from && today <= to
    }

    /// The year the window containing `date` started in, for the once-per-season ids.
    /// `nil` outside the window.
    public func seasonYear(at date: Date, calendar: Calendar = .current) -> Int? {
        guard isActive(at: date, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let today = MonthDay(month: parts.month ?? 1, day: parts.day ?? 1)
        return crossesNewYear && today <= to ? year - 1 : year
    }

    /// The start of the next window after `date` (midnight of its first day). Inside a
    /// window this is next year's start.
    public func nextStart(after date: Date, calendar: Calendar = .current) -> Date {
        let year = calendar.component(.year, from: date)
        for candidate in [year, year + 1] {
            if let start = calendar.date(from: DateComponents(year: candidate, month: from.month, day: from.day)),
               start > date {
                return start
            }
        }
        return date
    }
}
