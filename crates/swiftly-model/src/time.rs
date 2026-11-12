/// Ticks (100 ns) from seconds, without ever trapping
/// (`JellyfinClient.ticks(fromSeconds:)`, JellyfinKit/PlaybackReporting.swift:16).
///
/// NaN, infinity and anything not above zero is 0; huge values are capped just
/// below `i64::MAX / 10^7`.
pub fn ticks_from_seconds(seconds: f64) -> i64 {
    if !seconds.is_finite() || seconds <= 0.0 {
        return 0;
    }
    (seconds.min(900_000_000_000.0) * 10_000_000.0) as i64
}

/// Seconds from ticks (PlaybackReporting.swift:22).
pub fn seconds_from_ticks(ticks: i64) -> f64 {
    ticks as f64 / 10_000_000.0
}

/// Foundation's Gregorian calendar (what `ISO8601DateFormatter` uses) counts dates before
/// 1582-10-15 in the Julian calendar.
fn is_julian(y: i64, m: i64, d: i64) -> bool {
    (y, m, d) < (1582, 10, 15)
}

/// Days since 1970-01-01 for a Julian-calendar date (`JDN - 2440588`).
fn days_from_julian(y: i64, m: i64, d: i64) -> i64 {
    let a = (14 - m) / 12;
    let y2 = y + 4800 - a;
    let m2 = m + 12 * a - 3;
    d + (153 * m2 + 2) / 5 + 365 * y2 + y2.div_euclid(4) - 32_083 - 2_440_588
}

/// Days since 1970-01-01 for a civil date (Gregorian, Julian before 1582-10-15).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    if is_julian(y, m, d) {
        return days_from_julian(y, m, d);
    }
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn days_in_month(y: i64, m: i64) -> i64 {
    let julian_year = y < 1582;
    match m {
        2 if (y % 4 == 0 && (julian_year || y % 100 != 0)) || (!julian_year && y % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn digits(b: &[u8], from: usize, n: usize) -> Option<i64> {
    let s = b.get(from..from + n)?;
    if !s.iter().all(u8::is_ascii_digit) {
        return None;
    }
    s.iter()
        .try_fold(0i64, |a, d| Some(a * 10 + i64::from(d - b'0')))
}

/// Reads Jellyfin's timestamps into seconds since 1970 (UTC).
///
/// Port of `TimestampFormat.read` (JellyfinKit/Timestamp.swift:19): internet
/// date-time with or without fractional seconds, so both
/// `2026-09-03T14:10:09.2201736Z` (seven digits) and `2026-09-03T14:10:09Z`
/// read. A zone offset `+HH:MM` is honoured. Anything else is `None`.
pub fn parse_timestamp(text: &str) -> Option<f64> {
    let b = text.as_bytes();
    let (y, mo, d) = (digits(b, 0, 4)?, digits(b, 5, 2)?, digits(b, 8, 2)?);
    if b.get(4) != Some(&b'-') || b.get(7) != Some(&b'-') || b.get(10) != Some(&b'T') {
        return None;
    }
    let (h, mi, s) = (digits(b, 11, 2)?, digits(b, 14, 2)?, digits(b, 17, 2)?);
    if b.get(13) != Some(&b':') || b.get(16) != Some(&b':') {
        return None;
    }
    if !(1..=12).contains(&mo) || d < 1 || d > days_in_month(y, mo) || h > 23 || mi > 59 || s > 59 {
        return None;
    }
    let mut at = 19;
    let mut fraction = 0.0;
    if b.get(at) == Some(&b'.') {
        let start = at + 1;
        let mut end = start;
        while b.get(end).is_some_and(u8::is_ascii_digit) {
            end += 1;
        }
        if end == start {
            return None;
        }
        fraction = format!("0.{}", &text[start..end]).parse::<f64>().ok()?;
        at = end;
    }
    let offset = match b.get(at)? {
        b'Z' if at + 1 == b.len() => 0,
        sign @ (b'+' | b'-') => {
            // `+HH:MM`, `+HHMM` and `+HH` all read.
            let (oh, om, len) = if b.get(at + 3) == Some(&b':') {
                (digits(b, at + 1, 2)?, digits(b, at + 4, 2)?, 6)
            } else if at + 3 == b.len() {
                (digits(b, at + 1, 2)?, 0, 3)
            } else {
                (digits(b, at + 1, 2)?, digits(b, at + 3, 2)?, 5)
            };
            if at + len != b.len() || oh > 23 || om > 59 {
                return None;
            }
            let secs = oh * 3600 + om * 60;
            if *sign == b'+' { secs } else { -secs }
        }
        _ => return None,
    };
    let whole = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s - offset;
    Some(whole as f64 + fraction)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticks_without_crash() {
        assert_eq!(ticks_from_seconds(f64::NAN), 0);
        assert_eq!(ticks_from_seconds(f64::INFINITY), 0);
        assert_eq!(ticks_from_seconds(f64::NEG_INFINITY), 0);
        assert_eq!(ticks_from_seconds(-5.0), 0);
        assert!(ticks_from_seconds(1e300) > 0);
        assert_eq!(ticks_from_seconds(90.0), 900_000_000);
        assert_eq!(ticks_from_seconds(1.5), 15_000_000);
        assert_eq!(seconds_from_ticks(15_000_000), 1.5);
    }

    #[test]
    fn timestamps() {
        assert_eq!(parse_timestamp("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(parse_timestamp("2000-03-01T00:00:00Z"), Some(951_868_800.0));
        let seven = parse_timestamp("2026-09-03T14:10:09.2201736Z").unwrap();
        let none = parse_timestamp("2026-09-03T14:10:09Z").unwrap();
        assert!((seven - none - 0.2201736).abs() < 1e-3);
        assert_eq!(
            parse_timestamp("2026-09-03T16:10:09+02:00"),
            parse_timestamp("2026-09-03T14:10:09Z")
        );
        assert_eq!(parse_timestamp("2026-02-30T00:00:00Z"), None);
        assert_eq!(parse_timestamp("2026-09-03"), None);
        assert_eq!(parse_timestamp("nonsense"), None);
    }
}
