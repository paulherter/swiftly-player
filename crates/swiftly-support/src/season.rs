//! When a seasonal look is offered (`LookSeason.swift`): whole days, every year, a window may
//! run over New Year. The device clock is the source.

use crate::time::{Calendar, MonthDay, Timestamp};

/// A yearly window from one day to another, both whole days.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LookSeason {
    /// Stable part of the stored offer ids (`halloween-2026`).
    pub id: &'static str,
    /// First day.
    pub from: MonthDay,
    /// Last day, included up to its end.
    pub to: MonthDay,
}

impl LookSeason {
    /// 24 October to 2 November.
    pub const HALLOWEEN: LookSeason = LookSeason {
        id: "halloween",
        from: MonthDay::new(10, 24),
        to: MonthDay::new(11, 2),
    };

    /// A window that runs over New Year (1 Dec to 2 Jan).
    pub fn crosses_new_year(&self) -> bool {
        self.to < self.from
    }

    /// Whether the day of `date` is inside the window.
    pub fn is_active(&self, date: Timestamp, calendar: Calendar) -> bool {
        let today = calendar.month_day(date);
        if self.crosses_new_year() {
            return today >= self.from || today <= self.to;
        }
        today >= self.from && today <= self.to
    }

    /// The year the window containing `date` started in; `None` outside the window.
    pub fn season_year(&self, date: Timestamp, calendar: Calendar) -> Option<i32> {
        if !self.is_active(date, calendar) {
            return None;
        }
        let year = calendar.year(date);
        let today = calendar.month_day(date);
        Some(if self.crosses_new_year() && today <= self.to {
            year - 1
        } else {
            year
        })
    }

    /// Midnight of the first day of the next window after `date`; inside a window, next year's.
    pub fn next_start(&self, date: Timestamp, calendar: Calendar) -> Timestamp {
        let year = calendar.year(date);
        for candidate in [year, year + 1] {
            let start = calendar.timestamp(candidate, self.from.month, self.from.day, 0, 0);
            if start > date {
                return start;
            }
        }
        date
    }
}
