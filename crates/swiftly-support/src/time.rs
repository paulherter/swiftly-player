//! Time as the logic sees it: seconds since 1970 plus a fixed UTC offset for calendar days.
//! The host passes both in (sans-I/O); nothing here reads a clock.

use serde::{Deserialize, Deserializer, Serializer};

/// Seconds since 1970-01-01 UTC (Swift `Date` as `.secondsSince1970`).
pub type Timestamp = f64;

/// One day in seconds (`SupportPrompt.day`).
pub const DAY: f64 = 86_400.0;

/// A day of the year, without the year. For windows that come back every year
/// (`MonthDay`, `LookSeason.swift:4-16`). Ordered by month, then day.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MonthDay {
    /// 1 to 12.
    pub month: u32,
    /// 1 to 31.
    pub day: u32,
}

impl MonthDay {
    /// A month and a day.
    pub const fn new(month: u32, day: u32) -> Self {
        Self { month, day }
    }
}

/// The Gregorian calendar of a device at a fixed offset from UTC. Swift passes a `Calendar`;
/// here the host hands the offset it has for the moment in question.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Calendar {
    /// Seconds east of UTC.
    pub utc_offset: i64,
}

impl Calendar {
    /// UTC.
    pub const UTC: Calendar = Calendar { utc_offset: 0 };

    /// A calendar at the given offset east of UTC.
    pub const fn fixed(utc_offset: i64) -> Self {
        Self { utc_offset }
    }

    fn local_days(self, ts: Timestamp) -> i64 {
        ((ts.floor() as i64) + self.utc_offset).div_euclid(86_400)
    }

    /// Year, month and day of a moment on this calendar.
    pub fn civil(self, ts: Timestamp) -> (i32, u32, u32) {
        civil_from_days(self.local_days(ts))
    }

    /// The calendar year of a moment.
    pub fn year(self, ts: Timestamp) -> i32 {
        self.civil(ts).0
    }

    /// Month and day of a moment.
    pub fn month_day(self, ts: Timestamp) -> MonthDay {
        let (_, month, day) = self.civil(ts);
        MonthDay { month, day }
    }

    /// The moment of a local date and time (`Calendar.date(from:)`).
    pub fn timestamp(self, year: i32, month: u32, day: u32, hour: u32, minute: u32) -> Timestamp {
        let days = days_from_civil(year, month, day);
        (days * 86_400 + i64::from(hour) * 3_600 + i64::from(minute) * 60 - self.utc_offset) as f64
    }
}

// Howard Hinnant's civil-date algorithms.
fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let y = i64::from(year) - i64::from(month <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = (yoe + era * 400 + i64::from(month <= 2)) as i32;
    (year, month, day)
}

/// Serde for a [`Timestamp`] the way Swift's `.secondsSince1970` writes it: a whole number
/// has no fraction (`1792281600`, not `1792281600.0`).
pub(crate) mod secs {
    use super::{Deserialize, Deserializer, Serializer, Timestamp};

    pub fn serialize<S: Serializer>(value: &Timestamp, s: S) -> Result<S::Ok, S::Error> {
        if value.fract() == 0.0 && value.abs() < 9.0e15 {
            s.serialize_i64(*value as i64)
        } else {
            s.serialize_f64(*value)
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Timestamp, D::Error> {
        f64::deserialize(d)
    }
}

pub(crate) mod opt_secs {
    use super::{Deserialize, Deserializer, Serializer, Timestamp};

    pub fn serialize<S: Serializer>(value: &Option<Timestamp>, s: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(v) => super::secs::serialize(v, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Timestamp>, D::Error> {
        Option::<f64>::deserialize(d)
    }
}

pub(crate) mod secs_list {
    use super::{Deserialize, Deserializer, Serializer, Timestamp};
    use serde::ser::SerializeSeq;

    struct One<'a>(&'a Timestamp);
    impl serde::Serialize for One<'_> {
        fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
            super::secs::serialize(self.0, s)
        }
    }

    pub fn serialize<S: Serializer>(value: &[Timestamp], s: S) -> Result<S::Ok, S::Error> {
        let mut seq = s.serialize_seq(Some(value.len()))?;
        for v in value {
            seq.serialize_element(&One(v))?;
        }
        seq.end()
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<Timestamp>, D::Error> {
        Vec::<f64>::deserialize(d)
    }
}
