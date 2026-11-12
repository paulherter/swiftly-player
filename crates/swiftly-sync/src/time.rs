//! Server timestamps. Times everywhere in this crate are `f64` seconds since 1970 (UTC).

pub use swiftly_model::parse_timestamp;

/// `SyncPlay.timeText`: milliseconds, UTC, with `Z` (`2026-09-24T10:00:01.500Z`).
pub fn time_text(seconds: f64) -> String {
    let total_ms = (seconds * 1000.0).round();
    if !total_ms.is_finite() {
        return "1970-01-01T00:00:00.000Z".to_string();
    }
    let total_ms = total_ms as i64;
    let days = total_ms.div_euclid(86_400_000);
    let ms_of_day = total_ms.rem_euclid(86_400_000);
    let (y, m, d) = civil_from_days(days);
    let (h, mi, s, ms) = (
        ms_of_day / 3_600_000,
        ms_of_day / 60_000 % 60,
        ms_of_day / 1000 % 60,
        ms_of_day % 1000,
    );
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{ms:03}Z")
}

// Howard Hinnant's days -> civil date.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// `SyncPlay.timeRead`: with or without fractional seconds.
pub fn time_read(text: &str) -> Option<f64> {
    parse_timestamp(text)
}
